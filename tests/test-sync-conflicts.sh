#!/usr/bin/env bash
# dreamteam tests — scripts/sync-conflicts-check.sh (CHECK sync-conflicts, docs/CHECKS.md).
# Fixture roots, state and checks dir all live in one temp dir; the mail command is a stub that logs its arguments.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/sync-conflicts-check.sh"
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf -- "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

A="$TMP/Projects"; B="$TMP/dotclaude"
mkdir -p "$A/repo/src" "$A/repo/.git" "$A/repo/node_modules/x" "$A/.stversions/repo" "$B/skills" "$TMP/bin"
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" DREAMTEAM_CHECKS_DIR="$TMP/checks" \
       DREAMTEAM_SYNC_ROOTS="$A:$B" DREAMTEAM_CHECK_HOST=familiar CLAUDE_PLUGIN_ROOT="$ROOT"
mkdir -p "$HOME"
cat > "$TMP/bin/mail-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/mail.log"
[ ! -e "$TMP/mail.broken" ]
EOF
chmod +x "$TMP/bin/mail-stub"
export DREAMTEAM_MAIL_CMD="$TMP/bin/mail-stub send"
LINE="$TMP/checks/sync-conflicts.line"
mails() { [ -f "$TMP/mail.log" ] && wc -l < "$TMP/mail.log" || echo 0; }

T0=1000000000; export DREAMTEAM_NOW=$T0     # a fixed clock: the mail rule is tested in whole hours
# --- 1. a clean tree is ok, and nobody is mailed -------------------------------------------------------------
echo plain > "$A/repo/src/a.txt"
out=$(bash "$S"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "CHECK sync-conflicts ok · 0 conflict copies in 2 roots · daily, owner Sen" ] \
  && ok "clean tree: ok line, exact shape" || bad "clean tree: got rc=$rc '$out'"
[ "$(cat "$LINE" 2>/dev/null)" = "$out" ] && ok "line published to the checks dir" || bad "line not published"
[ "$(mails)" = 0 ] && ok "clean tree: no mail" || bad "clean tree mailed the lead"

# --- 2. conflict copies are counted per root; pruned dirs are not ---------------------------------------------
touch "$A/repo/src/a.sync-conflict-20261116-091556-ABCDEFG.txt" "$A/repo/b.sync-conflict-20261117-101010-HIJKLMN.md" \
      "$B/skills/SKILL.sync-conflict-20260926-120000-ABCDEFG.md"
touch "$A/repo/.git/x.sync-conflict-20261117-000000-AAAAAAA" "$A/repo/node_modules/x/y.sync-conflict-20261117-000000-AAAAAAA.js" \
      "$A/.stversions/repo/z.sync-conflict-20261117-000000-AAAAAAA.txt"
out=$(bash "$S"); rc=$?
case "$out" in
  "CHECK sync-conflicts warn · 3 conflict copies (2 in $A, 1 in $B), newest 0 d old · list: "*) ok "3 copies: warn with per-root counts" ;;
  *) bad "3 copies: got '$out'" ;;
esac
[ "$rc" = 0 ] && ok "warn still exits 0 (the line was published)" || bad "warn rc=$rc"
[ "$(wc -l < "$XDG_STATE_HOME/dreamteam/sync-conflicts.list")" = 3 ] && ok "list file holds the 3 paths" || bad "list file count wrong"
grep -q -e '/\.git/' -e node_modules -e '\.stversions' "$XDG_STATE_HOME/dreamteam/sync-conflicts.list" \
  && bad "a pruned dir's copy is in the list" || ok ".git, node_modules and .stversions are pruned"
[ "$(stat -c %a "$XDG_STATE_HOME/dreamteam/sync-conflicts.list")" = 600 ] && ok "list file is 0600" || bad "list file mode"
# the fact must stay ONE segment for the Watch (no ' · ' inside it)
[ "$(awk -F' · ' '{print NF}' <<< "$out")" = 3 ] && ok "warn line is exactly three segments" || bad "warn line segments"

# --- 3. the lead is mailed only when the count RISES, and at most once an hour -------------------------------
# The clock is DREAMTEAM_NOW (T0 was set before section 1, so section 2's first warn mailed at T0).
MEM="$XDG_STATE_HOME/dreamteam/sync-conflicts.mailed"
at() { DREAMTEAM_NOW=$((T0 + $1)) bash "$S" 2>"$TMP/err"; }
[ "$(mails)" = 1 ] && ok "first non-zero count mails the lead once" || bad "mail count after first warn: $(mails)"
grep -q '^send sen CHECK sync-conflicts warn: 3 conflict copies.*(was 0, peak 3) on ' "$TMP/mail.log" && ok "mail goes to sen, carries the fact and the old count" || bad "mail text: $(cat "$TMP/mail.log")"
at 7200 >/dev/null
[ "$(mails)" = 1 ] && ok "same count two hours on: no second mail" || bad "same count mailed again"
touch "$B/skills/more.sync-conflict-20261117-111111-ABCDEFG.md"
out=$(at 7800)                                                     # a rise, but the last mail was at T0... 2 h ago
[ "$(mails)" = 2 ] && ok "a rise more than an hour after the last mail is mailed" || bad "rise after 2 h: mails=$(mails)"
touch "$B/skills/more2.sync-conflict-20261117-111112-ABCDEFG.md"
out=$(at 8400)                                                     # 10 minutes after that mail
case "$out" in "CHECK sync-conflicts warn · 5 conflict copies"*) ok "a rise inside the hour still publishes the line" ;; *) bad "rise inside the hour: '$out'" ;; esac
[ "$(mails)" = 2 ] && grep -q "mail held" "$TMP/err" && ok "a rise inside the hour is NOT mailed (held, said on stderr)" || bad "rise inside the hour mailed: $(mails)"
at 11400 >/dev/null                                                # exactly one hour after the 7800 mail
[ "$(mails)" = 3 ] && ok "the held rise is mailed once the hour has passed" || bad "held rise not delivered: $(mails)"
grep -q '5 conflict copies.*(was 4, peak 5) on ' "$TMP/mail.log" && ok "the held rise's mail names the baseline it rose from" || bad "held mail text: $(tail -1 "$TMP/mail.log")"
rm -f "$B/skills/more2.sync-conflict-20261117-111112-ABCDEFG.md" "$B/skills/more.sync-conflict-20261117-111111-ABCDEFG.md"
out=$(at 20000)
case "$out" in "CHECK sync-conflicts warn · 3 conflict copies"*) ok "a fall is a line" ;; *) bad "fall line: '$out'" ;; esac
[ "$(mails)" = 3 ] && ok "a fall is not a mail" || bad "a fall mailed the lead"
[ "$(cut -d' ' -f1 "$MEM")" = 3 ] && ok "a fall lowers the baseline" || bad "baseline after the fall: $(cat "$MEM")"
touch "$B/skills/more.sync-conflict-20261117-111111-ABCDEFG.md"
at 20600 >/dev/null                                                # 10 minutes after the fall, hours after the last MAIL
[ "$(mails)" = 4 ] && ok "a rise from the lowered baseline mails again (a fall does not restart the hour)" || bad "rise after a fall: $(mails)"

# --- 3b. a rise that came and went inside the hour is still owed a mail (xreview r1) --------------------------
n=$(mails); touch "$B/skills/blip.sync-conflict-20261117-111113-ABCDEFG.md"
at 20900 >/dev/null                                                # 5 minutes after the 20600 mail: held
rm -f "$B/skills/blip.sync-conflict-20261117-111113-ABCDEFG.md"
at 21500 >/dev/null                                                # back at the baseline, still inside the hour
[ "$(mails)" = "$n" ] && [ "$(cut -d' ' -f3 "$MEM")" = 5 ] && ok "a held rise that fell back stays owed (pending peak kept)" || bad "held-then-fell: mails=$(mails) mem=$(cat "$MEM")"
touch "$TMP/mail.broken"; at 24200 >/dev/null; rm -f "$TMP/mail.broken" # the hour is up but the send does not happen
[ "$(cut -d' ' -f3 "$MEM")" = 5 ] && ok "a delayed send that does not happen keeps the debt" || bad "debt dropped after a send that did not happen: $(cat "$MEM")"
n=$(mails); at 24260 >/dev/null
[ "$(mails)" = $((n + 1)) ] && grep -q '4 conflict copies.*(was 4, peak 5) on ' "$TMP/mail.log" && ok "the owed mail goes out, naming the peak" || bad "owed mail: mails=$(mails) $(tail -1 "$TMP/mail.log")"
[ "$(cut -d' ' -f3 "$MEM")" = 0 ] && ok "the debt is cleared once mailed" || bad "debt not cleared: $(cat "$MEM")"
n=$(mails); at 30000 >/dev/null
[ "$(mails)" = "$n" ] && ok "no further mail for the same count" || bad "steady count mailed again"

# --- 4. a mail that cannot be sent changes nothing but is retried ---------------------------------------------
touch "$A/repo/c.sync-conflict-20261117-121212-ABCDEFG.md" "$TMP/mail.broken"
before=$(cat "$MEM")
out=$(at 40000); rc=$?
case "$out" in "CHECK sync-conflicts warn · 5 conflict copies"*) ok "mail down: the line is still published" ;; *) bad "mail down: '$out'" ;; esac
[ "$rc" = 0 ] && grep -q "not sent" "$TMP/err" && ok "mail down: rc 0 and a stderr note" || bad "mail down: rc=$rc"
[ "$(cut -d' ' -f1,2 "$MEM")" = "$(cut -d' ' -f1,2 <<< "$before")" ] && [ "$(cut -d' ' -f3 "$MEM")" = 5 ] \
  && ok "mail down: baseline and hour unchanged, the rise recorded as owed" || bad "mail down: memory $(cat "$MEM") (was $before)"
rm -f "$TMP/mail.broken"; n=$(mails)
at 40060 >/dev/null
[ "$(mails)" = $((n + 1)) ] && ok "mail is retried on the next run (no hour's wait after a send that did not happen)" || bad "mail not retried"

# --- 5. back to zero: ok, no mail; the next copy mails again --------------------------------------------------
find "$A" "$B" -name '*.sync-conflict-*' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.stversions/*' -delete
n=$(mails); out=$(at 50000)
case "$out" in "CHECK sync-conflicts ok · 0 conflict copies"*) ok "cleared: back to ok" ;; *) bad "cleared: '$out'" ;; esac
[ "$(mails)" = "$n" ] && [ "$(cut -d' ' -f1 "$MEM")" = 0 ] && ok "cleared: no mail, baseline 0" || bad "cleared: mails=$(mails) mem=$(cat "$MEM")"
touch "$A/repo/src/d.sync-conflict-20261118-010101-ABCDEFG.txt"
at 60000 >/dev/null
[ "$(mails)" = $((n + 1)) ] && ok "a new copy after a clean spell mails again" || bad "no mail after the clean spell"
rm -f "$A/repo/src/d.sync-conflict-20261118-010101-ABCDEFG.txt"
export DREAMTEAM_NOW=$((T0 + 70000))

# --- 6. an instrument that cannot see is a fail, never a zero ------------------------------------------------
out=$(DREAMTEAM_SYNC_ROOTS="$A:$TMP/absent" bash "$S")
case "$out" in "CHECK sync-conflicts fail · root $TMP/absent unreadable or absent · "*) ok "absent root: fail" ;; *) bad "absent root: '$out'" ;; esac
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$A/locked/in"; touch "$A/locked/in/e.sync-conflict-20261117-000000-ABCDEFG"; chmod 000 "$A/locked"
  out=$(bash "$S")
  case "$out" in "CHECK sync-conflicts fail · walk incomplete"*) ok "unreadable subdir: fail, not ok" ;; *) bad "unreadable subdir: '$out'" ;; esac
  chmod 700 "$A/locked"; rm -rf "$A/locked"
else
  ok "unreadable subdir: skipped as root"
fi
out=$(DREAMTEAM_SYNC_ROOTS="" HOME="$TMP/nohome" bash "$S")
case "$out" in "CHECK sync-conflicts fail · root "*) ok "default roots absent: fail" ;; *) bad "default roots absent: '$out'" ;; esac

# --- 7. host suffix, --list, bad arguments --------------------------------------------------------------------
out=$(DREAMTEAM_CHECK_HOST=Katana bash "$S")
case "$out" in "CHECK sync-conflicts-katana ok · "*) ok "off familiar the name carries the host" ;; *) bad "host suffix: '$out'" ;; esac
touch "$A/repo/src/f.sync-conflict-20261117-131313-ABCDEFG.txt"
out=$(bash "$S" --list | tail -1)
[ "$out" = "$A/repo/src/f.sync-conflict-20261117-131313-ABCDEFG.txt" ] && ok "--list prints the paths" || bad "--list: '$out'"
bash "$S" --nope >/dev/null 2>&1; [ $? = 22 ] && ok "unknown argument: exit 22" || bad "unknown argument rc"
bash "$S" --list extra >/dev/null 2>&1; [ $? = 22 ] && ok "extra argument: exit 22" || bad "extra argument rc"

# --- 8. xreview round 1: a symlinked root is walked; a newline in the roots is refused; one run at a time --------
ln -s "$A" "$TMP/ProjectsLink"
out=$(DREAMTEAM_SYNC_ROOTS="$TMP/ProjectsLink" bash "$S")
case "$out" in "CHECK sync-conflicts warn · 1 conflict copies (1 in $TMP/ProjectsLink)"*) ok "a symlinked root is followed, not read as a clean zero" ;; *) bad "symlink root: '$out'" ;; esac
out=$(DREAMTEAM_SYNC_ROOTS="$B"$'\n'"$A" bash "$S")
case "$out" in "CHECK sync-conflicts fail · DREAMTEAM_SYNC_ROOTS holds a newline · "*) ok "a newline in the roots is a fail (no prefix scan)" ;; *) bad "newline roots: '$out'" ;; esac
bash "$S" >/dev/null; cp "$LINE" "$TMP/line.before"; n=$(mails)
touch "$A/repo/src/g.sync-conflict-20261117-141414-ABCDEFG.txt"
( exec 9> "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock"; flock -n 9 || exit 9
  bash "$S" 9>&- >"$TMP/locked.out" 2>"$TMP/locked.err"; echo $? > "$TMP/locked.rc" )
[ "$(cat "$TMP/locked.rc")" = 75 ] && [ ! -s "$TMP/locked.out" ] && ok "lock held elsewhere: exit 75, nothing printed" || bad "lock held: rc=$(cat "$TMP/locked.rc") out=$(cat "$TMP/locked.out")"
cmp -s "$LINE" "$TMP/line.before" && [ "$(mails)" = "$n" ] && ok "lock held elsewhere: line and mail untouched" || bad "lock held: the line or mail changed"
out=$(bash "$S")
case "$out" in "CHECK sync-conflicts warn · 2 conflict copies"*) ok "lock free again: the run publishes" ;; *) bad "after the lock: '$out'" ;; esac

# --- 9. xreview round 2: relative roots are refused; a count that cannot be read is a fail --------------------
mkdir -p "$TMP/rel/!"; touch "$TMP/rel/!/h.sync-conflict-20261117-151515-ABCDEFG"
out=$(cd "$TMP/rel" && DREAMTEAM_SYNC_ROOTS='!' bash "$S")
case "$out" in "CHECK sync-conflicts fail · root '!' is not an absolute path · "*) ok "a relative root (a find operator's name) is refused" ;; *) bad "relative root: '$out'" ;; esac
mkdir -p "$TMP/wcstub"; printf '#!/bin/sh\nexit 1\n' > "$TMP/wcstub/wc"; chmod +x "$TMP/wcstub/wc"
out=$(PATH="$TMP/wcstub:$PATH" bash "$S")
case "$out" in "CHECK sync-conflicts fail · cannot count the list · "*) ok "a failing count is a fail, not a zero" ;; *) bad "wc stub: '$out'" ;; esac

# --- 10. xreview round 4: the lock file is never truncated and never followed through a symlink ---------------
echo sentinel > "$TMP/sentinel"; rm -f "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock"
ln -s "$TMP/sentinel" "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock"
out=$(bash "$S")
case "$out" in "CHECK sync-conflicts fail · lock file is a symlink or not ours · "*) ok "a symlinked lock is refused" ;; *) bad "symlink lock: '$out'" ;; esac
[ "$(cat "$TMP/sentinel")" = sentinel ] && ok "the symlink's target is untouched" || bad "the lock symlink's target was changed"
rm -f "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock"; echo keep > "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock"
bash "$S" >/dev/null
[ "$(cat "$XDG_STATE_HOME/dreamteam/sync-conflicts.lock")" = keep ] && ok "an existing lock file is not truncated" || bad "the lock file was truncated"

# --- 11. kept copies are skipped by directory NAME, visibly; only files count (Sen 22:11; xreview r1) ---------
find "$A" "$B" -name '*.sync-conflict-*' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.stversions/*' -delete 2>/dev/null
num() { sed -E 's/.*(ok|warn) · ([0-9]+) conflict.*/\2/'; }
base=$(bash "$S" | num)
mkdir -p "$A/repo/scratch/hk/backups/dreamteam-state-conflicts" "$A/repo/scratch/q/.sync-conflicts-merged" \
         "$A/repo/scratch/sync-conflicts-archive-2026-11-17" "$A/repo/src/dirname.sync-conflict-20261117-000000-ABCDEFG"
touch "$A/repo/scratch/hk/backups/dreamteam-state-conflicts/HANDOFF.sync-conflict-20261117-000001-ABCDEFG.md" \
      "$A/repo/scratch/q/.sync-conflicts-merged/dispatch.sync-conflict-20261117-000002-ABCDEFG.log" \
      "$A/repo/scratch/sync-conflicts-archive-2026-11-17/x.sync-conflict-20261117-000003-ABCDEFG.log"
out=$(bash "$S"); now=$(num <<< "$out")
[ "$now" = "$base" ] && ok "copies under the three named kept dirs are not counted" || bad "kept dirs counted: $base -> $now"
case "$out" in *", 3 kept dirs skipped · "*) ok "the line says how many kept dirs were skipped" ;; *) bad "skip not visible: '$out'" ;; esac
[ "$(wc -l < "$XDG_STATE_HOME/dreamteam/sync-conflicts.skipped")" = 3 ] && ok "the skipped dirs are listed in a file" || bad "skipped list"
[ "$(awk -F' · ' '{print NF}' <<< "$out")" = 3 ] && ok "the line is still three segments" || bad "segments with the skip note"
mkdir -p "$B/scratch/align-backup-20261116-121840/skills" "$A/repo/scratch/followups/syncthing-backups/deep"
touch "$B/scratch/align-backup-20261116-121840/skills/SKILL.sync-conflict-20261116-000005-ABCDEFG.md" \
      "$A/repo/scratch/followups/syncthing-backups/deep/x.sync-conflict-20260920-000006-ABCDEFG.txt"
out=$(bash "$S"); now=$(num <<< "$out")
[ "$now" = "$base" ] && ok "copies under align-backup-*/ and syncthing-backups/ are not counted (Sen 2026-11-18)" || bad "align/syncthing backups counted: $base -> $now"
case "$out" in *", 5 kept dirs skipped · "*) ok "and they show in the skipped count (5)" ;; *) bad "skip count with the two new names: '$out'" ;; esac
rm -rf "$B/scratch/align-backup-20261116-121840" "$A/repo/scratch/followups"
touch "$A/repo/scratch/hk/backups/real.sync-conflict-20261117-000004-ABCDEFG.md"                 # a generic backups dir
g=$(bash "$S" | num)
[ "$g" = $((base + 1)) ] && ok "a copy in a plain 'backups' dir is NOT hidden (no generic default name)" || bad "generic backups hidden: $base -> $g"
rm -f "$A/repo/scratch/hk/backups/real.sync-conflict-20261117-000004-ABCDEFG.md"
all=$(DREAMTEAM_SYNC_SKIP_DIRS="" bash "$S" | num)
[ "$all" = $((base + 3)) ] && ok "an empty skip list counts them (and still not the matching DIRECTORY)" || bad "empty skip list: $base -> $all"
DREAMTEAM_SYNC_SKIP_DIRS="" bash "$S" | grep -q "kept dirs skipped" && bad "empty skip list still reports skips" || ok "an empty skip list reports no skips"
one=$(DREAMTEAM_SYNC_SKIP_DIRS=".sync-conflicts-merged" bash "$S" | num)
[ "$one" = $((base + 2)) ] && ok "the skip list is the operator's: one name skips one kind" || bad "one skip name: $base -> $one"
touch "$A/repo/src/sync-conflicts-archive-notes.sync-conflict-20261117-000009-ABCDEFG.txt"   # a FILE matching a skip glob
f=$(bash "$S" | num)
[ "$f" = $((base + 1)) ] && ok "a regular file whose name matches a skip glob is still counted (skips are directories)" || bad "file matching a skip glob: $base -> $f"
rm -f "$A/repo/src/sync-conflicts-archive-notes.sync-conflict-20261117-000009-ABCDEFG.txt"
out=$(DREAMTEAM_SYNC_SKIP_DIRS="scratch/backups" bash "$S")
case "$out" in "CHECK sync-conflicts fail · a skip name holds a slash · "*) ok "a skip name with a slash is refused" ;; *) bad "slash skip: '$out'" ;; esac

echo "----"; echo "sync-conflicts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
