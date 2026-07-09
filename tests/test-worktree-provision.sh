#!/usr/bin/env bash
# dreamteam — regression test for worktree PROVISIONING (the 2026-07-08 subdir break).
#
#   THE BUG: the manual recipe used a CWD-RELATIVE `.claude/worktrees/<name>` path.
#   `git worktree add <relpath>` resolves it against the current dir, so run from a
#   SUBDIRECTORY (morpheus's cwd was rust/clock) it created the worktree NESTED inside
#   the working tree (rust/clock/.claude/worktrees/…) instead of at the repo root →
#   the agent "couldn't isolate and ran in-place (safe but wrong)".
#
#   THE FIX: scripts/worktree-provision.sh anchors to `git rev-parse --show-toplevel`
#   and uses an ABSOLUTE path, so provisioning works from ANY cwd.
#
# ISOLATION: fully hermetic — builds a throwaway git repo in a temp dir, uses a LOCAL
# base ref (no network/origin), removes it on exit. No production script is touched.
# (Sibling test-worktree.sh covers the separate worktree-GUARD hook.)
#
# Run standalone:  bash tests/test-worktree-provision.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROV="$ROOT/scripts/worktree-provision.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/rust/clock"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/rust/clock/f"
git -C "$REPO" add rust/clock/f
git -C "$REPO" commit -qm init >/dev/null
git -C "$REPO" branch -M main

EXPECT="$REPO/.claude/worktrees/lucid-262-x"
NESTED="$REPO/rust/clock/.claude/worktrees/lucid-262-x"

# ── (1) Provision FROM THE SUBDIR (reproduces morpheus's cwd), local base `main`.
OUT="$(cd "$REPO/rust/clock" && "$PROV" lucid fix/262-x main 2>/dev/null)"
[ "$OUT" = "$EXPECT" ]  && pass "subdir provision returns repo-root path" || fail "path: expected '$EXPECT' got '$OUT'"
[ -d "$EXPECT" ]        && pass "worktree exists at REPO ROOT"            || fail "worktree missing at repo root"
[ ! -e "$NESTED" ]      && pass "NOT nested inside rust/clock (fixed)"    || fail "worktree NESTED inside subdir — bug present"
git -C "$REPO" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $EXPECT" \
  && pass "worktree registered with git" || fail "worktree not registered"
git -C "$REPO" show-ref --verify --quiet "refs/heads/fix/262-x" \
  && pass "branch fix/262-x created"     || fail "branch not created"

# ── (2) Idempotent: re-run (from repo root this time) returns the SAME path, no error.
OUT2="$(cd "$REPO" && "$PROV" lucid fix/262-x main 2>/dev/null)"
[ "$OUT2" = "$EXPECT" ] && pass "idempotent re-run returns same path" || fail "idempotent: got '$OUT2'"

# ── (3) Negative control: prove the OLD relative recipe DOES nest (bug is real, not vacuous).
git -C "$REPO" worktree remove --force "$EXPECT" 2>/dev/null || true
git -C "$REPO" worktree prune 2>/dev/null || true
git -C "$REPO" branch -D fix/262-x >/dev/null 2>&1 || true
( cd "$REPO/rust/clock" && git worktree add -b legacy-demo ".claude/worktrees/legacy" main >/dev/null 2>&1 )
[ -e "$REPO/rust/clock/.claude/worktrees/legacy" ] \
  && pass "negative control: relative recipe from subdir DOES nest (bug confirmed real)" \
  || fail "negative control: relative recipe did not nest as expected"

echo "── worktree-provision: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
