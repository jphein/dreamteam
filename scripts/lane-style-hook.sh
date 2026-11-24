#!/usr/bin/env bash
# dreamteam — LANE STYLE  (SessionStart hook: startup, resume, clear, compact)
#
# Gives every LANE session the token-saving output style (output-styles/lane.md) at every start, by ROLE.
# Nobody opts in and nobody has to launch a lane a special way: the role is read from the session itself.
#
# WHY (Flow row d1a1c56a; JP 2026-11-21 "switch the other agents to some kind of token saving output"; xreview
# #284 r1): the first version was an opt-in script per directory. A lane got nothing unless someone ran it, and a
# lead started in a wired directory got the lane style too. A restart kept nothing that was not in a file.
#
# WHO IS A LANE. The role is the tmux SESSION NAME of the pane this session runs in:
#   • not in tmux                                   → not a lane (a one-off `claude -p`, a nightly job, a bare terminal)
#   • the name is a LEAD's: `.laneStyle.lead` (default ["spire"]) or $DREAMTEAM_LEAD_SESSION
#                                                   → NEVER styled. Checked FIRST, before the lane patterns.
#   • the name matches a `.laneStyle.exclude` glob  → not styled (the owner's own sessions go here, by name)
#   • the name matches a `.laneStyle.lanes` glob (default ["*"]) → a lane: styled
# A name that cannot be read (tmux does not answer in 2 s, a name that is not plain) is NOT a lane: the failure
# direction is "no style", so a lead is never styled by accident. `.laneStyle.enabled=false` switches it off; an
# unreadable config or host overlay also means no style (and one line on stderr).
#
# WHAT IT DOES. It prints the style as SessionStart additionalContext: the body of output-styles/lane.md, the one
# source of the text (the same file is the native output style `dreamteam:lane` for anyone who selects it by hand).
# SessionStart fires on startup, resume, clear and compact, so a restart, a resume and a compaction all keep it.
# The text says that it replaces any instruction to write Insight blocks (the explanatory-output-style plugin's
# SessionStart text, where that plugin is on).
#
#   lane-style-hook.sh              the hook (reads nothing from stdin it needs; always exit 0)
#   lane-style-hook.sh --who NAME   say what a session of that name would get, and why (for the lead; exit 0)
#
# A hook must never hold or fail a session start: every path exits 0, the tmux call is bounded, and hooks.json
# gives it 6 s.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
STYLE="$ROOT/output-styles/lane.md"
# shellcheck source=lib/config.sh
. "$ROOT/scripts/lib/config.sh" 2>/dev/null || exit 0

# decide <name> → prints "lane|<reason>" or "no|<reason>"
decide() {
  local name=$1 cfg rc g
  [[ "$name" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || { echo "no|the session name is not plain"; return; }
  # the lead first, from the environment too: no config can make a lead a lane
  [ -n "${DREAMTEAM_LEAD_SESSION:-}" ] && [ "$name" = "$DREAMTEAM_LEAD_SESSION" ] && { echo "no|$name is the lead (DREAMTEAM_LEAD_SESSION)"; return; }
  cfg=$(dreamteam_config "$CFG"); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$cfg" ] || { echo "no|the config or this host's overlay cannot be read (rc $rc)"; return; }
  local shape
  shape=$(jq -r '(.laneStyle // {}) as $l
      | if ($l | type) != "object" then "bad"
        elif ([$l.lead, $l.exclude, $l.lanes] | map(. == null or (type == "array" and all(type == "string"))) | all | not) then "bad"
        elif ($l.enabled != null and ($l.enabled | type) != "boolean") then "bad"
        else "ok" end' <<<"$cfg" 2>/dev/null) || shape=bad
  [ "$shape" = ok ] || { echo "no|.laneStyle in the config is not in its form"; return; }
  while IFS= read -r g; do [ "$name" = "$g" ] && { echo "no|$name is a lead (.laneStyle.lead)"; return; }; done \
    < <(jq -r '(.laneStyle.lead // ["spire"])[]' <<<"$cfg")
  [ "$(jq -r 'if .laneStyle.enabled == false then "false" else "true" end' <<<"$cfg")" = true ] || { echo "no|.laneStyle.enabled is false"; return; }
  while IFS= read -r g; do
    # shellcheck disable=SC2254
    case "$name" in $g) echo "no|$name matches the exclude pattern $g"; return ;; esac
  done < <(jq -r '(.laneStyle.exclude // [])[]' <<<"$cfg")
  while IFS= read -r g; do
    # shellcheck disable=SC2254
    case "$name" in $g) echo "lane|$name matches the lane pattern $g"; return ;; esac
  done < <(jq -r '(.laneStyle.lanes // ["*"])[]' <<<"$cfg")
  echo "no|$name matches no lane pattern"
}

if [ "${1:-}" = "--who" ]; then
  [ "$#" -eq 2 ] || { echo "usage: lane-style-hook.sh --who NAME" >&2; exit 0; }
  d=$(decide "$2"); echo "$2: $([ "${d%%|*}" = lane ] && echo "LANE, styled at every session start" || echo "not styled") (${d#*|})"
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$STYLE" ] || { echo "lane-style: $STYLE is missing: no style given" >&2; exit 0; }
# the session's name: the test seam first, else the tmux session of this pane
NAME="${DREAMTEAM_LANE_NAME:-}"
if [ -z "$NAME" ]; then
  [ -n "${TMUX_PANE:-}" ] || exit 0                       # not in tmux: not a lane
  NAME=$(timeout --kill-after=1 2 tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
fi
D=$(decide "$NAME")
if [ "${D%%|*}" != lane ]; then
  case "${D#*|}" in *"cannot be read"*|*"not in its form"*) echo "lane-style: ${D#*|}: no style given" >&2 ;; esac
  exit 0
fi
# the style's body: everything after the frontmatter
BODY=$(awk 'n >= 2 {print} /^---$/ {n++}' "$STYLE")
[ -n "$BODY" ] || { echo "lane-style: $STYLE has no body: no style given" >&2; exit 0; }
jq -n --arg name "$NAME" --arg body "$BODY" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext:
  ("OUTPUT STYLE: lane. This session is the dreamteam lane \"" + $name + "\" (its tmux session name). The style below governs everything you write to the conversation. It REPLACES any instruction in your context to write Insight blocks, explanatory asides or educational commentary.\n\n" + $body)}}'
exit 0
