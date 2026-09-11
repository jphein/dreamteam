#!/usr/bin/env bash
# dreamteam — cascade.sh [opts] <owner/repo> <pr>[:<lane>] [<pr>[:<lane>] …]
#
# Merge a queue of PRs in dependency order, one at a time, rebasing JUST IN TIME.
#
# THE PROTOCOL, AND WHY IT IS SHAPED LIKE THIS (measured over one wave,
# 2026-09-11, five merges to main):
#
#   Every merge invalidates every other open PR that touches a generated file.
#   In memorypalace, five files are rendered from one manifest and the changelog
#   table is NUMBERED, so a single new entry renumbers every row — the conflict
#   is total, never local. Rebasing all N PRs after each merge is O(N²) rebases
#   and N-1 of them are thrown away. So: rebase the NEXT PR only, and only once
#   the one before it has landed.
#
#   The second reason to rebase late: a fork-changes entry cites its own code
#   commit's sha, which a rebase changes. Rebase early and the entry cites an
#   orphan that still resolves LOCALLY (it lives in the rebaser's reflog) and
#   fails only in CI, where the clone has no orphan. Late rebase + rebuild is
#   the only order that is right in both places.
#
#   And the cascade does NOT wait for CI. It gates ONCE per PR and stops if the
#   answer is "still running". Polling is what exhausted the account quota that
#   same day (see scripts/no-poll-guard.sh). Re-run the cascade later instead —
#   it is idempotent: already-merged PRs are skipped.
#
# LANES. `<pr>:<lane>` names the teammate that owns the PR, so the cascade can
# print the exact message to send. Without a lane it names the head branch and
# the lead picks the owner. With --rebase the cascade does the rebase ITSELF in
# that lane's worktree instead of asking — use it when the lane has gone idle.
#
# OPTIONS
#   --dry-run              gate and report, never merge
#   --delete-branch        delete each head branch after its merge (read
#                          pr-merge.sh's header first — this is what breaks
#                          check-docs on main when an entry cites a branch sha)
#   --rebase               perform the rebase locally instead of pinging a lane
#   --repo-path <dir>      main checkout, for --rebase (default: $PWD)
#   --post-rebase <cmd>    run in the worktree after a successful rebase — the
#                          seam for a repo's docs rebuild (entry sha, renderers,
#                          check-docs). Also DREAMTEAM_POST_REBASE.
#
# EXIT CODES
#   0  every PR in the queue is merged
#   1  stopped: the next PR needs a rebase (a lane must act, or re-run --rebase)
#   2  usage error
#   3  stopped: a PR is not green, or its merge was rejected
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${DREAMTEAM_GH:-gh}"
GATE="${DREAMTEAM_PR_GATE:-$HERE/pr-gate.sh}"
MERGE="${DREAMTEAM_PR_MERGE:-$HERE/pr-merge.sh}"

usage() {
  echo "usage: cascade.sh [--dry-run] [--delete-branch] [--rebase] [--repo-path DIR]" >&2
  echo "                  [--post-rebase CMD] <owner/repo> <pr>[:<lane>] …" >&2
  exit 2
}

DRY=0; DELETE=0; REBASE=0; REPO_PATH="${PWD}"
POST_REBASE="${DREAMTEAM_POST_REBASE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY=1; shift ;;
    --delete-branch) DELETE=1; shift ;;
    --rebase)        REBASE=1; shift ;;
    --repo-path)     REPO_PATH="${2:-}"; shift 2 || usage ;;
    --post-rebase)   POST_REBASE="${2:-}"; shift 2 || usage ;;
    -h|--help)       usage ;;
    --) shift; break ;;
    -*) usage ;;
    *)  break ;;
  esac
done
[ $# -ge 2 ] || usage
repo="$1"; shift
case "$repo" in */*) ;; *) usage ;; esac

hr() { echo "────────────────────────────────────────────────────────────"; }

merged_count=0; total=$#
for spec in "$@"; do
  pr="${spec%%:*}"; lane=""
  case "$spec" in *:*) lane="${spec#*:}" ;; esac
  case "$pr" in ''|*[!0-9]*) echo "bad PR spec: $spec" >&2; exit 2 ;; esac

  hr
  meta=$("$GH" api "repos/$repo/pulls/$pr" \
          --jq '[.state, (.merged|tostring), .head.ref, .base.ref, .head.sha, .title] | @tsv' 2>/dev/null) \
    || { echo "CASCADE STOPPED: cannot read $repo#$pr"; exit 3; }
  IFS=$'\t' read -r state merged branch base headsha title <<< "$meta"

  if [ "$merged" = "true" ]; then
    echo "SKIP $repo#$pr — already merged ($title)"
    merged_count=$((merged_count + 1))
    continue
  fi
  if [ "$state" != "open" ]; then
    echo "CASCADE STOPPED: $repo#$pr is $state, not open"
    exit 3
  fi
  echo "NEXT: $repo#$pr  $title"
  echo "  head $branch @ ${headsha:0:8} → base $base"

  # ── is it behind base? compare/<base>...<head>: behind_by > 0 means a merge
  #    has landed since this branch was cut, so it must rebase before it can be
  #    trusted green (its CI ran against the old base).
  behind=$("$GH" api "repos/$repo/compare/$base...$branch" --jq '.behind_by' 2>/dev/null || echo "")
  if [ -z "$behind" ]; then
    echo "CASCADE STOPPED: cannot compare $base...$branch"
    exit 3
  fi

  if [ "$behind" -gt 0 ]; then
    basesha=$("$GH" api "repos/$repo/commits/$base" --jq '.sha' 2>/dev/null || echo "")
    echo "  BEHIND $base by $behind commit(s) — must rebase before merging."
    if [ "$REBASE" -eq 1 ]; then
      wt=$(git -C "$REPO_PATH" worktree list --porcelain 2>/dev/null \
            | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} /^branch /{if ($2==b) print w}' | head -1)
      [ -n "$wt" ] || { echo "  CASCADE STOPPED: no worktree in $REPO_PATH holds branch $branch"; exit 1; }
      echo "  rebasing in $wt"
      git -C "$wt" fetch origin --quiet || { echo "  CASCADE STOPPED: fetch failed"; exit 1; }
      if ! git -C "$wt" rebase "origin/$base"; then
        git -C "$wt" rebase --abort 2>/dev/null || true
        echo "  CASCADE STOPPED: rebase of $branch onto origin/$base conflicts — hand it to the lane"
        exit 1
      fi
      if [ -n "$POST_REBASE" ]; then
        echo "  post-rebase: $POST_REBASE"
        ( cd "$wt" && eval "$POST_REBASE" ) || { echo "  CASCADE STOPPED: post-rebase command failed"; exit 1; }
      fi
      echo "  rebased. Push it, let CI run, then re-run this cascade:"
      echo "      git -C $wt push --force-with-lease origin $branch"
      exit 1
    fi
    echo ""
    echo "  ACTION — send this to ${lane:-the lane that owns $branch}:"
    echo "      go #$pr ${basesha:0:8}"
    echo "  (rebase onto $base @ ${basesha:0:8}, rebuild the docs commit with the NEW code sha,"
    echo "   push, reply \"pushed\" — then re-run this cascade. Do not wait on CI here.)"
    exit 1
  fi

  echo "  up to date with $base — gating (REST, one shot, no polling)"
  if ! bash "$GATE" "$repo" "$pr"; then
    echo "  CASCADE STOPPED at $repo#$pr — not green (or still running). Re-run later; merged PRs are skipped."
    exit 3
  fi

  if [ "$DRY" -eq 1 ]; then
    echo "  DRY RUN: would merge $repo#$pr"
    merged_count=$((merged_count + 1))
    continue
  fi

  margs=""; [ "$DELETE" -eq 1 ] && margs="--delete-branch"
  # shellcheck disable=SC2086  # margs is a single controlled flag or empty
  if ! bash "$MERGE" $margs "$repo" "$pr"; then
    echo "  CASCADE STOPPED: merge of $repo#$pr failed"
    exit 3
  fi
  merged_count=$((merged_count + 1))
done

hr
newsha=$("$GH" api "repos/$repo/commits/HEAD" --jq '.sha' 2>/dev/null || echo "")
echo "CASCADE COMPLETE: $merged_count/$total merged. default branch head: ${newsha:0:8}"
exit 0
