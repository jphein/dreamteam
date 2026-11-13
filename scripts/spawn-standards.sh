#!/usr/bin/env bash
# dreamteam — SPAWN-STANDARDS gate (PreToolUse hook, matcher: Agent|Task).
#
# Enforces the skill's spawn conventions that coordinators keep talking past
# (JP, 2026-07-01: "coordinators are not always using the right type of agent
# [and] not naming things how i want"):
#
#   1. NAMING — teammates are named `<dreamname>-<role>` (skill § Naming
#      rules): a dream-roster name + short kebab ROLE suffix, e.g.
#      morpheus-architect, lucid-debugger, hypnos-agent-manager. The suffix
#      says what the agent IS (its acting role), not which ticket it holds, so
#      names stay accurate across reuse/reassignment; roles are an OPEN
#      vocabulary (the mechanical check is dream-name + non-empty kebab suffix).
#      Named spawns that don't match are blocked; unnamed spawns are blocked
#      only when they're teammates (team_name present) — anonymous utility
#      spawns (Explore-style) pass through.
#   2. TYPED PERSONAS — when the dreamname has an agent-type definition
#      (luna/morpheus/lucid/nebula/oracle + the hypnos/nyx manager roles), the
#      spawn must use it (subagent_type: dreamteam:<name>) so the persona system
#      prompt — and for oracle, the enforced read-only toolset — actually
#      applies. Without the type, a manager like hypnos-agent-manager would
#      spawn with NO persona yet still pass the name check (Revision 2 R1's hole).
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

# The dream roster (skill § The Dream Name Roster + overflow names + overnight
# roles + the hypnos/nyx per-team manager roles). argus/iona were retired per
# spec S6 (#45 dropped their SKILL/crash-audit refs; #46 drops them here too).
#
# DERIVED ARTIFACT — source of truth is lexicon's vocabularies/dreams.yaml
# (`dreams.roster`). Deepened to 80 names on 2026-08-31 (was 61 on 2026-08-14) after a 7-agent research
# wave exhausted the distinct picks and had to spawn everyone as nebula-*.
# Regenerate (do NOT hand-edit — order must match, so a re-run is a no-op diff):
#
#   cd ~/Projects/lexicon.realm.watch && python3 -c \
#     "import yaml;print('|'.join(yaml.safe_load(open('vocabularies/dreams.yaml'))['dreams']['roster']['words']))"
#
# The list is INLINE, not read from lexicon at runtime, deliberately: this hook
# runs on EVERY spawn under a 3s timeout, and a cross-repo file read would put
# lexicon's checkout on the critical path of every agent launch — and fail
# closed (blocking all spawns) if that path ever moved.
ROSTER='luna|morpheus|lucid|nebula|oracle|hypnos|nyx|vesper|reverie|somnia|aurora|selene|drift|wisp|echo|cirrus|haze|twilight|solace|onyx|zephyr|muse|starling|slumber|dusk|mirage|phantasm|phoenix|cassia|solara|yara|lyra|ember|sage|fern|reeve|hermes|oneiros|erebus|aether|halcyon|calypso|elysium|avalon|sylph|iris|maia|nocturne|gloam|umbra|hush|lull|eclipse|nimbus|stratus|solstice|meridian|zenith|nova|quasar|orion|eos|rhea|phoebe|vega|altair|deneb|polaris|castor|pollux|cygnus|carina|borealis|nimue|titania|lethe|gossamer|glimmer|dawn|murmur'
# Dreamnames that have agent-type definitions in agents/ (typed personas).
# hypnos/nyx are the manager roles: without their type the spawn loads NO persona
# system prompt yet still clears the name check — the R1 hole this list closes.
TYPED='luna|morpheus|lucid|nebula|oracle|hypnos|nyx'

teach() {
  {
    echo "🎭 DREAMTEAM SPAWN STANDARDS — spawn blocked: $1"
    echo "   Naming: <dreamname>-<role> (kebab), e.g. morpheus-architect, lucid-debugger, hypnos-agent-manager."
    echo "   Typed personas (use subagent_type: dreamteam:<name>):"
    echo "     luna=UI/design · morpheus=architecture/refactors · lucid=debugging/forensics"
    echo "     nebula=research/docs/audits · oracle=READ-ONLY verification (enforced)"
    echo "     hypnos=agent/comms manager · nyx=resource/memory manager (per-team ops roles)"
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

# Rule 0b — the lead's cwd must be a TRUSTED workspace (2026-11-13). Teammate panes start in the
# lead's cwd; in an untrusted one each pane stops at Claude Code's "Quick safety check" dialog with
# "No, exit" pre-selected and waits there silently (10:26–11:06: five fixers spawned from
# /home/jp/.claude sat 40 min). Trust rules as MEASURED on 2.1.323 (lucid, tmux probes, 11-13):
#   * outside git, trust is inherited from any trusted ancestor (a dir under trusted $HOME: no dialog);
#   * inside a git checkout it is NOT inherited across the repository root: a fresh repo under trusted
#     ~/srv prompted, and so did a worktree of that untrusted repo; a worktree of a TRUSTED repo did not.
# So: in git, trusted iff some dir from cwd up to the checkout root, or the main repo root, has
# projects[<dir>].hasTrustDialogAccepted == true in ~/.claude.json; outside git, cwd or any ancestor.
# Unknown (no cwd, unreadable config, jq error) fails OPEN: a guard bug must not block every spawn.
cwd_trust() {   # 0 trusted · 1 untrusted · 2 unknown; sets TRUST_KEY (the dir to pre-set)
  local cwd="$1" cj="${DREAMTEAM_CLAUDE_JSON:-$HOME/.claude.json}" top common d rc
  local -a cands=()
  TRUST_KEY="$cwd"
  [ -n "$cwd" ] && [ -d "$cwd" ] && [ -r "$cj" ] || return 2
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  d="$cwd"
  while :; do
    cands+=("$d")
    { [ -n "$top" ] && [ "$d" = "$top" ]; } && break
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
  if [ -n "$top" ]; then
    TRUST_KEY="$top"
    common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    case "$common" in */.git) cands+=("${common%/.git}"); TRUST_KEY="${common%/.git}" ;; esac
  fi
  # The config goes on STDIN: after --args jq reads every word as a string, never as a file
  # (the draft passed "$cj" there, so jq saw empty input, rc 4 = "unknown", and every spawn passed).
  jq -e --args '[.projects[$ARGS.positional[]]?.hasTrustDialogAccepted] | any(. == true)' "${cands[@]}" <"$cj" >/dev/null 2>&1
  rc=$?
  case $rc in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
if [ -n "$TEAM" ]; then
  LEAD_CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
  cwd_trust "$LEAD_CWD"
  if [ $? -eq 1 ]; then
    {
      echo "🔒 DREAMTEAM SPAWN STANDARDS — teammate spawn blocked: the lead's cwd is not a TRUSTED workspace:"
      echo "     $LEAD_CWD"
      echo "   Every teammate pane would start there and stop at Claude Code's 'Quick safety check'"
      echo "   with 'No, exit' selected, silently (2026-11-13 10:26–11:06: five fixers sat 40 min)."
      echo "   Trust on a parent dir does NOT cover a git repo below it (measured on 2.1.323)."
      echo "   Fix one of:"
      echo "     1. cd into a trusted project first, then spawn; or"
      echo "     2. pre-set trust (back up ~/.claude.json first), for the repo root:"
      echo "          projects[\"$TRUST_KEY\"].hasTrustDialogAccepted = true"
      echo "   Deliberate exception? Add 'STANDARDS-EXEMPT: <reason>' to the prompt."
    } >&2
    exit 2
  fi
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
