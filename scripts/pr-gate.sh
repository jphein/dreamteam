#!/usr/bin/env bash
# dreamteam — pr-gate.sh <owner/repo> <pr>
#
# "Is this PR actually green?" — the one question a merge must not get wrong.
# REST ONLY (`gh api repos/…`): GraphQL is secondary-rate-limited and took the
# whole fleet down on 2026-09-11, and `gh api rate_limit` cannot even see that
# limit — it read 5000 remaining while every `gh pr …` call failed.
#
# THE RULE THIS ENCODES: a BLANK conclusion is a RUNNING check, not a passing
# one. GitHub reports an in-flight check as {status:"in_progress", conclusion:
# null}; anything that treats "not failed" as "passed" merges mid-run. Only
# success / skipped / neutral count as green.
#
# ⚠️ THE VERDICT IS THE EXIT CODE, AND A PIPE THROWS IT AWAY.
#     pr-gate.sh o/r 12 | tail -5     # ← exit status is tail's 0. ALWAYS "green".
#   That is not hypothetical; it is why this script prints its verdict to stderr
#   as well as stdout, so a piped invocation still shows the truth on screen.
#   If you must pipe, `set -o pipefail` first, or test $? before the pipe.
#
# EXIT CODES
#   0  GATE OK — every counted check run concluded success/skipped/neutral
#   1  NOT GREEN — at least one check failed, or is still running
#   2  usage error
#   3  cannot read the PR or its check runs (auth, network, rate limit, no such PR)
#   4  no check runs at all on the head sha (expected for a repo with no CI —
#      e.g. palace-daemon has no .github/; gate on the local suite + review instead)
#
# IGNORED CHECKS: external review apps that may never reach a conclusion are not
# counted, but they ARE listed — a silent ignore is how a required check hides
# behind a glob. Override with DREAMTEAM_GATE_IGNORE (a `|`-separated glob list).
#
# ⚠️ The ignore list is matched pattern-by-pattern, NOT as one `case` alternation.
#   `case "$name" in $IGNORE)` looks right and matches NOTHING: bash parses the
#   `|` alternation in a case pattern BEFORE expanding variables, so an expanded
#   variable is a single pattern containing literal '|' characters. Caught by
#   tests/test-pr-tools.sh, which is the only reason this file is correct.
set -uo pipefail

usage() { echo "usage: pr-gate.sh <owner/repo> <pr>   (exit: 0 green, 1 not green, 2 usage, 3 unreadable, 4 no checks)" >&2; exit 2; }
[ $# -eq 2 ] || usage
repo="$1"; pr="$2"
case "$repo" in */*) ;; *) usage ;; esac
case "$pr" in ''|*[!0-9]*) usage ;; esac

IGNORE="${DREAMTEAM_GATE_IGNORE:-DeepSource*|CodeRabbit*|Copilot*|*copilot*}"
GH="${DREAMTEAM_GH:-gh}"

say() { echo "$*"; echo "$*" >&2; }   # verdict survives a pipe (see warning above)

meta=$("$GH" api "repos/$repo/pulls/$pr" --jq '[.head.sha, (.draft|tostring), .state] | @tsv' 2>/dev/null) \
  || { say "GATE UNREADABLE: cannot read repos/$repo/pulls/$pr"; exit 3; }
IFS=$'\t' read -r sha draft state <<< "$meta"
[ -n "$sha" ] || { say "GATE UNREADABLE: no head sha for $repo#$pr"; exit 3; }

if [ "$draft" = "true" ]; then say "NOT GREEN: $repo#$pr is a DRAFT"; exit 1; fi
if [ "$state" != "open" ]; then say "NOT GREEN: $repo#$pr is $state, not open"; exit 1; fi

# --paginate: a busy matrix can exceed one page, and a missing page reads as
# "fewer checks", which is the silent direction of failure.
# @tsv, not "a|b|c": a check-run name may legitimately contain the delimiter,
# and jq escapes a literal tab, so TSV is the only separator that cannot be
# forged by the data. (Same idiom as worktree-guard.sh.)
json=$("$GH" api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" \
        --jq '.check_runs[] | [.name, (.conclusion // ""), .status] | @tsv' 2>/dev/null) \
  || { say "GATE UNREADABLE: cannot read check runs for ${sha:0:8}"; exit 3; }

# NOTE: herestring, NOT a pipe — a piped `while` runs in a subshell and its
# counters die with it, so every PR would gate as green.
IFS='|' read -r -a IGNORE_PATS <<< "$IGNORE"
is_ignored() {
  local n="$1" p
  for p in "${IGNORE_PATS[@]}"; do
    [ -n "$p" ] || continue
    # one pattern per iteration: a lone expanded glob DOES match correctly;
    # only the '|' alternation is what bash refuses to build from a variable.
    # shellcheck disable=SC2254
    case "$n" in $p) return 0 ;; esac
  done
  return 1
}

bad=0; counted=0; ignored=0; ignored_names=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Split by hand, NOT `IFS=$'\t' read -r name concl status`. Tab is IFS
  # *whitespace*, so read COLLAPSES runs of it — and the field that is empty
  # here is `conclusion`, which is empty for exactly the in-flight check this
  # gate exists to catch. The collapse shifts `status` into `concl` and the
  # verdict line then reports "conclusion='in_progress'", which is nonsense.
  # (It still refused to merge — but a gate that is right by luck is one edit
  # away from being wrong. Caught by tests/test-pr-tools.sh.)
  name="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  concl="${rest%%$'\t'*}"; status="${rest#*$'\t'}"
  [ -z "$name" ] && continue
  if is_ignored "$name"; then
    ignored=$((ignored + 1)); ignored_names="$ignored_names $name"; continue
  fi
  counted=$((counted + 1))
  case "$concl" in
    success|skipped|neutral) ;;
    "") bad=$((bad + 1)); echo "NOT GREEN: $name is still RUNNING (status='$status', no conclusion yet)" ;;
    *)  bad=$((bad + 1)); echo "NOT GREEN: $name conclusion='$concl' status='$status'" ;;
  esac
done <<< "$json"

[ "$ignored" -gt 0 ] && echo "ignored $ignored external check(s):$ignored_names"

if [ "$counted" -eq 0 ]; then
  say "NO CHECKS on ${sha:0:8} — this repo may have no CI; gate on the local suite + review"
  exit 4
fi
if [ "$bad" -eq 0 ]; then
  say "GATE OK: $counted check runs concluded green on ${sha:0:8}"
  exit 0
fi
say "GATE FAILED: $bad of $counted check runs not green on ${sha:0:8}"
exit 1
