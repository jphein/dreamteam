#!/usr/bin/env bash
# dreamteam — regression tests for the NO-POLL GUARD.
#
#   • scripts/no-poll-guard.sh — PreToolUse(Bash|Monitor) hook that runs INSIDE a
#     teammate's session and exit-2 blocks a LOOPING GraphQL-heavy GitHub CI read
#     (`gh pr checks`, `gh pr view --json …statusCheckRollup…`).
#
# THE INCIDENT IT ENCODES (2026-09-11): three lanes each armed a 30 s
# `gh pr checks` loop. The quota is per-ACCOUNT, so they summed and every `gh`
# call in the fleet started failing — including the lead's merge cascade. The
# instrument an agent would reach for, `gh api rate_limit`, read 5000 remaining
# the whole time: it cannot see GraphQL SECONDARY limits.
#
# ISOLATION: the guard reads the world through (a) stdin JSON, (b) two env
# seams — DREAMTEAM_AGENT_ID (identity) and DREAMTEAM_CONFIG (kill switch). No
# network, no gh, no team config. The REAL guard logic runs unmodified.
#
# IDENTITY FIXTURE NOTE — the trap this suite had to dodge: with
# DREAMTEAM_AGENT_ID empty the guard walks /proc for an ancestor `--agent-id`.
# When this suite is run BY an agent that walk finds the runner's OWN id, so a
# "not a teammate → allow" assertion written that way would flip to a block and
# FAIL SPURIOUSLY on exactly the machine that matters. Non-teammate cases
# therefore use an id with no '@' (deterministically unparseable → fail open),
# and the truly-empty-identity case skips-with-note when the suite is itself
# running inside a teammate.
#
# Run standalone:  bash tests/test-no-poll-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/no-poll-guard.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '{"nopoll":{"enforce":true}}'  > "$TMP/on.json"
printf '%s\n' '{"nopoll":{"enforce":false}}' > "$TMP/off.json"

LANE="morpheus-lane@testteam"     # a resolvable teammate
NOTLANE="orchestrator-no-at-sign" # no '@' → unparseable → fail open (the lead)

GRC=0
# run <agent_id> <tool> <command> [config]
run() {
  local aid="$1" tool="$2" cmd="$3" cfg="${4:-$TMP/on.json}"
  GRC=0
  jq -nc --arg t "$tool" --arg c "$cmd" '{tool_name:$t,tool_input:{command:$c}}' \
    | DREAMTEAM_AGENT_ID="$aid" DREAMTEAM_CONFIG="$cfg" bash "$GUARD" 2>"$TMP/err" || GRC=$?
}
blocked() { [ "$GRC" -eq 2 ] && grep -qi 'NO-POLL GUARD' "$TMP/err"; }

# The literal command from the incident, reproduced verbatim.
MEASURED='for i in $(seq 1 40); do S458=$(gh pr checks 458 --repo techempower-org/mempalace 2>/dev/null | grep -c pending); [ "${S458:-1}" = "0" ] && break; sleep 30; done'

echo "── no-poll-guard.sh (CI-polling gate) ───────────────────────────"

# 0) static
if bash -n "$GUARD" 2>"$TMP/err"; then pass "no-poll-guard.sh passes bash -n"
else fail "syntax error: $(head -1 "$TMP/err")"; fi

# ── POSITIVE CONTROLS: these must BLOCK ──────────────────────────────
run "$LANE" Bash "$MEASURED"
if blocked; then pass "BLOCKS the measured incident command verbatim (seq loop + gh pr checks + sleep)"
else fail "measured incident command not blocked — exit $GRC"; fi

run "$LANE" Bash 'while true; do gh pr checks 466 --repo o/r; sleep 45; done'
if blocked; then pass "BLOCKS a while-loop gh pr checks"
else fail "while-loop poll not blocked — exit $GRC"; fi

run "$LANE" Bash 'until gh pr view 12 --json statusCheckRollup --jq ".x"; do sleep 20; done'
if blocked; then pass "BLOCKS a gh pr view --json statusCheckRollup poll"
else fail "statusCheckRollup poll not blocked — exit $GRC"; fi

run "$LANE" Monitor 'gh pr checks 458 --repo o/r | grep -v pass'
if blocked; then pass "BLOCKS a Monitor watch on gh pr checks (a Monitor IS a poller)"
else fail "Monitor poll not blocked — exit $GRC"; fi

# `--watch` IS the never-terminating watch this guard's header describes, and it
# needs no loop keyword at all. It slipped the first version of the detector:
# the loop patterns matched " watch " (space-delimited) and `--watch` is
# hyphen-prefixed, so the single most dangerous form was the one that passed.
run "$LANE" Bash 'gh pr checks 458 --repo o/r --watch'
if blocked; then pass "BLOCKS gh pr checks --watch (a flag, not a loop — and the worst case)"
else fail "--watch slipped the loop detector — exit $GRC"; fi

run "$LANE" Bash 'gh pr checks 458 --repo o/r; sleep 30; gh pr checks 458 --repo o/r'
if blocked; then pass "BLOCKS a sleep-separated repeat without an explicit loop keyword"
else fail "sleep-repeat poll not blocked — exit $GRC"; fi

# the block must actually say what to do instead — a guard nobody can act on
# just gets worked around.
run "$LANE" Bash "$MEASURED"
if grep -q 'pr-gate.sh' "$TMP/err" && grep -qi 'pushed' "$TMP/err"; then
  pass "the block message names the replacement protocol (push → \"pushed\" → lead runs pr-gate.sh)"
else fail "block message does not tell the agent what to do instead"; fi

# ── NEGATIVE CONTROLS: these must ALLOW (proving the block isn't vacuous) ──
run "$NOTLANE" Bash "$MEASURED"
if [ "$GRC" -eq 0 ]; then pass "ALLOWS the same loop from a NON-teammate (the lead's cascade must never be blocked)"
else fail "blocked a non-teammate — exit $GRC; the lead's own tooling would break"; fi

run "$LANE" Bash 'gh pr checks 458 --repo techempower-org/mempalace'
if [ "$GRC" -eq 0 ]; then pass "ALLOWS a one-shot gh pr checks (cheap; it is the LOOP that is the problem)"
else fail "blocked a one-shot check — exit $GRC"; fi

run "$LANE" Bash 'while read -r f; do ruff check "$f"; done < files.txt'
if [ "$GRC" -eq 0 ]; then pass "ALLOWS a loop that does not read GitHub CI status"
else fail "blocked an unrelated loop — exit $GRC"; fi

run "$LANE" Bash 'for i in 1 2 3; do gh api "repos/o/r/commits/$s/check-runs" --jq ".check_runs[].name"; sleep 10; done'
if [ "$GRC" -eq 0 ]; then pass "ALLOWS the sanctioned REST route in a loop (gh api …/check-runs is not the limited surface)"
else fail "blocked the REST route — exit $GRC; that is the route pr-gate.sh uses"; fi

run "$LANE" Bash "$MEASURED" "$TMP/off.json"
if [ "$GRC" -eq 0 ]; then pass "ALLOWS everything when nopoll.enforce=false (kill switch reachable)"
else fail "kill switch did not disengage — exit $GRC (jq '//' treats false as empty; use 'if == false')"; fi

# The ignore-list override must honour the EMPTY string — "ignore nothing" is
# the strictest setting, and `${VAR:-default}` silently replaces it with the
# default. Asserted in test-pr-tools.sh; noted here because the same idiom
# appears in both scripts.

run "$LANE" Edit "$MEASURED"
if [ "$GRC" -eq 0 ]; then pass "ALLOWS a non-Bash/Monitor tool (matcher discipline)"
else fail "fired on the wrong tool — exit $GRC"; fi

run "$LANE" Bash ''
if [ "$GRC" -eq 0 ]; then pass "ALLOWS an empty command (fail open)"
else fail "blocked an empty command — exit $GRC"; fi

# malformed stdin → fail open. A guard bug must never brick an agent.
GRC=0
printf 'not json at all' | DREAMTEAM_AGENT_ID="$LANE" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>"$TMP/err" || GRC=$?
if [ "$GRC" -eq 0 ]; then pass "ALLOWS on unparseable stdin (fail open)"
else fail "blocked on malformed stdin — exit $GRC"; fi

# missing config file → fail open to ENFORCING (a missing kill switch must not
# silently disable the guard), but still allow a non-poll command.
run "$LANE" Bash 'echo hello' "$TMP/nonexistent.json"
if [ "$GRC" -eq 0 ]; then pass "ALLOWS a benign command when the config file is missing"
else fail "blocked a benign command — exit $GRC"; fi
run "$LANE" Bash "$MEASURED" "$TMP/nonexistent.json"
if blocked; then pass "still ENFORCES when the config file is missing (absent kill switch ≠ disabled guard)"
else fail "a missing config silently disabled the guard — exit $GRC"; fi

# ── HEREDOC DATA (#191): a heredoc body is data unless something runs it ──────────
# The 2026-11-14 06:5x false blocks: a python heredoc that EDITED overnight.js quoted
# the merge warden's checks-loop line, and a heredoc writing an issue body described
# it. Nothing polled. The text is a mention; a poll is where a shell RUNS it. (The
# first edit of this very block was itself blocked on 2026-11-17 04:5x.)
LOOPLINE="$(grep -m1 'until gh pr checks' "$ROOT/workflows/overnight.js")"
POLLBODY=$'while true; do\n  gh pr checks 458 --repo o/r\n  sleep 30\ndone'
# allow <label> <command>  /  deny <label> <command>   (as the teammate, tool Bash)
allow() { run "$LANE" Bash "$2"; if [ "$GRC" -eq 0 ]; then pass "ALLOWS $1"; else fail "false block: $1 — exit $GRC"; fi; }
deny()  { run "$LANE" Bash "$2"; if blocked; then pass "BLOCKS $1"; else fail "missed a poll: $1 — exit $GRC"; fi; }

if [ -n "$LOOPLINE" ]; then pass "fixture: overnight.js still holds the checks-loop line the incident quoted"
else fail "fixture: the checks-loop line is gone from workflows/overnight.js"; fi
allow "the 11-14 incident: a python3 - heredoc that edits overnight.js and quotes its checks loop" \
  "cd $ROOT && python3 - <<'PY'"$'\np = "workflows/overnight.js"\ns = open(p).read()\nold = r"""'"$LOOPLINE"$'"""\nassert s.count(old) == 1\nopen(p, "w").write(s.replace(old, "   (the lead gates; no loop)"))\nPY\ngit diff --stat'
allow "the 11-14 second hit: an issue body written by heredoc, then posted with gh api -F body=@file" \
  $'cat > "$S/issue-191.md" <<\'EOF\'\nThe guard blocked a heredoc that quoted `until gh pr checks 1; do sleep 30; done`.\nEOF\ngh api repos/o/r/issues -X POST -F title=x -F body=@"$S/issue-191.md"'
allow "a PR body passed as \"\$(cat <<'EOF' … EOF)\" to gh pr create" \
  $'gh pr create --title t --body "$(cat <<\'EOF\'\nWe removed the old `while true; do gh pr checks 1; sleep 30; done` watcher.\nEOF\n)"'
allow "a commit message fed to git commit -F - by heredoc" \
  $'git commit -q -F - <<\'EOF\'\nfix: drop the `for i in $(seq 40); do gh pr checks 1; sleep 30; done` loop\nEOF'
allow "a body kept in a variable and passed only to gh" \
  $'body=$(cat <<\'EOF\'\nuntil gh pr checks 1; do sleep 30; done\nEOF\n)\ngh api repos/o/r/issues/1/comments -f body="$body"'
allow "a <<- heredoc with tab-indented data, written to a file nothing runs" \
  $'cat > notes.md <<-\'EOF\'\n\twhile :; do gh pr checks 1; sleep 30; done\n\tEOF\nwc -l notes.md'
allow "this suite's own edit (python heredoc holding allow/deny lines that name poll loops)" \
  "python3 - <<'PYEDIT'"$'\ns = open("t.sh").read()\ns += \'deny "x" $\\\'bash <<EOF\\nwhile :; do gh pr checks 1; sleep 30; done\\nEOF\\\'\\n\'\nopen("t.sh", "w").write(s)\nPYEDIT\ngit diff --stat t.sh'
deny "an edit script whose edited file is then run (it may now hold a poll)" \
  "python3 - <<'PYEDIT'"$'\ns = open("t.sh").read()\ns += "while :; do gh pr checks 1; sleep 30; done\\n"\nopen("t.sh", "w").write(s)\nPYEDIT\nbash t.sh'

deny "a heredoc fed to bash" $'bash <<\'EOF\'\n'"$POLLBODY"$'\nEOF'
deny "a heredoc fed to bash -s over ssh" $'ssh gpu1 bash -s <<\'EOF\'\n'"$POLLBODY"$'\nEOF'
deny "a heredoc piped into sh" $'cat <<\'EOF\' | sh\n'"$POLLBODY"$'\nEOF'
deny "a script written by heredoc and then run" $'cat > poll.sh <<\'EOF\'\n'"$POLLBODY"$'\nEOF\nbash poll.sh'
deny "a script written by heredoc, made executable and run by path" $'cat <<\'EOF\' > "$S/poll.sh" && chmod +x "$S/poll.sh" && "$S/poll.sh"\n'"$POLLBODY"$'\nEOF'
deny "a script written by tee and then sourced" $'tee p.sh >/dev/null <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n. ./p.sh'
deny "a heredoc read into a variable, then eval'd" $'read -r -d \'\' s <<\'EOF\'\n'"$POLLBODY"$'\nEOF\neval "$s"'
deny "a heredoc captured by \$(…) and run by bash -c" $'bash -c "$(cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n)"'
deny "a heredoc captured into a variable that bash -c runs" $'p=$(cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n)\nbash -c "$p"'
deny "a heredoc behind process substitution, sourced" $'source <(cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n)'
deny "a heredoc whose \$(…) runs when it expands (unquoted delimiter)" $'cat <<EOF\n$(while :; do gh pr checks 1; sleep 30; done)\nEOF'
deny "a heredoc inside a group piped to bash" $'{ cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n} | bash'
deny "a heredoc feeding a while-read loop that evals each line" $'while read -r l; do eval "$l"; done <<\'EOF\'\n'"$POLLBODY"$'\nEOF'
deny "a python heredoc that polls through os.system" $'python3 - <<\'PY\'\nimport os, time\nwhile True:\n    os.system("gh pr checks 458 --repo o/r")\n    time.sleep(30)\nPY'
deny "a gh alias defined from a heredoc (gh runs it as shell)" $'gh alias set --shell w - <<\'EOF\'\n'"$POLLBODY"$'\nEOF\ngh w'
deny "a real loop in the code, with a heredoc only as its input list" $'while read -r n; do gh pr checks "$n"; sleep 30; done <<\'EOF\'\n458\n459\nEOF'
# python3 missing or failing: step (f) must keep the block (the pre-#191 behaviour), never allow
mkdir -p "$TMP/nopy"; printf '#!/bin/sh\nexit 1\n' > "$TMP/nopy/python3"; chmod +x "$TMP/nopy/python3"
GRC=0
jq -nc --arg c $'cat > p.sh <<\'EOF\'\n'"$POLLBODY"$'\nEOF' '{tool_name:"Bash",tool_input:{command:$c}}' \
  | PATH="$TMP/nopy:$PATH" DREAMTEAM_AGENT_ID="$LANE" DREAMTEAM_CONFIG="$TMP/on.json" bash "$GUARD" 2>"$TMP/err" || GRC=$?
if blocked; then pass "KEEPS the block when python3 fails (no reader, no narrowing)"
else fail "a failing python3 turned a heredoc block into an allow — exit $GRC"; fi
deny "a heredoc written by a sink inside an if (its output is not followed)" $'if true; then cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\nfi | bash'
# xreview r1 (2026-11-17): each of these was allowed by the first cut
deny "code after an ANSI-C-quoted delimiter (<<\$'EOF' ends at EOF, not \$EOF)" $'cat <<$\'EOF\'\nnotes\nEOF\n'"$POLLBODY"
deny "an ANSI-C delimiter where the literal \$EOF line also exists further down" $'cat <<$\'EOF\'\nnotes\nEOF\n'"$POLLBODY"$'\n$EOF'
deny "a script written now for a LATER call to run (no data extension): the body stays judged" $'cat > "$HOME/bin/ci-wait" <<\'EOF\'\n'"$POLLBODY"$'\nEOF'
allow "a heredoc written to a .md file that nothing runs" $'cat > "$S/notes.md" <<\'EOF\'\n'"$POLLBODY"$'\nEOF'
# xreview r2
deny "a body copied by printf -vNAME (attached) into a variable that eval runs" $'read -r -d \'\' a <<\'EOF\'\n'"$POLLBODY"$'\nEOF\nprintf -vb \'%s\' "$a"\neval "$b"'
deny "a python body that writes to a path from an env var, then bash runs \"\$VAR\"" $'export POLL_SCRIPT="$S/ci-wait.sh"\npython3 - <<\'PY\'\nimport os\nfrom pathlib import Path\nPath(os.environ["POLL_SCRIPT"]).write_text("while true; do gh pr checks 458 --repo o/r; sleep 30; done\\n")\nPY\nbash "$POLL_SCRIPT"'
deny "a python body that writes a script, then a glob runs it" $'python3 - <<\'PY\'\nopen("ci-wait.sh", "w").write("while true; do gh pr checks 1; sleep 30; done\\n")\nPY\nbash ./ci-*.sh'
deny "a git alias defined from a heredoc, then run" $'git config alias.wait-checks "$(cat <<\'EOF\'\n!gh pr checks 458 --repo o/r --watch\nEOF\n)"\ngit wait-checks'
deny "a git -c alias from a heredoc" $'git -c alias.w="$(cat <<\'EOF\'\n!while :; do gh pr checks 1; sleep 30; done\nEOF\n)" w'
deny "gh config set pager from a heredoc" $'gh config set pager "$(cat <<\'EOF\'\nsh -c \'while :; do gh pr checks 1; sleep 30; done\'\nEOF\n)"\ngh pr view 1'
deny "a python edit followed by a test run: the edit may have written what runs (kept)" \
  $'python3 - <<\'PY\'\np = "workflows/overnight.js"\ns = open(p).read()\ns = s.replace("until gh pr checks 1; do sleep 30; done", "")\nopen(p, "w").write(s)\nPY\nbash tests/test-overnight-workflow.sh'
# xreview r3
deny "a python body that polls through a third-party runner (invoke.run)" $'python3 - <<\'PY\'\nfrom invoke import run\nrun("gh pr checks 458 --repo o/r --watch")\nPY'
deny "a python body that imports a runner by plain import (import sh)" $'python3 - <<\'PY\'\nimport sh\nsh.bash("-c", "gh pr checks 458 --repo o/r --watch")\nPY'
deny "a python body that writes a script with a two-letter name, then bash runs it" $'python3 - <<\'PY\'\nfrom pathlib import Path\nPath("ci").write_text("gh pr checks 458 --repo o/r --watch\\n")\nPY\nbash ci'
allow "a python edit importing only stdlib text modules (json, re, pathlib, textwrap)" \
  $'python3 - <<\'PY\'\nimport json, re, textwrap\nfrom pathlib import Path\np = Path("notes.md")\np.write_text(textwrap.dedent("""\n    old: until gh pr checks 1; do sleep 30; done\n"""))\nPY\ngit add notes.md'
# xreview r4
deny "a heredoc captured by \$( ) in command position (its words run as a command)" $'$(cat <<\'EOF\'\ngh pr checks 458 --repo o/r --watch\nEOF\n)'
deny "a python body that builds the script name (with_suffix), then bash runs it" $'python3 - <<\'PY\'\nfrom pathlib import Path\nscript = Path("ci-wait").with_suffix(".sh")\nscript.write_text("gh pr checks 458 --repo o/r --watch\\n")\nPY\nbash ci-wait.sh'
deny "an import after a semicolon (import time; from invoke import run)" $'python3 - <<\'PY\'\nimport time; from invoke import run\nwhile True:\n    run("gh pr checks 458 --repo o/r")\n    time.sleep(30)\nPY'
deny "an import inside a function body" $'python3 - <<\'PY\'\nimport time\ndef go():\n    from invoke import run\n    run("gh pr checks 458 --repo o/r")\nwhile True:\n    go(); time.sleep(30)\nPY'
deny "a python body that does not parse (kept: its imports cannot be read)" $'python3 - <<\'PY\'\nimport json\nwhile True:\n    print "gh pr checks 1"\n    sleep 30\nPY'
allow "a python edit followed only by git add / git commit (sinks)" \
  $'python3 - <<\'PY\'\np = "workflows/overnight.js"\ns = open(p).read()\nopen(p, "w").write(s.replace("until gh pr checks 1; do sleep 30; done", ""))\nPY\ngit add workflows/overnight.js && git commit -q -m "drop loop"'
allow "a commit message by heredoc, then a test run (git commit writes no file that runs)" \
  $'git commit -q -F - <<\'EOF\'\nfix: drop the `until gh pr checks 1; do sleep 30; done` loop\nEOF\nbash tests/run.sh'
deny "a patch by git apply, then any test run (the patch may have written it)" $'git apply <<\'PATCH\'\n--- a/t.sh\n+++ b/t.sh\n@@ -1 +1 @@\n-x\n+while :; do gh pr checks 1; sleep 30; done\nPATCH\nbash tests/run.sh'
deny "an unterminated heredoc (its delimiter may be misread): kept, never cut" $'cat <<\'EOF\'\n'"$POLLBODY"
deny "a python program that writes a script with Path.write_text, then bash runs it" $'python3 - <<\'PY\'\nfrom pathlib import Path\nPath("poll.sh").write_text("while true; do gh pr checks 458 --repo o/r; sleep 30; done\\n")\nPY\nbash poll.sh'
deny "a patch applied by git apply that creates a script, then bash runs it" $'git apply <<\'PATCH\'\ndiff --git a/poll.sh b/poll.sh\nnew file mode 100644\n--- /dev/null\n+++ b/poll.sh\n@@ -0,0 +1 @@\n+while true; do gh pr checks 458 --repo o/r; sleep 30; done\nPATCH\nbash poll.sh'
deny "a captured body copied into a second variable that bash -c runs" $'poll=$(cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n)\ncommand="set -e; $poll"\nbash -c "$command"'
deny "a captured body copied by local/export into a variable that eval runs" $'poll=$(cat <<\'EOF\'\n'"$POLLBODY"$'\nEOF\n)\nexport CMD2="$poll"\neval "$CMD2"'
deny "a body copied by printf -v into a variable that eval runs" $'read -r -d \'\' a <<\'EOF\'\n'"$POLLBODY"$'\nEOF\nprintf -v b \'%s\' "$a"\neval "$b"'
deny "a body put on the clipboard, then pasted into bash" $'xclip -selection clipboard <<\'EOF\'\n'"$POLLBODY"$'\nEOF\nxclip -o -selection clipboard | bash'
allow "a python edit whose later command only reads (git diff) the file it names" \
  $'python3 - <<\'PY\'\np = "notes.md"\nopen(p, "a").write("old: while :; do gh pr checks 1; sleep 30; done\\n")\nPY\ngit diff --stat notes.md'
deny "a poll on the header line of an unterminated heredoc" $'gh pr checks 1; sleep 30; gh pr checks 1; cat <<\'EOF\'\ntext'

# truly-empty identity: only assertable when the suite is not itself a teammate.
. "$ROOT/scripts/lib/agent-id.sh"
if [ -n "$(DREAMTEAM_AGENT_ID='' dt_agent_id)" ]; then
  skip "empty-identity fail-open: this suite is running inside a teammate, so the /proc walk finds a real id (see header)"
else
  run "" Bash "$MEASURED"
  if [ "$GRC" -eq 0 ]; then pass "ALLOWS when no teammate identity can be resolved (fail open)"
  else fail "blocked with no resolvable identity — exit $GRC"; fi
fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped, $((PASS+FAIL)) asserted"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
