#!/usr/bin/env bash
# dreamteam — lane-style: wire the token-saving output style `lane` (output-styles/lane.md) for the sessions that
# start in ONE directory, and undo it.
#
#   lane-style.sh on     [DIR]   DIR/.claude/settings.local.json gets  outputStyle = "dreamteam:lane"  and
#                                enabledPlugins."explanatory-output-style@claude-code-plugins" = false
#   lane-style.sh off    [DIR]   exactly those two values go back to what they were (absent, if they were absent)
#   lane-style.sh status [DIR]   what a session started in DIR gets, and whether the style file is there
#   DIR defaults to the current directory.
#
# WHY (Flow row d1a1c56a; JP 2026-11-21 "switch the other agents to some kind of token saving output"): every
# session on these hosts runs with the explanatory-output-style plugin on, which tells it to write Insight blocks.
# A lane's reader is the lead reading many lanes; the `lane` style is the bottom line first, then Changed /
# Checked / Evidence / Not verified, twelve lines at most.
#
# TWO WAYS TO WIRE A LANE, both measured live on 2026-11-24 (a session quoting the style's own text, and no
# Insight instructions in its context):
#   • for ONE session, at launch:   claude --settings "<plugin root>/config/lane.settings.json" …
#   • for every session started in a directory: this script. settings.local.json is per host and per
#     directory, and it wins over the user's settings.
# The lead and the owner are not lanes: this script refuses the home directory, and nothing here sets the style
# for a session nobody wired (the style file has no force-for-plugin).
# Both values take effect at the next session start in that directory. A session already running keeps the
# Insight instructions it was started with until it is restarted or compacted; `/output-style dreamteam:lane`
# in its pane switches the style from the next message on.
#
# What `off` restores is kept beside the settings, in DIR/.claude/lane-style.prev.json (written by `on`, only
# when there is none yet, so a second `on` never overwrites the true previous state). No key that Claude Code
# does not know is ever written into a settings file.
#
# Exit: 0 done · 2 refused (the home directory, a settings file that is a symlink or not a JSON object, no jq,
# a directory that does not exist) · 22 bad argument.
set -uo pipefail
STYLE="${DREAMTEAM_LANE_STYLE:-dreamteam:lane}"
PLUGIN="explanatory-output-style@claude-code-plugins"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
usage() { echo "usage: lane-style.sh on|off|status [DIR]" >&2; exit 22; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
VERB=$1; case "$VERB" in on|off|status) ;; *) usage ;; esac
DIR=${2:-$PWD}
[ -d "$DIR" ] || { echo "lane-style: $DIR is not a directory" >&2; exit 2; }
DIR=$(cd "$DIR" && pwd -P) || exit 2
command -v jq >/dev/null 2>&1 || { echo "lane-style: jq is needed" >&2; exit 2; }
[[ "$STYLE" =~ ^[A-Za-z0-9_.:-]{1,80}$ ]] || { echo "lane-style: the style name is not plain" >&2; exit 2; }
S="$DIR/.claude/settings.local.json"; PREV="$DIR/.claude/lane-style.prev.json"

# read: the settings as one JSON object on stdout ({} when there is no file); 2 when it cannot be trusted
read_settings() {
  if [ -L "$S" ]; then echo "lane-style: $S is a symlink: refused" >&2; return 2; fi
  if [ ! -e "$S" ]; then echo '{}'; return 0; fi
  jq -e 'if type == "object" then . else error("not an object") end' "$S" 2>/dev/null \
    || { echo "lane-style: $S is not a JSON object: refused, nothing written" >&2; return 2; }
}
# write <json>: a new file beside the old one, then one rename. The file as `on` found it is kept as
# .bak-lane-style until `off` (jq note: never `x // default` on these values; `//` reads false as absent)
write_settings() {
  local tmp
  mkdir -p "$DIR/.claude" || return 2
  [ -e "$S" ] && [ ! -e "$S.bak-lane-style" ] && cp -p -- "$S" "$S.bak-lane-style"
  tmp=$(mktemp "$DIR/.claude/.settings.local.XXXXXX") || return 2
  printf '%s\n' "$1" | jq . > "$tmp" && mv -f -- "$tmp" "$S" || { rm -f -- "$tmp"; return 2; }
}

case "$VERB" in
  status)
    cur=$(read_settings) || exit 2
    echo "directory: $DIR"
    echo "outputStyle: $(jq -r '.outputStyle // "(not set: the user'"'"'s setting, else default)"' <<<"$cur")"
    echo "explanatory plugin here: $(jq -r --arg p "$PLUGIN" 'if (.enabledPlugins // {}) | has($p) then (.enabledPlugins[$p] | tostring) else "(not set here: the user'"'"'s setting)" end' <<<"$cur")"
    if [ "$(jq -r '.outputStyle // ""' <<<"$cur")" = "$STYLE" ] && [ "$(jq -r --arg p "$PLUGIN" '(.enabledPlugins // {}) | if has($p) then .[$p] else "unset" end | tostring' <<<"$cur")" = false ]; then echo "lane style: ON for sessions started here"; else echo "lane style: off here"; fi
    [ -f "$ROOT/output-styles/lane.md" ] && echo "style file: $ROOT/output-styles/lane.md" || echo "style file: MISSING at $ROOT/output-styles/lane.md"
    exit 0 ;;
  on)
    [ "$DIR" != "$(cd "$HOME" && pwd -P)" ] || { echo "lane-style: refused for the home directory: the lead and the owner start there, and they are not lanes" >&2; exit 2; }
    cur=$(read_settings) || exit 2
    if [ ! -e "$PREV" ]; then
      mkdir -p "$DIR/.claude" || exit 2
      had=false; [ -e "$S" ] && had=true
      jq -n --argjson c "$cur" --arg p "$PLUGIN" --argjson had "$had" \
        '{hadFile: $had, outputStyle: (if $c | has("outputStyle") then {was: $c.outputStyle} else null end),
          plugin: (if ($c.enabledPlugins // {}) | has($p) then {was: $c.enabledPlugins[$p]} else null end),
          hadEnabledPlugins: ($c | has("enabledPlugins"))}' > "$PREV" || { echo "lane-style: cannot write $PREV" >&2; exit 2; }
    fi
    new=$(jq --arg s "$STYLE" --arg p "$PLUGIN" '.outputStyle = $s | .enabledPlugins = ((.enabledPlugins // {}) + {($p): false})' <<<"$cur") || exit 2
    write_settings "$new" || { echo "lane-style: cannot write $S" >&2; exit 2; }
    echo "lane style ON for sessions started in $DIR (outputStyle $STYLE, the explanatory plugin off); it applies from the next session start there" ;;
  off)
    cur=$(read_settings) || exit 2
    [ -e "$S" ] || { echo "lane style: nothing to undo in $DIR"; rm -f -- "$PREV"; exit 0; }
    prev='{"outputStyle":null,"plugin":null,"hadEnabledPlugins":true}'
    if [ -f "$PREV" ] && [ ! -L "$PREV" ]; then prev=$(jq -e 'if type == "object" then . else error("x") end' "$PREV" 2>/dev/null) || prev='{"outputStyle":null,"plugin":null,"hadEnabledPlugins":true}'; fi
    # only OUR two values are touched, and only while they are still ours
    new=$(jq --arg s "$STYLE" --arg p "$PLUGIN" --argjson v "$prev" '
        (if .outputStyle == $s then (if $v.outputStyle == null then del(.outputStyle) else .outputStyle = $v.outputStyle.was end) else . end)
      | (if (.enabledPlugins // {})[$p] == false then
           (if $v.plugin == null then del(.enabledPlugins[$p]) else .enabledPlugins[$p] = $v.plugin.was end)
         else . end)
      | (if ($v.hadEnabledPlugins | not) and (.enabledPlugins == {}) then del(.enabledPlugins) else . end)' <<<"$cur") || exit 2
    if [ "$(jq -c . <<<"$new")" = "{}" ] && [ "$(jq -r 'if has("hadFile") then .hadFile else true end' <<<"$prev")" = false ]; then
      rm -f -- "$S" "$S.bak-lane-style"            # there was no settings file before `on`: there is none again
    else
      write_settings "$new" || { echo "lane-style: cannot write $S" >&2; exit 2; }
      rm -f -- "$S.bak-lane-style"                 # the copy belonged to this on/off cycle
    fi
    rm -f -- "$PREV"
    echo "lane style off in $DIR: the two values are back to what they were" ;;
esac
