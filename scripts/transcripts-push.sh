#!/usr/bin/env bash
# dreamteam — copy THIS host's new session transcripts one way to where familiar reads them (sync replacement,
# phase 2). A transcript has one writer (the host whose session it is), so a one-way copy cannot conflict.
#
#   transcripts-push.sh --init <dest>   record the destination and set the cut: only transcripts changed AFTER this
#                                       moment are ever sent (everything older already reached familiar by sync)
#   transcripts-push.sh                 one pass: send every *.jsonl under the source changed since the cut
#
# <dest> is one of:
#   /abs/dir        a directory ON THE FLEET SHARE: it must lie under $TRANSCRIPTS_MOUNT (default /srv/fleet) after
#                   symlinks are resolved, and that mount point must be mounted. Any other local path is refused: an
#                   unmounted mount point is a plain local directory that would quietly swallow the files.
#   host:/abs/dir   rsync over ssh; the directory must exist and be writable there (probed on every pass).
# Files keep their path below the source (`<project>/<session>.jsonl`, subagent files included). It only ever ADDS
# or UPDATES files at the destination: no --delete, nothing is removed anywhere. Memory files, scratch and anything
# that is not a .jsonl are not sent.
#
# What "sent" means: rsync's size-and-time comparison. Transcripts are append-only, so a changed file has a new size;
# a checksum pass would re-read every transcript since the cut on both ends every ten minutes, so it is not used, and
# the line says "sent", not "identical".
#
# Line (docs/CHECKS.md):
#   CHECK transcripts-push[-<host>] ok   · N transcripts changed since the cut, all sent to <dest> · every 10 min, owner Sen
#   CHECK …                         warn · N listed for <dest>, some vanished mid-pass (next pass retries) · …
#   CHECK …                         fail · <not initialised | destination … | rsync exit R | …> · owner Sen
# Environment: TRANSCRIPTS_SRC (default ~/.claude/projects), TRANSCRIPTS_MOUNT. Test seams: TRANSCRIPTS_MOUNTPOINT_CMD,
#   TRANSCRIPTS_SSH. State: ${XDG_STATE_HOME:-~/.local/state}/dreamteam/transcripts-push.{dest,cut,lock}.
# Exit: 0 line published (any status) / init done · 1 line not published · 22 bad arguments · 75 lock held.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"
CHECK="$(check_name transcripts-push)"
OWNER="every 10 min, owner Sen"
SRC="${TRANSCRIPTS_SRC:-$HOME/.claude/projects}"
case "${XDG_STATE_HOME:-/}" in /*) ;; *) echo "XDG_STATE_HOME must be absolute" >&2; exit 22 ;; esac
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam"
DESTF="$STATE/transcripts-push.dest"; CUT="$STATE/transcripts-push.cut"; LOCK="$STATE/transcripts-push.lock"
SSH="${TRANSCRIPTS_SSH:-ssh}"
umask 077
# These two reach rsync, which reads `host:path` as a REMOTE source and re-parses its -e string on spaces: so the
# source is an absolute plain path (never something rsync could read as remote or as an option), and the ssh command
# is the word `ssh` or an absolute plain path (no spaces, nothing a second parser could split).
envcheck() {
  case "$SRC" in /*) ;; *) return 1 ;; esac
  case "$SRC" in *[!A-Za-z0-9._/@+-]*) return 1 ;; esac
  case "$SSH" in ssh) ;; /*) case "$SSH" in *[!A-Za-z0-9._/+-]*) return 1 ;; esac ;; *) return 1 ;; esac
  return 0
}

valid_dest() {   # /abs/dir or host:/abs/dir, plain characters only, no `..`, `.` or empty components
  case "$1" in *[!A-Za-z0-9._:/@-]*|"") return 1 ;; esac
  local path="$1"
  case "$1" in
    /*) case "$1" in *:*) return 1 ;; esac ;;
    *:/*) case "${1%%:*}" in *[!A-Za-z0-9._@-]*|""|-*) return 1 ;; esac; path="${1#*:}"; case "$path" in *:*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "$path/" in *//*|*/../*|*/./*) return 1 ;; esac
  return 0
}
plainfile() { [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }; }   # absent or a regular file; never a symlink (even dangling)
lock() {
  mkdir -p -- "$STATE" 2>/dev/null && [ -d "$STATE" ] || return 1
  plainfile "$LOCK" || return 1
  exec 9>> "$LOCK" || return 1
  flock -n 9 || { echo "transcripts-push: another run holds the lock; nothing done" >&2; exit 75; }
}
publish_new() {   # publish_new <text> <path>: create <path> with <text>, never replacing or following anything there
  local tmp rc
  tmp=$(mktemp "$STATE/.transcripts-push.new.XXXXXX") && printf '%s' "$1" > "$tmp" && ln -T -- "$tmp" "$2" 2>/dev/null
  rc=$?; rm -f -- "${tmp:-}"; return "$rc"
}

if [ "${1:-}" = --init ]; then
  envcheck || { echo "transcripts-push: TRANSCRIPTS_SRC must be an absolute plain path and TRANSCRIPTS_SSH 'ssh' or an absolute plain path" >&2; exit 22; }
  [ "$#" -eq 2 ] && valid_dest "$2" || { echo "usage: transcripts-push.sh --init </abs/dir on the share | host:/abs/dir>" >&2; exit 22; }
  lock || { echo "transcripts-push: cannot take the lock in $STATE" >&2; exit 1; }
  if [ -e "$CUT" ] || [ -L "$CUT" ] || [ -e "$DESTF" ] || [ -L "$DESTF" ]; then
    echo "transcripts-push: already initialised, or a state path is in the way ($CUT, $DESTF); remove them by hand to start over" >&2; exit 22
  fi
  publish_new "$2"$'\n' "$DESTF" || { echo "transcripts-push: could not create $DESTF (something appeared there); nothing changed" >&2; exit 1; }
  # If the cut cannot be created, NOTHING is removed (the dest file may have been replaced by someone else since):
  # a destination without a cut is "not initialised" to every later pass, and the operator clears it by hand.
  publish_new "" "$CUT" || { echo "transcripts-push: could not create $CUT; $DESTF is left in place: remove both paths by hand, then run --init again" >&2; exit 1; }
  echo "transcripts-push: destination $2; cut set at $(date -r "$CUT" '+%F %T %Z'): only transcripts changed after it are sent"
  exit 0
fi
[ "$#" -eq 0 ] || { echo "usage: transcripts-push.sh [--init <dest>]" >&2; exit 22; }

envcheck || { check_line "$CHECK" fail "TRANSCRIPTS_SRC or TRANSCRIPTS_SSH is not an absolute plain path" "$OWNER"; exit $?; }
lock || { check_line "$CHECK" fail "cannot take the lock (state dir or lock file not usable)" "$OWNER"; exit $?; }
[ -f "$CUT" ] && [ ! -L "$CUT" ] && [ -f "$DESTF" ] && [ ! -L "$DESTF" ] || { check_line "$CHECK" fail "not initialised (run --init <dest> once)" "$OWNER"; exit $?; }
IFS= read -r DEST < "$DESTF" || DEST=""
valid_dest "$DEST" || { check_line "$CHECK" fail "the recorded destination is not valid" "$OWNER"; exit $?; }
[ -d "$SRC" ] && [ -r "$SRC" ] || { check_line "$CHECK" fail "source ${SRC/#$HOME/\~} unreadable or absent" "$OWNER"; exit $?; }

# The destination must be proven reachable on EVERY pass, also when there is nothing to send.
case "$DEST" in
  /*)
    MNT="${TRANSCRIPTS_MOUNT-/srv/fleet}"; MNT="${MNT%/}"
    [ -n "$MNT" ] || { check_line "$CHECK" fail "no share mount point configured for a local destination" "$OWNER"; exit $?; }
    ls -- "$MNT" >/dev/null 2>&1                                   # wakes an automount
    "${TRANSCRIPTS_MOUNTPOINT_CMD:-mountpoint}" -q -- "$MNT" 2>/dev/null || { check_line "$CHECK" fail "$MNT is not mounted" "$OWNER"; exit $?; }
    rm=$(realpath -m -- "$MNT" 2>/dev/null) && rd=$(realpath -m -- "$DEST" 2>/dev/null) && [ -n "$rm" ] && [ -n "$rd" ] \
      || { check_line "$CHECK" fail "cannot resolve the destination" "$OWNER"; exit $?; }
    case "$rd/" in "$rm"/?*) ;; *) check_line "$CHECK" fail "destination $DEST is not under the share $MNT" "$OWNER"; exit $? ;; esac
    mkdir -p -- "$DEST" 2>/dev/null && [ -d "$DEST" ] && [ -w "$DEST" ] || { check_line "$CHECK" fail "destination $DEST unreachable or not writable" "$OWNER"; exit $?; }
    ;;
  *)
    rhost="${DEST%%:*}"; rpath="${DEST#*:}"
    "$SSH" -o BatchMode=yes -o ConnectTimeout=15 -- "$rhost" test -d "$rpath" -a -w "$rpath" </dev/null >/dev/null 2>&1 \
      || { check_line "$CHECK" fail "destination $DEST unreachable or not a writable directory" "$OWNER"; exit $?; }
    ;;
esac

trap 'check_line "$CHECK" fail "stopped before it finished (timeout or signal)" "$OWNER" >/dev/null; exit 143' TERM INT HUP
list="$(mktemp "$STATE/.transcripts-push.list.XXXXXX")" || { check_line "$CHECK" fail "cannot create a temp file" "$OWNER"; exit $?; }
trap 'rm -f -- "$list"' EXIT
# regular files only, changed since the cut; a walk that could not read a directory is not a complete list
if ! ( cd "$SRC" && find . -type f -name '*.jsonl' -newer "$CUT" -print0 ) > "$list" 2>/dev/null; then
  check_line "$CHECK" fail "the walk of the source was incomplete" "$OWNER"; exit $?
fi
n=$(tr -cd '\0' < "$list" | wc -c) && [[ "$n" =~ ^[0-9]+$ ]] || { check_line "$CHECK" fail "cannot count the list" "$OWNER"; exit $?; }

rc=0
if [ "$n" -gt 0 ]; then
  rsync -a --no-owner --no-group --from0 --files-from="$list" -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" -- "$SRC/" "$DEST/" >/dev/null 2>&1; rc=$?
fi
case "$rc" in
  0)  check_line "$CHECK" ok "$n transcripts changed since the cut, all sent to $DEST" "$OWNER" ;;
  24) check_line "$CHECK" warn "$n listed for $DEST, some vanished mid-pass (next pass retries)" "$OWNER" ;;   # a session file rotated away while it was read
  *)  check_line "$CHECK" fail "rsync exit $rc to $DEST ($n listed)" "$OWNER" ;;
esac
