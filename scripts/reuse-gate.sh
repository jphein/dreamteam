#!/usr/bin/env bash
# dreamteam — REUSE-BEFORE-SPAWN gate  (PreToolUse hook, matcher: Agent|Task)
#
# Enforces JP's directive: assign idle agents whenever possible instead of
# spinning up new ones, and route to the agent with the best existing context.
# Reusing an idle agent costs ZERO new RAM (the #1 lever against the 06-30 OOM,
# where 59 procs ran) AND keeps warm context (better answers, fewer tokens).
#
# Logic: on an Agent spawn, if the target team has a reusable idle agent
# (alive + isActive:false), BLOCK (exit 2) and tell the orchestrator to reuse
# the best-affinity match via SendMessage. Conscious override: include
# "FRESH-SPAWN: <reason>" in the prompt when a new agent is genuinely required
# (new worktree, independent parallel work, idle agent's context is wrong).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

# Master switch (default on). Disable via config: reuse.enforce=false
# NOTE: not `// true` — jq's // treats false as empty, so the old form made
# enforce=false unreachable (same bug class caught in scope-attach by tests).
ENFORCE=$(jq -r 'if .reuse.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || true)"
TEAM="$(printf '%s' "$INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || true)"

# Conscious override — a deliberate fresh spawn.
case "$PROMPT" in *FRESH-SPAWN*) exit 0 ;; esac

# No team context → nothing to reuse from (SendMessage needs a teammate). Allow.
[ -z "$TEAM" ] && exit 0

# Ask the oracle for reusable idle agents in this team, ranked by affinity.
IDLE_JSON="$(bash "$ROOT/scripts/idle-agents.sh" --team "$TEAM" --task "$PROMPT" --json 2>/dev/null || echo '[]')"
COUNT="$(printf '%s' "$IDLE_JSON" | jq 'length' 2>/dev/null || echo 0)"
[ "${COUNT:-0}" -eq 0 ] && exit 0   # none reusable → allow the spawn

{
  echo "🔄 DREAMTEAM REUSE GATE — spawn blocked: ${COUNT} idle agent(s) can take this task (zero new RAM, warm context)."
  printf '%s' "$IDLE_JSON" | jq -r '.[] | "   • \(.name)  (cwd=\(.cwd // "-"))\(if .why != "" then "  ["+.why+"]" else "" end)\n       was: \(.context)"' 2>/dev/null
  BEST="$(printf '%s' "$IDLE_JSON" | jq -r '.[0].name' 2>/dev/null)"
  echo "   → Best context match: ${BEST}. Assign via SendMessage({to:\"${BEST}\", ...}) instead of spawning."
  echo "   → If a FRESH agent is genuinely required (new worktree / independent parallel work / wrong context),"
  echo "     add a line 'FRESH-SPAWN: <reason>' to the prompt and retry."
} >&2
exit 2
