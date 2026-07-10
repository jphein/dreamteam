#!/usr/bin/env bash
# dreamteam — regression tests for the WORKTREE GUARD safety hook.
#
#   • scripts/worktree-guard.sh — PreToolUse(Edit|Write) hook that runs INSIDE a
#     teammate's own session and BLOCKS writes outside the agent's assigned
#     worktree (its team-config cwd) when that cwd is under .claude/worktrees/.
#     This converts the skill's #1 failure mode (cross-agent collision — 2 real
#     incidents) from prompt discipline into harness law.
#
# ISOLATION STRATEGY — zero edits to the production script:
#   The guard observes the world only through (a) stdin JSON, (b) env-overridable
#   seams: DREAMTEAM_AGENT_ID (session identity — bypasses the /proc walk),
#   DREAMTEAM_TEAMS_DIR (team config root), DREAMTEAM_CONFIG (the enforce switch),
#   and (c) $PWD for relative-path resolution. We drive every path through those
#   seams with fixture configs. The REAL guard logic runs unmodified.
#
#   KEY FIXTURE NOTE: the guard does PURE STRING MATCHING on file_path and cwd —
#   it never stats them (only the config files and /proc are read from disk). So
#   fixtures use SYNTHETIC absolute paths under /work/… — crucially NOT under
#   /tmp, because the guard legitimately ALLOWS /tmp (and */scratch/*). A fixture
#   rooted at mktemp's /tmp would make every block-path silently pass. (That
#   exact trap bit the first smoke test.) Only the config FILES live under
#   mktemp's /tmp — they're read via env seams, immune to the file_path rules.
#
#   The "no identity" case: with DREAMTEAM_AGENT_ID empty the guard walks /proc
#   for an ancestor --agent-id. When this suite is run by an agent, that walk may
#   find the runner's OWN id — but DREAMTEAM_TEAMS_DIR points at the fixture,
#   which has no config for that team, so resolution fails → fail-open exit 0.
#   Same exit 0 when run from a plain shell (no --agent-id ancestor at all). The
#   asserted property (unresolvable identity → allow) holds either way.
#
# Run standalone:  bash tests/test-worktree.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/worktree-guard.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── temp sandbox: fixture configs only (read via env seams), cleaned on exit ──
TMP="$(mktemp -d)"

# #48: the relative-path BLOCK test (test 10) resolves a relative file_path against
# the guard's real $PWD and asserts a BLOCK — so it must cd into a REAL directory
# and root the 'rel' member's worktree there. The guard ALWAYS allows /tmp/* and
# */scratch/* (correct product behavior), so if that base sits under one of those
# the block can NEVER fire and the assertion FAILS SPURIOUSLY — exactly what happens
# when the suite is run from a git-worktree extraction under /tmp (mktemp's default;
# hit while verifying #47). So DON'T root it at $ROOT (the repo may live under /tmp):
# pin it to a dedicated NON-exempt dir under $HOME, independent of where the repo is
# checked out. If no non-exempt base is obtainable (pathological — $HOME itself under
# /tmp/scratch, or uncreatable), RELBASE is emptied and test 10 skips-with-note —
# never a false FAIL.
RELBASE="$(mktemp -d "${HOME:-/nonexistent-home}/.dreamteam-reltest-XXXXXX" 2>/dev/null || true)"
case "${RELBASE:-}" in
  ''|/tmp/*|*/scratch/*) RELBASE="" ;;   # unobtainable or itself guard-exempt → skip test 10
  *) mkdir -p "$RELBASE" ;;
esac
trap 'rm -rf "$TMP" ${RELBASE:+"$RELBASE"}' EXIT

# Team config: a WORKTREE-mode member (cwd under .claude/worktrees → guarded),
# a SHARED-mode member (plain cwd → exempt), and a member for the relative-path
# case whose worktree cwd is rooted at the NON-exempt $RELBASE (see #48 note above)
# so we can cd into a real directory to exercise $PWD resolution (test 10 below).
REL_CWD="${RELBASE:-$ROOT}/.claude/worktrees/luna-rel"
mkdir -p "$TMP/teams/testteam"
cat > "$TMP/teams/testteam/config.json" <<JSON
{"members":[
  {"name":"luna","agentType":"lucid","isActive":false,"agentId":"luna@testteam","cwd":"/work/repo/.claude/worktrees/luna-1","prompt":"task: worktree member"},
  {"name":"morpheus","agentType":"morpheus","isActive":false,"agentId":"morpheus@testteam","cwd":"/work/repo","prompt":"task: shared-checkout member"},
  {"name":"rel","agentType":"lucid","isActive":false,"agentId":"rel@testteam","cwd":"$REL_CWD","prompt":"task: relative-resolution member"}
]}
JSON

# enforce on/off configs — exercises the `if .worktree.enforce == false` switch
# (NOT `// true`; jq's // treats false as empty — the bug this pattern avoids).
printf '%s\n' '{"worktree":{"enforce":true}}'  > "$TMP/on.json"
printf '%s\n' '{"worktree":{"enforce":false}}' > "$TMP/off.json"

export DREAMTEAM_TEAMS_DIR="$TMP/teams"

# run_gate <agent_id> <stdin-json> [config]  → sets GRC (exit code), $TMP/err (stderr).
# The env prefix is on the real `bash` command (not the function), so it is
# unambiguously exported into the guard process.
GRC=0
run_gate() {
  local aid="$1" json="$2" cfg="${3:-$TMP/on.json}"
  GRC=0
  printf '%s' "$json" | DREAMTEAM_AGENT_ID="$aid" DREAMTEAM_CONFIG="$cfg" bash "$GUARD" 2>"$TMP/err" || GRC=$?
}
# run_gate_cd <cwd> <agent_id> <stdin-json> [config]  → same, but runs the guard
# with a REAL working directory so relative file_paths resolve against $PWD.
run_gate_cd() {
  local dir="$1" aid="$2" json="$3" cfg="${4:-$TMP/on.json}"
  GRC=0
  ( cd "$dir" && printf '%s' "$json" | DREAMTEAM_AGENT_ID="$aid" DREAMTEAM_CONFIG="$cfg" bash "$GUARD" ) 2>"$TMP/err" || GRC=$?
}

# convenience payload builders
edit()  { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}'  "$1"; }
write() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }

echo "── worktree-guard.sh (worktree containment gate) ────────────────"

# 0) static: the script must parse.
if bash -n "$GUARD" 2>"$TMP/err"; then
  pass "worktree-guard.sh passes bash -n (syntax)"
else
  fail "worktree-guard.sh has a syntax error: $(head -1 "$TMP/err")"
fi

# 1) BLOCK: worktree-mode agent writing OUTSIDE its worktree (into the shared repo).
run_gate "luna@testteam" "$(edit /work/repo/src/main.kt)"
if [ "$GRC" -eq 2 ] && grep -qi 'WORKTREE GUARD' "$TMP/err"; then
  pass "BLOCKS (exit 2 + guard message) a worktree agent writing outside its worktree"
else
  fail "should block out-of-worktree write — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 2) ALLOW: same agent writing INSIDE its assigned worktree.
run_gate "luna@testteam" "$(edit /work/repo/.claude/worktrees/luna-1/src/main.kt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) a write inside the assigned worktree"
else
  fail "should allow in-worktree write — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 3) ALLOW: /tmp is an exempt scratch location.
run_gate "luna@testteam" "$(write /tmp/scratch-thing.txt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) a write under /tmp"
else
  fail "should allow /tmp write — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 4) ALLOW: any */scratch/* findings path is exempt (agents write findings there).
run_gate "luna@testteam" "$(write /home/jp/.claude/projects/x/scratch/task/luna.md)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) a write under a */scratch/* path"
else
  fail "should allow scratch write — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 5) ALLOW: SHARED-mode agent (cwd is a plain project dir, NOT a worktree) is
#    exempt — the legitimate disjoint-ownership mode. Writes anywhere in the repo.
run_gate "morpheus@testteam" "$(edit /work/repo/src/main.kt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) a shared-checkout agent writing in the shared repo"
else
  fail "should allow shared-mode write — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 6) ALLOW: no resolvable identity → orchestrator/main session → guard is a no-op.
#    (empty DREAMTEAM_AGENT_ID triggers the /proc walk; fixture teams dir ensures
#    any ambient id can't resolve to a worktree — see header note.)
run_gate "" "$(edit /work/repo/src/main.kt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) when no worktree identity resolves (orchestrator/main)"
else
  fail "should allow with no resolvable identity — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 7) ALLOW: non-Edit/Write tool passes through untouched (guard only gates writes).
run_gate "luna@testteam" '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) a non-Edit/Write tool (Bash) even for a worktree agent"
else
  fail "should ignore non-Edit/Write tools — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 8) NEGATIVE CONTROL: the EXACT payload that blocked in #1, with enforce=false,
#    must flip to ALLOW. Proves the block isn't vacuous AND the ==false switch works.
run_gate "luna@testteam" "$(edit /work/repo/src/main.kt)" "$TMP/off.json"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) the blocking payload when worktree.enforce=false (switch works, block non-vacuous)"
else
  fail "enforce=false should disable the guard — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 9) BLOCK: sibling-worktree prefix collision. Agent 'luna' owns …/luna-1; a write
#    into …/luna-12 must NOT be mistaken for "inside luna-1" (trailing-slash guard).
run_gate "luna@testteam" "$(edit /work/repo/.claude/worktrees/luna-12/x.kt)"
if [ "$GRC" -eq 2 ]; then
  pass "BLOCKS (exit 2) a write into a sibling worktree (luna-1 vs luna-12 prefix guard)"
else
  fail "should block sibling-worktree prefix collision — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 10) BLOCK: relative file_path is resolved against the hook's real $PWD, then
#     evaluated. We cd into $RELBASE (a REAL, guard-NON-exempt dir) — the 'rel'
#     member's worktree is $RELBASE/.claude/worktrees/luna-rel, so a bare
#     "reltest.kt" resolves to $RELBASE/reltest.kt (outside the worktree) → BLOCK.
#     Proves the relative→absolute resolution feeds the decision. (Note: bash
#     normalizes $PWD to the real cwd on startup, so PWD can't be faked via env —
#     hence cd. #48: rooted at $RELBASE, NOT $ROOT, so a repo living under /tmp
#     doesn't hit the guard's /tmp exemption and spuriously flip the block to allow.)
if [ -n "$RELBASE" ]; then
  run_gate_cd "$RELBASE" "rel@testteam" "$(edit reltest.kt)"
  if [ "$GRC" -eq 2 ]; then
    pass "BLOCKS (exit 2) a relative file_path that resolves outside the worktree (\$PWD resolution)"
  else
    fail "should resolve+block relative out-of-worktree path — got exit $GRC; stderr: $(head -1 "$TMP/err")"
  fi
else
  # No non-exempt base available (e.g. suite run with \$HOME under /tmp): the guard
  # correctly exempts /tmp & */scratch/*, so a block is untestable here. Skip, don't FAIL.
  echo "SKIP: relative-path block test — no non-exempt resolution base available (#48; guard correctly exempts /tmp & scratch)"
fi

# 11) FAIL-OPEN: identity resolves to a team with no config on disk → allow.
run_gate "ghost@nosuchteam" "$(edit /work/repo/src/main.kt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) fail-open when the team config is missing"
else
  fail "should fail open on missing team config — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 12) FAIL-OPEN: identity with no '@' can't be split into name/team → allow.
run_gate "malformed-no-at-sign" "$(edit /work/repo/src/main.kt)"
if [ "$GRC" -eq 0 ]; then
  pass "ALLOWS (exit 0) fail-open when the agent id has no '@' (unparseable)"
else
  fail "should fail open on unparseable agent id — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
