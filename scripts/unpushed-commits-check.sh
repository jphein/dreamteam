#!/usr/bin/env bash
# dreamteam — CHECK unpushed-commits: repositories whose history exists on this disk only (docs/CHECKS.md).
#
#   unpushed-commits-check.sh            look at the roots, publish the line, tell each NEW finding's owner once
#   unpushed-commits-check.sh --list     also print the findings (stdout), after the line
#
# Two findings (measured by scripts/lib/unpushed_commits.py, which says exactly what they mean and do not mean):
#   ahead      commits on HEAD that no remote-tracking branch holds, the oldest at least a day old
#   no-remote  a repository with commits and no remote at all
# 2026-11-18: one repo had 14 unpushed commits for 16 days and another had no remote. A file syncer copies the
# working tree, never `.git`, so such history has ONE copy. This check makes that visible every day.
#
# Line:  CHECK unpushed-commits[-<host>] ok   · 0 of N repos ahead for a day or more, 0 without a remote · daily, owner Sen
#        CHECK …                         warn · A of N repos ahead for a day or more (oldest: <name>, <days> d), B without a remote[, E unreadable] · list: <file>
#        CHECK …                         fail · <root> is not a readable directory | the measurement did not finish · owner Sen
#        An unreadable repository is counted and makes the line warn: it was not measured, so it is never part of an ok.
#
# Roots: $DREAMTEAM_UNPUSHED_ROOTS (colon-separated, absolute), else ~/Projects:~/srv. Top-level directories only.
#        A root that does not exist on this host is a fail, not a zero.
# Age:   $DREAMTEAM_UNPUSHED_MIN_AGE seconds (default 86400). Each git call is bounded by
#        $DREAMTEAM_UNPUSHED_GIT_TIMEOUT seconds (default 120); a call that does not finish makes that repo unreadable.
# Tell:  each finding's owner hears of it ONCE, when it first appears: one message per owner per run, naming up to
#        five repos and the list file. The owner of a directory is its line in $DREAMTEAM_REPO_OWNERS (default
#        ~/.config/dreamteam/repo-owners.tsv, `<directory name><TAB><lane>`), else the lead ($DREAMTEAM_LEAD_MAIL,
#        default `sen`). Sent with $DREAMTEAM_MAIL_CMD (default `agent-mail send`). A finding that goes away and
#        comes back is told again. A message that cannot be sent is tried again at the next run. Nothing is sent
#        for a finding already told: a daily repeat is noise.
# Writes nothing into any repository: no fetch, no status, GIT_OPTIONAL_LOCKS=0.
# State: ${XDG_STATE_HOME:-~/.local/state}/dreamteam/unpushed-commits.{list,told,lock} (0600).
# Exit:  0 line published (any status) · 1 line not published · 22 bad argument · 75 another run holds the lock.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"

LIST=0
case "${1:-}" in
  "") ;;
  --list) LIST=1 ;;
  *) echo "usage: unpushed-commits-check.sh [--list]" >&2; exit 22 ;;
esac
[ "$#" -le 1 ] || { echo "usage: unpushed-commits-check.sh [--list]" >&2; exit 22; }

umask 077
NAME="$(check_name unpushed-commits)"
OWNER="daily, owner Sen"
case "${XDG_STATE_HOME:-/}" in /*) ;; *) echo "XDG_STATE_HOME must be absolute" >&2; exit 22 ;; esac
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam"
roots_raw="${DREAMTEAM_UNPUSHED_ROOTS:-$HOME/Projects:$HOME/srv}"
case "$roots_raw" in *$'\n'*|*$'\r'*) check_line "$NAME" fail "DREAMTEAM_UNPUSHED_ROOTS holds a newline" "$OWNER"; exit $? ;; esac
IFS=: read -r -a ROOTS <<< "$roots_raw"
[ "${#ROOTS[@]}" -ge 1 ] || { check_line "$NAME" fail "no roots given" "$OWNER"; exit $?; }
min_age="${DREAMTEAM_UNPUSHED_MIN_AGE:-86400}"
[[ "$min_age" =~ ^[0-9]{1,9}$ ]] || { check_line "$NAME" fail "DREAMTEAM_UNPUSHED_MIN_AGE is not a number of seconds" "$OWNER"; exit $?; }
now="${DREAMTEAM_NOW:-$(date +%s)}"; [[ "$now" =~ ^[0-9]{1,12}$ ]] || now=$(date +%s)
# The lead's name becomes an argument of the mail command, like a mapped lane: the same plain grammar, checked first.
lead="${DREAMTEAM_LEAD_MAIL:-sen}"
[[ "$lead" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { check_line "$NAME" fail "DREAMTEAM_LEAD_MAIL is not a plain lane name" "$OWNER"; exit $?; }

mkdir -p "$STATE" 2>/dev/null && [ -d "$STATE" ] || { check_line "$NAME" fail "no state dir $STATE" "$OWNER"; exit $?; }
LOCK="$STATE/unpushed-commits.lock"
if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && { [ ! -f "$LOCK" ] || [ ! -O "$LOCK" ]; }; }; then
  check_line "$NAME" fail "lock file is a symlink or not ours" "$OWNER"; exit $?
fi
exec 9>> "$LOCK" || { check_line "$NAME" fail "cannot open the lock in $STATE" "$OWNER"; exit $?; }
flock -n 9 || { echo "unpushed-commits-check: another run holds the lock; nothing published" >&2; exit 75; }

# The state files this run reads must be plain files of ours, or absent: a symlink there could point into a
# repository, and this check never writes into one. Refused before anything is measured.
told="$STATE/unpushed-commits.told"
for f in "$told" "$STATE/unpushed-commits.list"; do
  if [ -L "$f" ] || { [ -e "$f" ] && { [ ! -f "$f" ] || [ ! -O "$f" ]; }; }; then
    check_line "$NAME" fail "a state file is a symlink or not a plain file of ours: $(basename -- "$f")" "$OWNER"; exit $?
  fi
done

for r in "${ROOTS[@]}"; do
  case "$r" in /*) ;; *) check_line "$NAME" fail "a root is not an absolute path" "$OWNER"; exit $? ;; esac
  [ -d "$r" ] && [ -r "$r" ] && [ -x "$r" ] || { check_line "$NAME" fail "${r/#$HOME/\~} is not a readable directory" "$OWNER"; exit $?; }
done

# The measurement: idle I/O and low priority where the tools exist (the server's copy is on a slow disk).
pre=()
command -v ionice >/dev/null 2>&1 && pre+=(ionice -c3)
command -v nice >/dev/null 2>&1 && pre+=(nice -n 15)
raw=$(mktemp "$STATE/.unpushed-commits.raw.XXXXXX") || { check_line "$NAME" fail "no temp file in $STATE" "$OWNER"; exit $?; }
trap 'rm -f -- "$raw" "${newlist:-}" "${newtold:-}"' EXIT
"${pre[@]}" python3 -I "$ROOT/scripts/lib/unpushed_commits.py" "$now" "$min_age" "${ROOTS[@]}" > "$raw" 2>/dev/null 9>&-
mrc=$?
res=$(grep -c '^RESULT ' "$raw" 2>/dev/null || true)
last=$(tail -n 1 "$raw" 2>/dev/null)
if [ "$mrc" != 0 ] || [ "$res" != 1 ] || [[ ! "$last" =~ ^RESULT\ repos=([0-9]+)\ ahead=([0-9]+)\ noremote=([0-9]+)\ errors=([0-9]+)\ young=([0-9]+)\ empty=([0-9]+)$ ]]; then
  check_line "$NAME" fail "the measurement did not finish (exit $mrc): nothing was counted" "$OWNER"; exit $?
fi
repos=${BASH_REMATCH[1]}; ahead=${BASH_REMATCH[2]}; noremote=${BASH_REMATCH[3]}; errors=${BASH_REMATCH[4]}

# The list: every finding line, in the measurer's order, minus the RESULT line. Its row count must equal the counts.
listf="$STATE/unpushed-commits.list"
newlist=$(mktemp "$STATE/.unpushed-commits.list.XXXXXX") || { check_line "$NAME" fail "no temp file in $STATE" "$OWNER"; exit $?; }
grep -v '^RESULT ' "$raw" > "$newlist" || true
rows=$(wc -l < "$newlist")
if [ "$rows" != $(( ahead + noremote + errors )) ] || grep -qvE $'^(ahead|no-remote|error)\t/[^\t]*\t[0-9]+\t[0-9]+$' "$newlist"; then
  check_line "$NAME" fail "the findings do not match their own counts: nothing is reported" "$OWNER"; exit $?
fi
mv -T -f -- "$newlist" "$listf" || { check_line "$NAME" fail "could not write the list" "$OWNER"; exit $?; }

if [ "$ahead" = 0 ] && [ "$noremote" = 0 ] && [ "$errors" = 0 ]; then
  status=ok
  fact="0 of $repos repos ahead for a day or more, 0 without a remote"
  nxt="$OWNER"
else
  status=warn
  fact="$ahead of $repos repos ahead for a day or more"
  if [ "$ahead" -gt 0 ]; then
    # the oldest: smallest epoch among the `ahead` rows
    IFS=$'\t' read -r _ opath _ oepoch < <(grep $'^ahead\t' "$listf" | sort -t $'\t' -k4,4n | head -n 1)
    fact="$fact (oldest: $(basename -- "$opath"), $(( (now - oepoch) / 86400 )) d)"
  fi
  fact="$fact, $noremote without a remote"
  [ "$errors" -gt 0 ] && fact="$fact, $errors unreadable"
  nxt="list: ${listf/#$HOME/\~}"
fi
check_line "$NAME" "$status" "$fact" "$nxt"; rc=$?
[ "$LIST" = 1 ] && cat -- "$listf"

# Tell each NEW finding's owner once. `told` holds "<kind>\t<path>" for findings already told.
# (The memory file was checked before the measurement: a plain file of ours, or absent. It is only ever replaced by
# a rename, never opened for writing, so nothing can be written through it.)
[ -e "$told" ] || { nt=$(mktemp "$STATE/.unpushed-commits.told.XXXXXX") && mv -T -f -- "$nt" "$told"; } \
  || { echo "unpushed-commits-check: told memory could not be created; nobody is told this run" >&2; exit "$rc"; }
owners="${DREAMTEAM_REPO_OWNERS:-$HOME/.config/dreamteam/repo-owners.tsv}"
owner_of() {   # directory name → lane (a plain lane name from the map), else the lead
  local o=""
  if [ -f "$owners" ] && [ ! -L "$owners" ]; then
    o=$(awk -F '\t' -v n="$1" '$1 == n { print $2; exit }' "$owners" 2>/dev/null)
  fi
  [[ "$o" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && printf '%s' "$o" || printf '%s' "$lead"
}
read -r -a mailcmd <<< "${DREAMTEAM_MAIL_CMD:-agent-mail send}"
host="${DREAMTEAM_CHECK_HOST:-$(hostname 2>/dev/null)}"
declare -A news=() count=()
while IFS=$'\t' read -r kind path n _; do
  [ "$kind" = error ] && continue                      # unreadable is in the line; it has no owner to act on it
  grep -qxF -- "$kind"$'\t'"$path" "$told" && continue
  o=$(owner_of "$(basename -- "$path")")
  count[$o]=$(( ${count[$o]:-0} + 1 ))
  [ "${count[$o]}" -le 5 ] && news[$o]="${news[$o]:-}${news[$o]:+; }$(basename -- "$path") ($kind, $n commits)"
done < "$listf"
newtold=$(mktemp "$STATE/.unpushed-commits.told.XXXXXX") || { echo "unpushed-commits-check: told memory not recorded" >&2; exit "$rc"; }
# Keep what is still a finding. A finding that went away is forgotten, so its return is told again; but only a
# MEASUREMENT can say it went away: a repo that could not be read this run keeps its memory (or every hiccup of an
# unreadable repo would tell its owner again).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if grep -qF -- "$line"$'\t' "$listf" || grep -qF -- "error"$'\t'"${line#*$'\t'}"$'\t' "$listf"; then
    printf '%s\n' "$line" >> "$newtold"
  fi
done < "$told"
for o in "${!news[@]}"; do
  more=""; [ "${count[$o]}" -gt 5 ] && more="; and $(( ${count[$o]} - 5 )) more"
  msg="CHECK $NAME: history on ${host:-?} only, yours to push or give a remote: ${news[$o]}$more. List: ${listf/#$HOME/\~}"
  if "${mailcmd[@]}" "$o" "$msg" >/dev/null 2>&1 9>&-; then
    while IFS=$'\t' read -r kind path _; do
      [ "$kind" = error ] && continue
      [ "$(owner_of "$(basename -- "$path")")" = "$o" ] || continue
      grep -qxF -- "$kind"$'\t'"$path" "$newtold" || printf '%s\t%s\n' "$kind" "$path" >> "$newtold"
    done < "$listf"
  else
    echo "unpushed-commits-check: message to $o not sent (will retry next run)" >&2
  fi
done
mv -T -f -- "$newtold" "$told" || echo "unpushed-commits-check: told memory not recorded" >&2
exit "$rc"
