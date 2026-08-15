#!/usr/bin/env bash
# dreamteam — memory budget reporter (shared by the gate + /dreamteam-status).
# Prints the live budget so the orchestrator can size a wave before spawning.
# Usage: mem-budget.sh            # human summary
#        mem-budget.sh --max      # just the integer MAX_AGENTS (for scripting)
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
# shellcheck source=/dev/null
[ -f "$ROOT/scripts/lib.sh" ] && . "$ROOT/scripts/lib.sh"
getcfg() { jq -r --arg k "$1" --arg d "$2" ".memory[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
getscope() { jq -r --arg k "$1" --arg d "$2" ".scope[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
PER_AGENT=$(getcfg perAgentMB 400); HOST_RESERVE=$(getcfg hostReserveMB 6000)
BALLOON=$(getcfg balloonReserveMB 8000); MIN_AVAIL=$(getcfg minAvailableMB 8000)
MAX_AGENTS=$(getcfg maxAgents 30)

# Local-model lane reserve (#37) — held back only when the ollama lane is armed
# (.local.enabled == true); its resident model is invisible to the claude-proc
# accounting. ==false-safe. Default 9000 MUST match mem-gate.sh + dashboard-data.sh
# (test-roster.sh defaults-agreement guard enforces this).
getlocal() { jq -r --arg k "$1" --arg d "$2" ".local[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
LOCAL_ARMED=$(jq -r 'if .local.enabled == true then 1 else 0 end' "$CFG" 2>/dev/null || echo 0)
LOCAL_RESERVE=$(getlocal reserveMB 9000); LOCAL_RESERVE=${LOCAL_RESERVE//[!0-9]/}; [ -n "$LOCAL_RESERVE" ] || LOCAL_RESERVE=9000
[ "$LOCAL_ARMED" = 1 ] && LOCAL_EFF=$LOCAL_RESERVE || LOCAL_EFF=0

# Balloon reserve is sized for ONE team's build spikes. N teams can balloon
# CONCURRENTLY — 2026-08-15 10:16 OOM: emberburrito + burrito-fw rustc storms
# filled swap and oomd killed tmux.service (every session at once). Count
# scopes actually carrying weight (>=2GiB) and scale the reserve.
NLANES=0
for sc in $(systemctl --user list-units 'dreamteam-*.scope' --state=active --no-legend 2>/dev/null | awk '{print $1}'); do
  mc=$(systemctl --user show "$sc" -p MemoryCurrent --value 2>/dev/null); mc=${mc//[!0-9]/}
  [ -n "$mc" ] && [ "$mc" -ge 2147483648 ] && NLANES=$((NLANES+1))
done
[ "$NLANES" -gt 1 ] && BALLOON=$(( BALLOON * NLANES ))

AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
# agent count via `claude agents --json` (real status), pgrep fallback — see lib.sh
if command -v count_agents >/dev/null 2>&1; then NAGENTS=$(count_agents); else
  NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || true); NAGENTS=${NAGENTS:-0}; fi
# BUDGET = how many MORE agents fit in free RAM (AVAIL already excludes what
# live agents consume — same semantics as mem-gate.sh). The old formula
# subtracted NAGENTS from this a second time, reporting "room: 0" on a box
# with 19 GiB free (2026-08-15). Count cap is enforced separately.
BUDGET=$(( (AVAIL - HOST_RESERVE - BALLOON - LOCAL_EFF) / PER_AGENT )); [ "$BUDGET" -lt 0 ] && BUDGET=0
ROOM_COUNT=$(( MAX_AGENTS - NAGENTS )); [ "$ROOM_COUNT" -lt 0 ] && ROOM_COUNT=0
ROOM=$(( BUDGET < ROOM_COUNT ? BUDGET : ROOM_COUNT ))
[ "$AVAIL" -lt "$MIN_AVAIL" ] && ROOM=0
CAP=$ROOM  # kept for consumers: --max = spawnable THIS WAVE (matches the gate)

if [ "${1:-}" = "--max" ]; then echo "$CAP"; exit 0; fi

# Local-lane reserve line — only rendered when the ollama lane is armed (#37).
LOCAL_LINE=""
[ "$LOCAL_ARMED" = 1 ] && LOCAL_LINE=$'\n'"  local reserve : ${LOCAL_RESERVE} MiB   (ollama lane armed — #37; held for the resident model)"

# Team scope footprint — only when the auto-containment scope is live. MemoryCurrent
# is the TRUE footprint: it includes the gradle/JVM child procs the claude-proc
# accounting is blind to (the 2026-07-01 16:06 oomd root cause; postmortem §5). Same
# MemoryCurrent sanitize as statusline.sh. Computed AFTER the --max fast path so the
# hot spawn gate stays untouched; renders nothing when the scope is inactive.
SCOPE_SUFFIX=""
DT_SCOPE="$(command -v dreamteam_scope_name >/dev/null 2>&1 && dreamteam_scope_name || echo dreamteam-agents)"
if systemctl --user is-active --quiet "$DT_SCOPE.scope" 2>/dev/null; then
  SMC=$(systemctl --user show "$DT_SCOPE.scope" -p MemoryCurrent --value 2>/dev/null); SMC=${SMC//[!0-9]/}
  S_HIGH=$(getscope memoryHigh 20G); S_MAX=$(getscope memoryMax 24G)
  if [ -n "$SMC" ] && [ "${#SMC}" -le 15 ]; then CUR="$(( SMC / 1048576 )) MiB current"; else CUR="? MiB current"; fi
  SCOPE_SUFFIX=$'\n'"  team scope    : ${CUR} / high ${S_HIGH} / max ${S_MAX}   (${DT_SCOPE}.scope, true footprint incl. child procs)"
fi

waydroid_note=""
command -v waydroid >/dev/null 2>&1 && waydroid status 2>/dev/null | grep -q 'Session.*RUNNING' \
  && waydroid_note="  ⚠ Waydroid is RUNNING — it consumes RAM AND poisons OOM victim selection (Android oom_score_adj 900+). 'waydroid session stop' before a large run."

cat <<EOF
dreamteam memory budget
  available RAM : ${AVAIL} MiB        swap used: ${SWAP_USED} MiB
  live agents   : ${NAGENTS}
  per-agent plan: ${PER_AGENT} MiB    host reserve: ${HOST_RESERVE} MiB    balloon reserve: ${BALLOON} MiB$([ "$NLANES" -gt 1 ] && printf ' (× %s active build lanes)' "$NLANES")${LOCAL_LINE}
  ─────────────────────────────────────────────
  room this wave: ${ROOM} more   (= min(memory budget ${BUDGET} more, count-cap remainder ${ROOM_COUNT} of ${MAX_AGENTS}))${SCOPE_SUFFIX}
${waydroid_note:+$waydroid_note}
EOF
[ "$AVAIL" -lt "$MIN_AVAIL" ] && echo "  🚫 below ${MIN_AVAIL} MiB floor — do NOT spawn; recover headroom first."
exit 0
