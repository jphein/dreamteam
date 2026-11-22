#!/usr/bin/env bash
# scripts/lib/pane_plain.py: a FAINT line in the input box is Claude Code's suggestion, not typed text.
# Fixtures are `tmux capture-pane -p -e` shaped text (escape codes kept). 2026-11-21: four "lines signed by the
# lead, typed but never sent" were such placeholders; a capture without -e cannot tell them from typed text.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PP="${PANE_PLAIN:-$ROOT/scripts/lib/pane_plain.py}"
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
E=$'\033'
typed() { printf '%s' "$1" | python3 -I "$PP" --typed; }
ghost() { printf '%s' "$1" | python3 -I "$PP" --ghost; }
plain() { printf '%s' "$1" | python3 -I "$PP"; }
is() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', want '$3'"; }

FAINT="  ...transcript...
──── @lane ──
❯ ${E}[2mSen 17:00: go on round 6 when the mutants are in${E}[0m
────
  Fable 5.2 · max"
is "a faint prompt line holds no typed text" "$(typed "$FAINT")" ""
is "the faint text is reported as the suggestion" "$(ghost "$FAINT")" "Sen 17:00: go on round 6 when the mutants are in"
is "the plain view shows an empty input box" "$(plain "$FAINT" | sed -n 3p)" "❯"
plain "$FAINT" | grep -q "go on round 6" && bad "the suggestion is still in the plain view" || ok
plain "$FAINT" | grep -q "@lane" && plain "$FAINT" | grep -q "Fable 5.2" && ok || bad "other lines were lost"
plain "$FAINT" | grep -q "$E" && bad "escape codes left in the plain view" || ok

TYPED="──── @lane ──
❯ ${E}[39mrun the tests now${E}[0m
────"
is "typed text is typed text" "$(typed "$TYPED")" "run the tests now"
is "typed text has no suggestion" "$(ghost "$TYPED")" ""
is "the plain view keeps typed text" "$(plain "$TYPED" | sed -n 2p)" "❯ run the tests now"

# typed text followed by a faint completion: the typed part stays, the completion goes
MIXED="❯ run the${E}[2m tests now and report${E}[22m"
is "typed + faint completion: only the typed part" "$(typed "$MIXED")" "run the"
is "typed + faint completion: the completion is the suggestion" "$(ghost "$MIXED")" "tests now and report"

# the ways faint is switched on and off
is "SGR 2 with other parameters (2;37)" "$(typed "❯ ${E}[2;37mghost${E}[0m")" ""
is "SGR with colons (38:5:8 then 2)" "$(typed "❯ ${E}[38:5:8m${E}[2mghost${E}[m")" ""
is "an empty SGR resets faint" "$(typed "❯ ${E}[2mghost${E}[mreal")" "real"
is "SGR 22 resets faint" "$(typed "❯ ${E}[2mghost${E}[22mreal")" "real"
is "SGR 0 resets faint" "$(typed "❯ ${E}[2mghost${E}[0mreal")" "real"
is "bold (1) is not faint" "$(typed "❯ ${E}[1mloud${E}[0m")" "loud"
is "faint does not leak into the next line" "$(typed "${E}[2mdim footer
❯ real")" "real"
# a bordered input box, as Claude Code draws it
is "a box border before the prompt" "$(typed "│ ❯ ${E}[2mghost${E}[0m                │")" ""
is "a box border, typed" "$(typed "│ ❯ real text   │")" "real text"
# the LAST prompt line is the live one
is "the last prompt line wins" "$(typed "❯ old typed line
output
❯ ${E}[2mghost${E}[0m")" ""
# faint text on a line that is NOT the input box is real output and stays
is "faint text elsewhere is kept" "$(plain "${E}[2m  ? for shortcuts${E}[0m")" "  ? for shortcuts"
# no escape codes at all (a capture taken without -e): nothing can be told apart, nothing is hidden
is "without escape codes the text passes through" "$(typed "❯ Sen 17:00: looks typed")" "Sen 17:00: looks typed"
# other control sequences are stripped, not shown
is "cursor and OSC sequences are dropped" "$(plain "${E}[?25l${E}]0;title${E}\\hello${E}[K")" "hello"
# bytes that are not UTF-8 survive
printf '\xe2\x9d\xaf real \xff\xfe' | python3 -I "$PP" --typed | od -An -c | grep -q '377 376' && ok || bad "non-UTF-8 bytes were lost"
# no prompt line at all
is "no input box: nothing typed" "$(typed "just output")" ""
is "no input box: no suggestion" "$(ghost "just output")" ""
python3 -I "$PP" --nope </dev/null >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "an unknown option is not 22"
# the helper never hides text when it fails inside: the input comes back with codes stripped
out=$(printf '❯ \033[2mghost\033[0m' | python3 -I -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("pp",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
def boom(t): raise RuntimeError("x")
m.process=boom; sys.argv=["pane_plain.py"]; sys.exit(m.main(sys.argv))' "$PP"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "❯ ghost" ] && ok || bad "on an internal error the text was not passed through whole: rc=$rc out='$out'"

echo "pane-plain: $pass passed, $fail failed"
[ "$fail" = 0 ]
