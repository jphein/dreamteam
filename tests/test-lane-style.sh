#!/usr/bin/env bash
# dreamteam — the token-saving output style `lane`, and the SessionStart hook that gives it to every lane session
# by ROLE (Flow row d1a1c56a; xreview #284 r1).
#
#   • output-styles/lane.md         the style. Its WHOLE TEXT is repeated below and compared byte for byte, so a
#                                   review of the source diff reads the style itself, and an edit of the file
#                                   without an edit here is red.
#   • scripts/lane-style-hook.sh    SessionStart (startup, resume, clear, compact): a lane session gets the style
#                                   as context; the lead never does. The role is the tmux session name.
#   • config.json .laneStyle        lead names, exclude globs, lane globs, the off switch
#
# Hermetic: fixture configs, a stub tmux, the hook's own seam for the session name. Nothing here starts Claude
# Code. What a real session does with it (the style quoted back by a lane and after a restart, absent for the
# lead, and the output tokens before and after) is measured by tests/probe-lane-restart.sh and
# tests/probe-lane-tokens.sh, by hand, with the numbers on the PR.
#
# Run standalone:  bash tests/test-lane-style.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/lane-style-hook.sh"; STYLE="$ROOT/output-styles/lane.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
T="$(mktemp -d)" && T="$(cd "$T" && pwd -P)" || { echo "FAIL: no temp dir"; exit 1; }
trap 'rm -rf -- "$T"' EXIT
unset DREAMTEAM_LEAD_SESSION DREAMTEAM_LANE_NAME TMUX TMUX_PANE
export DREAMTEAM_HOST=fxhost

echo "── the style, word for word ─────────────────────────────────────"
cat > "$T/expected.md" <<'LANE_STYLE_EOF'
---
name: lane
description: Token-saving output for dreamteam lanes. The result first, then Changed / Checked / Evidence / Not verified, twelve lines at most.
keep-coding-instructions: true
---

You are a lane in a fleet. Your reader is the lead or the owner, reading many lanes at once. Every line you write costs them attention and costs tokens.

**This limits what you WRITE, never what you DO.** Run every check, test and verification you would run without this style, and read what they print. A shorter report of unverified work is worse than a long one.

## A message that reports work

1. **First line: the bottom line.** What is now true, or what blocks it, in one sentence. No greeting, no "I'll", no lead-in.
2. Then only the parts that have content, one or two lines each, in this order and with these labels:
   - **Changed:** what is different now, in plain words.
   - **Checked:** what you ran against the real thing, and what it said.
   - **Evidence:** something another person can rerun or open: a sha, an id, a path, a count, a log line.
   - **Not verified:** what you inferred or did not check. This part is never dropped from a report of finished work; write "nothing" only when that is true.
3. **Twelve lines at most**, the first line included. What does not fit belongs in a file, a PR or the row: give its path or id.

## Between reports

- While working, write nothing unless it changes what the reader would do. One short line before a long step is enough. Do not narrate each tool call.
- Never restate the request, never repeat what an earlier message said, never summarise what you just wrote.
- No closing offers and no "want me to…?" questions. When a decision is truly the reader's, state it and your recommendation in one line.
- A question gets its answer in one to three sentences. No headings, tables or nested bullets in a short answer.
- No "Insight" blocks, no teaching asides, no praise, no apology longer than one clause.

## What the limit yields to

The twelve lines give way, as far as needed and no further, to anything on this list. None of it is ever cut to fit:

- A failure: the command, the error and the failing output, complete.
- What the reader needs in order to act safely: a destructive step and what it destroys, a security finding, an emergency (at the TOP, in bold).
- Every "Not verified" item, and every disclosure your instructions require of a report, such as a `surprise:` line and an `armed windows:` line.
- The tags your instructions require (`📜 rule:`, `⚙ skill:`, `⚓ hook:`, `🧠 memory:`): one terse tag each, on the line it applies to.
- Anything the reader asked to see in full.

What you write into files, commits, pull requests and Flow rows follows those places' own rules, not this limit.
LANE_STYLE_EOF
ok "output-styles/lane.md is exactly the text above" 'cmp -s "$T/expected.md" "$STYLE"'
fm() { awk '/^---$/ {n++; next} n == 1' "$STYLE"; }
ok "the style is named lane, keeps the coding instructions, and is NOT forced for the plugin" 'fm | grep -qx "name: lane" && fm | grep -qx "keep-coding-instructions: true" && ! fm | grep -q "force-for-plugin"'
for must in 'This limits what you WRITE, never what you DO' 'Run every check, test and verification you would run without this style' \
            'First line: the bottom line' 'Twelve lines at most' 'This part is never dropped from a report of finished work' \
            'Never restate the request' 'No closing offers' 'No "Insight" blocks' 'None of it is ever cut to fit' \
            'A failure: the command, the error and the failing output, complete' 'Every "Not verified" item' \
            'a `surprise:` line and an `armed windows:` line' 'The tags your instructions require'; do
  if grep -qF -- "$must" "$STYLE"; then pass "the style says: $must"; else fail "the style lacks: $must"; fi
done
ok "the four parts come in the order Changed, Checked, Evidence, Not verified" '[ "$(grep -o "\*\*\(Changed\|Checked\|Evidence\|Not verified\):\*\*" "$STYLE" | tr "\n" " ")" = "**Changed:** **Checked:** **Evidence:** **Not verified:** " ]'
ok "the style is small: it is sent at every session start (under 3500 bytes)" '[ "$(wc -c < "$STYLE")" -lt 3500 ]'

echo "── the hook: who is a lane ──────────────────────────────────────"
mkdir -p "$T/bin"
cfg() { printf '%s\n' "$1" > "$T/config.json"; rm -f "$T/config.fxhost.json"; }
# hook <name or ""> [env…]: runs the hook with the session-name seam; stdout → $T/out, stderr → $T/err
hook() { local n=$1; shift; env ${n:+DREAMTEAM_LANE_NAME="$n"} DREAMTEAM_CONFIG="$T/config.json" "$@" bash "$HOOK" > "$T/out" 2> "$T/err" < /dev/null; }
styled() { jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string")' "$T/out" > /dev/null 2>&1; }
silent() { [ ! -s "$T/out" ]; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' "$T/out"; }
BODY="$(awk 'n >= 2 {print} /^---$/ {n++}' "$STYLE")"

cfg '{}'
hook fx-luna; rc=$?
ok "a lane (default config): exit 0 and ONE JSON object for SessionStart" '[ "$rc" -eq 0 ] && styled && [ "$(jq -s length "$T/out")" = 1 ]'
ok "…its context is the WHOLE body of the style file, unchanged" '[ "$(ctx | tail -n +3)" = "$BODY" ]'
ok "…it names the lane and says it REPLACES Insight instructions" 'ctx | head -1 | grep -q "the dreamteam lane \"fx-luna\"" && ctx | head -1 | grep -q "REPLACES any instruction in your context to write Insight blocks"'
ok "…the frontmatter is not sent" '! ctx | grep -q "keep-coding-instructions"'
hook fx-luna; cp "$T/out" "$T/first"; hook fx-luna
ok "a second start of the same lane (a restart, a resume) gives exactly the same: nothing is remembered, nothing can be lost" 'cmp -s "$T/first" "$T/out"'
hook spire; rc=$?
ok "the lead (spire, the default lead name): exit 0, NOTHING printed" '[ "$rc" -eq 0 ] && silent'
hook fx-boss DREAMTEAM_LEAD_SESSION=fx-boss
ok "the lead named by DREAMTEAM_LEAD_SESSION: nothing" 'silent'
cfg '{"laneStyle":{"lead":["fx-captain"]}}'
hook fx-captain; ok "a lead named in .laneStyle.lead: nothing" 'silent'
hook spire; ok "…and with another lead configured, a session named spire is a lane like any other" 'styled'
cfg '{"laneStyle":{"lead":["fx-captain"],"lanes":["fx-captain","fx-*"]}}'
hook fx-captain; ok "a name that is BOTH a lead and a lane pattern: the lead wins, nothing" 'silent'
cfg '{"laneStyle":{"lead":[],"lanes":["*"]}}'
hook fx-boss DREAMTEAM_LEAD_SESSION=fx-boss; ok "no config can make the lead named by the environment a lane (an empty lead list)" 'silent'
cfg '{"laneStyle":{"exclude":["jp-*","manager"]}}'
hook jp-main; ok "an excluded session (a glob): nothing" 'silent'
hook manager; ok "an excluded session (a name): nothing" 'silent'
hook jpx; ok "…a name the exclude glob does not match is a lane" 'styled'
cfg '{"laneStyle":{"lanes":["luna-*","nebula*"]}}'
hook luna-map; ok "lane patterns: a matching name is styled" 'styled'
hook morpheus-roam; ok "lane patterns: a name that matches none is not" 'silent'
cfg '{"laneStyle":{"enabled":false}}'
hook fx-luna; ok "enabled=false: nothing, for anyone" 'silent'
rm -f "$T/config.json"; hook fx-luna; a=$(styled && echo y); hook spire
ok "no config file at all: the defaults (a lane is styled, spire is not)" '[ "$a" = y ] && silent'

echo "── the hook fails toward NO style ───────────────────────────────"
for bad in '{"laneStyle":"on"}' '{"laneStyle":{"lead":"spire"}}' '{"laneStyle":{"lanes":[1,2]}}' '{"laneStyle":{"enabled":"no"}}' '{"laneStyle":{"exclude":{"a":1}}}'; do
  cfg "$bad"; hook fx-luna; rc=$?
  if [ "$rc" -eq 0 ] && silent && [ "$(wc -l < "$T/err")" -eq 1 ] && grep -q "not in its form: no style given" "$T/err"; then pass "a .laneStyle that is not in its form ($bad): nothing, one line on stderr, exit 0"; else fail "bad form $bad: rc $rc out=$(head -c 80 "$T/out") err=$(cat "$T/err")"; fi
done
cfg '{}'; printf '{"laneStyle": {"lead": ["x"],,}\n' > "$T/config.fxhost.json"; hook fx-luna; rc=$?
ok "the overlay of this host exists and is not JSON: nothing (the lead list may be in it), one line, exit 0" '[ "$rc" -eq 0 ] && silent && grep -q "cannot be read" "$T/err"'
rm -f "$T/config.fxhost.json"
cfg '{}'; printf '{"laneStyle":{"lead":["fx-luna"]}}\n' > "$T/config.fxhost.json"; hook fx-luna
ok "the lead list of the HOST overlay is honoured (the config is read merged)" 'silent'
rm -f "$T/config.fxhost.json"
for n in 'two words' 'a;b' '$(id)' '../x'; do
  cfg '{}'; hook "$n"; rc=$?
  if [ "$rc" -eq 0 ] && silent; then pass "a session name that is not plain ($n): nothing"; else fail "name $n: rc $rc"; fi
done

echo "── the hook reads the role from tmux ────────────────────────────"
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$T/tmux.log"
case "\$(cat "$T/tmux-mode" 2>/dev/null)" in
  hang) sleep 30 ;;
  fail) exit 1 ;;
  *) cat "$T/tmux-name" ;;
esac
EOF
chmod +x "$T/bin/tmux"; cfg '{}'
tm() { : > "$T/tmux.log"; env "$@" PATH="$T/bin:$PATH" DREAMTEAM_CONFIG="$T/config.json" bash "$HOOK" > "$T/out" 2> "$T/err" < /dev/null; }
tm; rc=$?
ok "not in tmux (no TMUX_PANE): nothing, and tmux is not even asked" '[ "$rc" -eq 0 ] && silent && [ ! -s "$T/tmux.log" ]'
echo fx-luna > "$T/tmux-name"; rm -f "$T/tmux-mode"; tm TMUX_PANE=%7
ok "in a pane of the tmux session fx-luna: styled, and the pane it asked about is its own" 'styled && grep -qxF "tmux display-message -p -t %7 #{session_name}" "$T/tmux.log" && ctx | head -1 | grep -q "\"fx-luna\""'
echo spire > "$T/tmux-name"; tm TMUX_PANE=%7
ok "in a pane of the tmux session spire: nothing" 'silent'
echo fail > "$T/tmux-mode"; tm TMUX_PANE=%7; rc=$?
ok "tmux cannot say the session name: nothing, exit 0" '[ "$rc" -eq 0 ] && silent'
echo hang > "$T/tmux-mode"; t0=$(date +%s); tm TMUX_PANE=%7; rc=$?; t1=$(date +%s)
ok "a tmux that does not answer: nothing, exit 0, within the bound ($((t1 - t0)) s)" '[ "$rc" -eq 0 ] && silent && [ $((t1 - t0)) -le 5 ]'
rm -f "$T/tmux-mode"

echo "── a broken style file gives nothing, never half a style ────────"
mkdir -p "$T/plug/scripts/lib" "$T/plug/output-styles"; cp "$HOOK" "$T/plug/scripts/"; cp "$ROOT/scripts/lib/config.sh" "$ROOT/scripts/lib/config_merge.py" "$T/plug/scripts/lib/"
cfg '{}'
ph() { env DREAMTEAM_LANE_NAME=fx-luna CLAUDE_PLUGIN_ROOT="$T/plug" DREAMTEAM_CONFIG="$T/config.json" bash "$T/plug/scripts/lane-style-hook.sh" > "$T/out" 2> "$T/err" < /dev/null; }
ph; rc=$?; ok "no style file: nothing, exit 0, one line" '[ "$rc" -eq 0 ] && silent && grep -q "is missing: no style given" "$T/err"'
printf -- '---\nname: lane\n---\n' > "$T/plug/output-styles/lane.md"; ph; rc=$?
ok "a style file with no body: nothing, exit 0" '[ "$rc" -eq 0 ] && silent'
cp "$STYLE" "$T/plug/output-styles/lane.md"; ph; ok "(fixture: with the real file that copy styles)" 'styled'

echo "── --who, for the lead ──────────────────────────────────────────"
cfg '{"laneStyle":{"exclude":["jp-*"]}}'
who() { DREAMTEAM_CONFIG="$T/config.json" bash "$HOOK" --who "$1" 2>&1; }
ok "--who says lane, lead and excluded, each with its reason" 'who fx-luna | grep -q "^fx-luna: LANE, styled at every session start (.*lane pattern" && who spire | grep -q "^spire: not styled (spire is a lead" && who jp-main | grep -q "^jp-main: not styled (jp-main matches the exclude pattern jp-\*)"'

echo "── wired at EVERY session start, the shipped config ─────────────"
ENTRY=$(python3 -I -c "import json,sys; h=json.load(open(sys.argv[1])); e=[(g.get('matcher',''), x) for g in h['hooks']['SessionStart'] for x in g['hooks'] if 'lane-style-hook.sh' in x['command']]; assert len(e)==1; m,x=e[0]; print(m); print(x['timeout']); print(x['command'])" "$ROOT/hooks/hooks.json" 2>/dev/null)
ok "hooks.json registers the hook once on SessionStart" '[ -n "$ENTRY" ]'
ok "…for startup AND resume AND clear AND compact: a restart, a resume and a compaction all give the style again" '[ "$(sed -n 1p <<<"$ENTRY" | tr "|" "\n" | sort | tr "\n" " ")" = "clear compact resume startup " ]'
ok "…with a timeout in seconds and the plain bash form" '[ "$(sed -n 2p <<<"$ENTRY")" -le 10 ] && [ "$(sed -n 3p <<<"$ENTRY")" = "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/lane-style-hook.sh\"" ]'
ok "the shipped config: on, the lead spire named, every other tmux session a lane" '[ "$(jq -c "[.laneStyle.enabled, .laneStyle.lead, .laneStyle.exclude, .laneStyle.lanes]" "$ROOT/config.json")" = "[true,[\"spire\"],[],[\"*\"]]" ]'
env -u DREAMTEAM_CONFIG DREAMTEAM_LANE_NAME=spire bash "$HOOK" > "$T/out" 2>/dev/null < /dev/null; a=$(silent && echo y)
env -u DREAMTEAM_CONFIG DREAMTEAM_LANE_NAME=fx-luna bash "$HOOK" > "$T/out" 2>/dev/null < /dev/null
ok "…with the shipped config itself: spire gets nothing, a lane gets the style" '[ "$a" = y ] && styled'
ok "the opt-in pieces of round 1 are gone (no per-directory script, no settings file to pass by hand)" '[ ! -e "$ROOT/scripts/lane-style.sh" ] && [ ! -e "$ROOT/config/lane.settings.json" ]'
if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  ok "the hook is committed executable" '[ "$(git -C "$ROOT" ls-files -s -- scripts/lane-style-hook.sh | cut -c1-6)" = 100755 ]'
fi

echo
echo "lane-style: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
