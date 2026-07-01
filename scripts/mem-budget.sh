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
PER_AGENT=$(getcfg perAgentMB 400); HOST_RESERVE=$(getcfg hostReserveMB 6000)
BALLOON=$(getcfg balloonReserveMB 8000); MIN_AVAIL=$(getcfg minAvailableMB 8000)
MAX_AGENTS=$(getcfg maxAgents 30)

AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
# agent count via `claude agents --json` (real status), pgrep fallback — see lib.sh
if command -v count_agents >/dev/null 2>&1; then NAGENTS=$(count_agents); else
  NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || true); NAGENTS=${NAGENTS:-0}; fi
BUDGET=$(( (AVAIL - HOST_RESERVE - BALLOON) / PER_AGENT )); [ "$BUDGET" -lt 0 ] && BUDGET=0
CAP=$(( BUDGET < MAX_AGENTS ? BUDGET : MAX_AGENTS ))
ROOM=$(( CAP - NAGENTS )); [ "$ROOM" -lt 0 ] && ROOM=0
[ "$AVAIL" -lt "$MIN_AVAIL" ] && { CAP=0; ROOM=0; }

if [ "${1:-}" = "--max" ]; then echo "$CAP"; exit 0; fi

waydroid_note=""
command -v waydroid >/dev/null 2>&1 && waydroid status 2>/dev/null | grep -q 'Session.*RUNNING' \
  && waydroid_note="  ⚠ Waydroid is RUNNING — it consumes RAM AND poisons OOM victim selection (Android oom_score_adj 900+). 'waydroid session stop' before a large run."

cat <<EOF
dreamteam memory budget
  available RAM : ${AVAIL} MiB        swap used: ${SWAP_USED} MiB
  live agents   : ${NAGENTS}
  per-agent plan: ${PER_AGENT} MiB    host reserve: ${HOST_RESERVE} MiB    balloon reserve: ${BALLOON} MiB
  ─────────────────────────────────────────────
  MAX agents    : ${CAP}   (= min(count cap ${MAX_AGENTS}, memory budget ${BUDGET}))
  room for      : ${ROOM} more this wave
${waydroid_note:+$waydroid_note}
EOF
[ "$AVAIL" -lt "$MIN_AVAIL" ] && echo "  🚫 below ${MIN_AVAIL} MiB floor — do NOT spawn; recover headroom first."
exit 0
