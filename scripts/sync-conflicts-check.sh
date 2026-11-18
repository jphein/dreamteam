#!/usr/bin/env bash
# dreamteam — CHECK sync-conflicts: count Syncthing conflict copies in the synced trees (docs/CHECKS.md).
#
#   sync-conflicts-check.sh            walk the roots, publish the line, mail the lead when the count rose
#   sync-conflicts-check.sh --list     also print every path found (stdout), after the line
#
# A conflict copy (`<name>.sync-conflict-<date>-<time>-<device>.<ext>`) means two hosts wrote one file and one
# side's bytes were set aside. Nobody is told, so they pile up (2026-11-17: 124 on familiar; one earlier copy held
# a rotated key). This check makes the count visible and tells the lead when it rises, never every day.
#
# Line:   CHECK sync-conflicts[-<host>] ok   · 0 conflict copies in N roots · daily, owner Sen
#         CHECK …                       warn · K conflict copies (A in ~/Projects, B in ~/.claude), newest <age> · list: <file>
#         CHECK …                       fail · <root> unreadable | walk failed … · owner Sen     (unknown is never ok)
#
# Roots:  $DREAMTEAM_SYNC_ROOTS (colon-separated), else ~/Projects:~/.claude. A root that does not exist on this host
#         is a fail, not a zero: an instrument that cannot see has not measured anything.
# Walk:   one `find` per root under ionice -c3 nice -n 15 when available (familiar's HDD: heavy walks run idle, one at a
#         time); `.git`, `node_modules` and `.stversions` are pruned (version-store copies of conflicts are history).
#         Only regular files count (a directory whose name matches is not a conflict copy).
# Skips:  directories named in $DREAMTEAM_SYNC_SKIP_DIRS (colon-separated names or globs, no slash; default
#         `.sync-conflicts-merged:sync-conflicts-archive-*:dreamteam-state-conflicts`) hold copies kept on purpose
#         and are not walked. Directories only: a FILE with such a name still counts. Each skipped directory is
#         listed in sync-conflicts.skipped and the line says "K kept dirs skipped". Empty string = skip nothing.
# Mail:   $DREAMTEAM_MAIL_CMD (default `agent-mail send`) to $DREAMTEAM_LEAD_MAIL (default `sen`), only when the count
#         RISES above the remembered baseline, and at most once an hour; a rise inside the hour is held and
#         stays owed even if the count falls back; a fall lowers the baseline and sends nothing. A mail that cannot be sent never changes the line and is tried again at the next run.
# State:  ${XDG_STATE_HOME:-~/.local/state}/dreamteam/sync-conflicts.{list,mailed} (0600).
# Lock:   flock on $STATE/sync-conflicts.lock for the whole run (walk, list, line, mail).
# Exit:   0 line published (any status) · 1 line could not be published · 22 bad argument · 75 another run holds
#         the lock (nothing published).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"

LIST=0
case "${1:-}" in
  "") ;;
  --list) LIST=1 ;;
  *) echo "usage: sync-conflicts-check.sh [--list]" >&2; exit 22 ;;
esac
[ "$#" -le 1 ] || { echo "usage: sync-conflicts-check.sh [--list]" >&2; exit 22; }

umask 077
NAME="$(check_name sync-conflicts)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam"
OWNER="daily, owner Sen"
roots_raw="${DREAMTEAM_SYNC_ROOTS:-$HOME/Projects:$HOME/.claude}"
# `read` stops at the first newline, which would silently drop every root after it: refuse, never scan a prefix.
case "$roots_raw" in *$'\n'*|*$'\r'*) check_line "$NAME" fail "DREAMTEAM_SYNC_ROOTS holds a newline" "$OWNER"; exit $? ;; esac
IFS=: read -r -a ROOTS <<< "$roots_raw"

mkdir -p "$STATE" 2>/dev/null && [ -d "$STATE" ] || { check_line "$NAME" fail "no state dir $STATE" "$OWNER"; exit $?; }

# One run at a time per state dir: two overlapping runs could both mail, or an older walk could replace a newer
# list. The timer never overlaps itself; a hand run beside it waits its turn out (exit 75, nothing published).
# The lock file is opened for APPEND (never truncated) and must be a plain file we own: `>` through a planted
# symlink would empty its target before the lock was even tried.
LOCK="$STATE/sync-conflicts.lock"
if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && { [ ! -f "$LOCK" ] || [ ! -O "$LOCK" ]; }; }; then
  check_line "$NAME" fail "lock file is a symlink or not ours" "$OWNER"; exit $?
fi
exec 9>> "$LOCK" || { check_line "$NAME" fail "cannot open the lock in $STATE" "$OWNER"; exit $?; }
if ! flock -n 9; then
  echo "sync-conflicts-check: another run holds the lock; nothing published" >&2; exit 75
fi

# Directories whose conflict copies are KEPT on purpose are skipped by NAME, at any depth. The default names say
# what they are; a generic name such as `backups` is deliberately NOT a default (it would hide real conflicts in
# any backup dir). Every skipped directory is written to sync-conflicts.skipped and counted in the line, so a skip
# is never silent.
skip_raw="${DREAMTEAM_SYNC_SKIP_DIRS-.sync-conflicts-merged:sync-conflicts-archive-*:dreamteam-state-conflicts}"
IFS=: read -r -a SKIPS <<< "$skip_raw"
skipexpr=()
for sname in "${SKIPS[@]}"; do
  [ -n "$sname" ] || continue
  case "$sname" in */*) check_line "$NAME" fail "a skip name holds a slash" "$OWNER"; exit $? ;; esac
  skipexpr+=(${skipexpr[@]:+-o} -name "$sname")
done

idle=()
command -v ionice >/dev/null 2>&1 && idle+=(ionice -c3)
command -v nice >/dev/null 2>&1 && idle+=(nice -n 15)

tmp="$(mktemp "$STATE/.sync-conflicts.list.XXXXXX" 2>/dev/null)" || { check_line "$NAME" fail "cannot create a temp file in $STATE" "$OWNER"; exit $?; }
trap 'rm -f -- "$tmp"' EXIT

total=0; parts=""; n_roots=0
skipf="$STATE/sync-conflicts.skipped"; rm -f -- "$skipf" "$skipf".[0-9]* 2>/dev/null
for r in "${ROOTS[@]}"; do
  [ -n "$r" ] || continue
  n_roots=$((n_roots + 1))
  # absolute paths only: a relative root named like a find operator (`!`, `-delete`) would be read as an expression
  case "$r" in /*) ;; *) check_line "$NAME" fail "root '${r//[^[:print:]]/?}' is not an absolute path" "$OWNER"; exit $? ;; esac
  if [ ! -d "$r" ] || [ ! -r "$r" ]; then
    check_line "$NAME" fail "root ${r/#$HOME/\~} unreadable or absent" "$OWNER"; exit $?
  fi
  before=$(wc -l < "$tmp") && [[ "$before" =~ ^[0-9]+$ ]] || { check_line "$NAME" fail "cannot count the list" "$OWNER"; exit $?; }
  # -print0 is not used: one path per line is the list file's format, and a newline in a conflict name would only
  # inflate the count (a louder warn), never hide a file.
  # -H: a root that is a symlink is followed (plain find would not descend, and report a clean zero)
  kept=()   # kept dirs are pruned AND recorded (-fprint appends nothing to the list of copies)
  [ "${#skipexpr[@]}" -gt 0 ] && kept=(-type d \( "${skipexpr[@]}" \) -prune -fprint "$skipf.$n_roots" -o)
  if ! "${idle[@]}" find -H "$r" -type d \( -name .git -o -name node_modules -o -name .stversions \) -prune -o \
         "${kept[@]}" -type f -name '*.sync-conflict-*' -print >> "$tmp" 2>/dev/null; then
    # find exits non-zero on any unreadable subdirectory; a partial walk is not a measurement of zero
    partial=1
  fi
  now=$(wc -l < "$tmp") && [[ "$now" =~ ^[0-9]+$ ]] || { check_line "$NAME" fail "cannot count the list" "$OWNER"; exit $?; }
  k=$(( now - before ))
  total=$((total + k))
  parts="${parts:+$parts, }$k in ${r/#$HOME/\~}"
done
[ "$n_roots" -gt 0 ] || { check_line "$NAME" fail "no roots given" "$OWNER"; exit $?; }

n_skipped=0
if compgen -G "$skipf.[0-9]*" >/dev/null; then
  cat -- "$skipf".[0-9]* > "$skipf" 2>/dev/null && rm -f -- "$skipf".[0-9]*
  n_skipped=$(wc -l < "$skipf") && [[ "$n_skipped" =~ ^[0-9]+$ ]] || { check_line "$NAME" fail "cannot count the skipped dirs" "$OWNER"; exit $?; }
fi
skipnote=""; [ "$n_skipped" -gt 0 ] && skipnote=", $n_skipped kept dirs skipped"
listf="$STATE/sync-conflicts.list"
mv -T -f -- "$tmp" "$listf" 2>/dev/null || { check_line "$NAME" fail "cannot write $listf" "$OWNER"; exit $?; }
trap - EXIT

if [ "${partial:-0}" = 1 ]; then
  status=fail; fact="walk incomplete (an unreadable directory), $total conflict copies seen ($parts)"; next="$OWNER"
elif [ "$total" -eq 0 ]; then
  status=ok; fact="0 conflict copies in $n_roots roots$skipnote"; next="$OWNER"
else
  newest=$(xargs -d '\n' -r stat -c %Y -- < "$listf" 2>/dev/null | sort -n | tail -1)
  age="age unknown"
  if [[ "${newest:-}" =~ ^[0-9]+$ ]]; then
    d=$(( ( $(date +%s) - newest ) / 86400 )); age="newest ${d} d old"
  fi
  status=warn; fact="$total conflict copies ($parts), $age$skipnote"; next="list: ${listf/#$HOME/\~}"
fi

check_line "$NAME" "$status" "$fact" "$next"; rc=$?
[ "$LIST" = 1 ] && cat -- "$listf"

# Tell the lead only when the count RISES, and at most once an hour (Sen 2026-11-17 22:11). A fall is a line,
# not a mail. The memory is "<baseline> <epoch of the last mail> <pending peak>":
#   - a rise above the baseline is owed a mail; inside the hour it is HELD as the pending peak, and it stays owed
#     even if the count falls back before the hour is up (a copy that came and went was still made);
#   - a fall lowers the baseline without mailing and without restarting the hour;
#   - a mail that cannot be sent leaves the debt in place for the next run.
# A partial walk (fail) changes nothing here: its count is not a measurement.
mailed="$STATE/sync-conflicts.mailed"
base=0; last_mail=0; pend=0
if [ -f "$mailed" ] && [ ! -L "$mailed" ] && read -r b e q _ 2>/dev/null < "$mailed"; then
  [[ "${b:-}" =~ ^[0-9]+$ ]] && base=$b
  [[ "${e:-}" =~ ^[0-9]+$ ]] && last_mail=$e
  [[ "${q:-}" =~ ^[0-9]+$ ]] && pend=$q
fi
now="${DREAMTEAM_NOW:-$(date +%s)}"; [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
remember() {   # remember <baseline> <epoch> <pending peak>: one atomic write
  local mt
  mt=$(mktemp "$STATE/.sync-conflicts.mailed.XXXXXX" 2>/dev/null) && printf '%s %s %s\n' "$1" "$2" "$3" > "$mt" \
    && mv -T -f -- "$mt" "$mailed" || { rm -f -- "${mt:-}"; echo "sync-conflicts-check: mail memory not recorded" >&2; }
}
if [ "$status" = ok ] || [ "$status" = warn ]; then
  o_base=$base; o_pend=$pend
  if [ "$total" -gt "$base" ] && [ "$total" -gt "$pend" ]; then pend=$total; fi   # a new or higher rise is owed
  sent=0
  if [ "$pend" -gt 0 ]; then
    if [ $(( now - last_mail )) -ge 3600 ]; then
      read -r -a mailcmd <<< "${DREAMTEAM_MAIL_CMD:-agent-mail send}"
      host="${DREAMTEAM_CHECK_HOST:-$(hostname 2>/dev/null)}"
      if "${mailcmd[@]}" "${DREAMTEAM_LEAD_MAIL:-sen}" "CHECK $NAME $status: $fact (was $base, peak $pend) on ${host:-?}; list ${listf/#$HOME/\~}" >/dev/null 2>&1; then
        sent=1; base=$total; last_mail=$now; pend=0
      else
        echo "sync-conflicts-check: mail to the lead not sent (will retry next run)" >&2
      fi
    else
      echo "sync-conflicts-check: count rose to $pend; mail held (one an hour at most), sent at a later run" >&2
    fi
  fi
  [ "$sent" = 0 ] && [ "$total" -lt "$base" ] && base=$total                      # a fall lowers the baseline
  if [ "$sent" = 1 ] || [ "$base" != "$o_base" ] || [ "$pend" != "$o_pend" ]; then
    remember "$base" "$last_mail" "$pend"
  fi
fi
exit "$rc"
