#!/usr/bin/env bash
# dreamteam — worktree-provision.sh: create a per-agent worktree, CWD-INDEPENDENTLY.
#
# THE fix for the 2026-07-08 worktree-isolation breakage (morpheus / OTA spike):
# the manual recipe (skill) used a CWD-RELATIVE path — `.claude/worktrees/<name>`.
# `git worktree add <relpath>` resolves that against the *current directory*, so when
# provisioning ran from a SUBDIRECTORY (morpheus's cwd was `rust/clock`), the worktree
# was created NESTED inside the working tree at `rust/clock/.claude/worktrees/<name>`
# instead of at the repo root — the agent "couldn't isolate and ran in-place (safe but
# wrong)". (Reproduced 2026-07-08: from a subdir the relative recipe lands nested; a
# repo-root-anchored ABSOLUTE path lands correctly.)
#
# This script anchors to the repo TOPLEVEL (`git rev-parse --show-toplevel`) and uses an
# ABSOLUTE destination path, so provisioning works from ANY cwd — repo root, a subdir
# like rust/clock, or even another worktree.
#
# Usage: worktree-provision.sh <agent> <branch> [base-ref] [repo-dir]
#   agent     short agent name (e.g. lucid)   -> dir name is <agent>-<branch-basename>
#   branch    branch to create/use (e.g. fix/262-chroma-cache-close)
#   base-ref  base to branch off (default: origin/main)
#   repo-dir  any path inside the target repo (default: $PWD)
#
# Prints the ABSOLUTE worktree path on stdout (embed it verbatim in the agent's prompt).
# All git chatter goes to stderr so stdout is JUST the path.
# Idempotent: an already-registered worktree at the target path is reused (re-print + exit 0).
set -euo pipefail

AGENT="${1:?usage: worktree-provision.sh <agent> <branch> [base-ref] [repo-dir]}"
BRANCH="${2:?usage: worktree-provision.sh <agent> <branch> [base-ref] [repo-dir]}"
BASE="${3:-origin/main}"
REPODIR="${4:-$PWD}"

# 1. Resolve the repo TOPLEVEL — the core of the fix (cwd-independent).
ROOT="$(git -C "$REPODIR" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "worktree-provision: '$REPODIR' is not inside a git repository" >&2; exit 1; }

NAME="${AGENT}-${BRANCH##*/}"                 # e.g. lucid-262-chroma-cache-close
DEST="$ROOT/.claude/worktrees/$NAME"          # ABSOLUTE, repo-root-anchored

# 2. Idempotent: reuse an existing registered worktree at DEST.
if git -C "$ROOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $DEST"; then
  echo "worktree-provision: reusing existing worktree $DEST" >&2
  echo "$DEST"; exit 0
fi
if [ -e "$DEST" ]; then
  echo "worktree-provision: $DEST exists but is not a registered worktree — refusing to clobber (git worktree prune?)" >&2
  exit 1
fi

# 3. Fetch the base tip (best-effort) only when it's a remote-tracking ref.
if [ "${BASE#origin/}" != "$BASE" ]; then
  git -C "$ROOT" fetch -q origin "${BASE#origin/}" >&2 2>/dev/null \
    || git -C "$ROOT" fetch -q origin >&2 2>/dev/null || true
fi
git -C "$ROOT" rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1 || {
  echo "worktree-provision: base ref '$BASE' does not resolve (fetch failed or wrong name)" >&2; exit 1; }

# 4. Create the worktree at the ABSOLUTE path. New branch via -b; reuse if it already exists.
mkdir -p "$ROOT/.claude/worktrees"
if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$ROOT" worktree add "$DEST" "$BRANCH" >&2
else
  git -C "$ROOT" worktree add -b "$BRANCH" "$DEST" "$BASE" >&2
fi

echo "$DEST"
