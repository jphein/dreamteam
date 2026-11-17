#!/usr/bin/env bash
# dreamteam tests — scripts/self-audit.sh: the weekly audit's CHECK line and its failure report.
#
# The 2026-11-15 audit failed one suite and nothing outside the journal said so: there was no CHECK line, and the
# journal kept only the LAST 40 lines of the suite run, so the failing suite's own FAIL lines were cut off. These tests
# run the real self-audit.sh against a fake plugin root whose tests/run.sh is a stub, with HOME, the state dir and the
# checks dir in a temp dir and curl stubbed (the palace answer is a fixture): no network, no real state touched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SA="$ROOT/scripts/self-audit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# curl stub: prints $FAKE_PALACE_CODE as the HTTP code (the audit's only network call)
mkdir -p "$TMP/bin"
printf '%s\n' '#!/bin/bash' 'printf "%s" "${FAKE_PALACE_CODE:-200}"' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

mkroot() {  # mkroot <name> <run.sh body or "">  → a fake root with a palace env file (URL only; curl is stubbed)
  local r="$TMP/$1"; mkdir -p "$r/scripts" "$r/tests" "$r/home/.config/palace-daemon" "$r/state" "$r/checks"
  cp "$SA" "$r/scripts/self-audit.sh"; mkdir -p "$r/scripts/lib"; cp "$ROOT/scripts/lib/check-line.sh" "$r/scripts/lib/"
  echo 'PALACE_DAEMON_URL=http://palace.invalid' > "$r/home/.config/palace-daemon/env"
  [ -n "$2" ] && printf '%s\n' "$2" > "$r/tests/run.sh"
  echo "$r"
}
audit() {  # audit <root> [name]  → stdout+stderr to $root/out, rc to $root/rc
  local r="$1"
  HOME="$r/home" PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$r" DREAMTEAM_STATE="$r/state" DREAMTEAM_CHECKS_DIR="$r/checks" \
    DREAMTEAM_CHECK_NAME="${2-dreamteam-audit}" bash "$r/scripts/self-audit.sh" > "$r/out" 2>&1; echo $? > "$r/rc"
}
line() { cat "$1/checks/dreamteam-audit.line" 2>/dev/null; }
SHAPE='^CHECK dreamteam-audit (ok|warn|fail) · [^·]+ · [^·]+$'   # exactly three segments: the Watch splits at the FIRST " · "
GREEN='echo "━━━ test-a.sh"; echo "PASS: a"; echo "═══"; echo "ALL SUITES PASS (40/40)"; exit 0'

bash -n "$SA" && ok "bash -n self-audit.sh" || bad "bash -n"

# 1. all green, palace answering, no statusline capture → ok with the suite count, one line, no temp file left
R=$(mkroot green "$GREEN"); audit "$R"; L=$(line "$R")
[[ "$L" =~ $SHAPE ]] && ok "green: line has the fleet shape" || bad "green: shape: '$L'"
[[ "$L" == "CHECK dreamteam-audit ok · suites 40/40, "* ]] && ok "green: ok · suites 40/40" || bad "green: '$L'"
[ "$(cat "$R/rc")" = 0 ] && ok "green: exit 0" || bad "green: rc $(cat "$R/rc")"
[ "$(wc -l < "$R/checks/dreamteam-audit.line")" = 1 ] && ok "green: exactly one line" || bad "green: line count"
[ "$(ls -A "$R/checks")" = "dreamteam-audit.line" ] && ok "green: no temp file left in the checks dir" || bad "green: leftovers: $(ls -A "$R/checks" | tr '\n' ' ')"

# 2. one suite failed → fail naming it; the failing suite's FAIL line survives 80 later lines in the report
BODY='echo "━━━ test-standards.sh"; echo "PASS: s1"; echo "FAIL: wrong message: NOT inside tmux"; echo "  → test-standards.sh: FAILED (exit 1)"'
BODY="$BODY"'; for i in $(seq 1 80); do echo "PASS: later suite line $i"; done; echo "═══"; echo "FAILED: 1/39 suites — test-standards.sh"; exit 1'
R=$(mkroot red "$BODY"); audit "$R"; L=$(line "$R")
[[ "$L" =~ $SHAPE ]] && ok "red: line has the fleet shape" || bad "red: shape: '$L'"
[[ "$L" == "CHECK dreamteam-audit fail · suites 38/39, failing test-standards.sh, "* ]] && ok "red: fail · suites 38/39, failing test-standards.sh (one fact segment)" || bad "red: '$L'"
[[ "$L" == *"fix test-standards.sh, owner Sen" ]] && ok "red: next names the suite to fix" || bad "red: next: '$L'"
grep -q "FAIL: wrong message: NOT inside tmux" "$R/out" && ok "red: the failing suite's FAIL line survives 80 later lines" || bad "red: FAIL line cut from the report"
[ "$(cat "$R/rc")" = 0 ] && ok "red: still exit 0 (a report, not a gate)" || bad "red: rc $(cat "$R/rc")"

# 3. unreadable summaries are fail, never ok: missing run.sh, no summary, success string NOT on the last line,
#    inconsistent counts, zero suites, a pass summary with a non-zero exit
unreadable() {  # unreadable <case> <body>
  local R; R=$(mkroot "$1" "$2"); audit "$R"
  [[ "$(line "$R")" == "CHECK dreamteam-audit fail · suites unreadable"* ]] && ok "unreadable ($1): fail, not ok" || bad "unreadable ($1): '$(line "$R")'"
}
unreadable missing ""
unreadable nosummary 'echo "something else"; exit 0'
unreadable notlast 'echo "ALL SUITES PASS (40/40)"; echo "then it died"; exit 0'
unreadable inconsistent 'echo "ALL SUITES PASS (1/40)"; exit 0'
unreadable zero 'echo "ALL SUITES PASS (0/0)"; exit 0'
unreadable passrc1 'echo "ALL SUITES PASS (40/40)"; exit 1'
unreadable failrc0 'echo "FAILED: 1/40 suites — test-x.sh"; exit 0'
unreadable failtoomany 'echo "FAILED: 41/40 suites — test-x.sh"; exit 1'
unreadable noname 'echo "FAILED: 1/40 suites — "; exit 1'
unreadable punctname 'echo "FAILED: 1/40 suites — ;;;"; exit 1'
unreadable namecount 'echo "FAILED: 2/40 suites — test-a.sh"; exit 1'
unreadable hugecount 'echo "FAILED: 1/9999999999999999999999 suites — test-x.sh"; exit 1'
# leading zeros are decimal, never a shell octal abort: published, exit 0
R=$(mkroot octal 'echo "FAILED: 1/09 suites — test-x.sh"; exit 1'); audit "$R"; L=$(line "$R")
[ "$(cat "$R/rc")" = 0 ] && [[ "$L" == "CHECK dreamteam-audit fail · suites 8/9, failing test-x.sh, "* ]] \
  && ok "counts: '1/09' reads as decimal (8/9), published, exit 0" || bad "octal: rc=$(cat "$R/rc") '$L'"

# 4. health: green suites with the palace down, or statusline drift, are warn (naming what), never ok
R=$(mkroot palace-down "$GREEN"); FAKE_PALACE_CODE=000 audit "$R"; L=$(line "$R")
[[ "$L" == "CHECK dreamteam-audit warn · suites 40/40, "*"palace UNREACHABLE"*"check palace, owner Sen" ]] && ok "health: palace unreachable → warn naming the palace" || bad "palace-down: '$L'"
R=$(mkroot palace-noenv "$GREEN"); rm "$R/home/.config/palace-daemon/env"; audit "$R"; L=$(line "$R")
[[ "$L" == "CHECK dreamteam-audit warn · "*"palace no-env-file"* ]] && ok "health: palace unmeasured (no env) → warn" || bad "palace-noenv: '$L'"
R=$(mkroot drift "$GREEN"); echo '{"x":1}' > "$R/state/statusline-payload.json"; audit "$R"; L=$(line "$R")
[[ "$L" == "CHECK dreamteam-audit warn · "*"statusline DRIFT"*"check statusline, owner Sen" ]] && ok "health: statusline drift → warn naming the statusline" || bad "drift: '$L'"

# 5. the line also lands on stdout (the journal), beside the old summary
R=$(mkroot stdout 'echo "ALL SUITES PASS (3/3)"; exit 0'); audit "$R"
grep -q '^CHECK dreamteam-audit ok · suites 3/3' "$R/out" && ok "stdout carries the CHECK line" || bad "stdout: no CHECK line"
grep -q '^self-audit ' "$R/out" && ok "stdout keeps the self-audit summary" || bad "summary line gone"

# 6. publication safety
#  a) a SYMLINK at the destination is replaced, never followed (a direct write would overwrite the sentinel)
R=$(mkroot symlink "$GREEN"); echo SENTINEL > "$TMP/sentinel-a"; ln -s "$TMP/sentinel-a" "$R/checks/dreamteam-audit.line"; audit "$R"
[ "$(cat "$TMP/sentinel-a")" = SENTINEL ] && [ -f "$R/checks/dreamteam-audit.line" ] && [ ! -L "$R/checks/dreamteam-audit.line" ] \
  && ok "publish: a symlink at the destination is replaced, its target untouched" || bad "publish symlink: sentinel=$(cat "$TMP/sentinel-a")"
#  b) a DIRECTORY at the destination: nothing is moved inside it, exit 0, line still on stdout
R=$(mkroot dirdest "$GREEN"); mkdir "$R/checks/dreamteam-audit.line"; audit "$R"
[ -z "$(ls -A "$R/checks/dreamteam-audit.line")" ] && [ "$(cat "$R/rc")" = 0 ] && grep -q '^CHECK dreamteam-audit ok' "$R/out" \
  && ok "publish: a directory at the destination is refused, not written into" || bad "publish dir: $(ls -A "$R/checks/dreamteam-audit.line")"
#  c) an unwritable checks dir (a file in its place): exit 0, line on stdout
R=$(mkroot rodir "$GREEN"); rmdir "$R/checks"; : > "$R/checks"; audit "$R"
[ "$(cat "$R/rc")" = 0 ] && grep -q '^CHECK dreamteam-audit' "$R/out" && ok "publish: unwritable checks dir → exit 0, line on stdout" || bad "rodir: rc $(cat "$R/rc")"
#  d) a check name that is not a plain basename publishes nothing anywhere (traversal, separator, newline)
for nm in '../victim' 'a/b' $'x\ny' '.hidden'; do
  R=$(mkroot "badname$RANDOM" "$GREEN"); audit "$R" "$nm"
  stray=$(find "$TMP" -maxdepth 3 -name 'victim*' -o -maxdepth 3 -path "$R/checks/*" -name '*.line' | head -1)
  [ -z "$stray" ] && [ "$(cat "$R/rc")" = 0 ] && ok "publish: name '$(printf %q "$nm")' refused, nothing written" || bad "badname '$nm': wrote $stray"
done
#  e) staging never uses a predictable name: a planted symlink at the obvious temp names stays untouched
R=$(mkroot predictable "$GREEN"); echo SENTINEL > "$TMP/sentinel-e"
for t in dreamteam-audit.line.tmp .dreamteam-audit.line.tmp dreamteam-audit.tmp; do ln -s "$TMP/sentinel-e" "$R/checks/$t"; done
audit "$R"
[ "$(cat "$TMP/sentinel-e")" = SENTINEL ] && [[ "$(line "$R")" =~ $SHAPE ]] \
  && ok "publish: planted symlinks at predictable temp names are not followed" || bad "predictable temp followed: sentinel=$(cat "$TMP/sentinel-e")"
#  f) overlapping audits: one whole line, no temp left (a SMOKE check only: all writers publish the same content)
R=$(mkroot overlap "$GREEN")
for i in 1 2 3 4; do audit "$R" & done; wait
[ "$(wc -l < "$R/checks/dreamteam-audit.line")" = 1 ] && [[ "$(line "$R")" =~ $SHAPE ]] && [ "$(ls -A "$R/checks")" = "dreamteam-audit.line" ] \
  && ok "publish: 4 overlapping audits leave one whole line and no temp files" || bad "overlap: $(ls -A "$R/checks" | tr '\n' ' ')"

# 7. tests/run.sh gives every suite the timer's environment: TMUX unset even when the caller is inside tmux
H="$TMP/hermetic"; mkdir -p "$H/tests"; cp "$ROOT/tests/run.sh" "$H/tests/run.sh"
printf '%s\n' '#!/usr/bin/env bash' '[ -z "${TMUX:-}" ] && echo "PASS: no TMUX" || { echo "FAIL: TMUX leaked: $TMUX"; exit 1; }' > "$H/tests/test-probe.sh"
TMUX=/tmp/fake,1,1 bash "$H/tests/run.sh" > "$H/out" 2>&1 \
  && ok "run.sh: a suite never sees the caller's TMUX (timer and interactive runs agree)" || bad "run.sh leaks TMUX: $(grep FAIL "$H/out" | head -1)"

# 8. tests/run.sh never lets a suite write a REAL check line: each suite gets a throwaway DREAMTEAM_CHECKS_DIR
H2="$TMP/realdir"; mkdir -p "$H2/tests"; cp "$ROOT/tests/run.sh" "$H2/tests/run.sh"
printf '%s\n' '#!/usr/bin/env bash' ': > "$PROBE_RAN"' 'd="${DREAMTEAM_CHECKS_DIR:-}"' \
  '[ -n "$d" ] && [ -d "$d" ] && [ "${d#"$DREAMTEAM_REAL_HOME"/.local/state}" = "$d" ] && echo "PASS: throwaway $d" || { echo "FAIL: checks dir is \"$d\""; exit 1; }' > "$H2/tests/test-probe.sh"
export PROBE_RAN="$TMP/probe-ran"
env -u DREAMTEAM_CHECKS_DIR bash "$H2/tests/run.sh" > "$H2/out" 2>&1 \
  && ok "run.sh: every suite gets a throwaway checks dir (no test can overwrite a real line)" || bad "run.sh checks dir: $(grep FAIL "$H2/out" | head -1)"
# NEVER a real path here: on 2026-11-17 a mutated run.sh kept an inherited "$HOME/.local/state/checks" from this very
# case and its EXIT trap rm -rf'd the fleet's real checks folder. The inherited dir is a DECOY with a sentinel; the
# probe fails if it is handed the decoy, and the decoy must survive whatever run.sh does.
DECOY="$TMP/decoy-checks"; mkdir -p "$DECOY"; echo KEEP > "$DECOY/sentinel"
printf '%s\n' '#!/usr/bin/env bash' 'd="${DREAMTEAM_CHECKS_DIR:-}"' \
  '[ -n "$d" ] && [ -d "$d" ] && [ "$d" != "$DECOY_DIR" ] && echo "PASS: private $d" || { echo "FAIL: checks dir is \"$d\""; exit 1; }' > "$H2/tests/test-probe.sh"
DECOY_DIR="$DECOY" DREAMTEAM_CHECKS_DIR="$DECOY" bash "$H2/tests/run.sh" > "$H2/out2" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "run.sh: an INHERITED checks dir is replaced by a private one" || bad "run.sh inherited dir leaked: $(grep FAIL "$H2/out2" | head -1)"
[ "$(cat "$DECOY/sentinel" 2>/dev/null)" = KEEP ] && ok "run.sh: an inherited dir is never removed (its sentinel survives)" || bad "run.sh REMOVED the inherited dir"
printf '%s\n' '#!/usr/bin/env bash' ': > "$PROBE_RAN"' 'echo "PASS: ran"' > "$H2/tests/test-probe.sh"; rm -f "$PROBE_RAN"
TMPDIR="$TMP/no/such/dir" bash "$H2/tests/run.sh" > "$H2/out3" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q "cannot create a private test home" "$H2/out3" && [ ! -e "$PROBE_RAN" ] \
  && ok "run.sh: no private home possible → exit $rc, and the probe suite never ran (its sentinel is absent)" || bad "run.sh mktemp failure: rc=$rc ran=$([ -e "$PROBE_RAN" ] && echo yes) $(head -2 "$H2/out3")"
# every suite sees a private HOME, never the caller's
printf '%s\n' '#!/usr/bin/env bash' '[ "$HOME" != "$DREAMTEAM_REAL_HOME" ] && [ -d "$HOME" ] && echo "PASS: private home" || { echo "FAIL: HOME is $HOME"; exit 1; }' > "$H2/tests/test-probe.sh"
bash "$H2/tests/run.sh" > "$H2/out4" 2>&1 && ok "run.sh: every suite runs with a private HOME" || bad "run.sh HOME: $(grep FAIL "$H2/out4" | head -1)"
# an inherited XDG dir (a DECOY) never reaches a suite: config, state, data and cache all live under the private HOME
XD="$TMP/decoy-xdg"; mkdir -p "$XD"; echo KEEP > "$XD/sentinel"
printf '%s\n' '#!/usr/bin/env bash' 'for v in XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; do d="${!v}"; [ "${d#"$HOME"/}" != "$d" ] || { echo "FAIL: $v=$d"; exit 1; }; done; echo "PASS: xdg private"' > "$H2/tests/test-probe.sh"
XDG_CONFIG_HOME="$XD" XDG_STATE_HOME="$XD" XDG_DATA_HOME="$XD" XDG_CACHE_HOME="$XD" bash "$H2/tests/run.sh" > "$H2/out5" 2>&1 \
  && [ "$(cat "$XD/sentinel")" = KEEP ] && ok "run.sh: inherited XDG dirs are replaced by private ones (decoy untouched)" || bad "run.sh XDG: $(grep FAIL "$H2/out5" | head -1)"

echo "─────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
