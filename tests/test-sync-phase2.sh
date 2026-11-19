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

# ================= transcripts-push ============================================================================
SRC="$TMP/src"; DEST="$TMP/share/transcripts/hostA"; mkdir -p "$SRC/projA/sess1/subagents" "$SRC/projA/memory" "$SRC/projB" "$TMP/share"
export TRANSCRIPTS_SRC="$SRC" TRANSCRIPTS_MOUNT=""
echo old > "$SRC/projA/old.jsonl"; touch -d '2 hours ago' "$SRC/projA/old.jsonl"
TL="$TMP/checks/transcripts-push.line"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · not initialised (run --init <dest> once) · "*) ok "before --init: fail, nothing sent" ;; *) bad "uninitialised: '$out'" ;; esac
bash "$TP" --init "relative/dir" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses a relative destination" || bad "relative dest"
bash "$TP" --init "/a b" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses a destination with a space" || bad "space dest"
bash "$TP" --init "-x:/abs" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses a host part that starts like an option" || bad "option-like host"
bash "$TP" --init "host:relative" >/dev/null 2>&1; [ $? = 22 ] && ok "--init refuses a remote path that is not absolute" || bad "relative remote path"
bash "$TP" --init "$DEST" >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$XDG_STATE_HOME/dreamteam/transcripts-push.dest")" = "$DEST" ] && ok "--init records the destination and sets the cut" || bad "--init rc=$rc"
bash "$TP" --init "$DEST" >/dev/null 2>&1; [ $? = 22 ] && ok "a second --init is refused (the cut is not moved by accident)" || bad "second init"
sleep 1.1
echo new1 > "$SRC/projA/s1.jsonl"; echo sub > "$SRC/projA/sess1/subagents/agent.jsonl"; echo new2 > "$SRC/projB/s2.jsonl"
echo memory > "$SRC/projA/memory/MEMORY.md"; echo notes > "$SRC/projB/notes.txt"
out=$(bash "$TP"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "CHECK transcripts-push ok · 3 transcripts current at $DEST · every 10 min, owner Sen" ] && ok "3 new transcripts sent: ok line, exact shape" || bad "first pass: rc=$rc '$out'"
[ "$(cat "$DEST/projA/s1.jsonl")" = new1 ] && [ "$(cat "$DEST/projA/sess1/subagents/agent.jsonl")" = sub ] && [ "$(cat "$DEST/projB/s2.jsonl")" = new2 ] && ok "paths below the source are kept (a subagent file too)" || bad "copied files"
[ ! -e "$DEST/projA/old.jsonl" ] && ok "a transcript older than the cut is not sent" || bad "old transcript sent"
[ ! -e "$DEST/projA/memory" ] && [ ! -e "$DEST/projB/notes.txt" ] && ok "memory and non-jsonl files are not sent" || bad "non-transcript sent"
echo more >> "$SRC/projA/s1.jsonl"; bash "$TP" >/dev/null
[ "$(cat "$DEST/projA/s1.jsonl")" = "$(printf 'new1\nmore')" ] && ok "a transcript that grew is updated on the next pass" || bad "growth not copied"
echo extra > "$DEST/projB/only-at-dest.jsonl"; rm "$SRC/projB/s2.jsonl"; bash "$TP" >/dev/null
[ -f "$DEST/projB/only-at-dest.jsonl" ] && [ -f "$DEST/projB/s2.jsonl" ] && ok "nothing is ever removed at the destination" || bad "a destination file was removed"
mv "$DEST" "$TMP/hostA.away"; chmod 555 "$TMP/share/transcripts"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · destination $DEST unreachable or not writable · "*) ok "destination unreachable: fail, not ok" ;; *) [ "$(id -u)" = 0 ] && ok "unreachable destination: skipped as root" || bad "unreachable: '$out'" ;; esac
chmod 755 "$TMP/share/transcripts"; mv "$TMP/hostA.away" "$DEST"
out=$(TRANSCRIPTS_MOUNT="$TMP/share" bash "$TP"); case "$out" in "CHECK transcripts-push fail · $TMP/share is not mounted · "*) ok "the share's mount point not mounted: fail (files never land in a plain local dir)" ;; *) bad "unmounted share: '$out'" ;; esac
printf '#!/bin/sh\nexit 0\n' > "$TMP/mp"; chmod +x "$TMP/mp"
out=$(TRANSCRIPTS_MOUNT="$TMP/share" TRANSCRIPTS_MOUNTPOINT_CMD="$TMP/mp" bash "$TP"); case "$out" in "CHECK transcripts-push ok · "*) ok "mounted share: ok" ;; *) bad "mounted share: '$out'" ;; esac
out=$(TRANSCRIPTS_SRC="$TMP/absent" bash "$TP"); case "$out" in "CHECK transcripts-push fail · source "*" unreadable or absent · "*) ok "source absent: fail" ;; *) bad "absent source: '$out'" ;; esac
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 12\n' > "$TMP/bin/rsync"; chmod +x "$TMP/bin/rsync"; echo z > "$SRC/projA/z.jsonl"
out=$(PATH="$TMP/bin:$PATH" bash "$TP"); case "$out" in "CHECK transcripts-push fail · rsync exit 12 to $DEST ("*) ok "an rsync that does not work: fail with its exit code" ;; *) bad "rsync failure: '$out'" ;; esac
printf '#!/bin/sh\nexit 24\n' > "$TMP/bin/rsync"
out=$(PATH="$TMP/bin:$PATH" bash "$TP"); case "$out" in "CHECK transcripts-push ok · "*) ok "rsync 24 (a file vanished mid-pass) is not a failure" ;; *) bad "rsync 24: '$out'" ;; esac
printf 'bad dest\n' > "$XDG_STATE_HOME/dreamteam/transcripts-push.dest"
out=$(bash "$TP"); case "$out" in "CHECK transcripts-push fail · the recorded destination is not valid · "*) ok "a tampered destination file: fail" ;; *) bad "bad recorded dest: '$out'" ;; esac
printf '%s\n' "$DEST" > "$XDG_STATE_HOME/dreamteam/transcripts-push.dest"
( exec 9>> "$XDG_STATE_HOME/dreamteam/transcripts-push.lock"; flock -n 9 || exit 9; bash "$TP" 9>&- >/dev/null 2>&1; echo $? > "$TMP/rc" )
[ "$(cat "$TMP/rc")" = 75 ] && ok "lock held elsewhere: exit 75" || bad "transcripts lock rc=$(cat "$TMP/rc")"
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
