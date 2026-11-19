#!/usr/bin/env bash
# dreamteam — deliver a config repository into a live directory by git, with no hand "align" (sync replacement,
# phase 2). The live directory (default ~/.claude) is NOT a git worktree for this job: a pristine bare clone is kept
# outside it and files are deployed from that clone.
#
#   config-pull.sh --init <url> [<branch>]   once per host: make the pristine clone (default branch: main). Writes
#                                            nothing into the live directory.
#   config-pull.sh                           one pass: fetch, then for every file the branch head tracks outside
#                                            `projects/`, bring the live file to the head's version IF THAT IS LOSSLESS.
#
# The one rule. A live file is replaced only when nothing can be lost by it:
#   - it is absent, or
#   - its exact bytes are a version of THAT SAME PATH that some commit on the branch recorded (so git still has them).
# Anything else is a local edit: left exactly as it is and counted in the line. A path that is a symlink, a directory,
# or lies behind a symlinked directory is never written. Files the head does not track are never touched, and a file
# the head stopped tracking is not removed. Nothing under `projects/` is read or written (transcripts and memory
# belong to other mechanisms). Every replaced file's previous bytes are first kept in a dated backup directory.
#
# How a file is replaced: the new bytes are written to a temp file beside it; the live file is hard-linked into the
# backup dir and THAT link is judged; then the temp file is renamed over the live name; then the link is judged again.
# An editor that wrote into the old file meanwhile is caught by the second look and its bytes are put back. What is
# not excluded: an editor that replaces the file by rename in the instant between the link and our rename. The
# window is two system calls; the job says so here and does not claim more.
#
# Line (docs/CHECKS.md):
#   CHECK config-pull[-<host>] ok   · main at <sha>, N files updated, all T current · every 10 min, owner Sen
#   CHECK …                    warn · main at <sha>, N files updated, K local edits left alone · …
#   CHECK …                    fail · <not initialised | fetch did not work | …> · owner Sen       (unknown is never ok)
# Environment: CONFIG_PULL_DIR (the live directory, absolute; default ~/.claude).
# State: ${XDG_STATE_HOME:-~/.local/state}/dreamteam/config-pull/<key of the live dir>/{repo.git,branch,backup/}
# Exit: 0 line published (any status) / init done · 1 line not published · 2 init refused · 22 bad arguments · 75 lock held.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"
MODE="${1:-}"
case "$MODE" in "") [ "$#" -eq 0 ] ;; --init) [ "$#" -ge 2 ] && [ "$#" -le 3 ] ;; *) false ;; esac \
  || { echo "usage: config-pull.sh [--init <url> [<branch>]]" >&2; exit 22; }

DIR="${CONFIG_PULL_DIR:-$HOME/.claude}"
SKIP="projects/"
CHECK="$(check_name config-pull)"
OWNER="every 10 min, owner Sen"
case "${XDG_STATE_HOME:-/}" in /*) ;; *) echo "XDG_STATE_HOME must be absolute" >&2; exit 22 ;; esac
export GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1
umask 077

say_fail() { if [ "$MODE" = --init ]; then echo "config-pull: $1" >&2; exit 2; fi; check_line "$CHECK" fail "$1" "$OWNER"; exit $?; }
case "$DIR" in /*) ;; *) say_fail "CONFIG_PULL_DIR is not absolute" ;; esac
[ -d "$DIR" ] && [ ! -L "$DIR" ] || say_fail "${DIR/#$HOME/\~} is not a directory"
key=$(printf '%s' "$(cd "$DIR" && pwd -P)" | sha256sum | cut -c1-16)
ST="${XDG_STATE_HOME:-$HOME/.local/state}/dreamteam/config-pull/$key"
REPO="$ST/repo.git"; BRF="$ST/branch"; LOCK="$ST/lock"
mkdir -p -- "$ST" 2>/dev/null && [ -d "$ST" ] && [ ! -L "$ST" ] || say_fail "no state dir $ST"
if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then say_fail "lock file is a symlink or not a regular file"; fi
exec 9>> "$LOCK" || say_fail "cannot open the lock"
flock -n 9 || { echo "config-pull: another run holds the lock; nothing done" >&2; exit 75; }
r() { git --git-dir="$REPO" "$@" 9>&-; }

if [ "$MODE" = --init ]; then
  url="$2"; br="${3:-main}"
  case "$br" in *[!A-Za-z0-9._/-]*|""|-*) echo "config-pull: bad branch name" >&2; exit 22 ;; esac
  case "$url" in -*|"") echo "config-pull: bad url" >&2; exit 22 ;; esac
  [ ! -e "$REPO" ] && [ ! -L "$REPO" ] && [ ! -e "$BRF" ] && [ ! -L "$BRF" ] || { echo "config-pull: already initialised ($ST); remove it by hand to start over" >&2; exit 2; }
  tmp=$(mktemp -d "$ST/.repo.XXXXXX") || exit 2
  if ! git clone -q --bare --single-branch --branch "$br" -- "$url" "$tmp/repo.git" 9>&- 2>/dev/null; then rm -rf -- "$tmp"; echo "config-pull: could not clone $br from that url" >&2; exit 2; fi
  mv -T -- "$tmp/repo.git" "$REPO" && rmdir -- "$tmp" || { echo "config-pull: could not publish the clone" >&2; exit 2; }
  r config remote.origin.fetch "+refs/heads/$br:refs/remotes/origin/$br"
  printf '%s\n' "$br" > "$BRF" || exit 2
  echo "config-pull: pristine clone of $br at $(r rev-parse --short "$br") in $ST; nothing was written into ${DIR/#$HOME/\~}"
  exit 0
fi

# a run that is stopped (the unit's timeout, a shutdown) publishes fail: an earlier ok line must not stand for it
trap 'check_line "$CHECK" fail "stopped before it finished (timeout or signal)" "$OWNER" >/dev/null; exit 143' TERM INT HUP

[ -d "$REPO" ] && [ ! -L "$REPO" ] && [ -f "$BRF" ] && [ ! -L "$BRF" ] || say_fail "not initialised (run config-pull.sh --init <url> once)"
IFS= read -r br < "$BRF" || br=""
case "$br" in *[!A-Za-z0-9._/-]*|""|-*) say_fail "the recorded branch name is not valid" ;; esac
r fetch -q origin 2>/dev/null || say_fail "fetch did not work"
head=$(r rev-parse --verify -q "refs/remotes/origin/$br^{commit}") || say_fail "origin has no branch $br"
sha=$(r rev-parse --short "$head") || say_fail "cannot read the head"

work=$(mktemp -d "$ST/.work.XXXXXX") || say_fail "cannot create a work dir"
trap 'rm -rf -- "$work"' EXIT
r ls-tree -r -z --full-tree "$head" > "$work/tree" || say_fail "cannot list the head's files"

# lossless <path> <file>: 0 when <file>'s bytes are a version of <path> recorded by a commit on the branch
lossless() {
  local h
  h=$(r hash-object --no-filters -- "$2" 2>/dev/null) && [ -n "$h" ] || return 1
  r --literal-pathspecs log -m --format= --raw --no-abbrev --no-renames "$head" -- "$1" 2>/dev/null | awk '{print $3; print $4}' | grep -qx -- "$h"
}
behind_link() {   # 0 when a parent directory of <path> is a symlink (or not a directory) in the live tree
  local par; par=$(dirname -- "$1")
  while [ "$par" != . ] && [ "$par" != / ]; do
    if [ -L "$DIR/$par" ] || { [ -e "$DIR/$par" ] && [ ! -d "$DIR/$par" ]; }; then return 0; fi
    par=$(dirname -- "$par")
  done
  return 1
}

total=0; updated=0; edits=0; skipped=0; bdir=""
while IFS= read -r -d '' rec; do
  meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
  mode="${meta%% *}"; rest="${meta#* }"; type="${rest%% *}"; blob="${rest#* }"
  case "$path" in "$SKIP"*) continue ;; esac
  [ "$type" = blob ] || { skipped=$((skipped + 1)); continue; }                    # a submodule entry: not ours to write
  case "$mode" in 100644|100755) ;; *) skipped=$((skipped + 1)); continue ;; esac  # a tracked symlink: never written
  total=$((total + 1))
  live="$DIR/$path"
  if behind_link "$path" || [ -L "$live" ] || { [ -e "$live" ] && [ ! -f "$live" ]; }; then edits=$((edits + 1)); continue; fi
  if [ -f "$live" ]; then
    cur=$(r hash-object --no-filters -- "$live" 2>/dev/null) || { edits=$((edits + 1)); continue; }
    if [ "$cur" = "$blob" ]; then
      # same bytes; keep the executable bit as the repo has it
      if [ "$mode" = 100755 ] && [ ! -x "$live" ]; then chmod u+x,go+x -- "$live" 2>/dev/null || true; fi
      continue
    fi
  fi
  # the new bytes, beside the live file (same filesystem: the rename is atomic)
  mkdir -p -- "$(dirname -- "$live")" 2>/dev/null || { edits=$((edits + 1)); continue; }
  tmpf=$(mktemp "$(dirname -- "$live")/.config-pull.XXXXXX") || { edits=$((edits + 1)); continue; }
  if ! r cat-file blob "$blob" > "$tmpf" 2>/dev/null; then rm -f -- "$tmpf"; say_fail "cannot read $path from the clone"; fi
  if [ "$mode" = 100755 ]; then chmod 755 -- "$tmpf"; else chmod 644 -- "$tmpf"; fi
  if [ ! -e "$live" ] && [ ! -L "$live" ]; then
    # absent: publish without replacing anything that appears meanwhile
    if ln -T -- "$tmpf" "$live" 2>/dev/null; then updated=$((updated + 1)); else edits=$((edits + 1)); fi
    rm -f -- "$tmpf"; continue
  fi
  [ -n "$bdir" ] || { bdir="$ST/backup/$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p -- "$bdir" || { rm -f -- "$tmpf"; say_fail "cannot create the backup dir"; }; }
  bak="$bdir/$path"; mkdir -p -- "$(dirname -- "$bak")"
  # keep the live file's CURRENT inode in the backup dir and judge that
  if ! ln -T -- "$live" "$bak" 2>/dev/null && ! cp -p -- "$live" "$bak" 2>/dev/null; then rm -f -- "$tmpf"; edits=$((edits + 1)); continue; fi
  if ! lossless "$path" "$bak"; then rm -f -- "$tmpf" "$bak"; edits=$((edits + 1)); continue; fi
  mv -T -f -- "$tmpf" "$live" || { rm -f -- "$tmpf" "$bak"; edits=$((edits + 1)); continue; }
  # second look at what we displaced: if an editor wrote into it after it was judged, its bytes go back
  if ! lossless "$path" "$bak"; then
    cp -p -- "$bak" "$live.config-pull-edit" && mv -T -f -- "$live.config-pull-edit" "$live"
    edits=$((edits + 1)); continue
  fi
  updated=$((updated + 1))
done < "$work/tree"

[ "$total" -gt 0 ] || say_fail "the head tracks no file outside $SKIP"
if [ "$edits" -gt 0 ]; then
  check_line "$CHECK" warn "$br at $sha, $updated files updated, $edits local edits left alone" "$OWNER"
else
  check_line "$CHECK" ok "$br at $sha, $updated files updated, all $total current" "$OWNER"
fi
