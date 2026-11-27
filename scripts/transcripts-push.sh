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
#   CHECK transcripts-push[-<host>] ok   · N transcripts changed since the cut, all at <dest> (K copied this pass) · every 10 min, owner Sen
#   CHECK …                         warn · N transcripts changed since the cut, K copied this pass to <dest>; M over 300 MB not copied (token item): <every name (size)> · …
#   CHECK …                         warn · free space at <dest> unknown (<why>): nothing sent this pass · …
#   CHECK …                         warn · N listed for <dest>, some vanished mid-pass (next pass retries) · …
#   CHECK …                         fail · <not initialised | destination … | rsync exit R | …> · owner Sen
# HARDENED 2026-11-25 (Flow row 1de527eb; ubox0's root filled at 03:40: 43 rsync temp files, 32.5 GiB, under the
# share, because an 844 MB transcript was re-copied whole every pass and each pass, failing once the disk was full,
# left its temp file behind). On every pass, in this order:
#   1. stale rsync temp files at the destination (`.<name>.jsonl.XXXXXX`, regular files, older than 10 minutes)
#      are deleted, and only those; the line counts them; a sweep that did not finish is said (warn);
#   2. the destination's free space is measured (df there): under TRANSCRIPTS_MIN_FREE_GB (15) NOTHING is sent and
#      the line is a warn; a free space that is not KNOWN (df failed, was cut off, or answered no number) is the
#      same: nothing sent, warn, never read as plenty;
#   3. a transcript over TRANSCRIPTS_MAX_MB (300) is not copied: EVERY such file is named in the line with its
#      size as a token item (a session that large is a token-use finding, not a file to ship every ten minutes);
#      rsync's own --max-size holds the same limit for a file that grows past it after the walk, and rsync's
#      report of that file puts it in the same list;
#   4. rsync runs --partial-dir=.rsync-partial (a copy that is stopped keeps what arrived, beside its
#      destination; the next pass continues from it and removes it), --no-whole-file (the delta transfer also
#      to a local destination) and --timeout=120 (a stalled share ends the transfer instead of leaving an rsync
#      behind the unit). While a file is being written rsync's temp file exists beside it; one left behind by
#      a killed pass is what step 1 sweeps. "K copied this pass" counts the files rsync FINISHED, and only
#      when rsync exited 0.
#   Every command run AT the destination (the sweep's find, df) is bounded by TRANSCRIPTS_DEST_TIMEOUT (60 s), and
#   over ssh each argument is quoted for the remote shell.
#   Why --partial-dir and not --append-verify or --inplace: --append-verify sends only the new tail of an
#   append-only file, but a transcript that is rewritten (a compaction) fails its check and is sent whole;
#   --inplace leaves a half-written transcript under its real name when a pass stops, and rsync refuses it
#   beside --partial-dir. A partial is at most one per transcript and at most TRANSCRIPTS_MAX_MB.
# Environment: TRANSCRIPTS_SRC (default ~/.claude/projects), TRANSCRIPTS_MOUNT, TRANSCRIPTS_MAX_MB (300),
#   TRANSCRIPTS_MIN_FREE_GB (15), TRANSCRIPTS_DEST_TIMEOUT (60). Test seams: TRANSCRIPTS_MOUNTPOINT_CMD,
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
# from here on a run that is stopped (timeout, shutdown) publishes fail: also while it waits on the share or on ssh
trap 'check_line "$CHECK" fail "stopped before it finished (timeout or signal)" "$OWNER" >/dev/null; exit 143' TERM INT HUP
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

MAXMB="${TRANSCRIPTS_MAX_MB:-300}"; MINGB="${TRANSCRIPTS_MIN_FREE_GB:-15}"
[[ "$MAXMB" =~ ^[0-9]{1,6}$ ]] && [ "$MAXMB" -ge 1 ] || { check_line "$CHECK" fail "TRANSCRIPTS_MAX_MB must be a whole number of MB, 1-999999 (got '$MAXMB')" "$OWNER"; exit $?; }
[[ "$MINGB" =~ ^[0-9]{1,6}$ ]] || { check_line "$CHECK" fail "TRANSCRIPTS_MIN_FREE_GB must be a whole number of GB (got '$MINGB')" "$OWNER"; exit $?; }
DTO="${TRANSCRIPTS_DEST_TIMEOUT:-60}"
[[ "$DTO" =~ ^[0-9]{1,4}$ ]] && [ "$DTO" -ge 1 ] || { check_line "$CHECK" fail "TRANSCRIPTS_DEST_TIMEOUT must be a whole number of seconds, 1-9999 (got '$DTO')" "$OWNER"; exit $?; }
# Where to run a command against the destination: here, or over ssh on the destination's host. Two rules:
#   - it is BOUNDED (ConnectTimeout covers only the connection, not a df or find that hangs on a dead share);
#   - over ssh every argument is quoted: sshd joins the arguments into ONE string and the remote shell parses it,
#     so an unquoted pattern would be expanded there against the login directory.
at_dest() {
  case "$DEST" in
    /*) timeout -k 5 "$DTO" "$@" ;;
    *)  local q; q=$(printf '%q ' "$@")
        timeout -k 5 "$DTO" "$SSH" -o BatchMode=yes -o ConnectTimeout=15 -- "${DEST%%:*}" "$q" </dev/null ;;
  esac
}
DPATH="$DEST"; case "$DEST" in /*) ;; *) DPATH="${DEST#*:}" ;; esac
# 1. the sweep: before the free-space check, because it is what frees the space. find does not follow symlinks;
#    -type f keeps directories and symlinks of that name; the name pattern is rsync's temp name for a transcript.
#    A sweep that did not finish is said in the line and makes it a warn.
sw_out=$(at_dest find "$DPATH" -type f -name '.*.jsonl.??????' -mmin +10 -delete -print 2>/dev/null); swrc=$?
swept=$(printf '%s' "$sw_out" | grep -c .)
[[ "$swept" =~ ^[0-9]+$ ]] || swept=0
SW=""; [ "$swept" -gt 0 ] && SW="; swept $swept stale rsync temp file(s)"
SWBAD=""; [ "$swrc" -eq 0 ] || SWBAD="; the sweep of stale temp files did not finish (find exit $swrc)"
# 2. the free space at the destination, in KiB, from df -P's fourth column. Known only when df SUCCEEDED and
#    answered a number; anything else (failed, cut off, garbage) is unknown: nothing sent, warn.
df_out=$(at_dest df -Pk "$DPATH" 2>/dev/null); dfrc=$?
free=$(printf '%s\n' "$df_out" | awk 'NR == 2 {print $4}')
if [ "$dfrc" -ne 0 ] || ! [[ "$free" =~ ^[0-9]{1,15}$ ]]; then
  why="unreadable answer"; [ "$dfrc" -eq 0 ] || why="df exit $dfrc"; [ "$dfrc" -ne 124 ] || why="no answer in $DTO s"
  check_line "$CHECK" warn "free space at $DEST unknown ($why): nothing sent this pass$SW$SWBAD" "$OWNER"; exit $?
fi
freegb=$(( free / 1048576 ))
if [ "$free" -lt $(( MINGB * 1048576 )) ]; then
  check_line "$CHECK" warn "$DEST has $freegb GB free, under $MINGB GB: nothing sent this pass$SW$SWBAD" "$OWNER"; exit $?
fi

list="$(mktemp "$STATE/.transcripts-push.list.XXXXXX")" || { check_line "$CHECK" fail "cannot create a temp file" "$OWNER"; exit $?; }
big="$(mktemp "$STATE/.transcripts-push.big.XXXXXX")" || { rm -f -- "$list"; check_line "$CHECK" fail "cannot create a temp file" "$OWNER"; exit $?; }
rout="$(mktemp "$STATE/.transcripts-push.out.XXXXXX")" || { rm -f -- "$list" "$big"; check_line "$CHECK" fail "cannot create a temp file" "$OWNER"; exit $?; }
trap 'rm -f -- "$list" "$big" "$rout"' EXIT
# regular files only, changed since the cut; a walk that could not read a directory is not a complete list.
# 3. over the limit: listed apart (size and path, NUL-ended: a path may hold a space), never handed to rsync
KMAX=$(( MAXMB * 1024 ))
if ! ( cd "$SRC" && find . -type f -name '*.jsonl' -newer "$CUT" ! -size +"${KMAX}"k -print0 ) > "$list" 2>/dev/null \
   || ! ( cd "$SRC" && find . -type f -name '*.jsonl' -newer "$CUT" -size +"${KMAX}"k -printf '%s %P\0' ) > "$big" 2>/dev/null; then
  check_line "$CHECK" fail "the walk of the source was incomplete" "$OWNER"; exit $?
fi
# a name as one safe word: plain when it is plain, shell-quoted (one line, nothing lost) when it is not
enc() { case "$1" in *[!A-Za-z0-9._/-]*) printf '%q' "$1" ;; *) printf '%s' "$1" ;; esac; }
nover=0; NAMES=""
over() { nover=$((nover + 1)); NAMES="$NAMES${NAMES:+, }$(enc "$2") ($(( ($1 + 524288) / 1048576 )) MB)"; }   # over <bytes> <path>
while IFS= read -r -d '' rec; do over "${rec%% *}" "${rec#* }"; done < <(sort -z -rn "$big")
n=$(tr -cd '\0' < "$list" | wc -c) && [[ "$n" =~ ^[0-9]+$ ]] || { check_line "$CHECK" fail "cannot count the list" "$OWNER"; exit $?; }

# 4. the copy.
#    --partial-dir=.rsync-partial: a copy that is stopped leaves what arrived in <dir>/.rsync-partial/<name> beside
#    its destination; the next pass takes it as the basis, sends the rest, and removes it. (--inplace is gone:
#    rsync refuses it beside --partial-dir.) --no-whole-file: the delta transfer also to a local destination.
#    WHAT COUNTS AS COPIED: --out-format holds %b (bytes sent), which makes rsync write a file's line when that
#    file is FINISHED, not when it starts; and the count is called "copied" only when rsync exited 0. On any
#    other exit the line says how many transfers had finished before it.
#    OVER THE LIMIT AFTER THE WALK: rsync's --max-size holds back a file that grew past the limit since the walk
#    above. Such files are found by this script's own second walk (find, NUL-ended names), never read from
#    rsync's text, which escapes the names it prints.
rc=0; sent=0
if [ "$n" -gt 0 ]; then
  rsync -a --no-owner --no-group --partial-dir=.rsync-partial --no-whole-file --max-size="${MAXMB}M" --timeout=120 --out-format='%i %b %n' --from0 --files-from="$list" -e "$SSH -o BatchMode=yes -o ConnectTimeout=15" -- "$SRC/" "$DEST/" > "$rout" 2>/dev/null; rc=$?
  sent=$(grep -cE '^[<>]f[^ ]{9} [0-9]+ ' "$rout")
  declare -A seen=()
  while IFS= read -r -d '' rec; do seen["${rec#* }"]=1; done < "$big"
  if ( cd "$SRC" && find . -type f -name '*.jsonl' -newer "$CUT" -size +"${KMAX}"k -printf '%s %P\0' ) > "$rout" 2>/dev/null; then
    while IFS= read -r -d '' rec; do [ -n "${seen["${rec#* }"]:-}" ] || over "${rec%% *}" "${rec#* }"; done < <(sort -z -rn "$rout")
  else
    SWBAD="$SWBAD; the second walk for transcripts that grew past the limit was incomplete"
  fi
fi
BIG=""; [ "$nover" -eq 0 ] || BIG="; $nover over $MAXMB MB not copied (token item): $NAMES"
case "$rc" in
  0)  if [ "$nover" -gt 0 ] || [ -n "$SWBAD" ]; then check_line "$CHECK" warn "$n transcripts changed since the cut, $sent copied this pass to $DEST$BIG$SW$SWBAD" "$OWNER"
      else check_line "$CHECK" ok "$n transcripts changed since the cut, all at $DEST ($sent copied this pass)$SW" "$OWNER"; fi ;;
  24) check_line "$CHECK" warn "$n listed for $DEST, some vanished mid-pass (next pass retries)$BIG$SW$SWBAD" "$OWNER" ;;   # a session file rotated away while it was read
  *)  check_line "$CHECK" fail "rsync exit $rc to $DEST ($n listed; $sent transfers finished before it)$BIG$SW$SWBAD" "$OWNER" ;;
esac
