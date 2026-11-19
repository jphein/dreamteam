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
#   CLONE_STATE          where prepared git dirs, status files and tars live (default ~/.local/state/sync-phase1)
# Exit: 0 ok · 2 precondition not met · 22 usage.
set -uo pipefail
cmd="${1:-}"; name="${2:-}"
case "$name" in ""|*/*|.*) echo "usage: clone-in-place.sh check|apply|undo <name> …" >&2; exit 22 ;; esac
D="${CLONE_DIR:-$HOME/Projects/$name}"
case "$D" in /*) ;; *) echo "clone-in-place: CLONE_DIR must be absolute" >&2; exit 22 ;; esac
S="${CLONE_STATE:-$HOME/.local/state/sync-phase1}"
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
summary() {  # counts from one porcelain listing on stdin
  awk '{c=substr($0,1,2)} c=="??"{u++} c!="??"{m++} END{printf "%d differing tracked, %d untracked", m+0, u+0}'
}

case "$cmd" in
  check)
    url="${3:-}"; br="${4:-}"; bundle="${5:-}"
    [ -n "$url" ] && [ -n "$br" ] || { echo "usage: clone-in-place.sh check <name> <url> <branch> [bundle]" >&2; exit 22; }
    [ ! -e "$D/.git" ] || { echo "$name: already has a .git; nothing to do"; exit 2; }
    umask 077; mkdir -p "$S/gitdirs"; rm -rf -- "${G:?}"
    git init -q --bare "$G" || exit 2
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
    stale=0; edit=0; absent=0; other=0; skip=0; : > "$S/$name.edits"
    while IFS= read -r line; do
      xy="${line:0:2}"; f="${line:3}"
      if [ "$xy" != "??" ] && skipped "$f"; then skip=$((skip + 1)); continue; fi
      case "$xy" in
        "??") continue ;;
        " D"|"D ") absent=$((absent + 1)); continue ;;
        " M"|"M "|"MM")
          if [ -f "$D/$f" ] && h=$(g hash-object -- "$D/$f" 2>/dev/null) && git --git-dir="$G" cat-file -e "$h^{blob}" 2>/dev/null; then
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
    # After apply: bring ONLY stale files (bytes equal to an older committed version) and absent files up to HEAD.
    # Real edits and untracked files are never touched. The stale files are saved in a tar first.
    [ -d "$D/.git" ] || { echo "$name: not a clone yet (apply first)"; exit 2; }
    paused || { echo "$name: the Syncthing folder '$FOLDER' is not paused; refusing"; exit 2; }
    umask 077; mkdir -p "$S"
    ts=$(date +%Y%m%d-%H%M%S); lst="$S/$name.freshen-$ts.paths"; stl="$S/$name.freshen-$ts.stale"; : > "$lst"; : > "$stl"
    kept=0; linked=0; skipn=0
    while IFS= read -r -d '' rec; do
      xy="${rec:0:2}"; f="${rec:3}"
      # A tracked path that lies BEHIND a symlinked directory (scratch/ linked to the fleet share) is never
      # checked out: git would replace the link with a real directory (seen on serialhub's memorypalace, 11-18).
      par="$(dirname -- "$f")"; behind=0
      while [ "$par" != . ] && [ "$par" != / ]; do [ -L "$D/$par" ] && behind=1; par="$(dirname -- "$par")"; done
      if [ "$behind" = 1 ]; then linked=$((linked + 1)); continue; fi
      if [ "$xy" != "??" ] && skipped "$f"; then skipn=$((skipn + 1)); continue; fi
      case "$xy" in
        " D") printf '%s\0' "$f" >> "$lst" ;;
        " M")
          if [ -f "$D/$f" ] && [ ! -L "$D/$f" ] && h=$(git -C "$D" hash-object -- "$f" 2>/dev/null) && git -C "$D" cat-file -e "$h^{blob}" 2>/dev/null; then
            printf '%s\0' "$f" >> "$lst"; printf '%s\0' "$f" >> "$stl"
          else kept=$((kept + 1)); fi ;;
        "??") ;;
        *) kept=$((kept + 1)) ;;
      esac
    done < <(git -C "$D" status --porcelain -z --no-renames)
    n=$(tr -cd '\0' < "$lst" | wc -c); ns=$(tr -cd '\0' < "$stl" | wc -c)
    [ "$linked" = 0 ] || echo "$name: $linked tracked paths lie behind a linked directory; left alone"
    [ "$skipn" = 0 ] || echo "$name: $skipn differing paths under the skip prefixes; left alone"
    [ "$n" -gt 0 ] || { echo "$name: nothing stale or absent; $kept differing files left as they are"; exit 0; }
    tarf="$S/$name.pre-freshen-$ts.tar"
    if [ "$ns" -gt 0 ]; then
      tar -C "$D" --null -T "$stl" -cf "$tarf" || { echo "$name: backup tar did not work; nothing changed"; exit 2; }
      [ "$(tar -tf "$tarf" | wc -l)" = "$ns" ] || { echo "$name: backup tar is incomplete; nothing changed"; exit 2; }
    fi
    git -C "$D" checkout -q HEAD --pathspec-from-file="$lst" --pathspec-file-nul || { echo "$name: checkout did not work"; exit 2; }
    printf '%s: freshened %d files (%d stale, %d absent); %d differing files left as they are; status lines now %s; backup %s\n' \
      "$name" "$n" "$ns" "$((n - ns))" "$kept" "$(git -C "$D" status --porcelain | wc -l)" "$( [ "$ns" -gt 0 ] && echo "$tarf" || echo none)"
    ;;
  sync)
    # After a commit made through the GitHub API (the fleet's way): fetch, then move the local branch to origin's
    # head and reset the INDEX only. No file is written, so a file the lane already holds in its new form simply
    # stops showing as modified. Refuses when the branch has commits origin lacks (nothing is thrown away).
    [ -d "$D/.git" ] || { echo "$name: not a clone"; exit 2; }
    br=$(git -C "$D" symbolic-ref -q --short HEAD) || { echo "$name: detached HEAD; nothing done"; exit 2; }
    git -C "$D" fetch -q origin "$br" || { echo "$name: fetch did not work"; exit 2; }
    ahead=$(git -C "$D" rev-list --count "origin/$br..$br")
    [ "$ahead" = 0 ] || { echo "$name: $ahead local commits are not on origin; nothing done"; exit 2; }
    old=$(git -C "$D" rev-parse "$br"); new=$(git -C "$D" rev-parse "origin/$br")
    if [ "$old" != "$new" ]; then
      git -C "$D" update-ref "refs/heads/$br" "$new" "$old" && git -C "$D" reset -q || { echo "$name: could not move $br"; exit 2; }
    fi
    printf '%s: %s at %s (was %s); %s lines of status\n' "$name" "$br" "$(git -C "$D" rev-parse --short "$br")" "${old:0:7}" "$(git -C "$D" status --porcelain | wc -l)"
    ;;
  undo)
    [ -d "$D/.git" ] || { echo "$name: no .git to move out"; exit 2; }
    [ ! -e "$G" ] || { echo "$name: $G is in the way"; exit 2; }
    mkdir -p "$S/gitdirs" && mv -T -- "$D/.git" "$G" && git --git-dir="$G" config core.bare true && echo "$name: .git moved back out to $G; the tree is untouched"
    ;;
  *) echo "usage: clone-in-place.sh check|apply|undo <name> …" >&2; exit 22 ;;
esac
