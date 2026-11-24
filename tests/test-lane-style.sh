#!/usr/bin/env bash
# dreamteam — the token-saving output style `lane`, and the SessionStart hook that injects it into LANE sessions
# (Flow row d1a1c56a; xreview #284 r1 and r2).
#
#   • output-styles/lane.md         the style. Its WHOLE TEXT is repeated below and compared byte for byte: an
#                                   edit of the file without an edit here is red.
#   • scripts/lane-style-hook.sh    SessionStart (startup, resume, clear, compact): CONTEXT INJECTION, repeated at
#                                   each event, for a session whose tmux session name is EXACTLY one of
#                                   .laneStyle.lanes. Never the lead (by its record or its name), never katana,
#                                   never a session nobody listed.
#   • config.json .laneStyle        ships with NO lane named
#
# Hermetic: fixture configs, a lead.session fixture, a stub tmux (the ONLY source of the session's name and pane:
# the hook has no variable that tells it who it is), SessionStart payloads on stdin. Nothing here starts Claude
# Code. Real sessions (a lane, the same lane resumed and compacted, the lead, an unlisted session) and the output
# tokens before and after are measured by tests/probe-lane-restart.sh and tests/probe-lane-tokens.sh, by hand.
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

# ── the fixture world: a stub tmux is the only thing that says who the session is ─────────────────────────────
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$T/tmux.log"
case "\$(cat "$T/tmux-mode" 2>/dev/null)" in
  hang) sleep 30 ;;
  fail) exit 1 ;;
  *) cat "$T/tmux-who" ;;
esac
EOF
chmod +x "$T/bin/tmux"
SIDA=aaaaaaaa-1111-2222-3333-444444444444; SIDL=bbbbbbbb-1111-2222-3333-444444444444
cfg() { printf '%s\n' "$1" > "$T/config.json"; rm -f "$T/config.fxhost.json"; }
payload() { printf '{"session_id":"%s","source":"%s","hook_event_name":"SessionStart"}' "${2:-$SIDA}" "${1:-startup}"; }
# hk <tmux session name> [event] [session id] [-- env…]: one hook run as a pane 0.0 of that tmux session
hk() {
  local name=$1 ev=${2:-startup} sid=${3:-$SIDA}; shift; [ "$#" -gt 0 ] && shift; [ "$#" -gt 0 ] && shift; [ "${1:-}" = -- ] && shift
  echo "$name $name:0.0" > "$T/tmux-who"; : > "$T/tmux.log"
  payload "$ev" "$sid" | env PATH="$T/bin:$PATH" TMUX_PANE=%7 DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" "$@" bash "$HOOK" > "$T/out" 2> "$T/err"   # a caller's setting comes LAST, so it wins
}
styled() { jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string")' "$T/out" > /dev/null 2>&1; }
silent() { [ ! -s "$T/out" ]; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' "$T/out"; }
BODY="$(awk 'n >= 2 {print} /^---$/ {n++}' "$STYLE")"
LANES='{"laneStyle":{"lanes":["fx-luna","nebula"]}}'
rm -f "$T/state/lead.session" "$T/lane.log"

echo "── who is a lane: EXACT names from the list, nobody else ────────"
cfg '{}'; hk fx-luna; rc=$?
ok "no lane is listed (the shipped shape): NOBODY is styled" '[ "$rc" -eq 0 ] && silent'
cfg "$LANES"; hk fx-luna; rc=$?
ok "a session whose tmux name is in .laneStyle.lanes: exit 0 and ONE SessionStart JSON object" '[ "$rc" -eq 0 ] && styled && [ "$(jq -s length "$T/out")" = 1 ]'
ok "…the hook asked tmux about ITS OWN pane, and only that" '[ "$(cat "$T/tmux.log")" = "tmux display-message -p -t %7 #{session_name} #{session_name}:#{window_index}.#{pane_index}" ]'
ok "…the context is the WHOLE body of the style file, unchanged, after the stamp and the header" '[ "$(ctx | tail -n +4)" = "$BODY" ]'
ok "…it names the lane and says it REPLACES Insight instructions" 'ctx | sed -n 2p | grep -q "the dreamteam lane \"fx-luna\"" && ctx | sed -n 2p | grep -q "REPLACES any instruction in your context to write Insight blocks"'
ok "…the frontmatter is not sent" '! ctx | grep -q "keep-coding-instructions"'
for n in fx-luna-2 fx-lun xfx-luna FX-LUNA morpheus; do
  hk "$n"; if silent; then pass "a name that is not EXACTLY a listed one ($n): nothing"; else fail "$n was styled"; fi
done
cfg '{"laneStyle":{"lanes":["*","fx-*"]}}'; hk fx-luna
ok "the list holds names, not patterns: \"*\" and \"fx-*\" style nobody" 'silent'
cfg "$LANES"

echo "── it is INJECTION, at every event, and it leaves a trace ───────"
rm -f "$T/lane.log"
for ev in startup resume clear compact; do
  hk fx-luna "$ev"
  if styled && ctx | sed -n 1p | grep -qE "^\[lane style given [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} on $ev to fx-luna\]$"; then pass "on $ev: the style is given again, and its first line is a stamp naming the time, the event ($ev) and the lane"
  else fail "$ev: $(ctx 2>/dev/null | sed -n 1p)"; fi
done
ok "the hook's log has one line per injection: time, event, lane, session id" '[ "$(cut -d" " -f2- "$T/lane.log" | tr "\n" "|")" = "startup fx-luna $SIDA|resume fx-luna $SIDA|clear fx-luna $SIDA|compact fx-luna $SIDA|" ]'
hk fx-luna resume; a=$(ctx | tail -n +2); hk fx-luna resume
ok "two injections differ ONLY in the stamp: nothing is stored between them, so nothing can be lost by a restart" '[ "$(ctx | tail -n +2)" = "$a" ]'
n0=$(wc -l < "$T/lane.log"); hk morpheus resume
ok "a session that is not styled leaves no log line" '[ "$(wc -l < "$T/lane.log")" = "$n0" ]'
lane_pane() { echo "fx-luna fx-luna:0.0" > "$T/tmux-who"; }
lane_pane; printf 'garbage, not json' | env PATH="$T/bin:$PATH" TMUX_PANE=%7 DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$HOOK" > "$T/out" 2>/dev/null
ok "a payload that is not JSON: still styled, the event reads startup" 'styled && ctx | sed -n 1p | grep -q " on startup to fx-luna\]"'
lane_pane; payload 'compact; rm -rf /' | env PATH="$T/bin:$PATH" TMUX_PANE=%7 DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$HOOK" > "$T/out" 2>/dev/null
ok "an event name that is not one of the four is not echoed into the context or the log" 'styled && ! ctx | grep -q "rm -rf" && ! grep -q "rm -rf" "$T/lane.log"'
lane_pane; mkfifo "$T/held"; sleep 30 > "$T/held" & holder=$!; t0=$(date +%s)
env PATH="$T/bin:$PATH" TMUX_PANE=%7 DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$HOOK" > "$T/out" 2>/dev/null < "$T/held"; rc=$?; t1=$(date +%s)
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
ok "stdin held open and never written: the hook returns within its bound ($((t1 - t0)) s), exit 0, and the lane still gets its style" '[ "$rc" -eq 0 ] && [ $((t1 - t0)) -le 6 ] && styled'
hk fx-luna startup "$SIDA" -- DREAMTEAM_LANE_STYLE_LOG="$T/config.json/x.log"
ok "a log that cannot be written (its directory is a file) does not cost the lane its style" 'styled && [ ! -e "$T/config.json/x.log" ] && [ -f "$T/config.json" ]'

echo "── THE LEAD, by its role ────────────────────────────────────────"
cfg '{"laneStyle":{"lanes":["spire","fx-luna","fx-captain","fx-boss"]}}'
hk spire; ok "a session named spire is never styled, even when a config LISTS it as a lane (refused in the code)" 'silent'
hk fx-boss startup "$SIDA" -- DREAMTEAM_LEAD_SESSION=fx-boss; ok "the lead named by DREAMTEAM_LEAD_SESSION: nothing, though listed as a lane" 'silent'
cfg '{"laneStyle":{"lanes":["fx-luna","fx-captain"],"lead":["fx-captain"]}}'
hk fx-captain; ok "a lead added in .laneStyle.lead: nothing, though listed as a lane" 'silent'
cfg '{"laneStyle":{"lanes":["spire"],"lead":[]}}'; hk spire
ok "an EMPTY lead list does not make spire a lane (a config can add leads, never remove this one)" 'silent'
# by RECORD: lead.session names a session id and a pane; the lead may be called anything
cfg "$LANES"
printf 'session=%s\npane=other:3.1\ncwd=/x\n' "$SIDL" > "$T/state/lead.session"
hk fx-luna startup "$SIDL"; ok "the session whose ID is the one recorded in lead.session is the lead: nothing, though its tmux name is a listed lane" 'silent'
hk fx-luna startup "$SIDA"; ok "…another session of that same listed name is a lane" 'styled'
printf 'session=%s\npane=fx-luna:0.0\ncwd=/x\n' "$SIDL" > "$T/state/lead.session"
hk fx-luna startup "$SIDA"; ok "the session in the PANE recorded in lead.session is the lead (a new id after a restart): nothing" 'silent'
hk nebula startup "$SIDA"; ok "…a lane in another pane is still a lane" 'styled'
rm -f "$T/state/lead.session"; printf 'session=%s\npane=zz:9.9\n' "$SIDL" > "$T/real.session"; ln -s "$T/real.session" "$T/state/lead.session"
hk fx-luna; ok "a lead.session that is a symlink: who the lead is cannot be trusted, so NOBODY is styled (one line on stderr)" 'silent && grep -q "is a symlink" "$T/err"'
rm -f "$T/state/lead.session"
# RULING item 2: a record that EXISTS but is unreadable or malformed fails CLOSED: nobody is styled on that run
badrec() {  # badrec <name> <what the stderr line must say> ; the record is already in place
  hk fx-luna; local rc=$?
  if [ "$rc" -eq 0 ] && silent && [ "$(wc -l < "$T/err")" -eq 1 ] && grep -q "$2" "$T/err"; then pass "lead record $1: NOBODY is styled, exit 0, one line on stderr"; else fail "lead record $1: rc $rc out=$(head -c 60 "$T/out") err=$(cat "$T/err")"; fi
  rm -rf "$T/state/lead.session"
}
: > "$T/state/lead.session"; badrec "empty" "does not hold exactly one valid session= and one valid pane= line"
echo "garbage, not a record" > "$T/state/lead.session"; badrec "garbage" "does not hold exactly one valid"
printf 'session=%s\n' "$SIDL" > "$T/state/lead.session"; badrec "with a session line and NO pane line" "does not hold exactly one valid"
printf 'pane=zz:9.9\n' > "$T/state/lead.session"; badrec "with a pane line and NO session line" "does not hold exactly one valid"
printf 'session=not-an-id\npane=zz:9.9\n' > "$T/state/lead.session"; badrec "whose session id is not an id" "does not hold exactly one valid"
printf 'session=%s\npane=zz\n' "$SIDL" > "$T/state/lead.session"; badrec "whose pane is not a pane" "does not hold exactly one valid"
printf 'session=%s\nsession=%s\npane=zz:9.9\n' "$SIDL" "$SIDA" > "$T/state/lead.session"; badrec "with TWO session lines" "does not hold exactly one valid"
printf 'session=%s\npane=zz:9.9\npane=fx-luna:0.0\n' "$SIDL" > "$T/state/lead.session"; badrec "with TWO pane lines" "does not hold exactly one valid"
mkdir "$T/state/lead.session"; badrec "that is a DIRECTORY" "not a plain file, or unreadable"
if [ "$(id -u)" -ne 0 ]; then
  printf 'session=%s\npane=zz:9.9\n' "$SIDL" > "$T/state/lead.session"; chmod 000 "$T/state/lead.session"; badrec "that cannot be READ (mode 000)" "not a plain file, or unreadable"
fi
printf 'session=%s\npane=zz:9.9\ncwd=/x\nlaunch=bash /y\n' "$SIDL" > "$T/state/lead.session"; hk fx-luna
ok "(control: a WELL-FORMED record for another session and pane leaves a listed lane styled)" 'styled'
rm -f "$T/state/lead.session"

echo "── there is no variable that makes a session a lane ─────────────"
cfg "$LANES"
hk spire startup "$SIDA" -- DREAMTEAM_LANE_NAME=fx-luna
ok "a pane of spire with DREAMTEAM_LANE_NAME=fx-luna in its environment: nothing (round 2's seam is gone)" 'silent'
hk morpheus startup "$SIDA" -- DREAMTEAM_LANE_NAME=fx-luna; ok "an unlisted session with that variable: nothing" 'silent'
: > "$T/tmux.log"; payload startup | env DREAMTEAM_LANE_NAME=fx-luna PATH="$T/bin:$PATH" DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$HOOK" > "$T/out" 2>/dev/null; rc=$?
ok "outside tmux (no TMUX_PANE), with that variable: nothing, and tmux is not even asked" '[ "$rc" -eq 0 ] && silent && [ ! -s "$T/tmux.log" ]'
ok "the hook's code does not read such a variable at all" '! grep -q "DREAMTEAM_LANE_NAME" "$HOOK"'

echo "── never on katana; the off switch; hosts ───────────────────────"
hk fx-luna startup "$SIDA" -- DREAMTEAM_HOST=katana; ok "on katana a listed lane gets nothing (refused in the code)" 'silent'
cfg '{"laneStyle":{"lanes":["fx-luna"],"neverHosts":[]}}'; hk fx-luna startup "$SIDA" -- DREAMTEAM_HOST=katana
ok "…also when a config empties neverHosts" 'silent'
cfg '{"laneStyle":{"lanes":["fx-luna"],"neverHosts":["fxhost","other"]}}'; hk fx-luna; ok "a host named in .laneStyle.neverHosts: nothing" 'silent'
cfg '{"laneStyle":{"lanes":["fx-luna"],"neverHosts":["other"]}}'; hk fx-luna; ok "…a host that is not named there is not affected" 'styled'
cfg '{"laneStyle":{"lanes":["fx-luna"],"enabled":false}}'; hk fx-luna; ok "enabled=false: nothing, for anyone" 'silent'
cfg '{"laneStyle":{"lanes":[]}}'; printf '{"laneStyle":{"lanes":["fx-luna"]}}\n' > "$T/config.fxhost.json"; hk fx-luna
ok "THE DEPLOYMENT SHAPE: the base config lists nobody, this host's overlay lists its lanes: styled" 'styled'
hk fx-luna startup "$SIDA" -- DREAMTEAM_HOST=otherhost; ok "…and on another host that overlay does not apply: nothing" 'silent'
rm -f "$T/config.fxhost.json"

echo "── the hook fails toward NO style ───────────────────────────────"
for bad in '{"laneStyle":"on"}' '{"laneStyle":{"lanes":"fx-luna"}}' '{"laneStyle":{"lanes":["fx-luna"],"lead":"spire"}}' '{"laneStyle":{"lanes":[1,2]}}' '{"laneStyle":{"lanes":["fx-luna"],"enabled":"no"}}' '{"laneStyle":{"lanes":["fx-luna"],"neverHosts":"katana"}}'; do
  cfg "$bad"; hk fx-luna; rc=$?
  if [ "$rc" -eq 0 ] && silent && [ "$(wc -l < "$T/err")" -eq 1 ] && grep -q "not in its form: no style given" "$T/err"; then pass "a .laneStyle that is not in its form ($bad): nothing, one line on stderr, exit 0"; else fail "bad form $bad: rc $rc out=$(head -c 80 "$T/out") err=$(cat "$T/err")"; fi
done
cfg "$LANES"; printf '{"laneStyle": {"lead": ["x"],,}\n' > "$T/config.fxhost.json"; hk fx-luna; rc=$?
ok "the overlay of this host exists and is not JSON: nothing (the lead list may be in it), one line, exit 0" '[ "$rc" -eq 0 ] && silent && grep -q "cannot be read" "$T/err"'
rm -f "$T/config.fxhost.json"
cfg "$LANES"; printf '{"laneStyle":{"lead":["fx-luna"]}}\n' > "$T/config.fxhost.json"; hk fx-luna
ok "a lead named in the HOST overlay is honoured (the config is read merged)" 'silent'
rm -f "$T/config.fxhost.json"
cfg '{"laneStyle":{"lanes":["two words","a;b"]}}'
for n in 'two words' 'a;b'; do
  echo "$n $n:0.0" > "$T/tmux-who"; payload | env PATH="$T/bin:$PATH" TMUX_PANE=%7 DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$HOOK" > "$T/out" 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ] && silent; then pass "a session name that is not plain ($n), even listed: nothing"; else fail "name $n: rc $rc"; fi
done
cfg "$LANES"
echo fail > "$T/tmux-mode"; hk fx-luna; rc=$?; ok "tmux cannot say who the session is: nothing, exit 0" '[ "$rc" -eq 0 ] && silent'
echo hang > "$T/tmux-mode"; t0=$(date +%s); hk fx-luna; rc=$?; t1=$(date +%s)
ok "a tmux that does not answer: nothing, exit 0, within the bound ($((t1 - t0)) s)" '[ "$rc" -eq 0 ] && silent && [ $((t1 - t0)) -le 5 ]'
rm -f "$T/tmux-mode"

echo "── a broken style file gives nothing, never half a style ────────"
mkdir -p "$T/plug/scripts/lib" "$T/plug/output-styles"; cp "$HOOK" "$T/plug/scripts/"; cp "$ROOT/scripts/lib/config.sh" "$ROOT/scripts/lib/config_merge.py" "$T/plug/scripts/lib/"
ph() { echo "fx-luna fx-luna:0.0" > "$T/tmux-who"; payload | env PATH="$T/bin:$PATH" TMUX_PANE=%7 CLAUDE_PLUGIN_ROOT="$T/plug" DREAMTEAM_CONFIG="$T/config.json" LEAD_WATCHDOG_STATE="$T/state" DREAMTEAM_LANE_STYLE_LOG="$T/lane.log" bash "$T/plug/scripts/lane-style-hook.sh" > "$T/out" 2> "$T/err"; }
n0=$(wc -l < "$T/lane.log"); ph; rc=$?
ok "no style file: nothing, exit 0, one line, and no log line (nothing was given)" '[ "$rc" -eq 0 ] && silent && grep -q "is missing: no style given" "$T/err" && [ "$(wc -l < "$T/lane.log")" = "$n0" ]'
printf -- '---\nname: lane\n---\n' > "$T/plug/output-styles/lane.md"; ph; rc=$?
ok "a style file with no body: nothing, exit 0" '[ "$rc" -eq 0 ] && silent'
cp "$STYLE" "$T/plug/output-styles/lane.md"; ph; ok "(fixture: with the real file that copy styles)" 'styled'

echo "── --who, for the lead ──────────────────────────────────────────"
cfg '{"laneStyle":{"lanes":["fx-luna"]}}'
who() { DREAMTEAM_CONFIG="$T/config.json" bash "$HOOK" --who "$1" 2>&1; }
ok "--who says lane (with the lead-record caveat), lead, and not listed, each with its reason" 'who fx-luna | grep -q "^fx-luna: LANE by its name (fx-luna is listed in .laneStyle.lanes); .* UNLESS that session is the one recorded in lead.session" && who spire | grep -q "^spire: not styled (spire is the lead)" && who jp-main | grep -q "^jp-main: not styled (jp-main is not in .laneStyle.lanes"'

echo "── wired at EVERY SessionStart event; the shipped config ────────"
ENTRY=$(python3 -I -c "import json,sys; h=json.load(open(sys.argv[1])); e=[(g.get('matcher',''), x) for g in h['hooks']['SessionStart'] for x in g['hooks'] if 'lane-style-hook.sh' in x['command']]; assert len(e)==1; m,x=e[0]; print(m); print(x['timeout']); print(x['command'])" "$ROOT/hooks/hooks.json" 2>/dev/null)
ok "hooks.json registers the hook once on SessionStart" '[ -n "$ENTRY" ]'
ok "…for startup AND resume AND clear AND compact" '[ "$(sed -n 1p <<<"$ENTRY" | tr "|" "\n" | sort | tr "\n" " ")" = "clear compact resume startup " ]'
ok "…with a timeout in seconds and the plain bash form" '[ "$(sed -n 2p <<<"$ENTRY")" -le 10 ] && [ "$(sed -n 3p <<<"$ENTRY")" = "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/lane-style-hook.sh\"" ]'
ok "the shipped config names NO lane, no extra lead, and refuses katana" '[ "$(jq -c "[.laneStyle.enabled, .laneStyle.lanes, .laneStyle.lead, .laneStyle.neverHosts]" "$ROOT/config.json")" = "[true,[],[],[\"katana\"]]" ]'
cp "$ROOT/config.json" "$T/config.json"; rm -f "$T/config.fxhost.json"
a=""; for n in fx-luna nebula-management spire jp-main; do hk "$n"; silent || a="$a $n"; done
ok "…with the shipped config itself NOBODY is styled (a lane, the lead, an owner session)" '[ -z "$a" ]'
ok "the opt-in pieces of round 1 are gone (no per-directory script, no settings file to pass by hand)" '[ ! -e "$ROOT/scripts/lane-style.sh" ] && [ ! -e "$ROOT/config/lane.settings.json" ]'
ok "the hook's own header says what it is: context injection at each event, not an outputStyle setting" 'grep -q "this is context INJECTION, repeated at each start, resume, clear and compaction" "$HOOK" && grep -q "not an .outputStyle. setting" "$HOOK"'
if git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  ok "the hook is committed executable" '[ "$(git -C "$ROOT" ls-files -s -- scripts/lane-style-hook.sh | cut -c1-6)" = 100755 ]'
fi

echo
echo "lane-style: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
