#!/usr/bin/env bash
# dreamteam — POST-SPAWN accounting  (PostToolUse hook, matcher: Agent|Task)
#
# Logs the cumulative Claude footprint (agent count + total RSS + available RAM)
# after each spawn, so drift toward the memory budget is visible in one place.
# Cheap; no decisions — the pre-spawn mem-gate is the enforcement point.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/dreamteam}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
LOG="$STATE/dreamteam.log"
mkdir -p "$STATE"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || true); NAGENTS=${NAGENTS:-0}
TOTAL_MB=$(( $(ps -eo rss,args 2>/dev/null | grep '[c]laude/versions' | awk '{s+=$1} END{print s+0}') / 1024 ))
AVAIL=$(free -m | awk '/^Mem:/{print $7}')
echo "$(date +%FT%T) post-spawn: agents=${NAGENTS} total_rss=${TOTAL_MB}MB avail=${AVAIL}MiB" >> "$LOG"
exit 0
