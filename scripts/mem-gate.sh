#!/usr/bin/env bash
# dreamteam — pre-spawn MEMORY GATE  (PreToolUse hook, matcher: Agent|Task)
#
# THE prevention for the 2026-06-30 OOM cascade. Agent-spawning tool calls route
# through PreToolUse exactly like Bash/Edit do. exit 2 BLOCKS the spawn and feeds
# the stderr message back to the orchestrator — a deterministic gate the model
# cannot rationalize past (unlike a SKILL.md instruction).
#
# Reads the spawn request on stdin, measures live RAM + agent count, and blocks if
# there isn't headroom for another ~400 MB agent PLUS a balloon reserve. The balloon
# reserve is non-negotiable: 06-30 had TWO agents balloon at once (3.7 + 3.4 GB).
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
# shellcheck source=/dev/null
[ -f "$ROOT/scripts/lib.sh" ] && . "$ROOT/scripts/lib.sh"

# --- read hook input ---
INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac
# the reservation TOKEN (#256 r3 item 3): this session's id and the Agent call's subagent_type, which the lane's
# SubagentStart hook sees again as session_id and agent_type
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "-"' 2>/dev/null || echo -)"
ATYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // .tool_input.name // "agent"' 2>/dev/null || echo agent)"
RSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reservation.sh"

# --- config (defaults baked in so it works before config.json exists) ---
# A config the gate cannot trust is a BLOCK (exit 2), never an admit (xreview #230 r1): the helper must load, the merged
# config must be one object, and every number must be a bounded non-negative integer before any arithmetic.
invalid() { echo "🚫 DREAMTEAM MEMORY GATE — spawn blocked: $1 (config $CFG + config.<host>.json; fix it, or remove the overlay)" >&2; exit 2; }
# the config with this host's overlay (config.<host>.json) deep-merged over it: scripts/lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" 2>/dev/null || invalid "scripts/lib/config.sh did not load"
CFGJSON="$(dreamteam_config "$CFG")" || invalid "this host's overlay $(basename "${CFG%.json}").$(dreamteam_host).json exists but is not one readable JSON object"
jq -e 'type == "object"' <<<"$CFGJSON" >/dev/null 2>&1 || invalid "the merged config is not one JSON object"
MAXMB=10000000
STATE_ERR=$(mktemp -p "${XDG_RUNTIME_DIR:-${TMPDIR:-$HOME/.cache}}" .memgate.XXXXXX 2>/dev/null || mktemp) || invalid "no temp file"
trap 'rm -f "$STATE_ERR"' EXIT
# the shared validated readers (scripts/lib/config.sh): absent → default; present but invalid (false, null, "", "3000",
# negative, fractional, oversized: xreview #230 r2) → exit 2
getcfg() { local v e; v=$(dreamteam_int "$CFGJSON" memory "$1" "$2" 2>"$STATE_ERR") || { e=$(cat "$STATE_ERR"); invalid "$e"; }; printf '%s' "$v"; }
getbool() { local v e; v=$(dreamteam_bool "$CFGJSON" "$1" "$2" "$3" 2>"$STATE_ERR") || { e=$(cat "$STATE_ERR"); invalid "$e"; }; printf '%s' "$v"; }
PER_AGENT=$(getcfg perAgentMB 400) || exit 2
HOST_RESERVE=$(getcfg hostReserveMB 6000) || exit 2
BALLOON=$(getcfg balloonReserveMB 8000) || exit 2
MIN_AVAIL=$(getcfg minAvailableMB 8000) || exit 2
MIN_SWAP_FREE=$(getcfg minSwapFreeMB 0) || exit 2
MAX_AGENTS=$(getcfg maxAgents 30) || exit 2
[ "$PER_AGENT" -ge 1 ] || invalid "memory.perAgentMB is 0"
SCOPE_ONLY=$(getbool memory scopeToDreamteam false) || exit 2

# Local-model lane reserve (#37): when the ollama lane is ARMED (.local.enabled ==
# true), hold back reserveMB for the resident model. Its RSS/VRAM is invisible to
# this gate (which counts only claude procs) and the load is latent/bursty, so we
# reserve whether or not the model is currently loaded — exactly as BALLOON reserves
# for post-admission growth. ==false-safe (only a literal true arms it); zero effect
# when the lane is off (the default).
getlocal() { local v e; v=$(dreamteam_int "$CFGJSON" local "$1" "$2" 2>"$STATE_ERR") || { e=$(cat "$STATE_ERR"); invalid "$e"; }; printf '%s' "$v"; }
LA=$(getbool local enabled false) || exit 2; [ "$LA" = true ] && LOCAL_ARMED=1 || LOCAL_ARMED=0
LOCAL_RESERVE=$(getlocal reserveMB 9000) || exit 2
if [ "$LOCAL_ARMED" = 1 ]; then LOCAL_EFF=$LOCAL_RESERVE; LOCAL_NOTE="  local_reserve=${LOCAL_RESERVE} (ollama lane armed)"; else LOCAL_EFF=0; LOCAL_NOTE=""; fi
# the scope exemption only AFTER every admission key validated (xreview #230 r5): an invalid config blocks whether or not
# the gate would otherwise stand aside, so the gate, mem-budget and the dashboard agree on "invalid"
if [ "$SCOPE_ONLY" = "true" ] && [ ! -f "$STATE/active" ]; then exit 0; fi

# Balloon reserve is sized for ONE team's build spikes; scale by scopes actually
# carrying weight (>=2GiB) — 2026-08-15 OOM: two teams' rustc storms ballooned
# concurrently, filled swap, and oomd killed tmux.service. Mirrors mem-budget.sh.
NLANES=0
for sc in $(systemctl --user list-units 'dreamteam-*.scope' --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
  mc=$(systemctl --user show "$sc" -p MemoryCurrent --value 2>/dev/null); mc=${mc//[!0-9]/}
  [ -n "$mc" ] && [ "$mc" -ge 2147483648 ] && NLANES=$((NLANES+1))
done
[ "$NLANES" -gt 1 ] && BALLOON=$(( BALLOON * NLANES ))

# --- the host lock (dreamteam #256 r1 item 3): one lock per host, shared with a GPU claim's probe-to-record window
#     (scripts/lib/gpu_fleet.py HostLock takes the same file over ssh). Held elsewhere past the wait → BLOCK (fail
#     closed): a measurement never races a claim. Seams: DREAMTEAM_HOST_LOCK (path), DREAMTEAM_HOST_LOCK_WAIT (s, 5).
HLOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; HLOCK_WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
mkdir -p "$(dirname "$HLOCK")" 2>/dev/null
( : >>"$HLOCK" ) 2>/dev/null || invalid "cannot open the host lock $HLOCK"
exec 9>>"$HLOCK"
flock -w "$HLOCK_WAIT" 9 || invalid "host lock $HLOCK not taken within ${HLOCK_WAIT}s (a GPU claim is probing this host, or another lane is starting): retry"
# --- outstanding reservations (#256 r3 item 1): lanes already admitted whose processes are not yet visible. Read
#     under the lock; their MB comes off the available RAM and their count goes on the agent count below, so two
#     gates in a row cannot both pass on the same free memory. Unreadable → BLOCK.
RESV_OUT=$(bash "$RSV" outstanding --locked 2>"$STATE_ERR") || invalid "cannot read the outstanding reservations ($(head -c 160 "$STATE_ERR" 2>/dev/null))"
read -r RESV_MB RESV_N <<<"$RESV_OUT"
dreamteam_uint "${RESV_MB:-x}" "$MAXMB" && dreamteam_uint "${RESV_N:-x}" 100000 || invalid "outstanding reservations unreadable ('${RESV_MB:-}' '${RESV_N:-}')"

# --- measure RAM (instant — this is the real OOM guard, runs BEFORE the count) ---
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
SWAP_FREE=$(free -m | awk '/^Swap:/{print $4}')
# the measurements too: a reading that is not a number is a block, never a comparison error that falls through
dreamteam_uint "${AVAIL:-x}" "$MAXMB" || invalid "free -m gave no readable available memory ('$AVAIL')"
AVAIL=$(( AVAIL - RESV_MB )); [ "$AVAIL" -ge 0 ] || AVAIL=0     # reserved RAM is as good as used (#256 r3 item 1)
if [ "$MIN_SWAP_FREE" -gt 0 ]; then dreamteam_uint "${SWAP_FREE:-x}" "$MAXMB" || invalid "free -m gave no readable swap free ('$SWAP_FREE')"; fi
HEADROOM=$(( AVAIL - HOST_RESERVE - BALLOON - LOCAL_EFF ))
BUDGET=$(( HEADROOM / PER_AGENT )); [ "$BUDGET" -lt 0 ] && BUDGET=0

block() {
  {
    echo "🚫 DREAMTEAM MEMORY GATE — spawn blocked: $1"
    echo "   avail=${AVAIL}MiB (after ${RESV_MB}MiB reserved by ${RESV_N} admitted, not yet running)  swap_used=${SWAP_USED}MiB  agents=${2:-not counted (RAM block fires before the count)}  budget=${BUDGET} more"
    echo "   (per_agent=${PER_AGENT}  host_reserve=${HOST_RESERVE}  balloon_reserve=${BALLOON}  floor=${MIN_AVAIL}${LOCAL_NOTE})"
    echo "   Recover headroom: let in-flight agents finish + merge, reuse an idle teammate"
    echo "   (/dreamteam-roster), close Waydroid (waydroid session stop) + the browser, or"
    echo "   batch this agent into a later wave. Re-check: /dreamteam-status"
  } >&2
  exit 2
}

# RAM-based blocks first (don't wait on the agent count for the real guard):
[ "$AVAIL" -lt "$MIN_AVAIL" ] && block "only ${AVAIL}MiB RAM available (< ${MIN_AVAIL}MiB floor)."
# swap free (a full zram looks like nothing to MemAvailable; the next balloon then meets the OOM killer). 0 = no floor.
[ "$MIN_SWAP_FREE" -gt 0 ] && [ "$SWAP_FREE" -lt "$MIN_SWAP_FREE" ] && block "only ${SWAP_FREE}MiB swap free (< ${MIN_SWAP_FREE}MiB swap floor)."
[ "$BUDGET" -le 0 ]          && block "no budget for another agent (need ${PER_AGENT}+${BALLOON}MiB headroom)."

# Count cap last — uses `claude agents --json` (real status), pgrep fallback (see lib.sh).
if command -v count_agents >/dev/null 2>&1; then NAGENTS=$(count_agents); else
  NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || true); NAGENTS=${NAGENTS:-0}; fi
NAGENTS=$(( NAGENTS + RESV_N ))                                   # reserved agents hold a slot too (#256 r3 item 1)
[ "$NAGENTS" -ge "$MAX_AGENTS" ] && block "${NAGENTS} agents already running or reserved (cap ${MAX_AGENTS}; ${RESV_N} reserved, not yet running)." "$NAGENTS"

# --- the reservation (dreamteam #256 r2): admitted, and still under the host lock, so a GPU claim that locks next
#     sees this lane's budget before its process exists. The lane's SubagentStart marks it started (hooks.json) and its
#     SubagentStop releases it; unstarted, it expires in 90 s (scripts/reservation.sh LIFECYCLE). Cannot write it →
#     BLOCK: an unreserved start is the race this closes.
bash "$RSV" add "$PER_AGENT" 90 "$SESSION" "$ATYPE" --locked >/dev/null || invalid "cannot write the lane reservation (scripts/reservation.sh beside this gate)"
exit 0
