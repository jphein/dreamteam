#!/usr/bin/env bash
# dreamteam — POST-SPAWN accounting  (PostToolUse hook, matcher: Agent|Task)
#
# 1. Logs footprint to dreamteam.log (disk record)
# 2. Emits live agent count + memory to stdout JSON (injected into Claude's context)
# 3. Records agent name from tool result into roster state file
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/dreamteam}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
LOG="$STATE/dreamteam.log"
ROSTER="$STATE/agents.json"
mkdir -p "$STATE"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null || echo 0)
RSS_KB=$(ps -eo rss,args 2>/dev/null | grep '[c]laude/versions' | awk '{s+=$1} END{print s+0}' || echo 0)
TOTAL_MB=$(( ${RSS_KB:-0} / 1024 ))
AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)
TS=$(date +%FT%T)

echo "$TS post-spawn: agents=${NAGENTS} total_rss=${TOTAL_MB}MB avail=${AVAIL}MiB" >> "$LOG"

# Extract agent name/id from tool result if present
AGENT_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_result.name // .tool_input.name // empty' 2>/dev/null || true)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.tool_result.agentId // .tool_result.task_id // empty' 2>/dev/null || true)
AGENT_DESC=$(printf '%s' "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null || true)

# Update roster state file (append or update by name)
if [ -n "$AGENT_NAME" ]; then
  [ -f "$ROSTER" ] || echo '[]' > "$ROSTER"
  jq --arg name "$AGENT_NAME" --arg id "$AGENT_ID" --arg desc "$AGENT_DESC" --arg ts "$TS" \
    '[ .[] | select(.name != $name) ] + [{"name": $name, "id": $id, "desc": $desc, "spawned": $ts, "status": "active"}]' \
    "$ROSTER" > "$ROSTER.tmp" 2>/dev/null && mv "$ROSTER.tmp" "$ROSTER" || true
fi

# Build roster summary
ROSTER_LINE=""
if [ -f "$ROSTER" ]; then
  ROSTER_LINE=$(jq -r '[.[] | "\(.name)(\(.status))"] | join(" ")' "$ROSTER" 2>/dev/null || true)
fi

# Emit to stdout as JSON — PostToolUse hooks use systemMessage to inject into Claude's context
MSG="dreamteam: ${NAGENTS} agents | ${TOTAL_MB}MB RSS | ${AVAIL}MB free | ${ROSTER_LINE}"
jq -n --arg msg "$MSG" '{"systemMessage": $msg}'
