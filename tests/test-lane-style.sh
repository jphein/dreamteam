#!/usr/bin/env bash
# dreamteam — the token-saving output style `lane` and its wiring (Flow row d1a1c56a).
#
#   • output-styles/lane.md        the style a lane's session is given: the bottom line first, then Changed /
#                                  Checked / Evidence / Not verified, twelve lines at most
#   • config/lane.settings.json    the two settings, for `claude --settings <file>` (one session)
#   • scripts/lane-style.sh        the same two settings in ONE directory's .claude/settings.local.json, and back
#
# Hermetic: fixture directories under a temp dir; nothing here starts Claude Code. That a session really loads
# the style (and loses the Insight instructions) was measured live and is in the PR; a suite cannot see that.
#
# Run standalone:  bash tests/test-lane-style.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LS="$ROOT/scripts/lane-style.sh"; STYLE="$ROOT/output-styles/lane.md"; CFG="$ROOT/config/lane.settings.json"
P="explanatory-output-style@claude-code-plugins"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
T="$(mktemp -d)" && T="$(cd "$T" && pwd -P)" || { echo "FAIL: no temp dir"; exit 1; }
trap 'rm -rf -- "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
run() { bash "$LS" "$@" > "$T/out" 2> "$T/err"; }
norm() { jq -S -c . "$1"; }

echo "── the style file ───────────────────────────────────────────────"
fm() { awk '/^---$/ {n++; next} n == 1' "$STYLE"; }
ok "the style is named lane" 'fm | grep -qx "name: lane"'
ok "it keeps the coding instructions of Claude Code (it changes how a lane writes, not how it works)" 'fm | grep -qx "keep-coding-instructions: true"'
ok "it is NOT forced on every session with the plugin on (the lead and the owner are not lanes)" '! fm | grep -q "force-for-plugin"'
ok "it has a description for the picker" 'fm | grep -q "^description: .\{20,\}"'
for must in "First line: the bottom line" "\*\*Changed:\*\*" "\*\*Checked:\*\*" "\*\*Evidence:\*\*" "\*\*Not verified:\*\*" "Twelve lines at most" "Never restate the request" "No closing offers" 'No "Insight" blocks'; do
  if grep -q -- "$must" "$STYLE"; then pass "the style says: $must"; else fail "the style lacks: $must"; fi
done
ok "the four parts come in the order Changed, Checked, Evidence, Not verified" '[ "$(grep -o "\*\*\(Changed\|Checked\|Evidence\|Not verified\):\*\*" "$STYLE" | tr "\n" " ")" = "**Changed:** **Checked:** **Evidence:** **Not verified:** " ]'
ok "what must stay whole is named: a failure, safety, what was asked for, the rule tags" 'grep -q "A failure: the command, the error and the failing output, complete" "$STYLE" && grep -q "act safely" "$STYLE" && grep -q "asked to see in full" "$STYLE" && grep -q "rule:" "$STYLE"'
ok "the style is small: it is sent with every request (under 2500 bytes)" '[ "$(wc -c < "$STYLE")" -lt 2500 ]'

echo "── the settings for one session ─────────────────────────────────"
ok "config/lane.settings.json is exactly the two settings" '[ "$(norm "$CFG")" = "{\"enabledPlugins\":{\"'"$P"'\":false},\"outputStyle\":\"dreamteam:lane\"}" ]'

echo "── lane-style.sh ────────────────────────────────────────────────"
D="$T/proj"; mkdir -p "$D"; S="$D/.claude/settings.local.json"
run on "$D"; rc=$?
ok "on, no settings file: one is made with the two values" '[ "$rc" -eq 0 ] && [ "$(norm "$S")" = "{\"enabledPlugins\":{\"'"$P"'\":false},\"outputStyle\":\"dreamteam:lane\"}" ]'
run status "$D"; ok "status says ON" 'grep -qx "lane style: ON for sessions started here" "$T/out"'
run off "$D"; rc=$?
ok "off: there was no settings file before, there is none again (and no leftovers)" '[ "$rc" -eq 0 ] && [ ! -e "$S" ] && [ -z "$(ls -A "$D/.claude")" ]'

orig='{"permissions":{"allow":["Bash(ls:*)","Read"],"deny":[]},"env":{"FOO":"bar baz"},"outputStyle":"Explanatory","enabledPlugins":{"other@market":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true","timeout":4}]}]}}'
mkdir -p "$D/.claude"; printf '%s\n' "$orig" > "$S"; before=$(norm "$S")
run on "$D"; rc=$?
ok "on, a settings file with other keys: outputStyle and the plugin switch are set" '[ "$rc" -eq 0 ] && [ "$(jq -r .outputStyle "$S")" = dreamteam:lane ] && [ "$(jq -r --arg p "$P" ".enabledPlugins[\$p]" "$S")" = false ]'
ok "…every OTHER key is as it was (permissions, env, hooks, the other plugin)" '[ "$(jq -S -c --arg p "$P" "del(.outputStyle) | del(.enabledPlugins[\$p])" "$S")" = "$(jq -S -c "del(.outputStyle)" <<<"$orig")" ]'
ok "…the file as it was is kept beside it once" '[ "$(norm "$S.bak-lane-style")" = "$before" ]'
ok "…what off will restore is kept in a sidecar, not in the settings (no key Claude Code does not know)" '[ -f "$D/.claude/lane-style.prev.json" ] && [ "$(jq -r "keys | join(\",\")" "$S")" = "enabledPlugins,env,hooks,outputStyle,permissions" ]'
side=$(cat "$D/.claude/lane-style.prev.json"); now=$(norm "$S"); run on "$D"
ok "a second on changes nothing and does not overwrite the true previous state" '[ "$(norm "$S")" = "$now" ] && [ "$(cat "$D/.claude/lane-style.prev.json")" = "$side" ]'
run status "$D"; sig=$(stat -c '%y %i' "$S"); run status "$D"
ok "status writes nothing" '[ "$(stat -c "%y %i" "$S")" = "$sig" ]'
run off "$D"; rc=$?
ok "off: the file is back to what it was, the earlier outputStyle (Explanatory) included" '[ "$rc" -eq 0 ] && [ "$(norm "$S")" = "$before" ] && [ ! -e "$D/.claude/lane-style.prev.json" ] && [ ! -e "$S.bak-lane-style" ]'
run status "$D"; ok "status says off" 'grep -qx "lane style: off here" "$T/out"'

rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"enabledPlugins":{"%s":true}}\n' "$P" > "$S"; run on "$D"; run off "$D"
ok "the plugin was explicitly ON here before: off puts true back" '[ "$(norm "$S")" = "{\"enabledPlugins\":{\"'"$P"'\":true}}" ]'
rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"enabledPlugins":{"%s":false}}\n' "$P" > "$S"; run on "$D"; run off "$D"
ok "the plugin was explicitly OFF here before: it stays off after off" '[ "$(norm "$S")" = "{\"enabledPlugins\":{\"'"$P"'\":false}}" ]'
rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"env":{"A":"1"}}\n' > "$S"; run on "$D"; run off "$D"
ok "there was no enabledPlugins key before: off leaves none" '[ "$(norm "$S")" = "{\"env\":{\"A\":\"1\"}}" ]'
rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"env":{"A":"1"}}\n' > "$S"; run on "$D"
jq '.outputStyle = "Concise"' "$S" > "$S.x" && mv "$S.x" "$S"; run off "$D"
ok "someone chose ANOTHER style after on: off leaves their choice and still puts the plugin back" '[ "$(norm "$S")" = "{\"env\":{\"A\":\"1\"},\"outputStyle\":\"Concise\"}" ]'

rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"env":{"A":"1"},"enabledPlugins":{"other@market":true}}\n' > "$S"; run on "$D"; rm -f "$D/.claude/lane-style.prev.json"; run off "$D"; rc=$?
ok "the sidecar is gone (someone tidied): off still removes OUR two values and nothing else" '[ "$rc" -eq 0 ] && [ "$(norm "$S")" = "{\"enabledPlugins\":{\"other@market\":true},\"env\":{\"A\":\"1\"}}" ]'
rm -rf "$D/.claude"; run off "$D"; rc=$?
ok "off where nothing was ever wired: exit 0, nothing made" '[ "$rc" -eq 0 ] && [ ! -e "$D/.claude" ]'

echo "── refusals: nothing is written ─────────────────────────────────"
rm -rf "$D/.claude"; mkdir -p "$D/.claude"; printf '{"env": {"A": "1"},,}\n' > "$S"; b=$(sha256sum < "$S"); run on "$D"; rc=$?
ok "a settings file that is not JSON: exit 2, the file untouched, no sidecar" '[ "$rc" -eq 2 ] && [ "$(sha256sum < "$S")" = "$b" ] && [ ! -e "$D/.claude/lane-style.prev.json" ] && grep -q "not a JSON object" "$T/err"'
run off "$D"; rc=$?; ok "…off refuses it too" '[ "$rc" -eq 2 ] && [ "$(sha256sum < "$S")" = "$b" ]'
printf '["a"]\n' > "$S"; b=$(sha256sum < "$S"); run on "$D"; rc=$?
ok "a settings file that is JSON but not an object: exit 2, untouched, refused BY NAME (not by a later jq error), no sidecar" '[ "$rc" -eq 2 ] && [ "$(sha256sum < "$S")" = "$b" ] && grep -q "is not a JSON object: refused, nothing written" "$T/err" && [ "$(wc -l < "$T/err")" -eq 1 ] && [ ! -e "$D/.claude/lane-style.prev.json" ]'
rm -f "$S"; printf '{"env":{"A":"1"}}\n' > "$T/elsewhere.json"; ln -s "$T/elsewhere.json" "$S"; b=$(sha256sum < "$T/elsewhere.json"); run on "$D"; rc=$?
ok "a settings file that is a symlink: exit 2, its target untouched" '[ "$rc" -eq 2 ] && [ -L "$S" ] && [ "$(sha256sum < "$T/elsewhere.json")" = "$b" ]'
rm -f "$S"
run on "$HOME"; rc=$?
ok "the HOME directory is refused (the lead and the owner start there): exit 2, nothing made" '[ "$rc" -eq 2 ] && [ ! -e "$HOME/.claude" ] && grep -q "not lanes" "$T/err"'
run on "$T/no-such-dir"; ok "a directory that does not exist: exit 2" '[ "$?" -eq 2 ]'
run bogus "$D"; ok "an unknown verb: exit 22" '[ "$?" -eq 22 ]'
run on "$D" extra; ok "too many arguments: exit 22" '[ "$?" -eq 22 ]'
run; ok "no argument: exit 22" '[ "$?" -eq 22 ]'
rm -rf "$D/.claude"; DREAMTEAM_LANE_STYLE='x"; rm -rf /' run on "$D"; rc=$?
ok "a style name that is not plain: exit 2, nothing made" '[ "$rc" -eq 2 ] && [ ! -e "$D/.claude" ]'
( cd "$D" && bash "$LS" on > /dev/null 2>&1 ); ok "with no DIR it is the current directory" '[ "$(jq -r .outputStyle "$S")" = dreamteam:lane ]'
run status "$D"; ok "status names the style file of this plugin tree" 'grep -qx "style file: $ROOT/output-styles/lane.md" "$T/out"'

echo
echo "lane-style: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
