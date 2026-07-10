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

# --- config (defaults baked in so it works before config.json exists) ---
getcfg() { jq -r --arg k "$1" --arg d "$2" ".memory[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
PER_AGENT=$(getcfg perAgentMB 400)
HOST_RESERVE=$(getcfg hostReserveMB 6000)
BALLOON=$(getcfg balloonReserveMB 8000)
MIN_AVAIL=$(getcfg minAvailableMB 8000)
MAX_AGENTS=$(getcfg maxAgents 30)
SCOPE_ONLY=$(getcfg scopeToDreamteam false)
if [ "$SCOPE_ONLY" = "true" ] && [ ! -f "$STATE/active" ]; then exit 0; fi

# Local-model lane reserve (#37): when the ollama lane is ARMED (.local.enabled ==
# true), hold back reserveMB for the resident model. Its RSS/VRAM is invisible to
# this gate (which counts only claude procs) and the load is latent/bursty, so we
# reserve whether or not the model is currently loaded — exactly as BALLOON reserves
# for post-admission growth. ==false-safe (only a literal true arms it); zero effect
# when the lane is off (the default).
getlocal() { jq -r --arg k "$1" --arg d "$2" ".local[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
LOCAL_ARMED=$(jq -r 'if .local.enabled == true then 1 else 0 end' "$CFG" 2>/dev/null || echo 0)
LOCAL_RESERVE=$(getlocal reserveMB 9000); LOCAL_RESERVE=${LOCAL_RESERVE//[!0-9]/}; [ -n "$LOCAL_RESERVE" ] || LOCAL_RESERVE=9000
if [ "$LOCAL_ARMED" = 1 ]; then LOCAL_EFF=$LOCAL_RESERVE; LOCAL_NOTE="  local_reserve=${LOCAL_RESERVE} (ollama lane armed)"; else LOCAL_EFF=0; LOCAL_NOTE=""; fi

# --- measure RAM (instant — this is the real OOM guard, runs BEFORE the count) ---
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
HEADROOM=$(( AVAIL - HOST_RESERVE - BALLOON - LOCAL_EFF ))
BUDGET=$(( HEADROOM / PER_AGENT )); [ "$BUDGET" -lt 0 ] && BUDGET=0

block() {
  {
    echo "🚫 DREAMTEAM MEMORY GATE — spawn blocked: $1"
    echo "   avail=${AVAIL}MiB  swap_used=${SWAP_USED}MiB  agents=${2:-?}  budget=${BUDGET} more"
    echo "   (per_agent=${PER_AGENT}  host_reserve=${HOST_RESERVE}  balloon_reserve=${BALLOON}  floor=${MIN_AVAIL}${LOCAL_NOTE})"
    echo "   Recover headroom: let in-flight agents finish + merge, reuse an idle teammate"
    echo "   (/dreamteam-roster), close Waydroid (waydroid session stop) + the browser, or"
    echo "   batch this agent into a later wave. Re-check: /dreamteam-status"
  } >&2
  exit 2
}

# RAM-based blocks first (don't wait on the agent count for the real guard):
[ "$AVAIL" -lt "$MIN_AVAIL" ] && block "only ${AVAIL}MiB RAM available (< ${MIN_AVAIL}MiB floor)."
[ "$BUDGET" -le 0 ]          && block "no budget for another agent (need ${PER_AGENT}+${BALLOON}MiB headroom)."

# Count cap last — uses `claude agents --json` (real status), pgrep fallback (see lib.sh).
if command -v count_agents >/dev/null 2>&1; then NAGENTS=$(count_agents); else
  NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || true); NAGENTS=${NAGENTS:-0}; fi
[ "$NAGENTS" -ge "$MAX_AGENTS" ] && block "${NAGENTS} agents already running (cap ${MAX_AGENTS})." "$NAGENTS"

exit 0
