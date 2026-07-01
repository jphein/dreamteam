#!/usr/bin/env bash
# dreamteam — POST-SPAWN accounting  (PostToolUse hook, matcher: Agent|Task)
#
# 1. Logs footprint to dreamteam.log (disk record)
# 2. Emits live agent count + memory to stdout JSON (injected into Claude's context)
# 3. Appends the TRUE team roster (from roster.sh, which reads the authoritative
#    harness team config) to that message. The old lossy state/agents.json roster
#    file is RETIRED — it only saw new spawns and never marked idle/dead.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/dreamteam}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
LOG="$STATE/dreamteam.log"
mkdir -p "$STATE"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

# Robust metric capture. NEVER use `pipe || echo 0`: under `set -o pipefail` a
# failed/restricted `ps` (as in the hook sandbox) fails the pipe AND fires the
# fallback — while awk already printed "0" — yielding a multiline "0\n0" that
# then breaks the arithmetic below. Instead: let awk own the default (it always
# exits 0), then sanitize each value to bare digits before any math.
NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null); NAGENTS=${NAGENTS//[!0-9]/}; NAGENTS=${NAGENTS:-0}
RSS_KB=$(ps -eo rss,args 2>/dev/null | awk '/claude\/versions/ && !/awk/ {s+=$1} END{print s+0}')
RSS_KB=${RSS_KB//[!0-9]/}; RSS_KB=${RSS_KB:-0}
TOTAL_MB=$(( RSS_KB / 1024 ))
AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); AVAIL=${AVAIL//[!0-9]/}; AVAIL=${AVAIL:-0}
TS=$(date +%FT%T)

echo "$TS post-spawn: agents=${NAGENTS} total_rss=${TOTAL_MB}MB avail=${AVAIL}MiB" >> "$LOG"

# Build roster summary from the AUTHORITATIVE harness team config (via roster.sh)
# — every member with its TRUE status, not just spawns this session saw. roster.sh
# always exits 0; if it can't resolve a team, .agents is empty → blank line.
ROSTER_LINE=$(bash "$ROOT/scripts/roster.sh" --json 2>/dev/null \
  | jq -r 'if (.agents|length) > 0 then [.agents[] | "\(.name)(\(.status))"] | join(" ") else "" end' 2>/dev/null || true)

# Emit to stdout as JSON — PostToolUse hooks use systemMessage to inject into Claude's context
MSG="dreamteam: ${NAGENTS} agents | ${TOTAL_MB}MB RSS | ${AVAIL}MB free | ${ROSTER_LINE}"
jq -n --arg msg "$MSG" '{"systemMessage": $msg}'
