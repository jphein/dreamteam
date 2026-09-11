#!/usr/bin/env bash
# dreamteam — pr-merge.sh [--dry-run] [--delete-branch] <owner/repo> <pr>
#
# Squash-merge a PR via REST, but only after pr-gate.sh says it is green.
# REST, not GraphQL, for the reason in pr-gate.sh's header.
#
# Prints the NEW head sha of the base branch on success — the cascade needs it,
# and so does the next lane's rebase instruction ("go #N <sha>").
#
# ⚠️ WHY --delete-branch IS OPT-IN (measured, 2026-09-11)
#   A squash merge creates a NEW commit on main; the PR's branch sha is never
#   an ancestor of main afterwards. memorypalace's docs/fork-changes.yaml cites
#   that branch sha, and check-docs asserts every cited sha resolves. It does
#   resolve — but only while the branch ref still exists. Deleting the merged
#   branch is what finally breaks `check-docs` on main, at a moment with no
#   visible connection to the change that caused it. Two entries were already in
#   that state when this was found. So deletion is a deliberate act here, not a
#   default, and the cascade will remind you.
#
# EXIT CODES
#   0  merged (or, with --dry-run, would merge)
#   1  not merged — the gate said no
#   2  usage error
#   3  cannot read the PR / merge call rejected by the API
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${DREAMTEAM_GH:-gh}"
GATE="${DREAMTEAM_PR_GATE:-$HERE/pr-gate.sh}"

usage() { echo "usage: pr-merge.sh [--dry-run] [--delete-branch] <owner/repo> <pr>" >&2; exit 2; }
DRY=0; DELETE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY=1; shift ;;
    --delete-branch) DELETE=1; shift ;;
    -h|--help)       usage ;;
    --) shift; break ;;
    -*) usage ;;
    *)  break ;;
  esac
done
[ $# -eq 2 ] || usage
repo="$1"; pr="$2"
case "$repo" in */*) ;; *) usage ;; esac
case "$pr" in ''|*[!0-9]*) usage ;; esac

# The gate's verdict is its EXIT CODE. Do not pipe it; do not read its stdout.
if ! bash "$GATE" "$repo" "$pr"; then
  echo "NOT MERGED: gate refused $repo#$pr" >&2
  exit 1
fi

meta=$("$GH" api "repos/$repo/pulls/$pr" --jq '[.title, .number, .head.ref, .base.ref] | @tsv' 2>/dev/null) \
  || { echo "NOT MERGED: cannot read repos/$repo/pulls/$pr" >&2; exit 3; }
IFS=$'\t' read -r title number branch base <<< "$meta"

if [ "$DRY" -eq 1 ]; then
  echo "DRY RUN: would squash-merge $repo#$pr \"$title\" into $base (head branch: $branch)"
  [ "$DELETE" -eq 1 ] && echo "DRY RUN: would then delete branch $branch"
  exit 0
fi

"$GH" api -X PUT "repos/$repo/pulls/$pr/merge" \
  -f merge_method=squash -f "commit_title=$title (#$number)" --jq '.sha' >/dev/null 2>&1 \
  || { echo "NOT MERGED: the merge API rejected $repo#$pr (conflict, protection, or already merged)" >&2; exit 3; }

newsha=$("$GH" api "repos/$repo/commits/$base" --jq '.sha' 2>/dev/null || echo "")
echo "MERGED $repo#$pr into $base — new $base head: ${newsha:0:8}"

if [ "$DELETE" -eq 1 ]; then
  if "$GH" api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1; then
    echo "deleted branch $branch"
  else
    echo "could not delete branch $branch (already gone, or protected)"
  fi
else
  echo "kept branch $branch — pass --delete-branch to remove it."
  echo "  (A changelog entry citing the pre-merge sha resolves ONLY while this ref lives; see header.)"
fi
exit 0
