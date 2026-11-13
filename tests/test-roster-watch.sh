#!/usr/bin/env bash
# dreamteam — regression tests for scripts/roster-watch.sh (#81, contract #79).
#
# ISOLATION: roster.sh is replaced through DREAMTEAM_ROSTER_CMD by a stub that
# serves one fixture per poll (poll N → $FIX/N.json; a missing file = empty
# output = a poll error). INTERVAL=0 and --polls N bound every run. No team
# config, no ps, no tmux. The REAL watcher logic runs unmodified.
#
# Each of the issue's five rules has a positive control AND the negative that
# proves the check can fail (self excluded vs not, flicker vs settle, baseline
# vs late idle).
#
# Run standalone:  bash tests/test-roster-watch.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/scripts/roster-watch.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

STUB="$TMP/roster-stub.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/args.log"
c=$(cat "$FIX/n" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$FIX/n"
[ -f "$FIX/$c.json" ] && cat "$FIX/$c.json"
exit 0
SH
chmod +x "$STUB"

# polls "<spec poll 1>" "<spec poll 2>" …   spec = "name:status name:status", or ERR
polls() {
  FIX="$TMP/fix.$RANDOM$RANDOM"; mkdir -p "$FIX"; export FIX
  local i=0 spec
  for spec in "$@"; do
    i=$((i + 1))
    [ "$spec" = ERR ] && continue
    printf '%s\n' $spec | jq -Rn --arg team testteam \
      '{team:$team, agents:[inputs | select(length>0) | split(":") | {name:.[0], status:.[1]}]}' \
      > "$FIX/$i.json"
  done
  NPOLLS=$i
}
OUT=""; RC=0
watch() {  # watch [extra args…]  (each run replays the fixtures from poll 1)
  RC=0; rm -f "$FIX/n" "$FIX/args.log"
  OUT="$(DREAMTEAM_ROSTER_CMD="$STUB" DREAMTEAM_AGENT_ID="" ROSTER_WATCH_INTERVAL=0 \
         bash "$W" --polls "$NPOLLS" "$@" 2>"$TMP/err")" || RC=$?
}
count() { printf '%s\n' "$OUT" | grep -c -- "$1"; }

echo "── roster-watch.sh (debounced roster-health watcher) ────────────"

if bash -n "$W" 2>"$TMP/err"; then pass "roster-watch.sh passes bash -n"
else fail "syntax error: $(head -1 "$TMP/err")"; fi

# Rule 2 — the debounce threshold: 3 idle polls are silent, the 4th announces once.
polls "team-lead:lead a:active" "team-lead:lead a:idle" "team-lead:lead a:idle" "team-lead:lead a:idle"
watch --self hyp
[ "$(count 'SETTLED-IDLE')" -eq 0 ] && pass "3 idle polls < DEBOUNCE=4 → silent" \
  || fail "announced before the debounce threshold: $OUT"
polls "team-lead:lead a:active" "a:idle" "a:idle" "a:idle" "a:idle" "a:idle" "a:idle"
watch --self hyp
[ "$(count 'SETTLED-IDLE @ .*: a idle 4 polls')" -eq 1 ] && [ "$(count 'SETTLED-IDLE')" -eq 1 ] \
  && pass "4th idle poll announces SETTLED-IDLE exactly once (not again on polls 5–6)" \
  || fail "settle not announced exactly once: $OUT"

# Rule 1 — an isActive flicker resets the count.
polls "a:active" "a:idle" "a:idle" "a:active" "a:idle" "a:idle" "a:idle"
watch --self hyp
[ "$(count 'SETTLED-IDLE')" -eq 0 ] && pass "idle,idle,ACTIVE,idle×3 → silent (flicker resets the debounce)" \
  || fail "a flicker was reported as a finish: $OUT"

# --debounce is honoured (and so the default of 4 above is not hard-wired)
polls "a:active" "a:idle" "a:idle"
watch --self hyp --debounce 2
[ "$(count 'SETTLED-IDLE @ .*: a idle 2 polls')" -eq 1 ] && pass "--debounce 2 announces on the 2nd idle poll" \
  || fail "--debounce not honoured: $OUT"

# Rule 3 — SELF is never flagged; the negative control proves the check can fire.
polls "hyp:active a:active" "hyp:idle a:active" "hyp:idle a:active" "hyp:idle a:active" "hyp:idle a:active"
watch --self hyp
[ "$(count 'hyp')" -eq 0 ] && pass "--self hyp: the manager's own idleness never announced (no self-wake loop)" \
  || fail "the manager flagged itself: $OUT"
watch --self other
[ "$(count 'SETTLED-IDLE @ .*: hyp ')" -eq 1 ] && pass "negative control: without --self hyp, hyp IS announced" \
  || fail "self-exclusion test is vacuous (hyp never announced even when not SELF): $OUT"
polls "hyp:active a:active" "hyp:idle a:active" "hyp:idle a:active" "hyp:idle a:active" "hyp:idle a:active"
rm -f "$FIX/n"; RC=0; OUT="$(DREAMTEAM_ROSTER_CMD="$STUB" DREAMTEAM_AGENT_ID="hyp@testteam" ROSTER_WATCH_INTERVAL=0 \
  bash "$W" --polls "$NPOLLS" 2>"$TMP/err")" || RC=$?
[ "$(count 'hyp')" -eq 0 ] && pass "SELF defaults to the teammate identity (DREAMTEAM_AGENT_ID name@team → name)" \
  || fail "default SELF not derived from the agent id: $OUT"

# Rule 4 — baseline seed: already idle at launch is known, not news.
polls "a:idle b:active" "a:idle b:idle" "a:idle b:idle" "a:idle b:idle" "a:idle b:idle" "a:idle b:idle"
watch --self hyp
[ "$(count ': a idle')" -eq 0 ] && pass "baseline: 'a' idle at the first poll is never announced" \
  || fail "baseline-idle agent announced: $OUT"
[ "$(count 'SETTLED-IDLE @ .*: b idle 4 polls')" -eq 1 ] && pass "negative control: 'b' going idle AFTER launch is announced" \
  || fail "late idle not announced (baseline check vacuous): $OUT"

# Rule 5 — the event is a verify-first prompt that names the pane check.
polls "a:active" "a:idle"
watch --self hyp --debounce 1
printf '%s\n' "$OUT" | grep -q 'VERIFY before reporting: scripts/pane-peek.sh a' \
  && pass "SETTLED-IDLE names the pane-peek verification command" \
  || fail "settle line does not tell the manager to verify: $OUT"

# re-arm: a settled agent that re-engages and settles again is announced again
polls "a:active" "a:idle" "a:active" "a:idle"
watch --self hyp --debounce 1
[ "$(count 'SETTLED-IDLE @ .*: a ')" -eq 2 ] && pass "settle → active → settle announces twice (re-armed by activity)" \
  || fail "re-settle not re-announced: $OUT"

# AGENT-DEAD once per death
polls "a:active" "a:dead" "a:dead" "a:dead"
watch --self hyp
[ "$(count 'AGENT-DEAD @ .*: a status=dead')" -eq 1 ] && pass "AGENT-DEAD announced once across three dead polls" \
  || fail "dead not announced exactly once: $OUT"

# MEMBERSHIP-CHANGE on a join, not on the first poll
polls "a:active" "a:active" "a:active b:active"
watch --self hyp
[ "$(count 'MEMBERSHIP-CHANGE')" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'was\[a\] now\[a,b\]' \
  && pass "MEMBERSHIP-CHANGE once, with old and new member lists" \
  || fail "membership change wrong: $OUT"

# ROSTER-POLL-ERROR, then the watch continues and still baselines on the first GOOD poll
polls ERR "a:idle" "a:idle" "a:idle" "a:idle" "a:idle"
watch --self hyp
[ "$(count 'ROSTER-POLL-ERROR')" -eq 1 ] && [ "$(count 'SETTLED-IDLE')" -eq 0 ] \
  && pass "poll error reported once; the first GOOD poll is the baseline (no false settle)" \
  || fail "poll error handling wrong: $OUT"

# team pin: first call unpinned, every later call --team testteam
polls "a:active" "a:active" "a:active"
watch --self hyp
if [ "$(sed -n 1p "$FIX/args.log")" = "--json" ] && [ "$(grep -c -- '--team testteam --json' "$FIX/args.log")" -eq 2 ]; then
  pass "team pinned after the first poll (later polls pass --team testteam)"
else fail "team not pinned: $(tr '\n' '|' < "$FIX/args.log")"; fi
polls "a:active" "a:active"
watch --self hyp --team given
[ "$(grep -c -- '--team given --json' "$FIX/args.log")" -eq 2 ] && pass "--team is passed on every poll" \
  || fail "--team not honoured: $(tr '\n' '|' < "$FIX/args.log")"

# stop protocol (#79): poll limit and deadline both end with WATCH-END, exit 0
polls "a:active" "a:active"
watch --self hyp
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | tail -1 | grep -c 'WATCH-END .*poll limit 2')" -eq 1 ] \
  && pass "--polls: last line WATCH-END, exit 0" || fail "poll-limit end wrong (rc=$RC): $OUT"
polls "a:active"
watch --self hyp --until 1
[ "$RC" -eq 0 ] && [ "$OUT" = "$(printf '%s\n' "$OUT" | grep 'WATCH-END .*deadline')" ] && [ ! -f "$FIX/n" ] \
  && pass "--until in the past: WATCH-END before any poll" || fail "deadline end wrong (rc=$RC): $OUT"

# argument errors are exit 22 (client), never a silent default
for bad in "--debounce x" "--debounce 0" "--interval -1" "--polls" "--bogus"; do
  RC=0; DREAMTEAM_ROSTER_CMD="$STUB" bash "$W" $bad >/dev/null 2>&1 || RC=$?
  [ "$RC" -eq 22 ] && pass "rejects '$bad' with exit 22" || fail "'$bad' gave exit $RC, want 22"
done

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
