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

# --- 3. the lead is mailed once per change, not once per run --------------------------------------------------
[ "$(mails)" = 1 ] && ok "first non-zero count mails the lead once" || bad "mail count after first warn: $(mails)"
grep -q '^send sen CHECK sync-conflicts warn: 3 conflict copies' "$TMP/mail.log" && ok "mail goes to sen and carries the fact" || bad "mail text: $(cat "$TMP/mail.log")"
bash "$S" >/dev/null
[ "$(mails)" = 1 ] && ok "same count next run: no second mail" || bad "same count mailed again"
touch "$B/skills/more.sync-conflict-20261117-111111-ABCDEFG.md"
bash "$S" >/dev/null
[ "$(mails)" = 2 ] && ok "a changed count mails again" || bad "changed count: mails=$(mails)"

# --- 4. a mail that cannot be sent changes nothing but is retried ---------------------------------------------
touch "$A/repo/c.sync-conflict-20261117-121212-ABCDEFG.md" "$TMP/mail.broken"
out=$(bash "$S" 2>"$TMP/err"); rc=$?
case "$out" in "CHECK sync-conflicts warn · 5 conflict copies"*) ok "mail down: the line is still published" ;; *) bad "mail down: '$out'" ;; esac
[ "$rc" = 0 ] && grep -q "not sent" "$TMP/err" && ok "mail down: rc 0 and a stderr note" || bad "mail down: rc=$rc"
rm -f "$TMP/mail.broken"; n=$(mails)
bash "$S" >/dev/null
[ "$(mails)" = $((n + 1)) ] && ok "mail is retried on the next run" || bad "mail not retried"

# --- 5. back to zero: ok, and the next non-zero count mails again ---------------------------------------------
find "$A" "$B" -name '*.sync-conflict-*' -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.stversions/*' -delete
out=$(bash "$S")
case "$out" in "CHECK sync-conflicts ok · 0 conflict copies"*) ok "cleared: back to ok" ;; *) bad "cleared: '$out'" ;; esac
[ ! -e "$XDG_STATE_HOME/dreamteam/sync-conflicts.mailed" ] && ok "ok clears the mailed memory" || bad "mailed memory kept"
touch "$A/repo/src/d.sync-conflict-20261118-010101-ABCDEFG.txt"; n=$(mails)
bash "$S" >/dev/null
[ "$(mails)" = $((n + 1)) ] && ok "a new copy after a clean spell mails again" || bad "no mail after the clean spell"
rm -f "$A/repo/src/d.sync-conflict-20261118-010101-ABCDEFG.txt"

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

echo "----"; echo "sync-conflicts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
