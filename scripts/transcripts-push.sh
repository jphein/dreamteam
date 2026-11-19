#!/usr/bin/env bash
# dreamteam — copy THIS host's new session transcripts one way to where familiar reads them (sync replacement,
# phase 2). A transcript has one writer (the host whose session it is), so a one-way copy cannot conflict.
#
#   transcripts-push.sh --init <dest>   record the destination and set the cut: only transcripts changed AFTER this
#                                       moment are ever sent (everything older already reached familiar by sync)
#   transcripts-push.sh                 one pass: send every *.jsonl under the source changed since the cut
#
# <dest> is an absolute local directory (the fleet share, e.g. /srv/fleet/transcripts/<host>) or `host:/abs/dir`
# (rsync over ssh). Files keep their path below the source (`<project>/<session>.jsonl`, subagent files included).
# It only ever ADDS or UPDATES files at the destination: no --delete, nothing is removed anywhere.
# Memory files, scratch and anything that is not a .jsonl are not sent.
#
# Line (docs/CHECKS.md):
#   CHECK transcripts-push[-<host>] ok   · N transcripts current at <dest> · every 10 min, owner Sen
#   CHECK …                         fail · <destination unreachable | rsync exit R | not initialised> · owner Sen
# Environment: TRANSCRIPTS_SRC (default ~/.claude/projects). State: ${XDG_STATE_HOME:-~/.local/state}/dreamteam/
#   transcripts-push.dest (one line) and transcripts-push.cut (its mtime is the cut).
# Exit: 0 line published (any status) / init done · 1 line not published · 22 bad arguments · 75 lock held.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"
CHECK="$(check_name transcripts-push)"
OWNER="every 10 min, owner Sen"
SRC="${TRANSCRIPTS_SRC:-$HOME/.claude/projects}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam"
DESTF="$STATE/transcripts-push.dest"; CUT="$STATE/transcripts-push.cut"
umask 077

valid_dest() {   # an absolute local dir, or host:/absolute/dir; plain characters only (it becomes an rsync argument)
  case "$1" in *[!A-Za-z0-9._:/@-]*|"") return 1 ;; esac
  case "$1" in /*) case "$1" in *:*) return 1 ;; esac; return 0 ;; *:/*) case "${1%%:*}" in *[!A-Za-z0-9._@-]*|""|-*) return 1 ;; esac; return 0 ;; esac
  return 1
}

if [ "${1:-}" = --init ]; then
  [ "$#" -eq 2 ] && valid_dest "$2" || { echo "usage: transcripts-push.sh --init </abs/dir | host:/abs/dir>" >&2; exit 22; }
  mkdir -p "$STATE" || exit 1
  [ ! -e "$CUT" ] || { echo "transcripts-push: already initialised (cut $(date -r "$CUT" '+%F %T')); remove $CUT by hand to start over" >&2; exit 22; }
  printf '%s\n' "$2" > "$DESTF" && : > "$CUT" || exit 1
  echo "transcripts-push: destination $2; cut set at $(date -r "$CUT" '+%F %T %Z'): only transcripts changed after it are sent"
  exit 0
fi
[ "$#" -eq 0 ] || { echo "usage: transcripts-push.sh [--init <dest>]" >&2; exit 22; }

[ -f "$CUT" ] && [ ! -L "$CUT" ] && [ -f "$DESTF" ] && [ ! -L "$DESTF" ] || { check_line "$CHECK" fail "not initialised (run --init <dest> once)" "$OWNER"; exit $?; }
IFS= read -r DEST < "$DESTF" || DEST=""
valid_dest "$DEST" || { check_line "$CHECK" fail "the recorded destination is not valid" "$OWNER"; exit $?; }
[ -d "$SRC" ] && [ -r "$SRC" ] || { check_line "$CHECK" fail "source ${SRC/#$HOME/\~} unreadable or absent" "$OWNER"; exit $?; }

LOCK="$STATE/transcripts-push.lock"
if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then check_line "$CHECK" fail "lock file is a symlink or not a regular file" "$OWNER"; exit $?; fi
exec 9>> "$LOCK" || { check_line "$CHECK" fail "cannot open the lock" "$OWNER"; exit $?; }
flock -n 9 || { echo "transcripts-push: another run holds the lock; nothing done" >&2; exit 75; }

list="$(mktemp "$STATE/.transcripts-push.list.XXXXXX")" || { check_line "$CHECK" fail "cannot create a temp file" "$OWNER"; exit $?; }
trap 'rm -f -- "$list"' EXIT
# regular files only, changed since the cut; a walk that could not read a directory is not a complete list
if ! ( cd "$SRC" && find . -type f -name '*.jsonl' -newer "$CUT" -print0 ) > "$list" 2>/dev/null; then
  check_line "$CHECK" fail "the walk of the source was incomplete" "$OWNER"; exit $?
fi
n=$(tr -cd '\0' < "$list" | wc -c) && [[ "$n" =~ ^[0-9]+$ ]] || { check_line "$CHECK" fail "cannot count the list" "$OWNER"; exit $?; }

case "$DEST" in
  /*) # the share: it must answer (an automount that cannot mount gives an error here, not an empty directory),
      # and it must really BE the share: an unmounted mount point is a plain local directory that would swallow the
      # files. $TRANSCRIPTS_MOUNT (default /srv/fleet; empty = no such check) must be a mount point when DEST is under it.
      MNT="${TRANSCRIPTS_MOUNT-/srv/fleet}"
      if [ -n "$MNT" ]; then
        case "$DEST/" in "$MNT"/*)
          ls -- "$MNT" >/dev/null 2>&1
          "${TRANSCRIPTS_MOUNTPOINT_CMD:-mountpoint}" -q -- "$MNT" 2>/dev/null || { check_line "$CHECK" fail "$MNT is not mounted" "$OWNER"; exit $?; } ;;
        esac
      fi
      mkdir -p -- "$DEST" 2>/dev/null && [ -d "$DEST" ] && [ -w "$DEST" ] || { check_line "$CHECK" fail "destination $DEST unreachable or not writable" "$OWNER"; exit $?; } ;;
esac
if [ "$n" -gt 0 ]; then
  rsync -a --no-owner --no-group --from0 --files-from="$list" -e "ssh -o BatchMode=yes -o ConnectTimeout=15" -- "$SRC/" "$DEST/" >/dev/null 2>&1; rc=$?
  # 24 = a listed file vanished before it was read (a session file being rotated): the rest was sent; next pass retries
  if [ "$rc" != 0 ] && [ "$rc" != 24 ]; then check_line "$CHECK" fail "rsync exit $rc to $DEST ($n listed)" "$OWNER"; exit $?; fi
fi
check_line "$CHECK" ok "$n transcripts current at $DEST" "$OWNER"
