#!/usr/bin/env bash
# dreamteam — SPAWN-STANDARDS gate (PreToolUse hook, matcher: Agent|Task).
#
# Enforces the skill's spawn conventions that coordinators keep talking past
# (JP, 2026-07-01: "coordinators are not always using the right type of agent
# [and] not naming things how i want"):
#
#   1. NAMING — teammates are named `<dreamname>-<task-slug>` (skill § Naming
#      rules): a dream-roster name + short kebab slug, e.g. lucid-262-cache,
#      luna-wear-polish. Named spawns that don't match are blocked; unnamed
#      spawns are blocked only when they're teammates (team_name present) —
#      anonymous utility spawns (Explore-style) pass through.
#   2. TYPED PERSONAS — when the dreamname has an agent-type definition
#      (luna/morpheus/lucid/nebula/oracle), the spawn must use it
#      (subagent_type: dreamteam:<name>) so the persona system prompt — and
#      for oracle, the enforced read-only toolset — actually applies.
#
# Escape hatch: include `STANDARDS-EXEMPT: <reason>` in the prompt.
# Disable: config spawn.enforceStandards=false (explicit ==false check — jq's
# // treats false as empty; see reuse-gate for the bug this avoids).
# Exit 2 blocks the spawn; the stderr message teaches the convention.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

ENFORCE=$(jq -r 'if .spawn.enforceStandards == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

NAME="$(printf '%s' "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || true)"
TEAM="$(printf '%s' "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || true)"
TYPE="$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || true)"

case "$PROMPT" in *STANDARDS-EXEMPT:*) exit 0 ;; esac

# The dream roster (skill § The Dream Name Roster + overflow names + overnight roles).
ROSTER='luna|vesper|reverie|morpheus|somnia|nebula|aurora|selene|lucid|drift|wisp|echo|cirrus|haze|twilight|solace|onyx|zephyr|muse|starling|slumber|dusk|mirage|phantasm|phoenix|cassia|solara|yara|lyra|nyx|ember|sage|fern|reeve|hermes|argus|iona|oracle'
# Dreamnames that have agent-type definitions in agents/ (typed personas).
TYPED='luna|morpheus|lucid|nebula|oracle'

teach() {
  {
    echo "🎭 DREAMTEAM SPAWN STANDARDS — spawn blocked: $1"
    echo "   Naming: <dreamname>-<task-slug> (kebab), e.g. lucid-262-cache, luna-wear-polish."
    echo "   Typed personas (use subagent_type: dreamteam:<name>):"
    echo "     luna=UI/design · morpheus=architecture/refactors · lucid=debugging/forensics"
    echo "     nebula=research/docs/audits · oracle=READ-ONLY verification (enforced)"
    echo "   Other dream names (vesper/aurora/wisp/…) spawn as general-purpose with the"
    echo "   persona in the prompt — see the dreamteam skill roster."
    echo "   Deliberate exception? Add a line 'STANDARDS-EXEMPT: <reason>' to the prompt."
  } >&2
  exit 2
}

# Rule 0 — teammates require tmux (the skill's pre-flight, now enforced).
# Outside tmux the harness cannot create panes: teammates open separate GUI
# terminal WINDOWS instead (observed candela 2026-07-01) — no agents tab, no
# pane wall, and each agent dies with its window. TMUX in the hook env is the
# same signal pane-organizer trusts.
if [ -n "$TEAM" ] && [ -z "${TMUX:-}" ]; then
  {
    echo "🛌 DREAMTEAM SPAWN STANDARDS — teammate spawn blocked: orchestrator is NOT inside tmux."
    echo "   Teammates spawned here open separate GUI terminal windows (no agents tab; each"
    echo "   dies with its window). Relaunch the orchestrator inside tmux first — skill pre-flight:"
    echo "     tmux -L dreamteam new-session -s dream     # or any tmux session"
    echo "   Deliberate exception? Add 'STANDARDS-EXEMPT: <reason>' to the prompt."
  } >&2
  exit 2
fi

# Rule 1a — teammates must be named.
if [ -z "$NAME" ]; then
  [ -n "$TEAM" ] && teach "teammate spawned without a name (SendMessage addressing needs one)."
  exit 0   # anonymous utility spawn — not our business
fi

# Rule 1b — named spawns follow <dreamname>-<slug>.
LNAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
BASE="${LNAME%%-*}"
if ! printf '%s' "$BASE" | grep -qxE "$ROSTER"; then
  teach "'$NAME' is not a dream-roster name."
fi
if ! printf '%s' "$LNAME" | grep -qxE "($ROSTER)-[a-z0-9][a-z0-9-]*"; then
  teach "'$NAME' is missing its task slug (bare dream names collide across waves)."
fi

# Rule 2 — typed personas must spawn with their type.
if printf '%s' "$BASE" | grep -qxE "$TYPED"; then
  if [ "$TYPE" != "dreamteam:$BASE" ]; then
    teach "'$NAME' has a typed persona — spawn it with subagent_type: \"dreamteam:$BASE\" (got: '${TYPE:-none}')."
  fi
fi

exit 0
