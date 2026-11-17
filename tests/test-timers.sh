#!/usr/bin/env bash
# dreamteam — regression tests for the AUTOMATION lane (#12–#15): systemd user
# timers + the nightly PILOT launcher. Durable schedules are systemd user units
# (session CronCreate is in-memory and dies with the session) — so the "schedule"
# under test is the unit files + overnight-launch.sh's gate, NOT a live timer.
#
# HERMETIC — no real systemctl mutation, no gh, no audio:
#   • gh is PATH-stubbed (echoes $FAKE_ISSUES) so the dream-label gate is deterministic.
#   • speak is redirected via DREAMTEAM_SPEAK_BIN to a recorder (no audio); the
#     DREAMTEAM_TEST=1 silence path is asserted against it.
#   • unit files are validated by systemd-analyze verify when available, PLUS
#     always by key-presence asserts (so coverage holds on hosts without it).
#
# Run standalone:  bash tests/test-timers.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$ROOT/scripts/overnight-launch.sh"
CTL="$ROOT/scripts/timers-ctl.sh"
SD="$ROOT/systemd"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; REC="$TMP/speak-rec.log"; mkdir -p "$BIN" "$TMP/state"

# gh stub — echoes $FAKE_ISSUES (valid JSON array) regardless of args.
cat > "$BIN/gh" <<'S'
#!/bin/bash
echo "${FAKE_ISSUES:-[]}"
S
# speak recorder — records argv; never makes sound.
cat > "$BIN/speak-rec.sh" <<S
#!/bin/bash
echo "\$*" >> "$REC"
S
chmod +x "$BIN"/gh "$BIN"/speak-rec.sh

run_launch(){ # $1 = FAKE_ISSUES json, $2 = DREAMTEAM_TEST (default 0)
  # Prefix assignments (NOT `env $1`) so a JSON value with spaces isn't word-split.
  rm -f "$TMP/state/overnight-pending.md"
  FAKE_ISSUES="$1" DREAMTEAM_TEST="${2:-0}" \
  DREAMTEAM_STATE="$TMP/state" DREAMTEAM_REPO_SLUG="test/repo" \
  DREAMTEAM_SPEAK_BIN="$BIN/speak-rec.sh" CLAUDE_PLUGIN_ROOT="$ROOT" \
  PATH="$BIN:$PATH" bash "$LAUNCH"
}
ISSUES='[{"number":42,"title":"fix the thing"},{"number":43,"title":"and another"}]'

echo "── syntax ───────────────────────────────────────────────────────"
bash -n "$LAUNCH" && pass "overnight-launch.sh passes bash -n" || fail "overnight-launch.sh syntax error"
bash -n "$CTL"    && pass "timers-ctl.sh passes bash -n"       || fail "timers-ctl.sh syntax error"

echo "── unit files (key presence + systemd-analyze verify) ───────────"
HAVE_SDA=0; command -v systemd-analyze >/dev/null 2>&1 && HAVE_SDA=1
for pair in briefing audit nightly; do
  T="$SD/dreamteam-$pair.timer"; S="$SD/dreamteam-$pair.service"
  [ -f "$T" ] && [ -f "$S" ] && pass "unit pair present: dreamteam-$pair.{timer,service}" || { fail "missing unit pair dreamteam-$pair"; continue; }
  grep -q '^OnCalendar=' "$T"            && pass "$pair.timer has OnCalendar"            || fail "$pair.timer missing OnCalendar"
  grep -q '^Persistent=true' "$T"        && pass "$pair.timer is Persistent (wake catch-up)" || fail "$pair.timer not Persistent"
  grep -q '^WantedBy=timers.target' "$T" && pass "$pair.timer installs to timers.target"  || fail "$pair.timer missing [Install] WantedBy"
  grep -q '^ExecStart=' "$S"             && pass "$pair.service has ExecStart"            || fail "$pair.service missing ExecStart"
  grep -q '^MemoryMax=' "$S"             && pass "$pair.service has MemoryMax cap"        || fail "$pair.service missing MemoryMax"
  if [ "$HAVE_SDA" -eq 1 ]; then
    if out=$(systemd-analyze verify "$T" 2>&1); then pass "$pair.timer passes systemd-analyze verify"
    else fail "$pair.timer systemd-analyze verify: $out"; fi
  fi
done

echo "── retire-pilot (timers-ctl.sh): the 02:11 pilot must not stay armed on ANY host ──"
# katana kept dreamteam-nightly.timer enabled until 2026-11-17: install retired it only where install ran, and its
# file test ([ -e ]) is false for a dangling link while systemd still has the unit enabled. retire-pilot asks systemd.
SC="$TMP/sc"; mkdir -p "$SC/bin"
cat > "$SC/bin/systemctl" <<'S'
#!/bin/bash
# stub: logs every call; is-enabled answers from $SC_STATE/<unit> (absent file = not-found, exit 4)
echo "$*" >> "$SC_LOG"
[ "$1" = --user ] && shift
case "$1" in
  is-active) { [ -n "${SC_NOBUS:-}" ] || [ -n "${SC_NOACTIVE:-}" ]; } && exit 1; a="$SC_STATE/$2.active"; [ -f "$a" ] && { cat "$a"; exit 0; }; echo inactive; exit 3 ;;
  is-enabled) [ -n "${SC_NOBUS:-}" ] && { echo "Failed to connect to user scope bus" >&2; exit 1; }; f="$SC_STATE/$2"; [ -f "$f" ] && { cat "$f"; [ "$(cat "$f")" = enabled ] && exit 0 || exit 1; }; echo not-found; exit 4 ;;
  disable) shift; [ "$1" = --now ] && shift
           [ "${SC_DISABLE:-}" = keep-fail ] && exit 1                                   # fails, unit stays
           for u in "$@"; do rm -f "$SC_STATE/$u"; [ "${SC_DISABLE:-}" = stays-active ] || rm -f "$SC_STATE/$u.active"; done
           [ "${SC_DISABLE:-}" = remove-fail ] && exit 1 ;;                              # katana 11-17: gone, exit 1
  list-timers|daemon-reload|link|enable|stop|start|is-active) : ;;
esac
exit 0
S
chmod +x "$SC/bin/systemctl"
ctl(){ # ctl <verb>  (fresh log; XDG_CONFIG_HOME in the temp dir)
  : > "$SC/log"
  SC_LOG="$SC/log" SC_STATE="$SC/state" XDG_CONFIG_HOME="$SC/cfg" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$SC/bin:$PATH" DREAMTEAM_CHECKS_DIR="$SC/checks" DREAMTEAM_CHECK_HOST="${DREAMTEAM_CHECK_HOST:-familiar}" \
    bash "$CTL" "$@" > "$SC/out" 2>&1
}
reset_sc(){ rm -rf "$SC/state" "$SC/cfg" "$SC/checks"; mkdir -p "$SC/state" "$SC/cfg/systemd/user"; }
pl(){ cat "$SC/checks/dreamteam-nightly-pilot.line" 2>/dev/null; }
UD="$SC/cfg/systemd/user"

# a) live symlink, enabled → disabled --now, link removed
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; ln -s "$SD/dreamteam-nightly.timer" "$UD/dreamteam-nightly.timer"; ln -s "$SD/dreamteam-nightly.service" "$UD/dreamteam-nightly.service"
ctl retire-pilot
grep -q -- "--user disable --now dreamteam-nightly.timer" "$SC/log" && [ ! -e "$UD/dreamteam-nightly.timer" ] && [ ! -L "$UD/dreamteam-nightly.service" ] \
  && pass "retire-pilot: enabled pilot (live link) disabled --now and unlinked" || fail "retire-pilot live link: $(tr '\n' ';' < "$SC/log")"

# b) DANGLING link while systemd still reports it enabled → still disabled and the link removed
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; ln -s "$SC/gone/dreamteam-nightly.timer" "$UD/dreamteam-nightly.timer"
ctl retire-pilot
grep -q -- "--user disable --now dreamteam-nightly.timer" "$SC/log" && [ ! -L "$UD/dreamteam-nightly.timer" ] \
  && pass "retire-pilot: dangling link + enabled unit is still disabled and removed" || fail "retire-pilot dangling: $(tr '\n' ';' < "$SC/log") link=$([ -L "$UD/dreamteam-nightly.timer" ] && echo kept)"

# c) enabled with NO file in the user dir (unit loaded from elsewhere) → disabled anyway
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
ctl retire-pilot
grep -q -- "--user disable --now dreamteam-nightly.timer" "$SC/log" \
  && pass "retire-pilot: enabled unit with no user-dir file is disabled" || fail "retire-pilot no-file: $(tr '\n' ';' < "$SC/log")"

[[ "$(pl)" == "CHECK dreamteam-nightly-pilot ok · retired $(date +%F): dreamteam-nightly.timer and .service disabled and unlinked on "*" · no further runs"*", owner Sen" ]] \
  && pass "retire-pilot: writes the 'retired <date>' CHECK line" || fail "pilot line: '$(pl)'"

reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
DREAMTEAM_CHECK_HOST=katana ctl retire-pilot
[ -f "$SC/checks/dreamteam-nightly-pilot-katana.line" ] && [ ! -e "$SC/checks/dreamteam-nightly-pilot.line" ] \
  && pass "retire-pilot on katana writes dreamteam-nightly-pilot-katana.line (host-suffixed like every line)" || fail "pilot katana name: $(ls "$SC/checks" 2>/dev/null)"

# j) disable removes the unit but exits 1 (katana 2026-11-17, a LINKED unit): judged by the postcondition → retired
reset_sc; echo linked > "$SC/state/dreamteam-nightly.service"
SC_DISABLE=remove-fail ctl retire-pilot; rc=$?
[ "$rc" = 0 ] && grep -q "disable --now dreamteam-nightly.service attempted (was linked)" "$SC/out" && [[ "$(pl)" == "CHECK dreamteam-nightly-pilot ok · retired $(date +%F):"* ]] \
  && pass "retire-pilot: disable exits 1 but the unit is gone (not-found) → retired, line written" || fail "remove-fail: rc=$rc $(cat "$SC/out") line='$(pl)'"
# m) disable "succeeds" (or not) but the unit is STILL RUNNING → not retired: rc 3, no line
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; echo active > "$SC/state/dreamteam-nightly.timer.active"
SC_DISABLE=stays-active ctl retire-pilot; rc=$?
[ "$rc" = 3 ] && [ -z "$(pl)" ] && grep -q "still running or enabled; nothing claimed" "$SC/out" \
  && pass "retire-pilot: disable 'succeeds' (rc 0) but the unit is still active → rc 3, no line (the postcondition is always checked)" || fail "stays-active: rc=$rc '$(pl)'"
# o) the round-3 bypass: one unit not-found but STILL RUNNING, the other enabled and retirable → no retirement claimed
reset_sc; echo active > "$SC/state/dreamteam-nightly.service.active"; echo enabled > "$SC/state/dreamteam-nightly.timer"
ctl retire-pilot; rc=$?
[ "$rc" = 3 ] && [ -z "$(pl)" ] && grep -q "dreamteam-nightly.service is still running" "$SC/out" \
  && pass "retire-pilot: a not-found but running unit blocks the retirement claim (final gate), rc 3, no line" || fail "bypass: rc=$rc '$(pl)'"
# p) a leftover link alone (both units gone in systemd) is unlinked, and the claim is made only after the final gate
reset_sc; ln -s "$SC/gone/x" "$UD/dreamteam-nightly.service"
ctl retire-pilot; rc=$?
[ "$rc" = 0 ] && [[ "$(pl)" == "CHECK dreamteam-nightly-pilot ok · retired "* ]] && [ ! -L "$UD/dreamteam-nightly.service" ] \
  && grep -q -- "--user is-active dreamteam-nightly.timer" "$SC/log" && pass "retire-pilot: leftover link only → unlinked, both units verified gone, then the line" || fail "link-only: rc=$rc '$(pl)'"
# r) the final gate cannot ask (is-active answers nothing, e.g. the bus went away mid-run) → rc 3, nothing claimed
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
SC_NOACTIVE=1 ctl retire-pilot; rc=$?
[ "$rc" = 3 ] && [ -z "$(pl)" ] && grep -q "cannot ask systemd whether" "$SC/out" && pass "retire-pilot: an unanswerable final gate → rc 3, no line" || fail "noactive: rc=$rc '$(pl)'"

# q) "absent" is also only said after the final gate
reset_sc; echo active > "$SC/state/dreamteam-nightly.timer.active"
ctl retire-pilot; rc=$?
[ "$rc" = 3 ] && ! grep -q "pilot absent" "$SC/out" && pass "retire-pilot: nothing enabled but the timer running → not 'absent', rc 3" || fail "absent-running: rc=$rc $(cat "$SC/out")"

# n) --retired-on refuses when a pilot unit is still running, even with no enablement left
reset_sc; echo active > "$SC/state/dreamteam-nightly.service.active"
ctl retire-pilot --retired-on 2026-11-17; rc=$?
[ "$rc" = 3 ] && [ -z "$(pl)" ] && pass "retire-pilot --retired-on with a pilot unit still active → rc 3, nothing recorded" || fail "retired-on active: rc=$rc '$(pl)'"

# k) disable fails and systemd still knows the unit → still a failure (rc 3), no line
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
SC_DISABLE=keep-fail ctl retire-pilot; rc=$?
[ "$rc" = 3 ] && [ -z "$(pl)" ] && grep -q "still running or enabled; nothing claimed" "$SC/out" && pass "retire-pilot: disable fails and the unit remains → rc 3, no line" || fail "keep-fail: rc=$rc '$(pl)'"
# l) --retired-on records an earlier retirement of a pilot verified ABSENT (no systemd change at all)
reset_sc
ctl retire-pilot --retired-on 2026-11-17; rc=$?
[ "$rc" = 0 ] && [[ "$(pl)" == "CHECK dreamteam-nightly-pilot ok · retirement reported as 2026-11-17 (recorded $(date +%F), date given by the operator): dreamteam-nightly.timer and .service verified absent on "* ]] && ! grep -q disable "$SC/log" \
  && pass "retire-pilot --retired-on: an absent pilot gets 'retired <date> (recorded …)', nothing disabled" || fail "retired-on: rc=$rc '$(pl)'"
for d in 2999-01-01 2026-13-01 17-11-2026 '' 2026-02-30 2025-02-29; do
  reset_sc; ctl retire-pilot --retired-on "$d"; rc=$?
  [ "$rc" = 22 ] && [ -z "$(pl)" ] && pass "retire-pilot --retired-on '$d' → rc 22, no line (a real past date only)" || fail "retired-on '$d': rc=$rc '$(pl)'"
done

reset_sc; ctl retire-pilot --retired-on 2024-02-29; rc=$?
[ "$rc" = 0 ] && [[ "$(pl)" == *"reported as 2024-02-29"* ]] && pass "retire-pilot --retired-on 2024-02-29 (a real leap day) is accepted" || fail "leap: rc=$rc '$(pl)'"
# malformed invocations are refused before systemd is asked anything, and publish nothing
for args in "--retired-on=2026-11-16" "--retired-on 2026-11-16 junk" "--bogus" "--retired-on" "now"; do
  reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
  # shellcheck disable=SC2086
  ctl retire-pilot $args; rc=$?
  [ "$rc" = 22 ] && [ ! -s "$SC/log" ] && [ -z "$(pl)" ] && [ -f "$SC/state/dreamteam-nightly.timer" ] \
    && pass "retire-pilot $args → rc 22, no systemctl call, no line" || fail "args '$args': rc=$rc log=$(tr '\n' ';' < "$SC/log") line='$(pl)'"
done

# d) already absent → no disable call, says so, exit 0
reset_sc
ctl retire-pilot; rc=$?
! grep -q "disable" "$SC/log" && grep -q "pilot absent" "$SC/out" && [ "$rc" -eq 0 ] \
  && pass "retire-pilot: absent pilot → no disable, 'pilot absent', exit 0" || fail "retire-pilot absent: rc=$rc $(cat "$SC/out")"
[ -z "$(pl)" ] && pass "retire-pilot: an absent pilot invents no retirement line" || fail "absent wrote a line: '$(pl)'"

# e) BOTH pilot units enabled + an unrelated enabled unit with its own link: exactly the pilot calls, nothing else
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; echo enabled > "$SC/state/dreamteam-nightly.service"
echo enabled > "$SC/state/dreamteam-audit.timer"; ln -s "$SD/dreamteam-audit.timer" "$UD/dreamteam-audit.timer"
ctl retire-pilot
# per pilot unit: is-enabled (before), disable --now, is-active + is-enabled (the final gate)
expect=$(for u in dreamteam-nightly.service dreamteam-nightly.timer; do
  printf '%s\n' "--user is-enabled $u" "--user disable --now $u" "--user is-active $u" "--user is-enabled $u"; done | sort)
extra=$(diff <(sort "$SC/log") <(echo "$expect") | tr '\n' ';')
[ -z "$extra" ] \
  && [ -f "$SC/state/dreamteam-audit.timer" ] && [ -L "$UD/dreamteam-audit.timer" ] \
  && pass "retire-pilot: exactly the two pilot units disabled; the unrelated unit and its link untouched" || fail "retire-pilot call set: extra='$extra' log=$(tr '\n' ';' < "$SC/log")"

# i) the link cannot be removed (a directory sits at the unit path) → fail, no false "unlinked", install links nothing
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; mkdir -p "$UD/dreamteam-nightly.timer/x"
ctl retire-pilot; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "unlinked dreamteam-nightly.timer" "$SC/out" \
  && pass "retire-pilot: a path it cannot remove fails (rc=$rc), never reports 'unlinked'" || fail "retire-pilot rm failure: rc=$rc $(cat "$SC/out")"
reset_sc; mkdir -p "$UD/dreamteam-nightly.timer/x"
ctl install; rc=$?
[ "$rc" -ne 0 ] && ! grep -q -E "(^| )(link|enable) " "$SC/log" \
  && pass "install: stops (rc=$rc) when the pilot's path cannot be removed" || fail "install rm failure: rc=$rc $(tr '\n' ';' < "$SC/log")"

# g) systemd cannot answer (no user bus: empty stdout, rc 1) → NOT "pilot absent": exit non-zero, nothing disabled
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"
SC_NOBUS=1 ctl retire-pilot; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "pilot absent" "$SC/out" && ! grep -q "disable" "$SC/log" \
  && pass "retire-pilot: an unanswerable systemd query fails (rc=$rc), never reads as absence" || fail "retire-pilot no-bus: rc=$rc $(cat "$SC/out")"

# h) install with an unanswerable query stops before linking anything
reset_sc
SC_NOBUS=1 ctl install; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "link " "$SC/log" && ! grep -q "enable " "$SC/log" \
  && pass "install: stops (rc=$rc) before linking when the pilot cannot be confirmed retired" || fail "install no-bus: rc=$rc $(tr '\n' ';' < "$SC/log")"

# f) install runs the same retire (dangling case), before linking anything
reset_sc; echo enabled > "$SC/state/dreamteam-nightly.timer"; ln -s "$SC/gone/x" "$UD/dreamteam-nightly.timer"
ctl install
first_disable=$(grep -n -- "disable --now dreamteam-nightly.timer" "$SC/log" | head -1 | cut -d: -f1); first_link=$(grep -n "link " "$SC/log" | head -1 | cut -d: -f1)
[ -n "$first_disable" ] && [ -n "$first_link" ] && [ "$first_disable" -lt "$first_link" ] && [ ! -L "$UD/dreamteam-nightly.timer" ] \
  && pass "install: retires the pilot (dangling case) before linking" || fail "install retire: disable@${first_disable:-none} link@${first_link:-none}"

echo "── nightly PILOT gate (overnight-launch.sh) ─────────────────────"

# no dream issues → silent: exit 0, NO pending file, log records the skip
out=$(run_launch '[]'); rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$TMP/state/overnight-pending.md" ]; } \
  && pass "no dream issues → exit 0, no pending file (silent when idle)" \
  || fail "no-issue path (rc=$rc, pending exists=$([ -f "$TMP/state/overnight-pending.md" ] && echo yes || echo no))"
grep -q "no open 'dream' issues" "$TMP/state/dreamteam.log" 2>/dev/null \
  && pass "no-issue path logs one line" || fail "no-issue path did not log the skip"

# dream issues exist → writes pending file listing them (PILOT: no auto-start)
run_launch "$ISSUES" 1 >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TMP/state/overnight-pending.md" ] \
   && grep -q '#42' "$TMP/state/overnight-pending.md" && grep -q '#43' "$TMP/state/overnight-pending.md"; then
  pass "dream issues → writes state/overnight-pending.md listing them"
else
  fail "issue path pending file (rc=$rc)"
fi
grep -qi 'PILOT' "$TMP/state/overnight-pending.md" 2>/dev/null \
  && pass "pending file documents PILOT (no auto-start)" || fail "pending file missing PILOT note"

echo "── voice silence (DREAMTEAM_TEST) ───────────────────────────────"

# TEST=1 → NO speak even with issues
: > "$REC"
run_launch "$ISSUES" 1 >/dev/null
{ sleep 0.1; [ ! -s "$REC" ]; } && pass "DREAMTEAM_TEST=1 → no spoken line (suite stays silent)" \
  || fail "spoke under DREAMTEAM_TEST=1 (rec: $(cat "$REC" 2>/dev/null))"

# TEST off → speaks exactly one davis line
: > "$REC"
run_launch "$ISSUES" 0 >/dev/null
{ [ -s "$REC" ] && grep -q 'davis' "$REC"; } && pass "issues + TEST off → speaks one davis line" \
  || fail "did not speak when enabled (rec: $(cat "$REC" 2>/dev/null))"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
