#!/usr/bin/env bash
# dreamteam — regression tests for the PR gate / merge / cascade tools.
#
#   • scripts/pr-gate.sh    — is this PR ACTUALLY green? (REST only)
#   • scripts/pr-merge.sh   — squash-merge via REST, gate-first
#   • scripts/cascade.sh    — merge a queue in order, rebasing just in time
#
# THE TWO BUGS THESE PIN, both measured during the 2026-09-11 wave:
#
#  1. A BLANK CONCLUSION IS A RUNNING CHECK. GitHub reports an in-flight check
#     as {status:"in_progress", conclusion:null}. Any gate that treats "not
#     failed" as "passed" merges mid-run. Tested directly (test: running check).
#
#  2. THE VERDICT IS THE EXIT CODE, AND A PIPE THROWS IT AWAY.
#     `pr-gate.sh o/r 1 | tail -5` exits 0 — tail's status — no matter what the
#     gate decided. That is why the gate also prints its verdict to stderr, and
#     why there is a test asserting the piped case still SHOWS the failure.
#
# ISOLATION: `gh` is stubbed through the scripts' DREAMTEAM_GH seam and serves
# fixture JSON from a temp dir, piped through the REAL jq with the REAL --jq
# filter the script passed. No network, no credentials, no GitHub.
#
# Run standalone:  bash tests/test-pr-tools.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/pr-gate.sh"
MERGE="$ROOT/scripts/pr-merge.sh"
CASCADE="$ROOT/scripts/cascade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$FIX"

# ── the gh stub ──────────────────────────────────────────────────────────────
# Serves $FIX/<path with / and ?… flattened>.json through the caller's own --jq
# filter. A missing fixture exits 1, which is how the scripts see "unreadable".
# Mutating calls (-X PUT/DELETE) append to $TMP/calls.log so we can assert what
# the tools DID, not just what they printed.
cat > "$TMP/gh" <<'GHEOF'
#!/usr/bin/env bash
set -uo pipefail
FIX="${STUB_FIX:?}"; LOG="${STUB_LOG:?}"
method="GET"; path=""; jqf="."; seen_api=0
while [ $# -gt 0 ]; do
  case "$1" in
    api)        seen_api=1; shift ;;
    -X)         method="$2"; shift 2 ;;
    --jq)       jqf="$2"; shift 2 ;;
    -f|-F)      shift 2 ;;
    --paginate|--silent) shift ;;
    -*)         shift ;;
    *)          [ -z "$path" ] && path="$1"; shift ;;
  esac
done
[ "$seen_api" = "1" ] || { echo "stub: only 'gh api' is supported (got: $path)" >&2; exit 1; }
echo "$method $path" >> "$LOG"
key=$(printf '%s' "${path%%\?*}" | tr '/' '_')
f="$FIX/${method}_${key}.json"
[ -f "$f" ] || f="$FIX/GET_${key}.json"
[ -f "$f" ] || { echo "stub: no fixture for $method $path" >&2; exit 1; }
jq -r "$jqf" < "$f"
GHEOF
chmod +x "$TMP/gh"
export STUB_FIX="$FIX" STUB_LOG="$TMP/calls.log"
: > "$TMP/calls.log"
GHENV=(DREAMTEAM_GH="$TMP/gh" STUB_FIX="$FIX" STUB_LOG="$TMP/calls.log")

fixture() { cat > "$FIX/$1.json"; }
checks() { # checks <sha> <name@conclusion@status> …
  # '@' not ':' — a real check name contains a colon ("DeepSource: Analysis"),
  # and a fixture helper that splits on one silently mangles the very name the
  # ignore-list test depends on. (It did, on the first run.)
  local sha="$1"; shift
  { echo '{"check_runs":['
    local first=1 e n c s
    for e in "$@"; do
      IFS='@' read -r n c s <<< "$e"
      [ $first -eq 1 ] || echo ','
      first=0
      printf '{"name":"%s","conclusion":%s,"status":"%s"}' \
        "$n" "$([ -z "$c" ] && echo null || echo "\"$c\"")" "$s"
    done
    echo ']}'
  } > "$FIX/GET_repos_o_r_commits_${sha}_check-runs.json"
}
pull() { # pull <pr> <sha> <draft> <state> <merged> <branch> <base>
  fixture "GET_repos_o_r_pulls_$1" <<JSON
{"number":$1,"title":"a change","head":{"sha":"$2","ref":"$6"},"base":{"ref":"$7"},
 "draft":$3,"state":"$4","merged":$5}
JSON
}

RC=0; OUT=""
run() { RC=0; OUT=$(env "${GHENV[@]}" bash "$@" 2>"$TMP/err") || RC=$?; }

echo "── pr-gate.sh (is it ACTUALLY green?) ───────────────────────────"

if bash -n "$GATE" && bash -n "$MERGE" && bash -n "$CASCADE"; then
  pass "pr-gate.sh, pr-merge.sh, cascade.sh all pass bash -n"
else fail "a script has a syntax error"; fi

pull 1 aaaa1111 false open false feat/x main
checks aaaa1111 "test-linux@success@completed" "lint@success@completed" "test-macos@skipped@completed"
run "$GATE" o/r 1
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'GATE OK'; then
  pass "exit 0 + GATE OK when every check concluded success/skipped"
else fail "green PR did not pass the gate — exit $RC: $OUT"; fi

# ── #1: a blank conclusion is a RUNNING check, not a pass.
pull 2 bbbb2222 false open false feat/y main
checks bbbb2222 "test-linux@success@completed" "test-macos@@in_progress"
run "$GATE" o/r 2
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'still RUNNING'; then
  pass "exit 1 on a blank conclusion — a RUNNING check is not a passing one"
else fail "gate passed a still-running check — exit $RC: $OUT"; fi

pull 3 cccc3333 false open false feat/z main
checks cccc3333 "test-linux@failure@completed" "lint@success@completed"
run "$GATE" o/r 3
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'NOT GREEN: test-linux'; then
  pass "exit 1 and names the failing check"
else fail "failing check not caught — exit $RC: $OUT"; fi

# ── #2: the pipe trap. The exit code is lost, so the verdict must still be
#        VISIBLE. This asserts the stderr copy exists.
seen=$(env "${GHENV[@]}" bash "$GATE" o/r 3 2>&1 >/dev/null | grep -c 'GATE FAILED')
if [ "${seen:-0}" -ge 1 ]; then
  pass "the verdict is also on stderr, so \`| tail\` (which eats the exit code) still shows it"
else fail "piping the gate would hide the failure entirely"; fi

# ignored external apps are COUNTED OUT but NAMED — a silent ignore is how a
# required check hides behind a glob.
pull 4 dddd4444 false open false feat/w main
checks dddd4444 "test-linux@success@completed" "CodeRabbit@@queued" "DeepSource: Analysis@@queued"
run "$GATE" o/r 4
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ignored 2 external'; then
  pass "ignores never-concluding external apps AND lists them"
else fail "external-app handling wrong — exit $RC: $OUT"; fi

# a required check must NOT be ignorable by accident: override the glob and the
# same run must now fail. (Proves the ignore list is load-bearing, not decorative.)
RC=0
OUT=$(env "${GHENV[@]}" DREAMTEAM_GATE_IGNORE='nothing-matches-this' bash "$GATE" o/r 4 2>"$TMP/err") || RC=$?
if [ "$RC" -eq 1 ]; then
  pass "with the ignore list emptied, the same queued externals correctly fail the gate"
else fail "ignore-list override had no effect — exit $RC"; fi

pull 5 eeee5555 true open false feat/draft main
checks eeee5555 "test-linux@success@completed"
run "$GATE" o/r 5
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qi 'DRAFT'; then
  pass "exit 1 on a draft PR even when its checks are green"
else fail "draft PR not caught — exit $RC: $OUT"; fi

pull 6 ffff6666 false open false feat/nociv main
checks ffff6666
run "$GATE" o/r 6
if [ "$RC" -eq 4 ]; then
  pass "exit 4 (distinct from 1) when the repo has no check runs at all — 'no CI' is not 'red'"
else fail "no-checks case should be exit 4 — got $RC: $OUT"; fi

run "$GATE" o/r 999
if [ "$RC" -eq 3 ]; then pass "exit 3 (distinct from 1) when the PR cannot be read — 'unreadable' is not 'red'"
else fail "unreadable PR should be exit 3 — got $RC"; fi

run "$GATE" o/r
if [ "$RC" -eq 2 ]; then pass "exit 2 on a usage error"
else fail "usage error should be exit 2 — got $RC"; fi

echo "── pr-merge.sh ──────────────────────────────────────────────────"

fixture GET_repos_o_r_commits_main <<< '{"sha":"9999abcd0000"}'
fixture PUT_repos_o_r_pulls_1_merge <<< '{"merged":true,"sha":"9999abcd0000"}'
fixture DELETE_repos_o_r_git_refs_heads_feat_x <<< '{}'

: > "$TMP/calls.log"
run "$MERGE" --dry-run o/r 1
if [ "$RC" -eq 0 ] && ! grep -q '^PUT' "$TMP/calls.log"; then
  pass "--dry-run gates but issues no PUT (nothing is merged)"
else fail "--dry-run merged something — exit $RC; calls: $(cat "$TMP/calls.log")"; fi

: > "$TMP/calls.log"
run "$MERGE" o/r 1
if [ "$RC" -eq 0 ] && grep -q 'PUT repos/o/r/pulls/1/merge' "$TMP/calls.log" \
   && printf '%s' "$OUT" | grep -q 'new main head: 9999abcd'; then
  pass "merges via REST PUT and prints the new base head sha (the cascade needs it)"
else fail "merge path wrong — exit $RC: $OUT"; fi

# the branch must SURVIVE by default: deleting it is what breaks a changelog
# entry that cites the pre-merge sha (measured, 2026-09-11).
if ! grep -q '^DELETE' "$TMP/calls.log" && printf '%s' "$OUT" | grep -q 'kept branch feat/x'; then
  pass "keeps the head branch by default and says so (deletion orphans a cited sha)"
else fail "default merge deleted the branch"; fi

: > "$TMP/calls.log"
run "$MERGE" --delete-branch o/r 1
if grep -q 'DELETE repos/o/r/git/refs/heads/feat/x' "$TMP/calls.log"; then
  pass "--delete-branch is honoured when explicitly asked for"
else fail "--delete-branch did not delete; calls: $(cat "$TMP/calls.log")"; fi

: > "$TMP/calls.log"
run "$MERGE" o/r 3       # the red PR
if [ "$RC" -eq 1 ] && ! grep -q '^PUT' "$TMP/calls.log"; then
  pass "refuses to merge a red PR and never reaches the merge API"
else fail "merged a red PR — exit $RC; calls: $(cat "$TMP/calls.log")"; fi

: > "$TMP/calls.log"
run "$MERGE" o/r 2       # the still-running PR
if [ "$RC" -eq 1 ] && ! grep -q '^PUT' "$TMP/calls.log"; then
  pass "refuses to merge mid-run (the blank-conclusion case, end to end)"
else fail "merged a PR whose CI was still running — exit $RC"; fi

echo "── cascade.sh (just-in-time rebase order) ───────────────────────"

fixture GET_repos_o_r_compare_main...feat_x <<< '{"behind_by":0}'
fixture GET_repos_o_r_commits_HEAD <<< '{"sha":"9999abcd0000"}'

: > "$TMP/calls.log"
run "$CASCADE" --dry-run o/r 1
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'CASCADE COMPLETE: 1/1'; then
  pass "walks an up-to-date green queue to completion"
else fail "cascade did not complete — exit $RC: $OUT"; fi

# BEHIND base → stop and name the lane, WITHOUT merging. This is the whole
# just-in-time protocol: its CI ran against the old base, so it is not trustworthy.
pull 7 7777aaaa false open false feat/behind main
checks 7777aaaa "test-linux@success@completed"
fixture GET_repos_o_r_compare_main...feat_behind <<< '{"behind_by":3}'
: > "$TMP/calls.log"
run "$CASCADE" o/r 7:morpheus-lane
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'go #7 9999abcd' \
   && printf '%s' "$OUT" | grep -q 'morpheus-lane' && ! grep -q '^PUT' "$TMP/calls.log"; then
  pass "STOPS on a behind-base PR, prints the exact 'go #N <sha>' ping for the named lane, merges nothing"
else fail "behind-base handling wrong — exit $RC: $OUT"; fi

run "$CASCADE" o/r 7
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'feat/behind'; then
  pass "without a lane name, names the head branch so the lead can pick the owner"
else fail "unnamed-lane path wrong — exit $RC: $OUT"; fi

# idempotence: an already-merged PR is skipped, so a stopped cascade can simply
# be re-run rather than hand-edited.
pull 8 8888aaaa false closed true feat/done main
: > "$TMP/calls.log"
run "$CASCADE" --dry-run o/r 8 1
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'SKIP o/r#8 — already merged'; then
  pass "skips already-merged PRs, so a stopped cascade is safe to re-run verbatim"
else fail "not idempotent — exit $RC: $OUT"; fi

# ordering: a stop must not silently process later PRs.
: > "$TMP/calls.log"
run "$CASCADE" o/r 7:lane 1
if [ "$RC" -eq 1 ] && ! grep -q 'pulls/1/merge' "$TMP/calls.log"; then
  pass "a stop halts the queue — later PRs are not merged out of order"
else fail "cascade continued past a stop; calls: $(cat "$TMP/calls.log")"; fi

run "$CASCADE" o/r
if [ "$RC" -eq 2 ]; then pass "exit 2 on a usage error"
else fail "usage error should be exit 2 — got $RC"; fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
