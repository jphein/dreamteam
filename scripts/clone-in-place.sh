#!/usr/bin/env bash
# dreamteam — turn a Syncthing'd directory into a real git clone IN PLACE, without touching its files, and keep
# it current afterwards (sync replacement, phases 1 and 2; docs/superpowers/specs/2026-11-17-sync-replacement-design.md).
# Ran first from scratch on gpu0, gpu1 and serialhub on 2026-11-18; this is that tool, promoted with its tests.
# Run ON the host:
#   clone-in-place.sh check <name> <origin-url> <branch> [<bundle-file>]   build the git dir OUTSIDE the tree and
#                                                                          compare the tree with origin's branch
#   clone-in-place.sh apply <name>     move the prepared git dir to <dir>/.git (refuses unless the projects folder
#                                      is PAUSED in Syncthing and the check's result still holds)
#   clone-in-place.sh undo  <name>     move <dir>/.git back out (the tree is as it was; unpause to resume syncing)
#
# The working tree is never written: `check` keeps the repository under ~/.local/state/sync-phase1/gitdirs and
# reads the tree through --work-tree; the index lives in the git dir. `apply` adds exactly one thing to the
# tree: the .git directory (which Syncthing ignores).
#   clone-in-place.sh classify <name>  after check: which differing files are stale (an older committed version),
#                                      which are real edits, which are absent (read-only)
#   clone-in-place.sh freshen <name>   after apply: bring ONLY stale and absent files to HEAD (tar of the stale ones
#                                      first); real edits and untracked files are never touched
#   clone-in-place.sh sync <name>      fetch and move the branch to origin's head WITHOUT writing a file (the index
#                                      is reset; refuses when the branch has commits origin lacks)
# Environment:
#   CLONE_DIR            the directory to work on (default ~/Projects/<name>); <name> then only names the state files
#   CLONE_SYNC_FOLDER    the Syncthing folder id that must be PAUSED for apply and freshen (default `projects`);
#                        `none` skips that check, for a tree that keeps syncing only paths git does not track
#   CLONE_SKIP_PREFIXES  colon-separated path prefixes (e.g. `projects/`) that freshen never checks out and classify
#                        counts apart: paths another mechanism owns
#   CLONE_STATE          where prepared git dirs, status files and tars live (default ~/.local/state/sync-phase1);
#                        absolute. The per-directory lock is NOT here: ~/.local/state/dreamteam/clone-locks.
# .git/clone-in-place.protected in the repository lists paths that were the owner's untracked files when a sync made them tracked;
# freshen never writes them. Delete a line (or the file) by hand once the owner has dealt with the file.
# Exit: 0 ok · 2 precondition not met · 22 usage.
set -uo pipefail
cmd="${1:-}"; name="${2:-}"
case "$name" in ""|*/*|.*) echo "usage: clone-in-place.sh check|apply|undo <name> …" >&2; exit 22 ;; esac
D="${CLONE_DIR:-$HOME/Projects/$name}"
case "$D" in /*) ;; *) echo "clone-in-place: CLONE_DIR must be absolute" >&2; exit 22 ;; esac
S="${CLONE_STATE:-$HOME/.local/state/sync-phase1}"
case "$S" in /*) ;; *) echo "clone-in-place: CLONE_STATE must be absolute" >&2; exit 22 ;; esac
# the per-directory lock lives OUTSIDE the configurable state root, so two callers with different CLONE_STATE values
# still exclude each other on one directory
LOCKS="$HOME/.local/state/dreamteam/clone-locks"
FOLDER="${CLONE_SYNC_FOLDER:-projects}"
case "$FOLDER" in *[!A-Za-z0-9._-]*|"") echo "clone-in-place: CLONE_SYNC_FOLDER must be a folder id or none" >&2; exit 22 ;; esac
IFS=: read -r -a SKIPS <<< "${CLONE_SKIP_PREFIXES:-}"
skipped() {   # 0 when the path starts with one of the skip prefixes
  local p; for p in "${SKIPS[@]}"; do [ -n "$p" ] && case "$1" in "$p"*) return 0 ;; esac; done; return 1
}
G="$S/gitdirs/$name.git"
export GIT_TERMINAL_PROMPT=0 GIT_NO_LAZY_FETCH=1
g() { git --git-dir="$G" -c core.bare=false --work-tree="$D" "$@"; }
[ -d "$D" ] && [ ! -L "$D" ] || { echo "$name: $D is not a directory"; exit 2; }

paused() {   # 0 when the Syncthing folder that carries this tree is paused (or the caller said there is none to pause)
  [ "$FOLDER" = none ] && return 0
  syncthing cli config folders "$FOLDER" dump-json 2>/dev/null | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('paused') else 1)"
}
# old_version <path> : 0 when the file's ON-DISK bytes (no clean filter) equal a blob that a commit reachable from
# HEAD recorded AT THIS SAME PATH. An object that merely exists in the store is not enough: `git add` of a local edit
# creates one, and another file's content may match. Uses the array GITC (set by the caller) to reach the repo.
old_version() {   # old_version <path> [<file holding the bytes to judge>]   (default: the live file)
  local f="$1" src="${2:-$D/$1}" h
  h=$("${GITC[@]}" hash-object --no-filters -- "$src" 2>/dev/null) || return 1
  [ -n "$h" ] || return 1
  "${GITC[@]}" --literal-pathspecs log -m --format= --raw --no-abbrev --no-renames HEAD -- "$f" 2>/dev/null \
    | awk '{print $3; print $4}' | grep -qx -- "$h"
}
# raw_path <path>: 0 when git compares this path's working file with a blob BYTE FOR BYTE: no filter, text/eol
# conversion, ident or encoding attribute applies (the guarded write below runs with autocrlf and safecrlf off too).
# A path with any of them is never a freshen candidate: it is counted as kept.
raw_path() {
  local vals ac
  # a repository that converts line endings by configuration compares no file byte for byte: nothing is a candidate
  ac=$(git -C "$D" config --get core.autocrlf 2>/dev/null || true)
  case "$ac" in ""|false) ;; *) return 1 ;; esac
  # -z output is path NUL attr NUL value NUL ...; every third field is a value. A pipe keeps the NULs.
  vals=$(set -o pipefail; git -C "$D" check-attr -z filter text eol ident working-tree-encoding -- "$1" 2>/dev/null \
         | tr '\0' '\n' | awk 'NR%3==0') || return 1
  [ "$(wc -l <<< "$vals")" = 5 ] || return 1
  ! grep -qvx unspecified <<< "$vals"
}
dirlock() {  # one mutating run at a time per DIRECTORY, whatever <name> the callers use
  local key lf
  umask 077; mkdir -p -- "$S" "$LOCKS" || { echo "$name: no state dir"; exit 2; }
  key=$(printf '%s' "$(cd "$D" && pwd -P)" | sha256sum | cut -c1-16)
  lf="$LOCKS/lock.$key"
  if [ -L "$lf" ] || { [ -e "$lf" ] && [ ! -f "$lf" ]; }; then echo "$name: $lf is a symlink or not a regular file"; exit 2; fi
  exec 7>> "$lf" || { echo "$name: cannot open the lock"; exit 2; }
  flock -n 7 || { echo "$name: another clone-in-place run holds this directory's lock; nothing done"; exit 2; }
}
summary() {  # counts from one porcelain listing on stdin
  awk '{c=substr($0,1,2)} c=="??"{u++} c!="??"{m++} END{printf "%d differing tracked, %d untracked", m+0, u+0}'
}

case "$cmd" in
  check)
    url="${3:-}"; br="${4:-}"; bundle="${5:-}"
    [ -n "$url" ] && [ -n "$br" ] || { echo "usage: clone-in-place.sh check <name> <url> <branch> [bundle]" >&2; exit 22; }
    [ ! -e "$D/.git" ] || { echo "$name: already has a .git; nothing to do"; exit 2; }
    umask 077; mkdir -p "$S/gitdirs"; rm -rf -- "${G:?}"
    git init -q --bare -- "$G" || exit 2
    git --git-dir="$G" remote add origin "$url"
    src=origin; [ -n "$bundle" ] && src="$bundle"
    git --git-dir="$G" fetch -q --no-tags "$src" "refs/heads/$br:refs/remotes/origin/$br" || { echo "$name: fetch of $br did not work"; exit 2; }
    git --git-dir="$G" update-ref "refs/heads/$br" "refs/remotes/origin/$br"
    git --git-dir="$G" symbolic-ref HEAD "refs/heads/$br"
    git --git-dir="$G" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$br"
    git --git-dir="$G" config branch."$br".remote origin
    git --git-dir="$G" config branch."$br".merge "refs/heads/$br"
    g read-tree HEAD || exit 2                        # index only: no file in the tree is written
    g status --porcelain > "$S/$name.status" || exit 2
    printf '%s: origin/%s %s · %s\n' "$name" "$br" "$(git --git-dir="$G" rev-parse --short HEAD)" "$(summary < "$S/$name.status")"
    ;;
  classify)
    # For each tracked file that differs from origin's head: is its content an OLDER committed version (the synced
    # tree lags origin: "stale"), or bytes git has never seen (a real uncommitted edit: "edit")? Read-only.
    [ -d "$G" ] && [ -f "$S/$name.status" ] || { echo "$name: run check first"; exit 2; }
    GITC=(git --git-dir="$G" -c core.bare=false --work-tree="$D")
    stale=0; edit=0; absent=0; other=0; skip=0; : > "$S/$name.edits"
    while IFS= read -r line; do
      xy="${line:0:2}"; f="${line:3}"
      if [ "$xy" != "??" ] && skipped "$f"; then skip=$((skip + 1)); continue; fi
      case "$xy" in
        "??") continue ;;
        " D"|"D ") absent=$((absent + 1)); continue ;;
        " M"|"M "|"MM")
          if [ -f "$D/$f" ] && [ ! -L "$D/$f" ] && old_version "$f"; then
            stale=$((stale + 1))
          else
            edit=$((edit + 1)); printf '%s\n' "$f" >> "$S/$name.edits"
          fi ;;
        *) other=$((other + 1)); printf '%s\n' "$line" >> "$S/$name.edits" ;;
      esac
    done < "$S/$name.status"
    unt=$(grep -c '^??' "$S/$name.status" || true)
    printf '%s: %d stale (an older committed version) · %d real edits · %d absent on this host · %d other · %d untracked\n' \
      "$name" "$stale" "$edit" "$absent" "$other" "$unt"
    [ "$skip" = 0 ] || printf '%s: %d differing paths under the skip prefixes, not judged\n' "$name" "$skip"
    ;;
  apply)
    [ -d "$G" ] || { echo "$name: no prepared git dir (run check first)"; exit 2; }
    [ ! -e "$D/.git" ] || { echo "$name: already has a .git"; exit 2; }
    paused || { echo "$name: the Syncthing folder '$FOLDER' is not paused; refusing"; exit 2; }
    dirlock
    g status --porcelain > "$S/$name.status.apply" || exit 2
    cmp -s "$S/$name.status" "$S/$name.status.apply" || { echo "$name: the tree changed since the check; run check again"; exit 2; }
    mv -T -- "$G" "$D/.git" || exit 2
    git -C "$D" config core.bare false
    n=$(git -C "$D" status --porcelain | wc -l)
    printf '%s: now a clone (%s on %s, %s lines of status, same as the check: %s)\n' "$name" \
      "$(git -C "$D" rev-parse --short HEAD)" "$(git -C "$D" symbolic-ref --short HEAD)" "$n" \
      "$([ "$n" = "$(wc -l < "$S/$name.status")" ] && echo yes || echo NO)"
    ;;
  freshen)
    # After apply: bring ONLY stale files (on-disk bytes equal to an older committed version OF THE SAME PATH) and
    # absent files up to HEAD. Real edits and untracked files are never touched. The stale files go into a tar first.
    # The last line is machine-readable:  RESULT freshened=<n> stale=<s> absent=<a> kept=<k> linked=<l> skipped=<p>
    # The write is a two-way merge (see below): git itself refuses if a candidate changed after it was judged.
    [ -d "$D/.git" ] || { echo "$name: not a clone yet (apply first)"; exit 2; }
    paused || { echo "$name: the Syncthing folder '$FOLDER' is not paused; refusing"; exit 2; }
    dirlock
    GITC=(git -C "$D")
    stf=$(mktemp "$S/.$name.status.XXXXXX") && lst=$(mktemp "$S/.$name.paths.XXXXXX") && stl=$(mktemp "$S/.$name.stale.XXXXXX") \
      && sums=$(mktemp "$S/.$name.sums.XXXXXX") && abl=$(mktemp "$S/.$name.absent.XXXXXX") && snap=$(mktemp "$S/.$name.snap.XXXXXX") \
      || { echo "$name: cannot create work files in $S"; exit 2; }
    idx=""
    cleanup() { rm -f -- "$stf" "$lst" "$stl" "$sums" "$abl" "$snap" "$snap".* ${idx:+"$idx" "$idx.lock"}; }
    trap cleanup EXIT
    # paths that were UNTRACKED files of the owner when a sync made them tracked: never written, whatever their bytes.
    # The list lives in the repository's own git dir, so every caller (any name, any CLONE_STATE) sees the same one,
    # and a list that exists but cannot be read stops the run: protection never fails open.
    prot="$D/.git/clone-in-place.protected"
    if [ -e "$prot" ] || [ -L "$prot" ]; then
      [ -f "$prot" ] && [ ! -L "$prot" ] && [ -r "$prot" ] || { echo "$name: $prot is not a readable regular file; nothing changed"; exit 2; }
    fi
    protected() {   # 0 protected · 1 not · anything else stops the run
      [ -e "$prot" ] || return 1
      grep -qzxF -- "$1" "$prot"; local r=$?
      [ "$r" -le 1 ] || { echo "$name: cannot read $prot; nothing changed"; exit 2; }
      return "$r"
    }
    # the listing is complete or the run stops: a status that did not finish is not "nothing to do"
    git -C "$D" status --porcelain -z --no-renames > "$stf" || { echo "$name: git status did not work; nothing changed"; exit 2; }
    kept=0; linked=0; skipn=0; protn=0
    while IFS= read -r -d '' rec; do
      xy="${rec:0:2}"; f="${rec:3}"
      # A tracked path that lies BEHIND a symlinked directory (scratch/ linked to the fleet share) is never
      # checked out: git would replace the link with a real directory (seen on serialhub's memorypalace, 11-18).
      par="$(dirname -- "$f")"; behind=0
      while [ "$par" != . ] && [ "$par" != / ]; do [ -L "$D/$par" ] && behind=1; par="$(dirname -- "$par")"; done
      if [ "$behind" = 1 ]; then linked=$((linked + 1)); continue; fi
      if [ "$xy" != "??" ] && skipped "$f"; then skipn=$((skipn + 1)); continue; fi
      if [ "$xy" != "??" ] && protected "$f"; then kept=$((kept + 1)); protn=$((protn + 1)); continue; fi
      case "$xy" in
        " D") if [ ! -e "$D/$f" ] && [ ! -L "$D/$f" ]; then printf '%s\0' "$f" >> "$lst"; printf '%s\0' "$f" >> "$abl"; else kept=$((kept + 1)); fi ;;
        " M")
          # ONE snapshot of the bytes: the same copy is judged against history and gives the checksum the live file
          # must still have right before the write. An edit saved at any moment after the snapshot stops the run.
          if [ -f "$D/$f" ] && [ ! -L "$D/$f" ] && raw_path "$f" && cp -- "$D/$f" "$snap" 2>/dev/null && old_version "$f" "$snap"; then
            sum=$(sha256sum < "$snap" | cut -d' ' -f1)
            cp -- "$snap" "$snap.$sum" || { echo "$name: cannot keep the judged bytes of $f"; exit 2; }
            printf '%s\0' "$f" >> "$lst"; printf '%s\0' "$f" >> "$stl"
            printf '%s  %s\0' "$sum" "$f" >> "$sums"
          else kept=$((kept + 1)); fi ;;
        "??") ;;
        *) kept=$((kept + 1)) ;;
      esac
    done < "$stf"
    n=$(tr -cd '\0' < "$lst" | wc -c); ns=$(tr -cd '\0' < "$stl" | wc -c)
    [ "$linked" = 0 ] || echo "$name: $linked tracked paths lie behind a linked directory; left alone"
    [ "$skipn" = 0 ] || echo "$name: $skipn differing paths under the skip prefixes; left alone"
    [ "$protn" = 0 ] || echo "$name: $protn paths were the owner's untracked files before origin started tracking them; left alone"
    if [ "$n" = 0 ]; then
      echo "$name: nothing stale or absent; $kept differing files left as they are"
      echo "RESULT freshened=0 stale=0 absent=0 kept=$kept linked=$linked skipped=$skipn"; exit 0
    fi
    tarf=none
    if [ "$ns" -gt 0 ]; then
      tarf=$(mktemp "$S/$name.pre-freshen-$(date +%Y%m%d-%H%M%S).XXXXXX.tar") || { echo "$name: cannot name a backup tar; nothing changed"; exit 2; }
      tar -C "$D" --null -T "$stl" -cf "$tarf" || { echo "$name: backup tar did not work; nothing changed"; exit 2; }
      [ "$(tar -tf "$tarf" | wc -l)" = "$ns" ] || { echo "$name: backup tar is incomplete; nothing changed"; exit 2; }
    fi
    # The write is git's own two-way merge, from a tree holding EXACTLY the judged state of the candidates to HEAD.
    # git refuses the whole step if any candidate's file no longer matches what was judged ("not uptodate") or if a
    # file has appeared where an absent path would go ("would be overwritten"): an edit saved at any moment before
    # git's own check is kept, and nothing is written. Other paths with real edits are not in the merge: git keeps
    # them as they are. Done on a private copy of the index, so a refusal leaves the repository's index untouched.
    idx=$(mktemp "$S/.$name.index.XXXXXX") || { echo "$name: cannot create a work index"; exit 2; }
    rm -f -- "$idx"
    gi() { GIT_INDEX_FILE="$idx" git -c core.autocrlf=false -c core.safecrlf=false --literal-pathspecs -C "$D" "$@"; }
    # Built from HEAD, not from the repository's index: every non-candidate path is identical in both merge trees, so
    # the merge cannot touch it (a staged edit elsewhere is neither restored nor unstaged).
    gi read-tree HEAD || { echo "$name: cannot build a work index from HEAD"; exit 2; }
    while IFS= read -r -d '' rec; do
      want="${rec%%  *}"; f="${rec#*  }"
      mode=$(gi ls-files -s -- "$f" | head -1 | cut -d' ' -f1); [ -n "$mode" ] || mode=100644
      blob=$(gi hash-object --no-filters -w -- "$snap.$want" 2>/dev/null) || blob=""
      [ -n "$blob" ] || { echo "$name: cannot record the judged bytes of $f; nothing changed"; exit 2; }
      gi update-index --cacheinfo "$mode,$blob,$f" || { echo "$name: cannot stage $f; nothing changed"; exit 2; }
    done < "$sums"
    while IFS= read -r -d '' f; do
      gi update-index --force-remove -- "$f" || { echo "$name: cannot stage the absence of $f; nothing changed"; exit 2; }
    done < "$abl"
    gi update-index -q --refresh >/dev/null 2>&1
    from=$(gi write-tree) || { echo "$name: cannot write the judged tree; nothing changed"; exit 2; }
    if ! out=$(gi read-tree -m -u "$from" HEAD 2>&1); then
      echo "$name: a file changed or appeared while this ran ($(head -1 <<< "$out" | cut -c1-100)); nothing changed (run again)"; exit 2
    fi
    # the repository's own index changes ONLY at the candidate paths (now equal to HEAD); other entries stay staged
    git --literal-pathspecs -C "$D" reset -q --pathspec-from-file="$lst" --pathspec-file-nul -- \
      || { echo "$name: files updated; the index entries of those paths could not be reset (run: git -C $D status)"; exit 2; }
    printf '%s: freshened %d files (%d stale, %d absent); %d differing files left as they are; status lines now %s; backup %s\n' \
      "$name" "$n" "$ns" "$((n - ns))" "$kept" "$(git -C "$D" status --porcelain | wc -l)" "$tarf"
    echo "RESULT freshened=$n stale=$ns absent=$((n - ns)) kept=$kept linked=$linked skipped=$skipn"
    ;;
  sync)
    # After a commit made through the GitHub API (the fleet's way): fetch, then move the local branch to origin's
    # head and reset the INDEX only. No file is written, so a file the lane already holds in its new form simply
    # stops showing as modified. Refuses when the branch has commits origin lacks (nothing is thrown away).
    [ -d "$D/.git" ] || { echo "$name: not a clone"; exit 2; }
    dirlock
    br=$(git -C "$D" symbolic-ref -q --short HEAD) || { echo "$name: detached HEAD; nothing done"; exit 2; }
    git -C "$D" fetch -q origin "$br" || { echo "$name: fetch did not work"; exit 2; }
    ahead=$(git -C "$D" rev-list --count "origin/$br..$br")
    [ "$ahead" = 0 ] || { echo "$name: $ahead local commits are not on origin; nothing done"; exit 2; }
    old=$(git -C "$D" rev-parse "$br"); new=$(git -C "$D" rev-parse "origin/$br")
    if [ "$old" != "$new" ]; then
      # A file that is UNTRACKED now and that origin's new head tracks stays the owner's: remember it BEFORE the
      # move, so a later freshen never writes it (even when its bytes equal something this path once held).
      umask 077; mkdir -p -- "$S"; prot="$D/.git/clone-in-place.protected"
      [ ! -L "$prot" ] || { echo "$name: $prot is a symlink; nothing done"; exit 2; }
      added=$(mktemp "$S/.$name.added.XXXXXX") || { echo "$name: cannot create a work file"; exit 2; }
      git -C "$D" --literal-pathspecs diff --no-renames --name-only -z --diff-filter=A "$old" "$new" > "$added" \
        || { rm -f -- "$added"; echo "$name: cannot list what the move adds; nothing done"; exit 2; }
      while IFS= read -r -d '' f; do
        if [ -e "$D/$f" ] || [ -L "$D/$f" ]; then printf '%s\0' "$f" >> "$prot" || { rm -f -- "$added"; echo "$name: cannot record a protected path; nothing done"; exit 2; }; fi
      done < "$added"
      rm -f -- "$added"
      git -C "$D" update-ref "refs/heads/$br" "$new" "$old" && git -C "$D" reset -q || { echo "$name: could not move $br"; exit 2; }
    fi
    printf '%s: %s at %s (was %s); %s lines of status\n' "$name" "$br" "$(git -C "$D" rev-parse --short "$br")" "${old:0:7}" "$(git -C "$D" status --porcelain | wc -l)"
    ;;
  undo)
    [ -d "$D/.git" ] || { echo "$name: no .git to move out"; exit 2; }
    dirlock
    [ ! -e "$G" ] || { echo "$name: $G is in the way"; exit 2; }
    mkdir -p "$S/gitdirs" && mv -T -- "$D/.git" "$G" && git --git-dir="$G" config core.bare true && echo "$name: .git moved back out to $G; the tree is untouched"
    ;;
  *) echo "usage: clone-in-place.sh check|apply|undo <name> …" >&2; exit 22 ;;
esac
