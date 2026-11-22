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
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
PIDS=""
cleanup() { for p in $PIDS; do kill -KILL "$p" 2>/dev/null; done; rm -rf "$TMP"; }
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
allow "pkill narrowed to the caller's children (-P)" 'pkill -P $$ -f pytest'
allow "pkill narrowed to a session (--session)" 'pkill --session 4242 -f pytest'
allow "kill-mine, the replacement" "$KM 'make test|python.* -m pytest'"
allow "kill-mine after a listing" "ps -eo pid,args | grep pytest; $KM --under /x 'python.* -m pytest'"
allow "the stated override" 'WIDE_KILL_OK=1 pkill -f pytest'
allow "a commit message that quotes the idiom (heredoc data)" $'git commit -F - <<\'EOF\'\nfix: lanes ran pkill -f pytest host-wide\nEOF'
allow "an ordinary command" 'ls -la && git status'
allow "the word skill" 'cat skills/dreamteam/SKILL.md | grep pytest'

run Bash 'pkill -f pytest' "$TMP/off.json"
if [ "$GRC" -eq 0 ]; then pass "kill switch widekill.enforce=false allows"; else fail "kill switch ignored — exit $GRC"; fi
run Bash 'pkill -f pytest' "$TMP/absent.json"
if blocked; then pass "a MISSING config still enforces"; else fail "missing config disabled the guard — exit $GRC"; fi
run Monitor 'pkill -f pytest'
if [ "$GRC" -eq 0 ]; then pass "only Bash is judged (Monitor passes)"; else fail "Monitor blocked — exit $GRC"; fi
GRC=0; printf 'not json but kill' | DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>/dev/null || GRC=$?
if [ "$GRC" -eq 0 ]; then pass "malformed stdin fails open"; else fail "malformed stdin → exit $GRC"; fi
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
alive() { kill -0 "$(cat "$TMP/$1.pid")" 2>/dev/null; }
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
