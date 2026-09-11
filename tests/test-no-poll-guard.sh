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
