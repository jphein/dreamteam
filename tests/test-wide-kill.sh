#!/usr/bin/env bash
# dreamteam — regression tests for the WIDE-KILL GUARD and its replacement, kill-mine.
#
#   • scripts/wide-kill-guard.sh — PreToolUse(Bash) hook: blocks a host-wide pattern kill of a test runner.
#   • scripts/kill-mine.py       — stops the processes matching a pattern inside ONE directory.
#
# THE INCIDENT (serialhub, Flow row 62d79dae): a lane's "restart my suite" one-liner selected by command line
# and ended every lane's `make test` on the host: three times on 2026-11-20 two lanes' runs died in the same
# second. The guard's positive controls are those commands verbatim. They are only ever handed to the guard as
# JSON text; NOTHING here runs them.
#
# The kill-mine half uses real processes, named with a marker unique to this run (never a real runner's name),
# in two directories and two sessions: "mine" and "another lane's". The red test of the incident is that the
# other lane's stand-in is still alive afterwards.
#
# Run standalone:  bash tests/test-wide-kill.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/wide-kill-guard.sh"
KM="$ROOT/scripts/kill-mine.py"

PASS=0; FAIL=0
BLOG_SET=1   # the bypass log goes to this run's temp dir (set below, once it exists)
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)" && TMP="$(cd "$TMP" && pwd -P)" || { echo "FAIL: no temp dir"; exit 1; }
export DREAMTEAM_WIDEKILL_LOG="$TMP/bypass.log"
PIDS=""                                      # informational only: NOTHING here signals a remembered pid number
# Cleanup never trusts a pid it wrote down (a number can be reused by another lane's live suite, xreview #279
# r1). Every fixture stands in a directory under $TMP, which exists for this run only. So: take a pidfd, THEN
# read the process's directory through /proc, and signal through the pidfd only if that directory is ours.
reap_fixtures() {
  python3 -I - "$TMP" <<'PY' 2>/dev/null || true
import os, signal, sys
root = sys.argv[1].rstrip("/") + "/"
for name in os.listdir("/proc"):
    if not name.isdigit() or int(name) == os.getpid():
        continue
    try:
        fd = os.pidfd_open(int(name))
    except OSError:
        continue
    try:
        cwd = os.readlink(f"/proc/{name}/cwd")
        if (cwd + "/").startswith(root):
            signal.pidfd_send_signal(fd, signal.SIGKILL)
    except OSError:
        pass
    finally:
        os.close(fd)
PY
}
cleanup() { reap_fixtures; rm -rf "$TMP"; }
trap cleanup EXIT
printf '%s\n' '{"widekill":{"enforce":true}}'  > "$TMP/on.json"
printf '%s\n' '{"widekill":{"enforce":false}}' > "$TMP/off.json"

GRC=0
# run <tool> <command> [config]
run() {
  local tool="$1" cmd="$2" cfg="${3:-$TMP/on.json}"
  GRC=0
  jq -nc --arg t "$tool" --arg c "$cmd" '{tool_name:$t,tool_input:{command:$c}}' \
    | DREAMTEAM_CONFIG="$cfg" bash "$GUARD" 2>"$TMP/err" || GRC=$?
}
blocked() { [ "$GRC" -eq 2 ] && grep -q 'WIDE-KILL GUARD' "$TMP/err"; }
deny()  { run Bash "$2"; if blocked; then pass "BLOCKS $1"; else fail "not blocked ($1) — exit $GRC"; fi; }
allow() { run Bash "$2"; if [ "$GRC" -eq 0 ]; then pass "allows $1"; else fail "blocked ($1) — exit $GRC: $(head -1 "$TMP/err")"; fi; }

echo "── wide-kill-guard.sh ───────────────────────────────────────────"
if bash -n "$GUARD" 2>"$TMP/err"; then pass "wide-kill-guard.sh passes bash -n"; else fail "syntax: $(head -1 "$TMP/err")"; fi

# ── POSITIVE CONTROLS: the incident's commands, verbatim ─────────────
deny "the 11-20 12:35:13 restart loop (ps | grep 'make test|python.* -m pytest' | kill)" \
  'cd ~/srv/wt/realmwatch-roam && for p in $(ps -eo pid,args | grep -E "make test|python.* -m pytest" | grep -v "ps -eo\|grep -E\|realmwatch-where" | awk '"'"'{print $1}'"'"'); do kill $p 2>/dev/null; done; sleep 1; echo restarted'
deny "the 11-18 14:49 loop that echoes each kill" \
  'for p in $(ps -eo pid,args | grep -E "make test|python.* -m pytest|pytest" | grep -v "ps -eo\|grep -E" | awk '"'"'{print $1}'"'"'); do echo "kill $p: $(ps -o args= -p $p | cut -c1-60)"; kill $p 2>/dev/null; done'
deny "pkill -f with the [p] self-match trick (11-18 14:50)" \
  'pkill -f "[p]ython3 -m pytest -q plugins/system-updates" 2>/dev/null; sleep 1'
deny "pkill -f pytest (11-20 13:52)" \
  'pkill -f "pytest -q plugins/system-updates" && echo "suite stopped" || echo "no suite process"'
deny "pgrep | grep | xargs kill (11-18 14:36)" \
  'pgrep -f "pytest" -a | grep realmwatch-roam | awk '"'"'{print $1}'"'"' | xargs -r kill 2>/dev/null'
deny "the self-match trick on the runner's own name ([p]ytest)" 'pkill -f "[p]ytest -q"'
deny "killall of a runner" 'killall -q pytest'
deny "pkill whose pattern has the runner after a | inside the quotes" 'pkill -f "map_server|make test"'
deny "pkill of this repo's own suite runner" 'pkill -f tests/run.sh'
deny "a runner kill on a later line of a multi-line command" $'cd /x\npkill -f "python -m pytest"\nmake test'
deny "pkill -u (a user is no boundary: every lane is the same user)" 'pkill -u jp -f pytest'
deny "a heredoc fed to a shell is code, not data" $'bash <<EOF\npkill -f pytest\nEOF'
# xreview #279 r1: natural variants
deny "a -s inside the quoted PATTERN is pytest's flag, not pkill's narrowing" 'pkill -f "python -m pytest -s tests/test_example.py"'
deny "a -t inside a single-quoted pattern, likewise" "pkill -f 'pytest -t 4 tests'"
deny "kill \$(pgrep -f pytest): the listing is kill's own operand" 'kill $(pgrep -f pytest)'
deny "kill \$(ps | awk on a runner's name)" 'kill $(ps -eo pid,args | awk '"'"'/pytest/ {print $1}'"'"')'
deny "kill with a backtick listing" 'kill -TERM `pgrep -f "make test"`'
deny "a narrowing flag with no operand narrows nothing" 'pkill -f pytest -s'
# xreview #279 r2
deny "killall -s names a SIGNAL, not a session" 'killall -s TERM pytest'
deny "killall -g signals the matches' groups, it selects nothing narrower" 'killall -g pytest'
deny "pkill under an absolute path" '/usr/bin/pkill -f pytest'
deny "killall under an absolute path" '/usr/bin/killall -q pytest'
deny "kill of a substitution whose listing is under a path" 'kill $(/usr/bin/pgrep -f pytest)'
deny "the restart loop with ps under a path" 'for p in $(/bin/ps -eo pid,args | grep pytest | awk '"'"'{print $1}'"'"'); do kill $p; done'
deny "pidof under a path fed to kill" '/usr/bin/pidof pytest | xargs kill'
deny "a listing piped to while read, the variable then killed" 'pgrep -f pytest | while read -r p; do kill "$p"; done'
deny "a variable bound to the listing, killed two statements later" 'P=$(pgrep -f "make test" | head -1); sleep 1; echo x; kill -TERM ${P}'
# xreview #279 r3
deny "pkill behind sudo" 'sudo pkill -f pytest'
# Sen, xreview #279 r1 (2): a wrapper's own options and values are skipped, as gpu_detect skips a runner's
deny "sudo -n pkill" 'sudo -n pkill -f pytest'
deny "sudo -u <user> pkill" 'sudo -u jp pkill -f pytest'
deny "env -i pkill" 'env -i pkill -f pytest'
deny "env -i with assignments, then pkill" 'env -i PATH=/usr/bin LC_ALL=C pkill -f pytest'
deny "nice -n 10 pkill" 'nice -n 10 pkill -f "make test"'
deny "ionice -c3 pkill" 'ionice -c3 pkill -f pytest'
deny "ionice -c 3 -n 7 killall" 'ionice -c 3 -n 7 killall pytest'
deny "timeout 5 pkill" 'timeout 5 pkill -f pytest'
deny "timeout -k 1 5s pkill" 'timeout -k 1 5s pkill -f pytest'
deny "wrappers stacked: sudo -n nice -n 5 timeout 10 pkill" 'sudo -n nice -n 5 timeout 10 pkill -f pytest'
deny "a listing behind a wrapper feeds kill" 'sudo -n pgrep -f pytest | xargs -r sudo kill'
deny "kill of a substitution whose listing is behind a wrapper" 'kill $(sudo -n pgrep -f pytest)'
deny "pkill behind an assignment" 'LC_ALL=C pkill -f pytest'
deny "pkill after then" 'if true; then pkill -f pytest; fi'
deny "a variable bound to the listing, killed after &&" 'P=$(pgrep -f pytest) && kill $P'
deny "a trailing comment does not hide the kill" 'pkill -f pytest # stop the suite'
deny "a # inside the quoted pattern is not a comment" 'pkill -f "x # y pytest"'
# xreview #279 r4
deny "the pipeline written one stage per line (a newline after | continues it)" \
  $'ps -eo pid,args |\n  grep pytest |\n  awk \'{print $1}\' |\n  xargs kill'
deny "the same formatting inside kill \$( )" $'kill $(pgrep -f pytest |\n  head -1)'
deny "the restart loop with its listing wrapped after |" \
  $'for p in $(ps -eo pid,args |\n    grep -E "make test|pytest" | awk \'{print $1}\'); do kill $p; done'
deny "pidof fed to kill" 'pidof pytest | xargs kill'
deny "a ; inside the quoted awk program does not end the listing's statement" \
  'ps -eo pid,args | awk '"'"'{n++; if ($0 ~ /pytest/) print $1}'"'"' | xargs kill'

# ── NEGATIVE CONTROLS: the block is not vacuous ──────────────────────
allow "kill of a captured pid" 'make test > log 2>&1 & PID=$!; sleep 5; kill "$PID"'
allow "ps | grep of a runner with no kill" 'ps -eo pid,args | grep -E "make test|pytest" | grep -v grep'
allow "pgrep of a runner with no kill" 'pgrep -af pytest | wc -l'
allow "a listing of something else, a suite, then kill of a captured pid (replay 11-02)" \
  $'echo "before: $(pgrep -c -x workerd)"\npnpm test:workerd 2>&1 | grep -E "PASS|FAIL"\nnode run.mjs > sig.log 2>&1 & P=$!; sleep 1.5; kill -TERM "$P"; wait "$P"'
deny "ps | awk on a runner's name, the pid then killed (10-23)" \
  'PID=$(ps -eo pid,args | awk '"'"'/pytest -q tests\/test_files.py/ && !/awk/ {print $1}'"'"' | head -1); echo "pid=$PID"; [ -n "$PID" ] && kill "$PID"'
allow "pkill of something that is not a test runner" 'pkill -f "^python3 server.py$" || true; sleep 1'
allow "a server pkill followed by a suite on the NEXT line" $'pkill -f map_server.py\nsleep 1\nmake test'
allow "a server pkill, then a suite after ;" 'pkill -f map_server.py; make test'
allow "a server pkill, || then a suite (the suite is not pkill's argument)" 'pkill -f server.py || make test'
allow "a server pkill piped to a file named after a runner" 'pkill -f server.py | tee pytest.log'
allow "a server pkill && a suite" 'pkill -f server.py && python -m pytest -q'
allow "kill of a substitution that lists something else" 'kill $(pgrep -f map_server.py); make test'
allow "a ; inside an awk program does not end the listing's statement (no runner in it)" \
  'ps -eo pid,args | awk '"'"'{n++; print $1}'"'"' | wc -l; make test; kill "$PID"'
allow "a listing to LOOK, then a kill of the pid captured at launch (xreview r2)" 'ps -eo pid,args | grep pytest; kill "$PID"'
allow "a listing bound to one variable, a kill of another" 'N=$(pgrep -fc pytest); echo "$N running"; kill "$PID"'
allow "a kill, then a listing that is echo's argument, not kill's" 'kill "$PID" && echo "$(pgrep -f pytest)"'
allow "a file merely named after a killer" 'cat docs/pkill.md | grep pytest'
allow "files named after a killer and a runner, side by side" 'cat notes/pkill.md pytest.ini'
allow "a listing && kill-mine in ONE statement (kill-mine is not kill)" "pgrep -af pytest && $KM 'python.* -m pytest'"
allow "a killer's path as an argument, a runner after ;" 'ls -l /usr/bin/pkill; pytest -q'
allow "pkill narrowed to a pid file" 'pkill -F run.pid -f pytest'
# xreview #279 r3
allow "a QUOTED narrowing operand after the pattern" 'pkill -f pytest -P "$$"'
allow "an attached narrowing operand" 'pkill -P$$ -f pytest'
allow "a listing && a kill of the captured pid: sequencing is not a feed" 'ps -eo pid,args | grep pytest && kill "$PID"'
allow "a listing || a kill of the captured pid" 'pgrep -f pytest > /dev/null || kill "$PID"'
allow "killer and runner both as FILE arguments" 'ls -l /usr/bin/pkill /usr/bin/pytest'
allow "the same behind a wrapper: sudo runs ls, pkill is ls's argument" 'sudo -n ls -l /usr/bin/pkill /usr/bin/pytest'
allow "timeout runs a suite; a killer's name is only its argument" 'timeout 600 make test ARGS=pkill'
allow "a wrapper with options, then a server pkill" 'sudo -n pkill -f map_server.py; make test'
allow "a runner named only in a trailing comment (pkill)" 'pkill -f server.py # restart before pytest'
allow "a runner named only in a trailing comment (kill of a listing)" 'kill $(pgrep -f server.py) # restart before pytest'
allow "a runner after the substitution's closing ), not in its body" 'kill $(pgrep -f server.py) && make test'
# xreview #279 r4: the bound variable is named by a LATER command, not by the kill
allow "bound variable only in echo after &&" 'N=$(pgrep -fc pytest); kill "$PID" && echo "$N suites were running"'
allow "bound variable only in echo after ||" 'N=$(pgrep -fc pytest); kill "$PID" || echo "$N suites still running"'
allow "bound variable only in a command after |" 'N=$(pgrep -fc pytest); kill "$PID" 2>&1 | sed "s/^/$N: /"'
allow "a newline that is NOT after | still ends the pipeline" $'pgrep -af pytest\nkill "$PID"'
allow "kill -0 of a listed runner is a liveness probe, it sends nothing (replay 11-17)" \
  'kill -0 $(pgrep -f "vitest run __tests__/scripts" | head -1) 2>/dev/null && echo running'
allow "a listing, then kill -0" 'pgrep -f pytest | xargs kill -0'
deny "kill -0 does not excuse a real kill after it" 'pgrep -f pytest | xargs kill -0 && pgrep -f pytest | xargs kill'
allow "pkill narrowed to the caller's children (-P)" 'pkill -P $$ -f pytest'
allow "pkill narrowed to a session (--session)" 'pkill --session 4242 -f pytest'
allow "kill-mine, the replacement" "$KM 'make test|python.* -m pytest'"
allow "kill-mine after a listing" "ps -eo pid,args | grep pytest; $KM --under /x 'python.* -m pytest'"
allow "the stated override" 'WIDE_KILL_OK=1 pkill -f pytest'
allow "a commit message that quotes the idiom mid-sentence" $'git commit -F - <<\'EOF\'\nfix: lanes ran pkill -f pytest host-wide\nEOF'
allow "a commit message with the idiom on a line of its own (heredoc data, removed by the #191 reader)" \
  $'git commit -F - <<\'EOF\'\nfix: block the restart idiom\n\npkill -f pytest\nEOF'
allow "docker ps … | xargs docker kill: ps and kill are docker's arguments here" 'docker ps -q --filter name=pytest | xargs docker kill'
allow "a script whose NAME starts with a killer's" './pkill.sh pytest'
allow "kill-mine named after a listing inside one pipeline" 'echo "$(pgrep -fc pytest) suites running; stop yours with scripts/kill-mine.py"'
allow "an ordinary command" 'ls -la && git status'
allow "the word skill" 'cat skills/dreamteam/SKILL.md | grep pytest'

# ── the two bypasses leave a line each (lead ruling on #279) ────────────────────────────────────────────────
BL="$DREAMTEAM_WIDEKILL_LOG"
[ ! -s "$BL" ] && pass "everything allowed or blocked so far wrote NO bypass line (a not-wide command bypasses nothing; a block is not a bypass)… except the stated override, checked next" \
  || { [ "$(wc -l < "$BL")" -eq 1 ] && grep -q 'bypass=WIDE_KILL_OK=1 ' "$BL" && pass "so far exactly ONE bypass line exists: the stated override's" || fail "unexpected bypass lines so far: $(cat "$BL")"; }
: > "$BL"; run Bash 'WIDE_KILL_OK=1 pkill -f pytest'
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$BL")" -eq 1 ] && grep -qE '^[0-9-]{10} [0-9:]{8} wide-kill-guard ALLOWED bypass=WIDE_KILL_OK=1 verdict=wide-kill cmd=WIDE_KILL_OK=1 pkill -f pytest$' "$BL"; then
  pass "WIDE_KILL_OK=1 on a judged wide kill: allowed AND logged, one line naming the bypass and the command"; else fail "override not logged: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"; run Bash 'WIDE_KILL_OK=1 pkill -f server.py'
if [ "$GRC" -eq 0 ] && [ ! -s "$BL" ]; then pass "WIDE_KILL_OK=1 on a command that is NOT a wide kill: nothing was bypassed, nothing is logged"; else fail "override on a harmless command: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"; run Bash 'pkill -f pytest'
if blocked && [ ! -s "$BL" ]; then pass "a BLOCKED wide kill writes no bypass line"; else fail "block wrote a bypass line: $(cat "$BL")"; fi
: > "$BL"; run Bash 'pkill -f pytest' "$TMP/off.json"
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$BL")" -eq 1 ] && grep -q 'ALLOWED bypass=widekill.enforce=false verdict=wide-kill cmd=pkill -f pytest$' "$BL"; then
  pass "kill switch widekill.enforce=false: a judged wide kill is allowed AND logged (the judgement still ran: the line carries its verdict)"; else fail "kill switch: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"; run Bash 'pkill -f server.py' "$TMP/off.json"
if [ "$GRC" -eq 0 ] && [ ! -s "$BL" ]; then pass "kill switch on a command judged NOT wide: allowed, nothing bypassed, nothing logged"; else fail "kill switch, harmless command: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"; run Bash $'ps -eo pid,args | grep pytest |\n  awk \'{print $1}\' |\n\txargs kill' "$TMP/off.json"
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$BL")" -eq 1 ]; then pass "a command of several lines is ONE log line"; else fail "multi-line command: rc $GRC, $(wc -l < "$BL") line(s)"; fi
: > "$TMP/notadir"; GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"WIDE_KILL_OK=1 pkill -f pytest"}}' | DREAMTEAM_WIDEKILL_LOG="$TMP/notadir/x.log" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>"$TMP/err" || GRC=$?
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ] && grep -q 'ALLOWED bypass=WIDE_KILL_OK=1 verdict=wide-kill' "$TMP/err"; then pass "a log that cannot be written: the allow stands and the line goes to stderr"; else fail "unwritable log: rc $GRC, err: $(cat "$TMP/err")"; fi
: > "$BL"
run Bash 'pkill -f pytest' "$TMP/absent.json"
if blocked; then pass "a MISSING config still enforces"; else fail "missing config disabled the guard — exit $GRC"; fi
run Monitor 'pkill -f pytest'
if [ "$GRC" -eq 0 ]; then pass "only Bash is judged (Monitor passes)"; else fail "Monitor blocked — exit $GRC"; fi
# WHO: every Bash session, the lead's too (Sen, xreview #279 r1 note 4). There is no "non-lane → allowed" control in
# this suite on purpose: unlike the no-poll guard, no role exists for which ending another lane's suite is the job.
# Every run above is made with NO identity in the environment, which is the lead's own case, and it is blocked.
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | env -u DREAMTEAM_AGENT_ID -u ASK_WHO -u TMUX DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 2 ]; then pass "a session with no lane identity (the lead) is blocked like any other"; else fail "no-identity session → exit $GRC"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | DREAMTEAM_AGENT_ID="morpheus-lane@team" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 2 ]; then pass "…and so is a teammate"; else fail "teammate → exit $GRC"; fi

# TIMING (note 5; the other gates hold the same line): under 200 ms on the fixture, median of 7, for the call that
# leaves at the first test, for one that reaches the detector and passes, and for one that is blocked.
med() { local i t0 t1 a=(); for i in 1 2 3 4 5 6 7; do t0=$(date +%s%N); jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" > /dev/null 2>&1; t1=$(date +%s%N); a+=($(( (t1 - t0) / 1000000 ))); done; printf '%s\n' "${a[@]}" | sort -n | sed -n 4p; }
for c in 'git status --short' 'pkill -f map_server.py; make test' 'for p in $(ps -eo pid,args | grep -E "make test|pytest" | awk "{print \$1}"); do kill $p; done'; do
  m=$(med "$c"); if [ "$m" -lt 200 ]; then pass "timing: ${m} ms median (< 200) for: ${c:0:38}"; else fail "timing: ${m} ms for: ${c:0:38}"; fi
done
GRC=0; printf 'not json but kill' | DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 0 ]; then pass "malformed stdin fails open"; else fail "malformed stdin → exit $GRC"; fi
# FAIL CLOSED (Sen, xreview #279 r1): a text that names a killer and cannot be judged is blocked, with ONE line;
# the kill switch is the only bypass. A command with no killer or listing in it never reaches the judge.
mkdir -p "$TMP/badpy" "$TMP/nopy"
printf '#!/bin/sh\nexit 3\n' > "$TMP/badpy/python3"; chmod +x "$TMP/badpy/python3"
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>"$TMP/err" || GRC=$?
if [ "$GRC" -eq 2 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ] && grep -q 'detector failed (exit 3, not a verdict)' "$TMP/err"; then pass "a detector that errors (exit 3) is a BLOCK, with one line"; else fail "erroring judge → exit $GRC: $(cat "$TMP/err")"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f server.py"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 2 ]; then pass "…also for a harmless pkill: unjudged is not run"; else fail "erroring judge, harmless pkill → exit $GRC"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/off.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 0 ]; then pass "the kill switch is the bypass for a failing detector"; else fail "kill switch with a failing detector → exit $GRC"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"ls -la; echo skill"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 0 ]; then pass "a command with no killer or listing never reaches the detector, failing or not"; else fail "ordinary command with a failing detector → exit $GRC"; fi
for t in jq grep cat bash dirname; do ln -s "$(command -v "$t")" "$TMP/nopy/$t" 2>/dev/null; done
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/nopy" DREAMTEAM_CONFIG="$TMP/on.json" "$(command -v bash)" "$GUARD" 2>/dev/null || GRC=$?
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/nopy" DREAMTEAM_CONFIG="$TMP/on.json" "$(command -v bash)" "$GUARD" 2>"$TMP/err" || GRC=$?
if [ "$GRC" -eq 2 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ] && grep -q 'python3 is missing' "$TMP/err"; then pass "no python3 on PATH is a BLOCK, with one line"; else fail "no python3 → exit $GRC: $(cat "$TMP/err")"; fi
# the judge's own exit codes: 20 and 21 are the verdicts; anything else (0 and 1 included) is the failure blocked above
printf '%s' 'pkill -f pytest' | python3 -I "$ROOT/scripts/lib/widekill_text.py"; rc=$?
printf '%s' 'pkill -f server.py' | python3 -I "$ROOT/scripts/lib/widekill_text.py"; rc2=$?
if [ "$rc" -eq 20 ] && [ "$rc2" -eq 21 ]; then pass "the detector's verdicts are 20 (wide) and 21 (not): codes no failure produces"; else fail "detector exits $rc / $rc2"; fi

# xreview #279 r2 (1): a REAL detector failure. Python exits 1 on an uncaught exception, a syntax error and a
# failed import; exit 1 used to mean "not a wide kill". Each broken copy below must BLOCK, with one line.
brk() {  # brk <name> <python text put at the top of the detector>
  local d="$TMP/broken-$1"; mkdir -p "$d/scripts/lib"; cp "$GUARD" "$d/scripts/"; cp "$ROOT/scripts/lib/nopoll_text.py" "$d/scripts/lib/"
  { printf '%s\n' "$2"; cat "$ROOT/scripts/lib/widekill_text.py"; } > "$d/scripts/lib/widekill_text.py"
  GRC=0; jq -nc --arg c "${3:-pkill -f server.py}" '{tool_name:"Bash",tool_input:{command:$c}}' | CLAUDE_PLUGIN_ROOT="$d" DREAMTEAM_CONFIG="${4:-$TMP/on.json}" bash "$d/scripts/wide-kill-guard.sh" 2>"$TMP/err" || GRC=$?
}
brk exception 'raise RuntimeError("boom")'
python3 -I "$TMP/broken-exception/scripts/lib/widekill_text.py" < /dev/null > /dev/null 2>&1; prc=$?
if [ "$prc" -eq 1 ]; then pass "fixture: an uncaught exception in the detector really exits 1"; else fail "fixture: exception exits $prc"; fi
if [ "$GRC" -eq 2 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ] && grep -q 'detector failed (exit 1, not a verdict)' "$TMP/err"; then pass "an uncaught exception in the detector (exit 1) BLOCKS, with exactly one line"
else fail "detector exception → exit $GRC: $(cat "$TMP/err")"; fi
brk syntax 'def broken(:'
if [ "$GRC" -eq 2 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ]; then pass "a syntax error in the detector BLOCKS, with exactly one line"; else fail "detector syntax error → exit $GRC"; fi
brk import 'import a_module_that_does_not_exist_anywhere'
if [ "$GRC" -eq 2 ] && [ "$(wc -l < "$TMP/err")" -eq 1 ]; then pass "a failed import in the detector BLOCKS, with exactly one line"; else fail "detector import error → exit $GRC"; fi
brk exitzero 'import sys; sys.exit(0)'
if [ "$GRC" -eq 2 ]; then pass "a detector that ends with 0 and no verdict BLOCKS"; else fail "detector exit 0 → exit $GRC"; fi
# the kill switch skips the BLOCK, never the JUDGEMENT: with a broken detector or no interpreter the health checks
# still run, and what could not be judged is written down
: > "$BL"; brk exception 'raise RuntimeError("boom")' 'pkill -f server.py' "$TMP/off.json"
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$BL")" -eq 1 ] && grep -q 'ALLOWED bypass=widekill.enforce=false verdict=UNJUDGED(detector-exit-1) cmd=pkill -f server.py$' "$BL"; then
  pass "kill switch with a BROKEN detector: allowed, and the log says the command was NOT judged and why (the health check ran)"; else fail "kill switch, broken detector: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"; GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"pkill -f pytest"}}' | PATH="$TMP/nopy" DREAMTEAM_CONFIG="$TMP/off.json" "$(command -v bash)" "$GUARD" 2>/dev/null || GRC=$?
# this PATH has no date, tr, cut or mkdir either: the WHOLE line, its time included, must still be there
if [ "$GRC" -eq 0 ] && [ "$(wc -l < "$BL")" -eq 1 ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} wide-kill-guard ALLOWED bypass=widekill\.enforce=false verdict=UNJUDGED\(python3-missing\) cmd=pkill -f pytest$' "$BL"; then
  pass "kill switch with NO python3 (and no date, tr, cut): allowed, logged as not judged, the line whole with its time"; else fail "kill switch, no python3: rc $GRC, log: $(cat "$BL")"; fi
: > "$BL"
# (2) the WIDE_KILL_OK=1 prefix does NOT excuse a command that could not be judged
brk exception 'raise RuntimeError("boom")' 'WIDE_KILL_OK=1 pkill -f pytest'
if [ "$GRC" -eq 2 ]; then pass "WIDE_KILL_OK=1 with a failing detector: still blocked (only the kill switch bypasses a failure)"; else fail "override with a failing detector → exit $GRC"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"WIDE_KILL_OK=1 pkill -f pytest"}}' | PATH="$TMP/nopy" DREAMTEAM_CONFIG="$TMP/on.json" "$(command -v bash)" "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 2 ]; then pass "WIDE_KILL_OK=1 with no python3: still blocked"; else fail "override with no python3 → exit $GRC"; fi
GRC=0; jq -nc '{tool_name:"Bash",tool_input:{command:"WIDE_KILL_OK=1 pkill -f pytest"}}' | PATH="$TMP/badpy:$PATH" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 2 ]; then pass "WIDE_KILL_OK=1 with an interpreter that exits 3: still blocked"; else fail "override with a bad interpreter → exit $GRC"; fi

run Bash 'pkill -f pytest'
if grep -q 'kill-mine.py' "$TMP/err" && grep -q 'WIDE_KILL_OK=1' "$TMP/err"; then pass "the block names kill-mine and the override"
else fail "the block message names no way forward"; fi
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor") | .hooks[] | select(.command | test("wide-kill-guard.sh")) | select(.timeout <= 10)' \
     "$ROOT/hooks/hooks.json" >/dev/null 2>&1; then pass "hooks.json wires the guard on Bash with a timeout in seconds"
else fail "hooks.json does not wire wide-kill-guard.sh (or its timeout is not seconds)"; fi

echo "── kill-mine.py ─────────────────────────────────────────────────"
M="kmprobe$$x$RANDOM"                       # the marker: no real process carries it
MINE="$TMP/wt-mine"; OTHER="$TMP/wt-other"; ELSE="$TMP/elsewhere"
mkdir -p "$MINE/sub" "$OTHER" "$ELSE" "$TMP/home"
export HOME="$TMP/home"                     # kill-mine refuses a dir holding HOME; the fixtures are not under it

# stand_in DIR NAME → a detached session in DIR: python3 … -m <marker> NAME; its pid lands in $TMP/NAME.pid
stand_in() {
  ( cd "$1" || exit 1; setsid python3 -c 'import time; time.sleep(120)' -m "$M" "$2" > /dev/null 2>&1 < /dev/null & echo $! > "$TMP/$2.pid" )
  local p; p="$(cat "$TMP/$2.pid")"; PIDS="$PIDS $p"
}
# alive NAME: the pid still is OUR fixture (its directory is under $TMP), not merely a live number; no signal sent
alive() { local c; c="$(readlink "/proc/$(cat "$TMP/$1.pid")/cwd" 2>/dev/null)" || return 1; case "$c/" in "$TMP"/*) return 0 ;; esac; return 1; }
gone()  { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do alive "$1" || return 0; sleep 0.1; done; return 1; }
wait_up() { local i; for i in $(seq 1 30); do grep -q "$M" "/proc/$(cat "$TMP/$1.pid")/cmdline" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

stand_in "$MINE" mine1; stand_in "$MINE/sub" mine2; stand_in "$OTHER" other1
wait_up mine1 && wait_up mine2 && wait_up other1 || fail "the stand-ins did not start"

# the fixture is real: all three match the marker, in different sessions
n=$(ps -eo args | grep -c -- "-m $M" || true)
if [ "$n" -ge 3 ]; then pass "fixture: three stand-ins carry the marker"; else fail "fixture: $n stand-ins"; fi

out="$(cd "$MINE" && python3 "$KM" --dry-run -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && alive mine1 && alive mine2 && alive other1 && printf '%s' "$out" | grep -q '2 would be signalled'; then
  pass "--dry-run names two and signals none"
else fail "--dry-run: rc $rc, out: $out"; fi

# called the way a lane would: from a shell whose own command line holds the pattern
out="$(cd "$MINE" && bash -c "python3 '$KM' -- '-m $M' # stop my suite: -m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && gone mine1 && gone mine2; then pass "ends the matching processes in this directory and below it"
else fail "mine not ended: rc $rc, out: $out"; fi
if alive other1; then pass "THE INCIDENT, RED TEST: the other lane's run, same command line, is still alive"
else fail "the other lane's stand-in was killed"; fi
if printf '%s' "$out" | grep -q '1 matching elsewhere left alone'; then pass "the report counts what a host-wide kill would have hit"
else fail "no 'elsewhere' count: $out"; fi
if printf '%s' "$out" | grep -q '^kill-mine: 2 signalled (SIGTERM)'; then pass "the calling shell (its command line holds the pattern) is spared"
else fail "the summary is not '2 signalled': $out"; fi

out="$(cd "$MINE" && python3 "$KM" -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && alive other1; then pass "nothing left under this directory → exit 1, nothing signalled"
else fail "empty run: rc $rc, out: $out"; fi

# a matching child of a taken process that has moved elsewhere (a runner that chdir'ed under its make)
( cd "$MINE" || exit 1; setsid python3 -c '
import os, subprocess, sys, time
c = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", "-m", sys.argv[2], "child"], cwd=sys.argv[3])
open(sys.argv[4], "w").write(str(c.pid)); time.sleep(120)' -m "$M" "$ELSE" "$TMP/child.pid" > /dev/null 2>&1 < /dev/null & echo $! > "$TMP/parent.pid" )
PIDS="$PIDS $(cat "$TMP/parent.pid")"
for i in $(seq 1 30); do [ -s "$TMP/child.pid" ] && break; sleep 0.1; done
PIDS="$PIDS $(cat "$TMP/child.pid" 2>/dev/null)"
wait_up child || fail "the child stand-in did not start"
out="$(python3 "$KM" --under "$MINE" --signal KILL -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && gone parent && gone child && alive other1; then pass "--under DIR from anywhere; a matching descendant standing elsewhere goes with its parent; --signal KILL"
else fail "descendant case: rc $rc, out: $out"; fi

# a non-matching process in the directory is never touched
( cd "$MINE" || exit 1; setsid sleep 120 > /dev/null 2>&1 < /dev/null & echo $! > "$TMP/bystander.pid" ); PIDS="$PIDS $(cat "$TMP/bystander.pid")"
mkdir -p "$MINE-2"                          # a sibling worktree whose path merely STARTS with ours
stand_in "$MINE" mine3; stand_in "$MINE-2" sibling; wait_up mine3; wait_up sibling
python3 "$KM" --under "$MINE" -- "-m $M" > /dev/null 2>&1
if gone mine3 && alive bystander; then pass "a process in the directory that does not match is left alone"
else fail "bystander case"; fi
if alive sibling; then pass "a sibling directory sharing our path as a prefix (wt-mine-2) is not ours"
else fail "the sibling worktree's stand-in was killed (prefix match)"; fi

# pid reuse (xreview #279 r1), driven deterministically: the selected record and what /proc says once the
# pidfd is open differ in ONE field at a time. Only an identical record is signalled. No real signal is sent.
out="$(python3 -I - "$KM" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("kill_mine", sys.argv[1]); km = importlib.util.module_from_spec(spec); spec.loader.exec_module(km)
sel = (10, "python3 -m pytest -q", "/wt/mine", 5000, "")      # ppid, command line, directory, start time, marker
cases = {"same": sel, "reparented (ppid only)": (1,) + sel[1:], "later start": sel[:3] + (5001, ""),
         "other directory": sel[:2] + ("/wt/other", 5000, ""), "other command": (10, "python3 -m pytest -x", "/wt/mine", 5000, ""),
         "another marker (a different process)": sel[:4] + ("/wt/other",), "gone": None}
bad = []
for name, now in cases.items():
    sent, closed = [], []
    km.os.close = lambda fd, c=closed: c.append(fd)
    r = km.signal_one(4242, sel, km.signal.SIGTERM, read=lambda pid, n=now: n, opener=lambda pid: 99, sender=lambda fd, sig, s=sent: s.append((fd, sig)))
    want = name in ("same", "reparented (ppid only)")
    if r != want or bool(sent) != want or closed != [99]:
        bad.append(f"{name}: returned {r}, sent {sent}, closed {closed}")
def no_such(pid): raise ProcessLookupError()
if km.signal_one(4242, sel, km.signal.SIGTERM, read=lambda pid: sel, opener=no_such, sender=lambda fd, sig: bad.append("sent with no pidfd")):
    bad.append("no pidfd: returned True")
# the real reader's start time is the kernel's: field 22 of /proc/self/stat
me = km.read_proc(km.os.getpid()); raw = open("/proc/self/stat").read(); f22 = int(raw[raw.rindex(")") + 2:].split()[19])
if me is None or me[3] != f22 or me[0] != km.os.getppid() or me[4] != km.os.path.realpath(km.os.environ.get("DREAMTEAM_WORKTREE", "")) * bool(km.os.environ.get("DREAMTEAM_WORKTREE")):
    bad.append(f"read_proc: {me} vs start {f22} ppid {km.os.getppid()}")
# the family of a descendant standing elsewhere (xreview #279 r3): pid 20 stands in the directory, 30 is its
# child elsewhere, 40 a grandchild elsewhere through a non-matching 35; 50 is elsewhere with no such ancestor.
procs = {20: (1, "make test", "/wt/mine", 100, ""), 30: (20, "pytest", "/tmp/x", 110, ""), 35: (20, "sh -c", "/tmp/x", 111, ""),
         40: (35, "pytest", "/tmp/y", 112, ""), 50: (1, "pytest", "/wt/other", 113, ""), 60: (50, "pytest", "/tmp/z", 114, "")}
ch = km.descendants(procs, {30, 40, 50, 60}, {20})
if ch != {30: [20], 40: [35, 20]}:
    bad.append(f"descendants: {ch}")
def reader(changed):
    return lambda pid: changed.get(pid, procs.get(pid))
if not km.family_intact(40, ch[40], procs, read=reader({})):
    bad.append("an unchanged family is refused")
for what, changed in {"the in-directory ancestor's pid was recycled (later start, another directory)": {20: (1, "make test", "/wt/other", 999, "")},
                      "a middle link was recycled": {35: (7, "sh -c", "/tmp/x", 998, "")},
                      "the candidate was reparented": {40: (1, "pytest", "/tmp/y", 112, "")},
                      "an ancestor is gone": {20: None}}.items():
    if km.family_intact(40, ch[40], procs, read=reader(changed)):
        bad.append(f"family admitted although {what}")
# select() is what main() runs: with every family intact it takes 20, 30 and 40 and leaves 50 and 60; with the
# in-directory ancestor recycled between the scan and the second read, its descendants standing elsewhere are
# NOT taken (they are counted elsewhere), and a spared pid is never taken.
rx = km.re.compile("pytest|make test")
t, e = km.select(procs, rx, "/wt/mine", set(), read=reader({}))
if (t, e) != ({20, 30, 40}, {50, 60}):
    bad.append(f"select, intact: {t} {e}")
t, e = km.select(procs, rx, "/wt/mine", set(), read=reader({35: (7, "sh -c", "/tmp/x", 998, "")}))
if (t, e) != ({20, 30}, {40, 50, 60}):
    bad.append(f"select, a recycled middle link: {t} {e}")
# the second ownership signal: started with DREAMTEAM_WORKTREE under the directory, standing elsewhere, no ancestor
# of ours: taken. The same with another worktree's marker, or a path that merely starts like ours: not.
p2 = dict(procs); p2.update({70: (1, "pytest", "/tmp/q", 120, "/wt/mine"), 71: (1, "pytest", "/tmp/q", 121, "/wt/mine/sub"),
                             72: (1, "pytest", "/tmp/q", 122, "/wt/other"), 73: (1, "pytest", "/tmp/q", 123, "/wt/mine-2"), 74: (1, "sleep", "/tmp/q", 124, "/wt/mine")})
t, e = km.select(p2, rx, "/wt/mine", set(), read=lambda pid: p2.get(pid))
if not ({70, 71} <= t) or t & {72, 73, 74} or not ({72, 73} <= e):
    bad.append(f"select, markers: taken {sorted(t)} elsewhere {sorted(e)}")
t, e = km.select(procs, rx, "/wt/mine", {30}, read=reader({}))
if 30 in t or 30 in e:
    bad.append(f"select took or counted a spared pid: {t} {e}")
print("; ".join(bad) if bad else "ok")
PY
)"
if [ "$out" = "ok" ]; then pass "a pid whose start time, directory or command changed after selection is not signalled (pid reuse); the pidfd is always closed"
else fail "pid-reuse cases: $out"; fi

# the marker on REAL processes: started with DREAMTEAM_WORKTREE=<mine>, standing in another directory, no parent of
# ours → taken; the same started with the OTHER worktree's marker → left alone
( cd "$ELSE" || exit 1; DREAMTEAM_WORKTREE="$MINE" setsid python3 -c 'import time; time.sleep(120)' -m "$M" marked > /dev/null 2>&1 < /dev/null & echo $! > "$TMP/marked.pid" )
( cd "$ELSE" || exit 1; DREAMTEAM_WORKTREE="$OTHER" setsid python3 -c 'import time; time.sleep(120)' -m "$M" markedother > /dev/null 2>&1 < /dev/null & echo $! > "$TMP/markedother.pid" )
wait_up marked; wait_up markedother
out="$(python3 "$KM" --under "$MINE" -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && gone marked; then pass "a runner started with DREAMTEAM_WORKTREE=<this worktree> is ours although it stands elsewhere (read from /proc/<pid>/environ)"
else fail "marked runner not taken: rc $rc, out: $out"; fi
if alive markedother && alive other1; then pass "…and one started with another worktree's marker is not"; else fail "another worktree's marked runner was killed"; fi
out="$(DREAMTEAM_WORKTREE="$MINE" python3 -I - "$KM" <<'PY' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("kill_mine", sys.argv[1]); km = importlib.util.module_from_spec(spec); spec.loader.exec_module(km)
me = km.read_proc(os.getpid()); print("ok" if me and me[4] == os.path.realpath(os.environ["DREAMTEAM_WORKTREE"]) else f"bad {me}")
PY
)"
if [ "$out" = ok ]; then pass "read_proc reports the marker a process was started with"; else fail "read_proc marker: $out"; fi
if grep -q 'is MISSED' "$KM" && grep -q 'not a credential' "$KM"; then pass "the header states what the two signals do not prove"; else fail "kill-mine's header does not state the remaining limit"; fi

# refusals and arguments
out="$(python3 "$KM" --under "$HOME" -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && alive other1; then pass "refuses the home directory (exit 2)"; else fail "home: rc $rc, $out"; fi
out="$(python3 "$KM" --under / -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && alive other1; then pass "refuses / (exit 2)"; else fail "/: rc $rc, $out"; fi
out="$(python3 "$KM" --under "$TMP" -- "-m $M" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && alive other1; then pass "refuses an ancestor of the home directory (exit 2)"; else fail "ancestor: rc $rc, $out"; fi
python3 "$KM" --under "$OTHER" -- '(' > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 22 ]; then pass "a bad pattern is exit 22"; else fail "bad pattern rc $rc"; fi
python3 "$KM" --under "$OTHER" -- '' > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 22 ] && alive other1; then pass "an empty pattern is exit 22 (it would match everything)"; else fail "empty pattern rc $rc"; fi
python3 "$KM" --under "$OTHER" --signal BOGUS -- "-m $M" > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 22 ] && alive other1; then pass "an unknown signal is exit 22"; else fail "bad signal rc $rc"; fi
python3 "$KM" --under "$TMP/nowhere" -- "-m $M" > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 22 ]; then pass "a missing directory is exit 22"; else fail "missing dir rc $rc"; fi
python3 "$KM" > /dev/null 2>&1; rc=$?
if [ "$rc" -eq 22 ]; then pass "no pattern is exit 22"; else fail "no args rc $rc"; fi

# the default directory is the git top level, so a call from a subdirectory covers the worktree
if command -v git >/dev/null 2>&1; then
  git -C "$MINE" init -q 2>/dev/null
  stand_in "$MINE" mine4; wait_up mine4
  out="$(cd "$MINE/sub" && python3 "$KM" -- "-m $M" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && gone mine4 && alive other1; then pass "default DIR is the git top level (called from a subdirectory)"
  else fail "git top level: rc $rc, out: $out"; fi
fi

echo ""
echo "wide-kill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
