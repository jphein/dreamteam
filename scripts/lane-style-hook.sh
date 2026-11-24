#!/usr/bin/env bash
# dreamteam — LANE STYLE  (SessionStart hook: startup, resume, clear, compact)
#
# Gives a LANE session the token-saving output style (output-styles/lane.md) as CONTEXT, at every SessionStart
# event. Say it plainly: this is context INJECTION, repeated at each start, resume, clear and compaction. It is
# not an `outputStyle` setting and nothing is selected or stored per session: each event the hook decides again
# from the session's role, and when the role, the config or the style file no longer qualify it prints nothing.
#
# WHY (Flow row d1a1c56a; JP 2026-11-21 "switch the other agents to some kind of token saving output").
#
# WHO GETS IT (xreview #284 r2). In this order; the first line that applies decides:
#   1. this host is katana, or is named in `.laneStyle.neverHosts`            → nothing. katana is the owner's
#      desktop and is refused by name in the code, whatever a config says.
#   2. the session is not in a tmux pane                                      → nothing (a one-off `claude -p`, a
#      nightly job, a bare terminal).
#   3. THE LEAD, by its role and not only by a name:
#        a. the session is the one recorded in lead.session (written by the lead's own SessionStart hook,
#           scripts/lead-session-write.sh): same session id, or same pane                         → nothing
#           A record that exists but cannot be trusted (a symlink, not a plain readable file, or without
#           exactly one valid session= and pane= line) → NOBODY is styled: the lead cannot be told apart.
#        b. its tmux session is named `spire`, or $DREAMTEAM_LEAD_SESSION, or is in `.laneStyle.lead`: `spire`
#           is refused in the code itself, a config can only ADD names                            → nothing
#   4. its tmux session name is EXACTLY one of `.laneStyle.lanes`              → a lane: the style is given.
#      That list is exact names, no patterns, and ships EMPTY: a host names its lanes in its own overlay
#      (config.<host>.json). A session nobody listed, such as one the owner opens and types in, is never styled.
#   5. anything else                                                          → nothing.
# The session's name and pane come from tmux, asked about this session's own pane ($TMUX_PANE). There is no
# variable that tells the hook who it is: the only way to be a lane is to run in a pane of a listed session.
# Every failure (tmux does not answer in 2 s, a name that is not plain, a `.laneStyle` not in its form, a host
# overlay that cannot be read, a missing or bodyless style file) means NO style, one line on stderr, exit 0.
#
# WHAT IT LEAVES BEHIND, so that an injection can be shown and not just believed:
#   • the context starts with a stamp:  [lane style given <ISO time> on <startup|resume|clear|compact> to <name>]
#     A session resumed or compacted carries one stamp per event.
#   • one line per injection in $DREAMTEAM_LANE_STYLE_LOG (default ~/.claude/state/dreamteam/lane-style.log):
#     <ISO time> <event> <session name> <session id>
#
#   lane-style-hook.sh               the hook (stdin: the SessionStart payload; always exit 0)
#   lane-style-hook.sh --who NAME    what a tmux session of that name gets on this host by its NAME (the lead by
#                                    record cannot be judged from a name alone; the line says so)
#
# A hook must never hold or fail a session start: every path exits 0, stdin and tmux are bounded, hooks.json
# gives it 8 s.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
STYLE="$ROOT/output-styles/lane.md"
LEADREC="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}/lead.session"
LOG="${DREAMTEAM_LANE_STYLE_LOG:-$HOME/.claude/state/dreamteam/lane-style.log}"
# shellcheck source=lib/config.sh
. "$ROOT/scripts/lib/config.sh" 2>/dev/null || exit 0

# by_name <session name> → "lane|<reason>" or "no|<reason>": rules 1, 3b, 4, 5 (what a NAME decides)
by_name() {
  local name=$1 cfg rc g host shape
  [[ "$name" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || { echo "no|the session name is not plain"; return; }
  host=$(dreamteam_host)
  [ "$host" != katana ] || { echo "no|this host is katana (the owner's desktop): never styled"; return; }
  [ "$name" != spire ] || { echo "no|spire is the lead"; return; }
  [ -n "${DREAMTEAM_LEAD_SESSION:-}" ] && [ "$name" = "$DREAMTEAM_LEAD_SESSION" ] && { echo "no|$name is the lead (DREAMTEAM_LEAD_SESSION)"; return; }
  cfg=$(dreamteam_config "$CFG"); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$cfg" ] || { echo "no|the config or this host's overlay cannot be read (rc $rc)"; return; }
  shape=$(jq -r '(.laneStyle // {}) as $l
      | if ($l | type) != "object" then "bad"
        elif ([$l.lead, $l.lanes, $l.neverHosts] | map(. == null or (type == "array" and all(type == "string"))) | all | not) then "bad"
        elif ($l.enabled != null and ($l.enabled | type) != "boolean") then "bad"
        else "ok" end' <<<"$cfg" 2>/dev/null) || shape=bad
  [ "$shape" = ok ] || { echo "no|.laneStyle in the config is not in its form"; return; }
  while IFS= read -r g; do [ -n "$host" ] && [ "$host" = "$g" ] && { echo "no|this host ($host) is in .laneStyle.neverHosts"; return; }; done \
    < <(jq -r '(.laneStyle.neverHosts // [])[]' <<<"$cfg")
  while IFS= read -r g; do [ "$name" = "$g" ] && { echo "no|$name is a lead (.laneStyle.lead)"; return; }; done \
    < <(jq -r '(.laneStyle.lead // [])[]' <<<"$cfg")
  [ "$(jq -r 'if .laneStyle.enabled == false then "false" else "true" end' <<<"$cfg")" = true ] || { echo "no|.laneStyle.enabled is false"; return; }
  while IFS= read -r g; do [ "$name" = "$g" ] && { echo "lane|$name is listed in .laneStyle.lanes"; return; }; done \
    < <(jq -r '(.laneStyle.lanes // [])[]' <<<"$cfg")
  echo "no|$name is not in .laneStyle.lanes (lanes are listed by exact name, per host)"
}

if [ "${1:-}" = "--who" ]; then
  [ "$#" -eq 2 ] || { echo "usage: lane-style-hook.sh --who NAME" >&2; exit 0; }
  d=$(by_name "$2")
  if [ "${d%%|*}" = lane ]; then echo "$2: LANE by its name (${d#*|}); given the style at every session start UNLESS that session is the one recorded in lead.session"
  else echo "$2: not styled (${d#*|})"; fi
  exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0                               # rule 2: not in tmux
# the payload: which event this is, and the session's id (bounded: a stdin that never closes must not hold a start)
IN=$(timeout --kill-after=1 2 cat 2>/dev/null || true)
EVENT=$(jq -r '.source // "startup"' <<<"$IN" 2>/dev/null) || EVENT=startup
SID=$(jq -r '.session_id // ""' <<<"$IN" 2>/dev/null) || SID=""
[[ "$EVENT" =~ ^(startup|resume|clear|compact)$ ]] || EVENT=startup
[[ "$SID" =~ ^[0-9a-f-]{8,64}$ ]] || SID=""
# who am I: asked of tmux about this session's OWN pane, nothing else
WHO=$(timeout --kill-after=1 2 tmux display-message -p -t "$TMUX_PANE" '#{session_name} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || exit 0
NAME=${WHO%% *}; PANE=${WHO#* }
[ -n "$NAME" ] && [ "$PANE" != "$WHO" ] || exit 0
# rule 3a: the recorded lead, by session id or by pane, whatever its tmux session is called
# A record that EXISTS must be one this hook can trust and read in full: a plain readable file with exactly one valid
# session= line and one valid pane= line. Anything else at that path (a symlink, a directory, an unreadable or
# empty or malformed file) means the hook cannot tell who the lead is, and then NOBODY is styled.
if [ -e "$LEADREC" ] || [ -L "$LEADREC" ]; then
  if [ -L "$LEADREC" ] || [ ! -f "$LEADREC" ] || [ ! -r "$LEADREC" ]; then
    echo "lane-style: $LEADREC is a symlink, not a plain file, or unreadable, so who the lead is cannot be trusted: no style given" >&2; exit 0
  fi
  lsid=$(grep -c '^session=' "$LEADREC" 2>/dev/null):$(sed -n 's/^session=//p' "$LEADREC" 2>/dev/null | head -1)
  lpane=$(grep -c '^pane=' "$LEADREC" 2>/dev/null):$(sed -n 's/^pane=//p' "$LEADREC" 2>/dev/null | head -1)
  if ! [[ "$lsid" =~ ^1:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || ! [[ "$lpane" =~ ^1:[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]]; then
    echo "lane-style: $LEADREC does not hold exactly one valid session= and one valid pane= line, so who the lead is cannot be trusted: no style given" >&2; exit 0
  fi
  lsid=${lsid#1:}; lpane=${lpane#1:}
  { [ -n "$SID" ] && [ "$SID" = "$lsid" ]; } && exit 0
  [ "$PANE" = "$lpane" ] && exit 0
fi
D=$(by_name "$NAME")
if [ "${D%%|*}" != lane ]; then
  case "${D#*|}" in *"cannot be read"*|*"not in its form"*) echo "lane-style: ${D#*|}: no style given" >&2 ;; esac
  exit 0
fi
[ -f "$STYLE" ] || { echo "lane-style: $STYLE is missing: no style given" >&2; exit 0; }
BODY=$(awk 'n >= 2 {print} /^---$/ {n++}' "$STYLE")
[ -n "$BODY" ] || { echo "lane-style: $STYLE has no body: no style given" >&2; exit 0; }
printf -v NOW '%(%FT%T%z)T' -1
{ { [ -d "${LOG%/*}" ] || mkdir -p "${LOG%/*}"; } && printf '%s %s %s %s\n' "$NOW" "$EVENT" "$NAME" "${SID:--}" >> "$LOG"; } 2>/dev/null || true
jq -n --arg name "$NAME" --arg body "$BODY" --arg now "$NOW" --arg ev "$EVENT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext:
  ("[lane style given " + $now + " on " + $ev + " to " + $name + "]\nOUTPUT STYLE: lane. This session is the dreamteam lane \"" + $name + "\" (its tmux session name). The style below governs everything you write to the conversation. It REPLACES any instruction in your context to write Insight blocks, explanatory asides or educational commentary.\n\n" + $body)}}'
exit 0
