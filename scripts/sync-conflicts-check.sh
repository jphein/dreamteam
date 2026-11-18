#!/usr/bin/env bash
# dreamteam — CHECK sync-conflicts: count Syncthing conflict copies in the synced trees (docs/CHECKS.md).
#
#   sync-conflicts-check.sh            walk the roots, publish the line, mail the lead when the count changed
#   sync-conflicts-check.sh --list     also print every path found (stdout), after the line
#
# A conflict copy (`<name>.sync-conflict-<date>-<time>-<device>.<ext>`) means two hosts wrote one file and one
# side's bytes were set aside. Nobody is told, so they pile up (2026-11-17: 124 on familiar; one earlier copy held
# a rotated key). This check makes the count visible and tells the lead once per change, never every day.
#
# Line:   CHECK sync-conflicts[-<host>] ok   · 0 conflict copies in N roots · daily, owner Sen
#         CHECK …                       warn · K conflict copies (A in ~/Projects, B in ~/.claude), newest <age> · list: <file>
#         CHECK …                       fail · <root> unreadable | walk failed … · owner Sen     (unknown is never ok)
#
# Roots:  $DREAMTEAM_SYNC_ROOTS (colon-separated), else ~/Projects:~/.claude. A root that does not exist on this host
#         is a fail, not a zero: an instrument that cannot see has not measured anything.
# Walk:   one `find` per root under ionice -c3 nice -n 15 when available (familiar's HDD: heavy walks run idle, one at a
#         time); `.git`, `node_modules` and `.stversions` are pruned (version-store copies of conflicts are history).
# Mail:   $DREAMTEAM_MAIL_CMD (default `agent-mail send`) to $DREAMTEAM_LEAD_MAIL (default `sen`), only when the count
#         is non-zero AND differs from the count last mailed. A mail that cannot be sent never changes the line.
# State:  ${XDG_STATE_HOME:-~/.local/state}/dreamteam/sync-conflicts.{list,mailed} (0600).
# Exit:   0 line published (any status) · 1 line could not be published · 22 bad argument.
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
IFS=: read -r -a ROOTS <<< "$roots_raw"

mkdir -p "$STATE" 2>/dev/null && [ -d "$STATE" ] || { check_line "$NAME" fail "no state dir $STATE" "$OWNER"; exit $?; }

idle=()
command -v ionice >/dev/null 2>&1 && idle+=(ionice -c3)
command -v nice >/dev/null 2>&1 && idle+=(nice -n 15)

tmp="$(mktemp "$STATE/.sync-conflicts.list.XXXXXX" 2>/dev/null)" || { check_line "$NAME" fail "cannot create a temp file in $STATE" "$OWNER"; exit $?; }
trap 'rm -f -- "$tmp"' EXIT

total=0; parts=""; n_roots=0
for r in "${ROOTS[@]}"; do
  [ -n "$r" ] || continue
  n_roots=$((n_roots + 1))
  if [ ! -d "$r" ] || [ ! -r "$r" ]; then
    check_line "$NAME" fail "root ${r/#$HOME/\~} unreadable or absent" "$OWNER"; exit $?
  fi
  before=$(wc -l < "$tmp")
  # -print0 is not used: one path per line is the list file's format, and a newline in a conflict name would only
  # inflate the count (a louder warn), never hide a file.
  if ! "${idle[@]}" find "$r" \( -name .git -o -name node_modules -o -name .stversions \) -prune -o \
         -name '*.sync-conflict-*' -print >> "$tmp" 2>/dev/null; then
    # find exits non-zero on any unreadable subdirectory; a partial walk is not a measurement of zero
    partial=1
  fi
  k=$(( $(wc -l < "$tmp") - before ))
  total=$((total + k))
  parts="${parts:+$parts, }$k in ${r/#$HOME/\~}"
done
[ "$n_roots" -gt 0 ] || { check_line "$NAME" fail "no roots given" "$OWNER"; exit $?; }

listf="$STATE/sync-conflicts.list"
mv -T -f -- "$tmp" "$listf" 2>/dev/null || { check_line "$NAME" fail "cannot write $listf" "$OWNER"; exit $?; }
trap - EXIT

if [ "${partial:-0}" = 1 ]; then
  status=fail; fact="walk incomplete (an unreadable directory), $total conflict copies seen ($parts)"; next="$OWNER"
elif [ "$total" -eq 0 ]; then
  status=ok; fact="0 conflict copies in $n_roots roots"; next="$OWNER"
else
  newest=$(xargs -d '\n' -r stat -c %Y -- < "$listf" 2>/dev/null | sort -n | tail -1)
  age="age unknown"
  if [[ "${newest:-}" =~ ^[0-9]+$ ]]; then
    d=$(( ( $(date +%s) - newest ) / 86400 )); age="newest ${d} d old"
  fi
  status=warn; fact="$total conflict copies ($parts), $age"; next="list: ${listf/#$HOME/\~}"
fi

check_line "$NAME" "$status" "$fact" "$next"; rc=$?
[ "$LIST" = 1 ] && cat -- "$listf"

# Tell the lead once per change. A count of zero clears the memory, so the next non-zero count mails again.
mailed="$STATE/sync-conflicts.mailed"
last=$(cat -- "$mailed" 2>/dev/null || true)
if [ "$status" = warn ] && [ "$last" != "$total" ]; then
  read -r -a mailcmd <<< "${DREAMTEAM_MAIL_CMD:-agent-mail send}"
  host="${DREAMTEAM_CHECK_HOST:-$(hostname 2>/dev/null)}"
  if "${mailcmd[@]}" "${DREAMTEAM_LEAD_MAIL:-sen}" "CHECK $NAME warn: $fact on ${host:-?}; list ${listf/#$HOME/\~}" >/dev/null 2>&1; then
    printf '%s\n' "$total" > "$mailed"
  else
    echo "sync-conflicts-check: mail to the lead not sent (will retry next run)" >&2
  fi
elif [ "$status" = ok ]; then
  rm -f -- "$mailed"
fi
exit "$rc"
