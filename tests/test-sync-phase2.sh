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

# ================= config-pull =================================================================================
q init "$TMP/w"; mkdir -p "$TMP/w/hooks" "$TMP/w/projects/p/memory"
echo v1 > "$TMP/w/hooks/a.sh"; echo keep > "$TMP/w/settings.json"; echo mem1 > "$TMP/w/projects/p/memory/m.md"
q -C "$TMP/w" add .; q -C "$TMP/w" commit -m one
q clone --bare "$TMP/w" "$TMP/origin.git"; q -C "$TMP/w" remote add origin "$TMP/origin.git"
C="$HOME/.claude"; q clone "$TMP/origin.git" "$C"
LINE="$TMP/checks/config-pull.line"

out=$(bash "$CP"); rc=$?
[ "$rc" = 0 ] && [[ "$out" =~ ^CHECK\ config-pull\ ok\ ·\ main\ at\ [0-9a-f]+,\ 0\ files\ updated\ ·\ every\ 10\ min,\ owner\ Sen$ ]] && ok "nothing new: ok line, exact shape" || bad "nothing new: rc=$rc '$out'"
[ "$(cat "$LINE")" = "$out" ] && ok "line published" || bad "line not published"

# origin moves: a hook changes, a new file appears, a tracked memory file changes
echo v2 > "$TMP/w/hooks/a.sh"; echo new > "$TMP/w/hooks/b.sh"; echo mem2 > "$TMP/w/projects/p/memory/m.md"
q -C "$TMP/w" commit -am two; q -C "$TMP/w" add .; q -C "$TMP/w" commit -m three; q -C "$TMP/w" push origin main
echo local-note > "$C/untracked.txt"; echo "my edit" > "$C/settings.json"          # a real local edit and an untracked file
out=$(bash "$CP")
case "$out" in "CHECK config-pull warn · main at "*", 2 files updated, 1 local edits left alone · "*) ok "origin moved: 2 files updated, the local edit counted and left" ;; *) bad "origin moved: '$out'" ;; esac
[ "$(cat "$C/hooks/a.sh")" = v2 ] && [ "$(cat "$C/hooks/b.sh")" = new ] && ok "the changed hook and the new hook are live" || bad "hooks not updated"
[ "$(cat "$C/settings.json")" = "my edit" ] && [ "$(cat "$C/untracked.txt")" = local-note ] && ok "the local edit and the untracked file are untouched" || bad "a local file was changed"
[ "$(cat "$C/projects/p/memory/m.md")" = mem1 ] && ok "nothing under projects/ is written (another mechanism's)" || bad "a file under projects/ was written"
[ "$(git -C "$C" rev-parse HEAD)" = "$(git -C "$TMP/w" rev-parse HEAD)" ] && ok "the branch is at origin's head" || bad "branch not moved"
ls "$TMP/clonestate"/claude.pre-freshen-*.tar >/dev/null 2>&1 && [ "$(tar -xOf "$(ls "$TMP/clonestate"/claude.pre-freshen-*.tar | head -1)" hooks/a.sh)" = v1 ] && ok "the replaced file's old bytes are in a tar" || bad "no pre-update tar"
[ "$(awk -F' · ' '{print NF}' <<< "$out")" = 3 ] && ok "the line is three segments" || bad "segments"
out=$(bash "$CP"); case "$out" in "CHECK config-pull warn · main at "*", 0 files updated, 1 local edits left alone · "*) ok "a second pass updates nothing and still names the edit" ;; *) bad "second pass: '$out'" ;; esac
git -C "$C" checkout -q HEAD -- settings.json
out=$(bash "$CP"); case "$out" in "CHECK config-pull ok · "*) ok "edit gone: back to ok" ;; *) bad "after the edit is gone: '$out'" ;; esac

# unknown is never ok
git -C "$C" remote set-url origin "$TMP/nowhere.git"
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · sync did not work: fetch did not work · "*) ok "origin unreachable: fail" ;; *) bad "unreachable origin: '$out'" ;; esac
git -C "$C" remote set-url origin "$TMP/origin.git"
echo x > "$C/local.txt"; q -C "$C" add local.txt; q -C "$C" commit -m local
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · sync did not work: 1 local commits are not on origin; nothing done · "*) ok "a local commit origin lacks: fail, branch not moved" ;; *) bad "local commit: '$out'" ;; esac
q -C "$C" reset --hard origin/main
out=$(CONFIG_PULL_DIR="$TMP/notaclone" bash "$CP"); case "$out" in "CHECK config-pull fail · "*"is not a git clone · "*) ok "not a clone: fail" ;; *) bad "not a clone: '$out'" ;; esac
out=$(CONFIG_PULL_DIR="relative" bash "$CP"); case "$out" in "CHECK config-pull fail · CONFIG_PULL_DIR is not absolute · "*) ok "relative dir: fail" ;; *) bad "relative dir: '$out'" ;; esac
( exec 9>> "$XDG_STATE_HOME/dreamteam/config-pull.claude.lock"; flock -n 9 || exit 9; cp "$LINE" "$TMP/l.before"; bash "$CP" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && cmp -s "$LINE" "$TMP/l.before" && ok "lock held elsewhere: exit 75, line untouched" || bad "lock: rc=$(cat "$TMP/rc")"
rm -f "$XDG_STATE_HOME/dreamteam/config-pull.claude.lock"; ln -s "$TMP/locktarget" "$XDG_STATE_HOME/dreamteam/config-pull.claude.lock"
out=$(bash "$CP"); case "$out" in "CHECK config-pull fail · lock file is a symlink"*) [ ! -e "$TMP/locktarget" ] && ok "a symlinked lock is refused and its target never created" || bad "lock target created" ;; *) bad "symlink lock: '$out'" ;; esac
rm -f "$XDG_STATE_HOME/dreamteam/config-pull.claude.lock"
bash "$CP" extra >/dev/null 2>&1; [ $? = 22 ] && ok "an argument: exit 22" || bad "argument rc"
out=$(DREAMTEAM_CHECK_HOST=Katana bash "$CP"); case "$out" in "CHECK config-pull-katana ok · "*) ok "off familiar the name carries the host" ;; *) bad "host suffix: '$out'" ;; esac

# a freshen that prints no RESULT line is not "0 files updated"
mkdir -p "$TMP/fakeroot/scripts/lib"; cp "$ROOT/scripts/lib/check-line.sh" "$TMP/fakeroot/scripts/lib/"; cp "$CP" "$TMP/fakeroot/scripts/"
printf '#!/bin/sh\ncase "$1" in sync) echo "claude: main at abc (was abc); 0 lines of status" ;; freshen) echo "claude: nothing stale or absent" ;; esac\n' > "$TMP/fakeroot/scripts/clone-in-place.sh"
out=$(CLAUDE_PLUGIN_ROOT="$TMP/fakeroot" bash "$TMP/fakeroot/scripts/config-pull.sh")
case "$out" in "CHECK config-pull fail · the update step gave no result line · "*) ok "no RESULT line from the update step: fail, never '0 files updated'" ;; *) bad "missing RESULT: '$out'" ;; esac

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
printf '%s\n' "$DEST" > "$ST/transcripts-push.dest"
( exec 9>> "$ST/transcripts-push.lock"; flock -n 9 || exit 9; bash "$TP" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && ok "lock held elsewhere: exit 75" || bad "transcripts lock rc=$(cat "$TMP/rc")"
rm -f "$ST/transcripts-push.lock"; ln -s "$TMP/tlock-target" "$ST/transcripts-push.lock"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · cannot take the lock"*) [ ! -e "$TMP/tlock-target" ] && ok "a symlinked lock is refused and its target never created" || bad "lock target created" ;; *) bad "symlink lock: '$out'" ;; esac
rm -f "$ST/transcripts-push.lock"
bash "$TP" nope >/dev/null 2>&1; [ $? = 22 ] && ok "unknown argument: exit 22" || bad "argument rc"

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
