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
