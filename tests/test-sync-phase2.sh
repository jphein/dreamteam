#!/usr/bin/env bash
# dreamteam tests — scripts/config-pull.sh and scripts/transcripts-push.sh (sync replacement, phase 2).
# Everything lives in one temp dir: a fake HOME, a local bare "origin", local destinations. No network, no real ~/.claude.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CP="$ROOT/scripts/config-pull.sh"; TP="$ROOT/scripts/transcripts-push.sh"
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf -- "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" DREAMTEAM_CHECKS_DIR="$TMP/checks" DREAMTEAM_CHECK_HOST=familiar \
       CLAUDE_PLUGIN_ROOT="$ROOT" CLONE_STATE="$TMP/clonestate" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
       GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME"
q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# ================= config-pull (deploy from a pristine clone) ===================================================
q init "$TMP/w"; mkdir -p "$TMP/w/hooks" "$TMP/w/projects/p/memory"
echo v1 > "$TMP/w/hooks/a.sh"; chmod +x "$TMP/w/hooks/a.sh"; echo keep > "$TMP/w/settings.json"; echo mem1 > "$TMP/w/projects/p/memory/m.md"
q -C "$TMP/w" add hooks/a.sh settings.json projects/p/memory/m.md; q -C "$TMP/w" commit -m one
q clone --bare "$TMP/w" "$TMP/origin.git"; q -C "$TMP/w" remote add origin "$TMP/origin.git"
C="$HOME/.claude"; mkdir -p "$C/hooks" "$C/projects/p/memory"            # a live dir that is NOT a clone
echo v1 > "$C/hooks/a.sh"; echo keep > "$C/settings.json"
echo "live memory" > "$C/projects/p/memory/m.md"; echo t > "$C/projects/p/sess.jsonl"; echo mine > "$C/untracked.txt"
LINE="$TMP/checks/config-pull.line"
psum() { (cd "$C" && find projects untracked.txt -type f -exec sha256sum {} + | sort | sha256sum); }
before=$(psum)

out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · not initialised (run config-pull.sh --init <url> once) · "*) ok "before --init: fail" ;; *) bad "no init: '$out'" ;; esac
bash "$CP" --init "$TMP/nowhere.git" >/dev/null 2>&1; [ $? = 2 ] && ok "--init with an unreachable url: exit 2" || bad "init bad url"
bash "$CP" --init "-x" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses a url that starts like an option" || bad "init option url"
bash "$CP" --init "$TMP/origin.git" "bad;branch" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses an odd branch name" || bad "init odd branch"
out=$(bash "$CP" --init "$TMP/origin.git"); rc=$?
[ "$rc" = 0 ] && grep -q "nothing was written into" <<< "$out" && [ ! -e "$C/.git" ] && ok "--init makes the pristine clone outside the live dir (no .git in it)" || bad "init: rc=$rc '$out'"
bash "$CP" --init "$TMP/origin.git" >/dev/null 2>&1; [ $? = 2 ] && ok "a second --init is refused" || bad "second init"

out=$(bash "$CP"); rc=$?
[ "$rc" = 0 ] && [[ "$out" =~ ^CHECK\ config-pull\ ok\ ·\ main\ at\ [0-9a-f]+,\ 0\ files\ updated,\ all\ 2\ current\ ·\ every\ 10\ min,\ owner\ Sen$ ]] && ok "nothing to do: ok line, exact shape (2 files tracked outside projects/)" || bad "nothing new: rc=$rc '$out'"
[ "$(cat "$LINE")" = "$out" ] && ok "line published" || bad "line not published"
[ -x "$C/hooks/a.sh" ] && ok "the executable bit follows the repo" || bad "exec bit"

# origin moves
echo v2 > "$TMP/w/hooks/a.sh"; echo new > "$TMP/w/hooks/b.sh"; echo mem2 > "$TMP/w/projects/p/memory/m.md"
q -C "$TMP/w" add hooks/a.sh hooks/b.sh projects/p/memory/m.md; q -C "$TMP/w" commit -m two; q -C "$TMP/w" push origin main
out=$(bash "$CP")
case "$out" in "CHECK config-pull ok · main at "*", 2 files updated, all 3 current · "*) ok "origin moved: a changed file and a new file are deployed" ;; *) bad "origin moved: '$out'" ;; esac
[ "$(cat "$C/hooks/a.sh")" = v2 ] && [ "$(cat "$C/hooks/b.sh")" = new ] && ok "both hooks are live" || bad "hooks not updated"
[ "$(psum)" = "$before" ] && ok "nothing under projects/ and no untracked file was touched" || bad "projects/ or an untracked file changed"
bk=$(find "$XDG_STATE_HOME/dreamteam/config-pull" -path '*/backup/*' -name a.sh | head -1)
[ -n "$bk" ] && [ "$(cat "$bk")" = v1 ] && ok "the replaced file's previous bytes are in the backup dir" || bad "no backup of the replaced file"
[ "$(awk -F' · ' '{print NF}' <<< "$out")" = 3 ] && ok "the line is three segments" || bad "segments"

# a real local edit is never replaced; other files still deploy
echo "my edit" > "$C/hooks/a.sh"
echo v3 > "$TMP/w/hooks/a.sh"; echo new3 > "$TMP/w/hooks/b.sh"; q -C "$TMP/w" commit -am three; q -C "$TMP/w" push origin main
out=$(bash "$CP")
case "$out" in "CHECK config-pull warn · main at "*", 1 files updated, 1 local edits left alone · "*) ok "a local edit: warn; the other changed file still deploys" ;; *) bad "local edit: '$out'" ;; esac
[ "$(cat "$C/hooks/a.sh")" = "my edit" ] && [ "$(cat "$C/hooks/b.sh")" = new3 ] && ok "the edit is kept byte for byte" || bad "edit overwritten"
out=$(bash "$CP"); case "$out" in "CHECK config-pull warn · "*", 0 files updated, 1 local edits left alone · "*) ok "it stays a warn on every pass until someone deals with it" ;; *) bad "second pass: '$out'" ;; esac
# bytes equal to ANOTHER path's version are not "an older version of this path"
cp "$C/settings.json" "$C/hooks/a.sh"
bash "$CP" >/dev/null; [ "$(cat "$C/hooks/a.sh")" = keep ] && ok "content matching another path's blob is a local edit, never replaced" || bad "cross-path bytes replaced"
# an OLDER committed version of the same path is replaced (nothing can be lost: git has it)
echo v1 > "$C/hooks/a.sh"
out=$(bash "$CP"); [ "$(cat "$C/hooks/a.sh")" = v3 ] && case "$out" in "CHECK config-pull ok · "*) true ;; *) false ;; esac && ok "a stale file (an older committed version of that path) is brought to the head" || bad "stale file: '$out'"
# an owner's file where the repo starts tracking a path: kept unless its bytes are a committed version of that path
echo "owner's own" > "$C/hooks/c.sh"; echo upstream-c > "$TMP/w/hooks/c.sh"; q -C "$TMP/w" add hooks/c.sh; q -C "$TMP/w" commit -m four; q -C "$TMP/w" push origin main
out=$(bash "$CP")
[ "$(cat "$C/hooks/c.sh")" = "owner's own" ] && case "$out" in "CHECK config-pull warn · "*"1 local edits left alone"*) true ;; *) false ;; esac && ok "an existing file at a newly tracked path is kept" || bad "owner file at a new path: '$out' $(cat "$C/hooks/c.sh")"
rm -f "$C/hooks/c.sh"; bash "$CP" >/dev/null; [ "$(cat "$C/hooks/c.sh")" = upstream-c ] && ok "an absent tracked file is created" || bad "absent file not created"
# symlinks and odd types are never written through
rm -f "$C/hooks/b.sh"; echo target > "$TMP/elsewhere.txt"; ln -s "$TMP/elsewhere.txt" "$C/hooks/b.sh"
out=$(bash "$CP"); [ "$(cat "$TMP/elsewhere.txt")" = target ] && [ -L "$C/hooks/b.sh" ] && case "$out" in *"1 local edits left alone"*) true ;; *) false ;; esac && ok "a symlink at a tracked path is left alone and not written through" || bad "symlink path: '$out'"
rm -f "$C/hooks/b.sh"; mv "$C/hooks" "$C/hooks.real"; mkdir -p "$TMP/linkedhooks"; ln -s "$TMP/linkedhooks" "$C/hooks"
out=$(bash "$CP"); [ -z "$(ls -A "$TMP/linkedhooks")" ] && case "$out" in *"3 local edits left alone"*) true ;; *) false ;; esac && ok "nothing is written behind a symlinked directory" || bad "linked dir: '$out' $(ls -A "$TMP/linkedhooks")"
rm -f "$C/hooks"; mv "$C/hooks.real" "$C/hooks"; bash "$CP" >/dev/null
# ---- races, driven through the Python core with one system call wrapped (the core has no test hooks of its own) ----
stdir=$(dirname "$(find "$XDG_STATE_HOME/dreamteam/config-pull" -maxdepth 2 -name repo.git)")
HEADSHA=$(git --git-dir="$stdir/repo.git" rev-parse refs/remotes/origin/main)
cat > "$TMP/drv.py" <<'PY'
"""Run config_deploy.main with ONE os function wrapped, so a test can make something happen at an exact moment.
   drv.py <lib dir> <what> <arg> -- <config_deploy args...>"""
import os, sys
lib, what, arg = sys.argv[1:4]
rest = sys.argv[sys.argv.index("--") + 1:]
sys.path.insert(0, lib)
import config_deploy as cd
live = rest[2]
real_rename, real_link = os.rename, os.link
state = {"done": False}
def rename(src, dst, **kw):
    if not state["done"] and dst == "a.sh" and str(src).startswith(".config-pull."):
        state["done"] = True
        if what == "inplace":            # an editor writes INTO the old file just before it is displaced
            with open(os.path.join(live, "hooks", "a.sh"), "w") as f: f.write(arg + "\n")
        elif what == "swap-parent":      # the parent directory is replaced by a symlink to another directory
            os.rename(os.path.join(live, "hooks"), os.path.join(live, "hooks.moved"))
            os.symlink(arg, os.path.join(live, "hooks"))
    return real_rename(src, dst, **kw)
def link(src, dst, **kw):
    if what == "appear" and dst == "c.sh" and not state["done"]:
        state["done"] = True             # the owner creates the file just before we would publish ours
        with open(os.path.join(live, "hooks", "c.sh"), "w") as f: f.write(arg + "\n")
    if what == "no-witness" and str(dst).endswith("/hooks/a.sh"):
        raise OSError(18, "Invalid cross-device link")     # the backup dir is on another filesystem
    return real_link(src, dst, **kw)
os.rename, os.link = rename, link
sys.exit(cd.main(rest))
PY
core() { python3 -I "$TMP/drv.py" "$ROOT/scripts/lib" "$1" "$2" -- "$stdir/repo.git" "$HEADSHA" "$C" "$TMP/bk-$1" "projects/"; }

# an editor writing INTO the file while it is being replaced gets its bytes back; no fixed recovery name is used
echo v1 > "$C/hooks/a.sh"; echo sentinel > "$C/hooks/a.sh.config-pull-edit"; echo outside > "$TMP/outside.txt"; ln -s "$TMP/outside.txt" "$C/hooks/a.sh.recover"
out=$(core inplace "written in place mid-replace")
grep -q "displaced=1" <<< "$out" && [ "$(cat "$TMP/bk-inplace/hooks/a.sh")" = "written in place mid-replace" ] && ok "an in-place write landing during the replace is detected; its bytes are kept in the backup dir" || bad "in-place race: $out / $(cat "$TMP/bk-inplace/hooks/a.sh" 2>&1)"
[ "$(cat "$C/hooks/a.sh")" = v3 ] && ok "nothing is put back automatically (a second rename could displace something newer)" || bad "live after displacement: $(cat "$C/hooks/a.sh")"
[ "$(cat "$C/hooks/a.sh.config-pull-edit")" = sentinel ] && [ "$(cat "$TMP/outside.txt")" = outside ] && ok "neighbour files and symlinks with fixed-looking names are untouched" || bad "a neighbour was clobbered"
rm -f "$C/hooks/a.sh.config-pull-edit" "$C/hooks/a.sh.recover"
# no hard-link witness (backup dir on another filesystem): the file is NOT replaced, even though its bytes are an old version
echo v1 > "$C/hooks/a.sh"
out=$(core no-witness x)
[ "$(cat "$C/hooks/a.sh")" = v1 ] && grep -q "updated=0 edits=1" <<< "$out" && ok "no witness link possible: the file is left alone and counted (never a copy as stand-in)" || bad "no-witness: '$(cat "$C/hooks/a.sh")' / $out"
# the parent directory swapped for a symlink just before the rename: nothing lands in the other directory
mkdir -p "$TMP/otherdir"; echo "other dir's own a.sh" > "$TMP/otherdir/a.sh"; echo v1 > "$C/hooks/a.sh"
out=$(core swap-parent "$TMP/otherdir")
[ "$(cat "$TMP/otherdir/a.sh")" = "other dir's own a.sh" ] && [ -z "$(find "$TMP/otherdir" -name '.config-pull.*')" ] && ok "a parent swapped for a symlink mid-pass cannot redirect the write: the other directory is untouched" || bad "parent swap wrote outside: $(cat "$TMP/otherdir/a.sh")"
[ "$(cat "$C/hooks.moved/a.sh")" = v3 ] && ok "the write went to the directory that was pinned (now renamed aside)" || bad "pinned dir content: $(cat "$C/hooks.moved/a.sh" 2>&1)"
rm -f "$C/hooks"; mv "$C/hooks.moved" "$C/hooks"
# a file that appears where an absent one is being created is not replaced
rm -f "$C/hooks/c.sh"
out=$(core appear "appeared just now"); [ "$(cat "$C/hooks/c.sh")" = "appeared just now" ] && ok "a file appearing at an absent path during the pass is kept (no-replace publish)" || bad "appearing file replaced: $out"
# the exec bit is set through a no-follow descriptor: a symlink swapped in at the leaf is not chmod-ed through
echo target > "$TMP/chmod-target.txt"; chmod 600 "$TMP/chmod-target.txt"; mv "$C/hooks/a.sh" "$C/hooks/a.sh.real"; ln -s "$TMP/chmod-target.txt" "$C/hooks/a.sh"
bash "$CP" >/dev/null; [ "$(stat -c %a "$TMP/chmod-target.txt")" = 600 ] && ok "a symlink at an executable tracked path: its target's mode is never changed" || bad "chmod followed a symlink: $(stat -c %a "$TMP/chmod-target.txt")"
rm -f "$C/hooks/a.sh"; mv "$C/hooks/a.sh.real" "$C/hooks/a.sh"; chmod 644 "$C/hooks/a.sh"; bash "$CP" >/dev/null
[ -x "$C/hooks/a.sh" ] && ok "a current file that lost its exec bit gets it back" || bad "exec bit not restored"
# tracked entries the job does not handle are never hidden behind an ok
ln -s a.sh "$TMP/w/hooks/link.sh"; q -C "$TMP/w" add hooks/link.sh; q -C "$TMP/w" commit -m symlink; q -C "$TMP/w" push origin main
out=$(bash "$CP"); case "$out" in "CHECK config-pull warn · "*" local edits left alone, 1 tracked entries not handled (symlinks or odd names) · "*) ok "a tracked symlink: warn naming the unhandled entry, never 'all current'" ;; *) bad "tracked symlink: '$out'" ;; esac
[ ! -e "$C/hooks/link.sh" ] && [ ! -L "$C/hooks/link.sh" ] && ok "and the symlink is not created in the live dir" || bad "tracked symlink was written"
q -C "$TMP/w" rm -q hooks/link.sh; q -C "$TMP/w" commit -m nosymlink; q -C "$TMP/w" push origin main; bash "$CP" >/dev/null
# a displaced edit turns the whole line to fail, naming where the bytes are
mkdir -p "$TMP/fakeroot/scripts/lib"; cp "$ROOT/scripts/lib/check-line.sh" "$TMP/fakeroot/scripts/lib/"; cp "$CP" "$TMP/fakeroot/scripts/"
printf 'print("RESULT total=4 updated=1 edits=0 skipped=0 displaced=1")\n' > "$TMP/fakeroot/scripts/lib/config_deploy.py"
out=$(CLAUDE_PLUGIN_ROOT="$TMP/fakeroot" bash "$TMP/fakeroot/scripts/config-pull.sh")
case "$out" in "CHECK config-pull fail · 1 edits displaced during the update: their bytes are kept in "*"/backup/"*) ok "a displaced edit: fail, with the backup dir in the line" ;; *) bad "displaced line: '$out'" ;; esac
printf 'print("nothing useful")\n' > "$TMP/fakeroot/scripts/lib/config_deploy.py"
out=$(CLAUDE_PLUGIN_ROOT="$TMP/fakeroot" bash "$TMP/fakeroot/scripts/config-pull.sh")
case "$out" in "CHECK config-pull fail · the deploy pass gave no result line · "*) ok "no RESULT line from the core: fail, never a count" ;; *) bad "missing RESULT: '$out'" ;; esac

# a long history: the matching old version is found although it is far from the end of git's output
for i in $(seq 1 60); do echo "rev $i" > "$TMP/w/hooks/long.sh"; q -C "$TMP/w" add hooks/long.sh; q -C "$TMP/w" commit -m "long $i"; done; q -C "$TMP/w" push origin main
echo "rev 2" > "$C/hooks/long.sh"; out=$(bash "$CP")
[ "$(cat "$C/hooks/long.sh")" = "rev 60" ] && ok "an old version deep in a 60-commit history is recognised and replaced" || bad "long history: $(cat "$C/hooks/long.sh") / $out"
[ -z "$(find "$C" -name '.config-pull.*')" ] && ok "no temp file is left in the live dir" || bad "temp files left: $(find "$C" -name '.config-pull.*' | head -2)"
rm -f "$C/hooks/c.sh"; bash "$CP" >/dev/null

# unknown is never ok
stdir=$(dirname "$(find "$XDG_STATE_HOME/dreamteam/config-pull" -maxdepth 2 -name repo.git)")
git --git-dir="$stdir/repo.git" remote set-url origin "$TMP/nowhere.git"
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · fetch did not work · "*) ok "origin unreachable: fail" ;; *) bad "unreachable origin: '$out'" ;; esac
git --git-dir="$stdir/repo.git" remote set-url origin "$TMP/origin.git"
printf 'no;such\n' > "$stdir/branch"
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · the recorded branch name is not valid · "*) ok "a tampered branch file: fail" ;; *) bad "bad branch file: '$out'" ;; esac
printf 'main\n' > "$stdir/branch"
out=$(CONFIG_PULL_DIR="$TMP/absentdir" bash "$CP"); case "$out" in "CHECK config-pull fail · "*"is not a directory · "*) ok "live dir absent: fail" ;; *) bad "absent live dir: '$out'" ;; esac
out=$(CONFIG_PULL_DIR="relative" bash "$CP"); case "$out" in "CHECK config-pull fail · CONFIG_PULL_DIR is not absolute · "*) ok "relative dir: fail" ;; *) bad "relative dir: '$out'" ;; esac
( exec 9>> "$stdir/lock"; flock -n 9 || exit 9; cp "$LINE" "$TMP/l.before"; bash "$CP" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && cmp -s "$LINE" "$TMP/l.before" && ok "lock held elsewhere: exit 75, line untouched" || bad "lock: rc=$(cat "$TMP/rc")"
rm -f "$stdir/lock"; ln -s "$TMP/locktarget" "$stdir/lock"
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · lock file is a symlink"*) [ ! -e "$TMP/locktarget" ] && ok "a symlinked lock is refused and its target never created" || bad "lock target created" ;; *) bad "symlink lock: '$out'" ;; esac
rm -f "$stdir/lock"
bash "$CP" extra >/dev/null 2>&1; [ $? = 22 ] && ok "an unknown argument: exit 22" || bad "argument rc"
out=$(DREAMTEAM_CHECK_HOST=Katana bash "$CP"); case "$out" in "CHECK config-pull-katana ok · "*) ok "off familiar the name carries the host" ;; *) bad "host suffix: '$out'" ;; esac

# ================= transcripts-push ============================================================================
SRC="$TMP/src"; SHARE="$TMP/share"; DEST="$SHARE/transcripts/hostA"; mkdir -p "$SRC/projA/sess1/subagents" "$SRC/projA/memory" "$SRC/projB" "$SHARE"
printf '#!/bin/sh\n[ -e "%s/unmounted" ] && exit 1\nexit 0\n' "$TMP" > "$TMP/mp"; chmod +x "$TMP/mp"
export TRANSCRIPTS_SRC="$SRC" TRANSCRIPTS_MOUNT="$SHARE" TRANSCRIPTS_MOUNTPOINT_CMD="$TMP/mp"
ST="$XDG_STATE_HOME/dreamteam"
echo old > "$SRC/projA/old.jsonl"; touch -d '2 hours ago' "$SRC/projA/old.jsonl"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · not initialised (run --init <dest> once) · "*) ok "before --init: fail, nothing sent" ;; *) bad "uninitialised: '$out'" ;; esac
for bad_dest in "relative/dir" "/a b" "-x:/abs" "host:relative" "/srv/../etc" "host:/a/../b" "/a//b" "/a/./b"; do
  bash "$TP" --init "$bad_dest" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses '$bad_dest'" || bad "--init accepted '$bad_dest'"
done
# state paths are never followed or replaced
ln -s "$TMP/cut-target" "$ST/transcripts-push.cut"
bash "$TP" --init "$DEST" >/dev/null 2>&1; rc=$?
[ "$rc" = 22 ] && [ ! -e "$TMP/cut-target" ] && [ ! -e "$ST/transcripts-push.dest" ] && ok "a dangling symlink at the cut path: --init refuses, creates neither its target nor the dest file" || bad "cut symlink: rc=$rc"
rm -f "$ST/transcripts-push.cut"; echo sentinel > "$TMP/dest-target"; ln -s "$TMP/dest-target" "$ST/transcripts-push.dest"
bash "$TP" --init "$DEST" >/dev/null 2>&1; rc=$?
[ "$rc" = 22 ] && [ "$(cat "$TMP/dest-target")" = sentinel ] && ok "a symlink at the dest path: --init refuses and its target is untouched" || bad "dest symlink: rc=$rc"
rm -f "$ST/transcripts-push.dest"
( exec 9>> "$ST/transcripts-push.lock"; flock -n 9 || exit 9; bash "$TP" --init "$DEST" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && [ ! -e "$ST/transcripts-push.cut" ] && ok "--init takes the same lock as a pass (held elsewhere: exit 75, nothing written)" || bad "init lock rc=$(cat "$TMP/rc")"
# a file that APPEARS at the dest path after the check is neither replaced nor removed
mkdir -p "$TMP/racebin"; REALMKTEMP="$(command -v mktemp)"
printf '#!/bin/sh\ncase "$*" in *transcripts-push.new*) [ -e "%s/transcripts-push.dest" ] || echo foreign > "%s/transcripts-push.dest" ;; esac\nexec "%s" "$@"\n' "$ST" "$ST" "$REALMKTEMP" > "$TMP/racebin/mktemp"; chmod +x "$TMP/racebin/mktemp"
PATH="$TMP/racebin:$PATH" bash "$TP" --init "$DEST" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$ST/transcripts-push.dest")" = foreign ] && [ ! -e "$ST/transcripts-push.cut" ] && ok "a dest file appearing mid-init survives untouched; no cut is set" || bad "mid-init file: rc=$rc dest=$(cat "$ST/transcripts-push.dest" 2>&1)"
rm -f "$ST/transcripts-push.dest"
# a cut that cannot be created: the dest file (possibly someone else's by now) is NOT removed
printf '#!/bin/sh\ncase "$*" in *transcripts-push.new*) if [ -e "%s/transcripts-push.dest" ]; then echo "replaced by another" > "%s/transcripts-push.dest"; mkdir -p "%s/transcripts-push.cut"; fi ;; esac\nexec "%s" "$@"\n' "$ST" "$ST" "$ST" "$REALMKTEMP" > "$TMP/racebin/mktemp"
PATH="$TMP/racebin:$PATH" bash "$TP" --init "$DEST" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$ST/transcripts-push.dest")" = "replaced by another" ] && [ -d "$ST/transcripts-push.cut" ] && ok "cut blocked after the dest was published and replaced: both foreign paths survive" || bad "rollback: rc=$rc dest=$(cat "$ST/transcripts-push.dest" 2>&1)"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · not initialised"*) ok "a destination without a cut is 'not initialised' to a pass" ;; *) bad "partial init: '$out'" ;; esac
rm -f "$ST/transcripts-push.dest"; rmdir "$ST/transcripts-push.cut"
# the two settings that reach rsync are absolute plain paths
mkdir -p "$TMP/host:"; ( cd "$TMP" && TRANSCRIPTS_SRC="host:/data" bash "$TP" --init "$DEST" >/dev/null 2>&1 ); [ $? = 22 ] && ok "a relative source that rsync would read as remote (host:/data) is refused" || bad "colon source"
out=$(TRANSCRIPTS_SRC="relative/src" bash "$TP"); case "$out" in "CHECK transcripts-push fail · TRANSCRIPTS_SRC or TRANSCRIPTS_SSH is not an absolute plain path · "*) ok "a relative source: fail on a pass" ;; *) bad "relative source: '$out'" ;; esac
mkdir -p "$TMP/bin with space"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin with space/ssh"; chmod +x "$TMP/bin with space/ssh"
out=$(TRANSCRIPTS_SSH="$TMP/bin with space/ssh" bash "$TP"); case "$out" in "CHECK transcripts-push fail · TRANSCRIPTS_SRC or TRANSCRIPTS_SSH is not an absolute plain path · "*) ok "an ssh path with a space (rsync would split it) is refused" ;; *) bad "spaced ssh: '$out'" ;; esac
TRANSCRIPTS_SSH="ssh -oProxyCommand=x" bash "$TP" --init "$DEST" >/dev/null 2>&1; [ $? = 22 ] && ok "an ssh setting carrying options is refused" || bad "ssh with options"

bash "$TP" --init "$DEST" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$ST/transcripts-push.dest")" = "$DEST" ] && [ -f "$ST/transcripts-push.cut" ] && ok "--init records the destination and sets the cut" || bad "--init rc=$rc"
bash "$TP" --init "$DEST" >/dev/null 2>&1; [ $? = 22 ] && ok "a second --init is refused (the cut is not moved by accident)" || bad "second init"
sleep 1.1
echo new1 > "$SRC/projA/s1.jsonl"; echo sub > "$SRC/projA/sess1/subagents/agent.jsonl"; echo new2 > "$SRC/projB/s2.jsonl"
echo memory > "$SRC/projA/memory/MEMORY.md"; echo notes > "$SRC/projB/notes.txt"
out=$(bash "$TP"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "CHECK transcripts-push ok · 3 transcripts changed since the cut, all sent to $DEST · every 10 min, owner Sen" ] && ok "3 new transcripts sent: ok line, exact shape" || bad "first pass: rc=$rc '$out'"
[ "$(cat "$DEST/projA/s1.jsonl")" = new1 ] && [ "$(cat "$DEST/projA/sess1/subagents/agent.jsonl")" = sub ] && [ "$(cat "$DEST/projB/s2.jsonl")" = new2 ] && ok "paths below the source are kept (a subagent file too)" || bad "copied files"
[ ! -e "$DEST/projA/old.jsonl" ] && ok "a transcript older than the cut is not sent" || bad "old transcript sent"
[ ! -e "$DEST/projA/memory" ] && [ ! -e "$DEST/projB/notes.txt" ] && ok "memory and non-jsonl files are not sent" || bad "non-transcript sent"
echo more >> "$SRC/projA/s1.jsonl"; bash "$TP" >/dev/null
[ "$(cat "$DEST/projA/s1.jsonl")" = "$(printf 'new1\nmore')" ] && ok "a transcript that grew is updated on the next pass" || bad "growth not copied"
echo extra > "$DEST/projB/only-at-dest.jsonl"; rm "$SRC/projB/s2.jsonl"; bash "$TP" >/dev/null
[ -f "$DEST/projB/only-at-dest.jsonl" ] && [ -f "$DEST/projB/s2.jsonl" ] && ok "nothing is ever removed at the destination" || bad "a destination file was removed"
# the share must really be the share
touch "$TMP/unmounted"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · $SHARE is not mounted · "*) ok "share not mounted: fail (files never land in a plain local dir)" ;; *) bad "unmounted share: '$out'" ;; esac
rm -f "$TMP/unmounted"
out=$(TRANSCRIPTS_MOUNT="$SHARE/" bash "$TP"); case "$out" in "CHECK transcripts-push ok · "*) ok "a trailing slash on the mount setting is the same mount" ;; *) bad "trailing-slash mount: '$out'" ;; esac
out=$(TRANSCRIPTS_MOUNT="" bash "$TP"); case "$out" in "CHECK transcripts-push fail · no share mount point configured for a local destination · "*) ok "no mount configured: a local destination is refused, not trusted" ;; *) bad "empty mount: '$out'" ;; esac
mkdir -p "$TMP/elsewhere"; printf '%s\n' "$TMP/elsewhere/t" > "$ST/transcripts-push.dest"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · destination $TMP/elsewhere/t is not under the share $SHARE · "*) [ ! -e "$TMP/elsewhere/t" ] && ok "a local destination outside the share: fail, nothing created there" || bad "outside dir created" ;; *) bad "outside share: '$out'" ;; esac
ln -s "$TMP/elsewhere" "$SHARE/escape"; printf '%s\n' "$SHARE/escape/t" > "$ST/transcripts-push.dest"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · destination $SHARE/escape/t is not under the share $SHARE · "*) [ ! -e "$TMP/elsewhere/t" ] && ok "a symlink inside the share that leads out of it: fail" || bad "escape dir created" ;; *) bad "symlink escape: '$out'" ;; esac
rm -f "$SHARE/escape"; printf '%s\n' "$DEST" > "$ST/transcripts-push.dest"
mv "$DEST" "$TMP/hostA.away"; chmod 555 "$SHARE/transcripts"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · destination $DEST unreachable or not writable · "*) ok "destination unreachable: fail, not ok" ;; *) [ "$(id -u)" = 0 ] && ok "unreachable destination: skipped as root" || bad "unreachable: '$out'" ;; esac
chmod 755 "$SHARE/transcripts"; mv "$TMP/hostA.away" "$DEST"
out=$(TRANSCRIPTS_SRC="$TMP/absent" bash "$TP"); case "$out" in "CHECK transcripts-push fail · source "*" unreadable or absent · "*) ok "source absent: fail" ;; *) bad "absent source: '$out'" ;; esac
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 12\n' > "$TMP/bin/rsync"; chmod +x "$TMP/bin/rsync"; echo z > "$SRC/projA/z.jsonl"
out=$(PATH="$TMP/bin:$PATH" bash "$TP"); case "$out" in "CHECK transcripts-push fail · rsync exit 12 to $DEST ("*) ok "an rsync that does not work: fail with its exit code" ;; *) bad "rsync failure: '$out'" ;; esac
printf '#!/bin/sh\nexit 24\n' > "$TMP/bin/rsync"
out=$(PATH="$TMP/bin:$PATH" bash "$TP"); case "$out" in "CHECK transcripts-push warn · "*" listed for $DEST, some vanished mid-pass (next pass retries) · "*) ok "rsync 24 (a file vanished mid-pass) is a warn that says so, never 'all sent'" ;; *) bad "rsync 24: '$out'" ;; esac
printf 'bad dest\n' > "$ST/transcripts-push.dest"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · the recorded destination is not valid · "*) ok "a tampered destination file: fail" ;; *) bad "bad recorded dest: '$out'" ;; esac
# a remote destination is probed on every pass, also with nothing to send
printf 'far:/data/t\n' > "$ST/transcripts-push.dest"
printf '#!/bin/sh\necho "$*" >> "%s/ssh.log"\n[ -e "%s/remote.down" ] && exit 255\nexit 0\n' "$TMP" "$TMP" > "$TMP/bin/fakessh"; chmod +x "$TMP/bin/fakessh"
find "$SRC" -name '*.jsonl' -exec touch -d '3 hours ago' {} +                 # nothing newer than the cut now
touch "$TMP/remote.down"
out=$(TRANSCRIPTS_SSH="$TMP/bin/fakessh" bash "$TP"); case "$out" in "CHECK transcripts-push fail · destination far:/data/t unreachable or not a writable directory · "*) ok "remote down with nothing to send: fail, not 'all sent'" ;; *) bad "remote down, empty list: '$out'" ;; esac
rm -f "$TMP/remote.down"
out=$(TRANSCRIPTS_SSH="$TMP/bin/fakessh" bash "$TP"); case "$out" in "CHECK transcripts-push ok · 0 transcripts changed since the cut, all sent to far:/data/t · "*) ok "remote up with nothing to send: ok after a real probe" ;; *) bad "remote up, empty list: '$out'" ;; esac
grep -q -- "-- far test -d /data/t -a -w /data/t" "$TMP/ssh.log" && ok "the probe asks the remote for a writable directory" || bad "probe args: $(tail -1 "$TMP/ssh.log")"
# a pass stopped while the ssh probe hangs replaces the earlier ok with fail (the trap is set before any probe)
grep -q "^CHECK transcripts-push ok" "$TMP/checks/transcripts-push.line" || bad "precondition: an earlier ok line"
printf '#!/bin/sh\nsleep 60 & echo $! > "%s/probe.pid"; wait\n' "$TMP" > "$TMP/bin/hangssh"; chmod +x "$TMP/bin/hangssh"
TRANSCRIPTS_SSH="$TMP/bin/hangssh" bash "$TP" >/dev/null 2>&1 & tpid=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$TMP/probe.pid" ] && break; sleep 0.3; done
kill -TERM "$tpid" 2>/dev/null; wait "$tpid"
case "$(cat "$TMP/checks/transcripts-push.line")" in "CHECK transcripts-push fail · stopped before it finished (timeout or signal) · "*) ok "a pass stopped during a hanging ssh probe: the earlier ok is replaced by fail" ;; *) bad "TERM during probe: $(cat "$TMP/checks/transcripts-push.line")" ;; esac
[ -f "$TMP/probe.pid" ] && kill "$(cat "$TMP/probe.pid")" 2>/dev/null
printf '%s\n' "$DEST" > "$ST/transcripts-push.dest"
( exec 9>> "$ST/transcripts-push.lock"; flock -n 9 || exit 9; bash "$TP" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && ok "lock held elsewhere: exit 75" || bad "transcripts lock rc=$(cat "$TMP/rc")"
rm -f "$ST/transcripts-push.lock"; ln -s "$TMP/tlock-target" "$ST/transcripts-push.lock"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · cannot take the lock"*) [ ! -e "$TMP/tlock-target" ] && ok "a symlinked lock is refused and its target never created" || bad "lock target created" ;; *) bad "symlink lock: '$out'" ;; esac
rm -f "$ST/transcripts-push.lock"
bash "$TP" nope >/dev/null 2>&1; [ $? = 22 ] && ok "unknown argument: exit 22" || bad "argument rc"

# ================= xreview r3 on #262: relative state root; a stopped run publishes fail ======================
for job in "$CP" "$TP"; do
  XDG_STATE_HOME="rel/state" bash "$job" >/dev/null 2>&1; [ $? = 22 ] && ok "$(basename "$job"): a relative XDG_STATE_HOME is refused" || bad "$(basename "$job") relative state"
  XDG_STATE_HOME="-x" bash "$job" >/dev/null 2>&1; [ $? = 22 ] && ok "$(basename "$job"): a dash-led XDG_STATE_HOME is refused" || bad "$(basename "$job") dash state"
done
bash "$CP" >/dev/null 2>&1; grep -q "^CHECK config-pull ok" "$LINE" || bash "$CP" >/dev/null 2>&1
mkdir -p "$TMP/slowbin"; REALGIT3="$(command -v git)"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) sleep 60 & echo $! > "%s/slow.pid"; wait ;; esac\nexec "%s" "$@"\n' "$TMP" "$REALGIT3" > "$TMP/slowbin/git"; chmod +x "$TMP/slowbin/git"
PATH="$TMP/slowbin:$PATH" bash "$CP" >/dev/null 2>&1 & pid=$!
sleep 1.5; kill -TERM "$pid" 2>/dev/null; wait "$pid"; rc=$?
case "$(cat "$LINE")" in "CHECK config-pull fail · stopped before it finished (timeout or signal) · "*) ok "config-pull stopped by TERM: the earlier ok is replaced by fail" ;; *) bad "TERM left: $(cat "$LINE") rc=$rc" ;; esac
[ -f "$TMP/slow.pid" ] && kill "$(cat "$TMP/slow.pid")" 2>/dev/null; true

# ================= units =======================================================================================
if command -v systemd-analyze >/dev/null 2>&1; then
  for u in dreamteam-config-pull dreamteam-transcripts-push; do
    v=$(SYSTEMD_UNIT_PATH="$ROOT/systemd:/usr/lib/systemd/user:/usr/lib/systemd/system" systemd-analyze --user verify "$ROOT/systemd/$u.timer" 2>&1 | grep "$u" | grep -v "is not executable\|No such file" || true)
    [ -z "$v" ] && ok "systemd-analyze has no complaint about $u" || bad "$u: $(head -2 <<< "$v")"
  done
fi
grep -q '^OnCalendar=\*:0/10$' "$ROOT/systemd/dreamteam-config-pull.timer" && grep -q '^OnCalendar=\*:5/10$' "$ROOT/systemd/dreamteam-transcripts-push.timer" && ok "both timers run every 10 minutes, five minutes apart" || bad "timer schedules"

echo "----"; echo "sync-phase2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
