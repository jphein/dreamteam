#!/usr/bin/env bash
# dreamteam tests — scripts/clone-in-place.sh: fake HOME, a local bare "origin", a stub syncthing. Touches nothing real.
set -uo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)/scripts/clone-in-place.sh"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }; bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
       GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME/Projects" "$TMP/bin"
# stub syncthing: prints {"paused": <value of $TMP/paused>}
cat > "$TMP/bin/syncthing" <<EOF
#!/bin/sh
printf '{"paused": %s}\n' "\$(cat "$TMP/paused")"
EOF
chmod +x "$TMP/bin/syncthing"; export PATH="$TMP/bin:$PATH"; echo false > "$TMP/paused"
q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
# origin with two commits on main
q init "$TMP/src"; printf 'node_modules/\nscratch/\n' > "$TMP/src/.gitignore"; echo one > "$TMP/src/a.txt"; mkdir "$TMP/src/sub"; echo s > "$TMP/src/sub/s.txt"
q -C "$TMP/src" add .; q -C "$TMP/src" commit -m one; echo two >> "$TMP/src/a.txt"; q -C "$TMP/src" commit -am two
q clone --bare "$TMP/src" "$TMP/origin.git"
q -C "$TMP/origin.git" bundle create "$TMP/main.bundle" main
# the "synced tree": origin's files, no .git, plus one edit, one untracked file, an ignored scratch dir
P="$HOME/Projects/proj"; mkdir -p "$P"; (cd "$TMP/src" && git archive main) | tar -x -C "$P"
echo edited > "$P/sub/s.txt"; echo new > "$P/notes.md"; mkdir -p "$P/scratch"; echo r > "$P/scratch/report.md"
snap() { (cd "$P" && find . -path ./.git -prune -o -type f -printf '%p %s %T@\n' | sort | sha256sum); }
before=$(snap)

out=$(bash "$S" check proj "$TMP/origin.git" main); rc=$?
[ "$rc" = 0 ] && case "$out" in "proj: origin/main "*" · 1 differing tracked, 1 untracked") true ;; *) false ;; esac && ok "check: 1 differing, 1 untracked (ignored scratch not listed)" || bad "check: rc=$rc '$out'"
[ "$(snap)" = "$before" ] && [ ! -e "$P/.git" ] && ok "check writes nothing into the tree" || bad "check changed the tree"
out=$(bash "$S" check proj https://example.invalid/none.git main "$TMP/main.bundle")
case "$out" in *"1 differing tracked, 1 untracked") ok "check from a bundle gives the same answer" ;; *) bad "bundle check: '$out'" ;; esac
[ "$(git --git-dir="$HOME/.local/state/sync-phase1/gitdirs/proj.git" remote get-url origin)" = https://example.invalid/none.git ] && ok "origin URL is the real remote, not the bundle" || bad "origin url"

bash "$S" apply proj >/dev/null 2>&1; [ $? = 2 ] && [ ! -e "$P/.git" ] && ok "apply refuses while the folder is not paused" || bad "apply ran unpaused"
echo true > "$TMP/paused"
echo later > "$P/later.txt"
bash "$S" apply proj >/dev/null 2>&1; [ $? = 2 ] && [ ! -e "$P/.git" ] && ok "apply refuses when the tree changed since the check" || bad "apply ignored a changed tree"
rm "$P/later.txt"; before=$(snap)
out=$(bash "$S" apply proj); rc=$?
[ "$rc" = 0 ] && [ -d "$P/.git" ] && case "$out" in *"same as the check: yes)") true ;; *) false ;; esac && ok "apply: .git in place, status as checked" || bad "apply: rc=$rc '$out'"
[ "$(snap)" = "$before" ] && ok "apply changed no file of the tree" || bad "apply changed the tree"
[ "$(git -C "$P" status --porcelain | sort | tr '\n' '|')" = " M sub/s.txt|?? notes.md|" ] && ok "git status in the clone is true" || bad "status: $(git -C "$P" status --porcelain | tr '\n' '|')"
[ "$(git -C "$P" rev-parse HEAD)" = "$(git -C "$TMP/src" rev-parse main)" ] && [ "$(git -C "$P" rev-parse --abbrev-ref '@{u}')" = origin/main ] && ok "HEAD is origin's main and tracks it" || bad "HEAD/upstream"
[ "$(git -C "$P" log --oneline | wc -l)" = 2 ] && ok "history is there" || bad "history"
bash "$S" check proj x main >/dev/null 2>&1; [ $? = 2 ] && ok "check refuses a dir that already has a .git" || bad "check over an existing .git"
out=$(bash "$S" undo proj); [ ! -e "$P/.git" ] && [ "$(snap)" = "$before" ] && ok "undo: .git out, tree untouched" || bad "undo: '$out'"
bash "$S" apply proj >/dev/null && [ -d "$P/.git" ] && ok "apply works again after undo" || bad "re-apply"
bash "$S" check ../x u b >/dev/null 2>&1; [ $? = 22 ] && ok "a name with a slash is refused" || bad "slash name"

# --- freshen: only stale and absent files move to HEAD; edits and untracked files stay -------------------------
echo one > "$P/a.txt"                       # a.txt at its FIRST commit's content = stale
rm "$P/.gitignore"                          # absent on this host
echo false > "$TMP/paused"
bash "$S" freshen proj >/dev/null 2>&1; [ $? = 2 ] && [ "$(cat "$P/a.txt")" = one ] && ok "freshen refuses while the folder is not paused" || bad "freshen ran unpaused"
echo true > "$TMP/paused"
out=$(bash "$S" freshen proj); rc=$?
case "$out" in "proj: freshened 2 files (1 stale, 1 absent); 1 differing files left as they are; status lines now 2; backup "*) ok "freshen: 1 stale + 1 absent updated, the edit counted and left" ;; *) bad "freshen: rc=$rc '$out'" ;; esac
[ "$(cat "$P/a.txt")" = "$(printf 'one\ntwo')" ] && [ -f "$P/.gitignore" ] && ok "the stale file is at HEAD and the absent one is back" || bad "freshen result"
[ "$(cat "$P/sub/s.txt")" = edited ] && [ "$(cat "$P/notes.md")" = new ] && [ "$(cat "$P/scratch/report.md")" = r ] && ok "the real edit, the untracked file and scratch are untouched" || bad "freshen touched an edit or untracked file"
tarf=$(sed -E 's/.*backup //' <<< "$out")
[ "$(tar -xOf "$tarf" a.txt)" = one ] && [ "$(tar -tf "$tarf" | wc -l)" = 1 ] && ok "the tar holds the stale file's old bytes, and only that" || bad "pre-freshen tar"
out=$(bash "$S" freshen proj)
case "$out" in "proj: nothing stale or absent; 1 differing files left as they are") ok "a second freshen has nothing to do" ;; *) bad "second freshen: '$out'" ;; esac

# --- freshen never checks out a tracked path that lies behind a linked directory (serialhub memorypalace, 11-18) --
mkdir -p "$TMP/sharedsub"; cp "$P/sub/s.txt" "$TMP/sharedsub/s.txt"; mv "$P/sub" "$P/sub.local"; ln -s "$TMP/sharedsub" "$P/sub"
rm "$P/a.txt"                                  # one ordinary absent file, so freshen has work to do
out=$(bash "$S" freshen proj)
[ -L "$P/sub" ] && ok "the linked directory is still a link after freshen" || bad "freshen replaced the linked directory"
grep -q "1 tracked paths lie behind a linked directory; left alone" <<< "$out" && [ -f "$P/a.txt" ] && ok "it says so, and still restores the ordinary absent file" || bad "freshen behind a link: '$out'"
rm "$P/sub"; mv "$P/sub.local" "$P/sub"

# --- sync: after an API commit, the branch moves to origin's head and no file is written -----------------------
git -C "$P" remote set-url origin "$TMP/origin.git"
q clone "$TMP/origin.git" "$TMP/w"; echo edited > "$TMP/w/sub/s.txt"; echo up > "$TMP/w/up.txt"
q -C "$TMP/w" add .; q -C "$TMP/w" commit -m three; q -C "$TMP/w" push origin main      # "the API commit": s.txt as the lane has it
before=$(snap)
out=$(bash "$S" sync proj); rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$P" rev-parse main)" = "$(git -C "$TMP/w" rev-parse main)" ] && ok "sync: the branch is at origin's new head" || bad "sync: rc=$rc '$out'"
[ "$(snap)" = "$before" ] && ok "sync writes no file of the tree" || bad "sync changed the tree"
st=$(git -C "$P" status --porcelain | sort | tr '\n' '|')
[ "$st" = " D up.txt|?? notes.md|" ] && ok "the shipped edit no longer shows as modified; a file new on origin shows as absent" || bad "status after sync: $st"
echo local > "$P/l.txt"; q -C "$P" add l.txt; q -C "$P" commit -m local
bash "$S" sync proj >/dev/null 2>&1; [ $? = 2 ] && ok "sync refuses when the branch has commits origin lacks" || bad "sync moved a branch with local commits"

# --- the seams for a tree outside ~/Projects (phase 2: ~/.claude) ---------------------------------------------
C="$HOME/dotclaude"; mkdir -p "$C"; (cd "$TMP/src" && git archive main) | tar -x -C "$C"
mkdir -p "$C/projects/p/memory"; echo m > "$C/projects/p/memory/note.md"
q -C "$TMP/w" pull origin main; mkdir -p "$TMP/w/projects/p/memory"; echo tracked-mem > "$TMP/w/projects/p/memory/t.md"; echo hook2 >> "$TMP/w/a.txt"
q -C "$TMP/w" add .; q -C "$TMP/w" commit -m four; q -C "$TMP/w" push origin main
echo old-mem > "$C/projects/p/memory/t.md"                 # a tracked memory file with other bytes: another mechanism's
echo false > "$TMP/paused"
E() { CLONE_DIR="$C" CLONE_SYNC_FOLDER=none CLONE_SKIP_PREFIXES="projects/" bash "$S" "$@"; }
out=$(E check claude "$TMP/origin.git" main); rc=$?
[ "$rc" = 0 ] && ok "CLONE_DIR: check works on a directory outside ~/Projects" || bad "CLONE_DIR check: rc=$rc '$out'"
out=$(E classify claude)
grep -q "1 differing paths under the skip prefixes, not judged" <<< "$out" && ok "classify counts paths under a skip prefix apart" || bad "classify skip: '$out'"
E apply claude >/dev/null 2>&1; [ $? = 0 ] && [ -d "$C/.git" ] && ok "CLONE_SYNC_FOLDER=none: apply needs no paused folder" || bad "apply with folder none"
out=$(E freshen claude)
[ "$(cat "$C/projects/p/memory/t.md")" = old-mem ] && grep -q "under the skip prefixes; left alone" <<< "$out" && ok "freshen never checks out a path under a skip prefix" || bad "freshen wrote under a skip prefix: '$out'"
grep -q hook2 "$C/a.txt" && ok "and still updates a stale file outside the prefix" || bad "freshen did not update a.txt: '$out'"
CLONE_DIR="relative/dir" bash "$S" check x u b >/dev/null 2>&1; [ $? = 22 ] && ok "a relative CLONE_DIR is refused" || bad "relative CLONE_DIR"
CLONE_SYNC_FOLDER='a;b' bash "$S" check proj u b >/dev/null 2>&1; [ $? = 22 ] && ok "a folder id with odd characters is refused" || bad "odd folder id"

echo "----"; echo "clone-in-place: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
