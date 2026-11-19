#!/usr/bin/env bash
# dreamteam — keep a git-delivered config directory current without anyone "aligning" it (sync replacement, phase 2).
#
#   config-pull.sh            one pass over $CONFIG_PULL_DIR (default ~/.claude): fetch, move the branch to origin's
#                             head (index only), then bring files that are OLDER COMMITTED VERSIONS up to date.
#
# What it never does: write a file that holds a real local edit (bytes git has never seen), touch an untracked file,
# touch anything under $CONFIG_PULL_SKIP (default `projects/`: transcripts and memory belong to other mechanisms),
# or move a branch that has commits origin lacks. A tar of every file it replaces is written first (clone-in-place's
# freshen). It is the same two steps a person ran by hand: `clone-in-place.sh sync`, then `freshen`.
#
# Line (docs/CHECKS.md):
#   CHECK config-pull[-<host>] ok   · main at <sha>, N files updated · every 10 min, owner Sen
#   CHECK …                    warn · main at <sha>, N files updated, K local edits left alone · every 10 min, owner Sen
#   CHECK …                    fail · <what did not work> · owner Sen            (unknown is never ok)
# Environment: CONFIG_PULL_DIR, CONFIG_PULL_NAME (state-file name, default `claude`), CONFIG_PULL_SKIP.
# Exit: 0 line published (any status) · 1 line could not be published · 75 another run holds the lock.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"
[ "$#" -eq 0 ] || { echo "usage: config-pull.sh   (no arguments; see the header for the environment)" >&2; exit 22; }

DIR="${CONFIG_PULL_DIR:-$HOME/.claude}"
NAME="${CONFIG_PULL_NAME:-claude}"
SKIP="${CONFIG_PULL_SKIP-projects/}"
CHECK="$(check_name config-pull)"
OWNER="every 10 min, owner Sen"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam"
TOOL="$ROOT/scripts/clone-in-place.sh"
case "$NAME" in *[!A-Za-z0-9._-]*|""|.*) check_line "$CHECK" fail "bad CONFIG_PULL_NAME" "$OWNER"; exit $? ;; esac
case "$DIR" in /*) ;; *) check_line "$CHECK" fail "CONFIG_PULL_DIR is not absolute" "$OWNER"; exit $? ;; esac
[ -d "$DIR/.git" ] || { check_line "$CHECK" fail "${DIR/#$HOME/\~} is not a git clone" "$OWNER"; exit $?; }

umask 077
mkdir -p "$STATE" 2>/dev/null && [ -d "$STATE" ] || { check_line "$CHECK" fail "no state dir $STATE" "$OWNER"; exit $?; }
LOCK="$STATE/config-pull.$NAME.lock"
if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then check_line "$CHECK" fail "lock file is a symlink or not a regular file" "$OWNER"; exit $?; fi
exec 9>> "$LOCK" || { check_line "$CHECK" fail "cannot open the lock" "$OWNER"; exit $?; }
flock -n 9 || { echo "config-pull: another run holds the lock; nothing done" >&2; exit 75; }

run() { CLONE_DIR="$DIR" CLONE_SYNC_FOLDER=none CLONE_SKIP_PREFIXES="$SKIP" bash "$TOOL" "$@" 9>&-; }

out=$(run sync "$NAME" 2>&1); rc=$?
if [ "$rc" != 0 ]; then
  why=$(tail -1 <<< "$out"); why=${why#"$NAME: "}
  check_line "$CHECK" fail "sync did not work: ${why:0:120}" "$OWNER"; exit $?
fi
out=$(run freshen "$NAME" 2>&1); rc=$?
if [ "$rc" != 0 ]; then
  why=$(tail -1 <<< "$out"); why=${why#"$NAME: "}
  check_line "$CHECK" fail "update did not work: ${why:0:120}" "$OWNER"; exit $?
fi
updated=0
if [[ "$out" =~ freshened\ ([0-9]+)\ files ]]; then updated="${BASH_REMATCH[1]}"; fi

br=$(git -C "$DIR" symbolic-ref -q --short HEAD) && sha=$(git -C "$DIR" rev-parse --short HEAD) \
  || { check_line "$CHECK" fail "cannot read HEAD after the update" "$OWNER"; exit $?; }
# local edits left alone: tracked, differing, outside the skip prefixes
edits=0
st=$(git -C "$DIR" status --porcelain --no-renames 2>/dev/null) || { check_line "$CHECK" fail "git status did not work" "$OWNER"; exit $?; }
IFS=: read -r -a SK <<< "$SKIP"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  [ "${line:0:2}" = "??" ] && continue
  f="${line:3}"; s=0
  for p in "${SK[@]}"; do [ -n "$p" ] && case "$f" in "$p"*) s=1 ;; esac; done
  [ "$s" = 1 ] || edits=$((edits + 1))
done <<< "$st"

if [ "$edits" -gt 0 ]; then
  check_line "$CHECK" warn "$br at $sha, $updated files updated, $edits local edits left alone" "$OWNER"
else
  check_line "$CHECK" ok "$br at $sha, $updated files updated" "$OWNER"
fi
