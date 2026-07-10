#!/usr/bin/env bash
# dreamteam — regression tests for the VOICE attention seam (#9).
#
#   • scripts/speak.sh       — fire-and-forget TTS seam: detached, hard-timeout,
#                              silent no-op on missing python/tts/creds; resolves
#                              the davis alias and passes voice via AZURE_SPEECH_VOICE.
#   • scripts/team-events.sh — RED-tier / scope-pressure attention ALSO speaks
#                              (one sentence, davis), sharing notify_red's 600s
#                              throttle marker (one attention event, many channels)
#                              and suppressed under DREAMTEAM_TEST.
#
# HERMETIC — no real audio, no Azure, no desktop bus:
#   A fake python tts.py (records AZURE_SPEECH_VOICE + argv to a log; never calls
#   Azure) is wired through the REAL speak.sh via config .speech.ttsPath — so we
#   exercise the true speak.sh → tts contract, not a reimplementation. free /
#   systemctl / notify-send are PATH-stubbed for the team-events tier path.
#   speak.sh fires tts DETACHED, so success assertions poll the record log.
#
# Run standalone:  bash tests/test-voice.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEAK="$ROOT/scripts/speak.sh"
EVENTS="$ROOT/scripts/team-events.sh"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; REC="$TMP/tts-rec.log"
mkdir -p "$BIN" "$TMP/state" "$TMP/teams/faketeam"

# fake tts.py — speak.sh runs `python3 <ttsPath>`, so this MUST be python.
# It records "<AZURE_SPEECH_VOICE>\t<argv...>" per call; never touches Azure/audio.
cat > "$TMP/tts.py" <<PY
import sys, os
with open("$REC", "a") as f:
    f.write(os.environ.get("AZURE_SPEECH_VOICE", "") + "\t" + " ".join(sys.argv[1:]) + "\n")
PY

# configs (unquoted heredoc → \$TMP expands)
cat > "$TMP/cfg-ok.json" <<J
{"speech":{"ttsPath":"$TMP/tts.py"},"memory":{"minAvailableMB":8000},"scope":{"memoryHigh":"20G"}}
J
cat > "$TMP/cfg-missing.json" <<J
{"speech":{"ttsPath":"$TMP/nope-does-not-exist.py"}}
J
cat > "$TMP/cfg-off.json" <<J
{"speech":{"enabled":false,"ttsPath":"$TMP/tts.py"}}
J
CFG_OK="$TMP/cfg-ok.json"

# wait_lines <n>: poll REC for >= n lines (tts is fired detached/async). ~4s max.
wait_lines(){ local n="$1" i; for i in $(seq 1 40); do [ -f "$REC" ] && [ "$(wc -l < "$REC" 2>/dev/null || echo 0)" -ge "$n" ] && return 0; sleep 0.1; done; return 1; }
# no_rec: brief grace, then assert nothing was recorded (for no-op paths where
# speak.sh exits BEFORE launching tts, so no async race exists).
no_rec(){ sleep 0.3; [ ! -s "$REC" ]; }

echo "── speak.sh (voice seam) ────────────────────────────────────────"

bash -n "$SPEAK" && pass "speak.sh passes bash -n" || fail "speak.sh syntax error"

# 1) passes text + resolves davis→en-US-DavisNeural; returns 0 instantly (detached)
: > "$REC"
timeout 5 env DREAMTEAM_CONFIG="$CFG_OK" bash "$SPEAK" "hello attention world" --voice davis; rc=$?
[ "$rc" -eq 0 ] && pass "speak.sh exits 0 instantly (detached, non-blocking)" || fail "speak.sh exit $rc (blocked or errored)"
if wait_lines 1 && grep -q 'en-US-DavisNeural' "$REC" && grep -q 'hello attention world' "$REC"; then
  pass "speak.sh passes text + davis→en-US-DavisNeural to tts (AZURE_SPEECH_VOICE seam)"
else
  fail "speak.sh did not pass text+voice (rec: $(tr '\t' '|' < "$REC" 2>/dev/null))"
fi

# 2) explicit voice id is forwarded unchanged (passthrough, not clobbered by alias)
: > "$REC"
env DREAMTEAM_CONFIG="$CFG_OK" bash "$SPEAK" "x" --voice en-US-BrianNeural
{ wait_lines 1 && grep -q 'en-US-BrianNeural' "$REC"; } && pass "speak.sh forwards an explicit voice id unchanged" || fail "voice passthrough (rec: $(cat "$REC" 2>/dev/null))"

# 3) empty text → silent no-op (exit 0, no tts launched)
: > "$REC"
env DREAMTEAM_CONFIG="$CFG_OK" bash "$SPEAK" "" --voice davis; rc=$?
{ [ "$rc" -eq 0 ] && no_rec; } && pass "speak.sh empty text → silent no-op (exit 0, no tts)" || fail "empty-text no-op (rc=$rc)"

# 4) tts.py missing → silent no-op (exit 0) — the 'azure/script missing' contract
: > "$REC"
env DREAMTEAM_CONFIG="$TMP/cfg-missing.json" bash "$SPEAK" "hi" --voice davis; rc=$?
{ [ "$rc" -eq 0 ] && no_rec; } && pass "speak.sh missing tts.py → silent no-op (exit 0)" || fail "missing-tts no-op (rc=$rc)"

# 5) master mute: speech.enabled=false → muted (exit 0). Proves the ==false switch.
: > "$REC"
env DREAMTEAM_CONFIG="$TMP/cfg-off.json" bash "$SPEAK" "hi" --voice davis; rc=$?
{ [ "$rc" -eq 0 ] && no_rec; } && pass "speak.sh speech.enabled=false → muted (exit 0, ==false switch works)" || fail "mute switch (rc=$rc, rec: $(cat "$REC"))"

echo "── engine fallback chain (#17): SPEECH_ENGINE seam + azure→piper ──"

# Engine-aware fake tts.py: records "<SPEECH_ENGINE>\t<AZURE_SPEECH_VOICE>\t
# <PIPER_VOICE>\t<argv>" per call and EXITS NON-ZERO for any engine named in the
# $CTL control file — the exact upstream contract the fallback drives on (missing
# creds / synth failure → non-zero → try next engine). Never touches Azure/audio.
RECE="$TMP/tts-eng-rec.log"; CTL="$TMP/fail-engines"; : > "$CTL"
cat > "$TMP/tts-eng.py" <<PY
import sys, os
eng = os.environ.get("SPEECH_ENGINE", "")
try:
    fail = open("$CTL").read().strip()
except Exception:
    fail = ""
with open("$RECE", "a") as f:
    f.write("\t".join([eng, os.environ.get("AZURE_SPEECH_VOICE", ""),
                       os.environ.get("PIPER_VOICE", ""), " ".join(sys.argv[1:])]) + "\n")
sys.exit(1 if eng and eng in fail.split(",") else 0)
PY
cat > "$TMP/cfg-chain.json" <<J
{"speech":{"ttsPath":"$TMP/tts-eng.py","engine":"azure","fallback":["piper"]}}
J
cat > "$TMP/cfg-chain-override.json" <<J
{"speech":{"ttsPath":"$TMP/tts-eng.py","engine":"azure","fallback":["piper"],"voices":{"davis":{"piper":"en_US-custom-low"}}}}
J
# poll an arbitrary record file for >= n lines (chain fires detached, like speak).
wait_file(){ local f="$1" n="$2" i; for i in $(seq 1 40); do [ -f "$f" ] && [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -ge "$n" ] && return 0; sleep 0.1; done; return 1; }

# 6) azure HEALTHY (exits 0) → speaks once via azure, SPEECH_ENGINE=azure seam set,
#    davis→en-US-DavisNeural; piper stays DORMANT — the zero-behavior-change guarantee.
: > "$RECE"; : > "$CTL"
env DREAMTEAM_CONFIG="$TMP/cfg-chain.json" bash "$SPEAK" "chain hi" --voice davis
if wait_file "$RECE" 1; then sleep 0.4
  n="$(wc -l < "$RECE")"; e1="$(sed -n 1p "$RECE" | cut -f1)"; v1="$(sed -n 1p "$RECE" | cut -f2)"
  { [ "$n" -eq 1 ] && [ "$e1" = azure ] && [ "$v1" = en-US-DavisNeural ]; } \
    && pass "chain azure-healthy → single azure call (SPEECH_ENGINE=azure, davis), piper dormant (zero behavior change)" \
    || fail "azure-healthy chain (n=$n e1=$e1 v1=$v1)"
else fail "azure-healthy chain: nothing recorded"; fi

# 7) azure DOWN (exits 1) → falls back to piper; the davis alias keeps ONE identity
#    across engines — en-US-DavisNeural (azure) then en_US-ryan-high (piper).
: > "$RECE"; printf 'azure' > "$CTL"
env DREAMTEAM_CONFIG="$TMP/cfg-chain.json" bash "$SPEAK" "chain hi" --voice davis
if wait_file "$RECE" 2; then
  e1="$(sed -n 1p "$RECE" | cut -f1)"; v1="$(sed -n 1p "$RECE" | cut -f2)"
  e2="$(sed -n 2p "$RECE" | cut -f1)"; v2="$(sed -n 2p "$RECE" | cut -f3)"
  { [ "$e1" = azure ] && [ "$v1" = en-US-DavisNeural ] && [ "$e2" = piper ] && [ "$v2" = en_US-ryan-high ]; } \
    && pass "chain azure-down → falls back to piper; davis stays one identity (azure DavisNeural → piper ryan)" \
    || fail "azure→piper fallback (e1=$e1 v1=$v1 e2=$e2 v2=$v2)"
else fail "azure→piper fallback: <2 lines (rec: $(tr '\t' '|' < "$RECE"))"; fi

# 8) ALL engines down → speak.sh walks the WHOLE chain and STILL exits 0 (a dead
#    voice path must never brick a hook — the core silent-no-op contract holds).
: > "$RECE"; printf 'azure,piper' > "$CTL"
env DREAMTEAM_CONFIG="$TMP/cfg-chain.json" bash "$SPEAK" "chain hi" --voice davis; rc=$?
if [ "$rc" -eq 0 ] && wait_file "$RECE" 2; then
  e1="$(sed -n 1p "$RECE" | cut -f1)"; e2="$(sed -n 2p "$RECE" | cut -f1)"
  { [ "$e1" = azure ] && [ "$e2" = piper ]; } \
    && pass "chain all-engines-down → walks full azure→piper chain, speak.sh exits 0 (never bricks a hook)" \
    || fail "all-down chain order (e1=$e1 e2=$e2)"
else fail "all-down chain (rc=$rc, rec: $(tr '\t' '|' < "$RECE"))"; fi

# 9) config .speech.voices.<alias>.<engine> overrides the baked piper identity.
: > "$RECE"; printf 'azure' > "$CTL"
env DREAMTEAM_CONFIG="$TMP/cfg-chain-override.json" bash "$SPEAK" "chain hi" --voice davis
if wait_file "$RECE" 2; then
  v2="$(sed -n 2p "$RECE" | cut -f3)"
  [ "$v2" = en_US-custom-low ] && pass "config .speech.voices.davis.piper overrides the baked piper identity" \
    || fail "piper voice override (v2=$v2)"
else fail "piper voice override: <2 lines (rec: $(tr '\t' '|' < "$RECE"))"; fi

echo "── team-events.sh RED / scope attention → voice (shared throttle) ─"

# tier-path stubs (mirror test-lifecycle): free=controllable avail, scope
# inactive by default (deterministic), notify-send recorded to nowhere.
cat > "$BIN/free" <<'S'
#!/bin/bash
printf 'Mem: 0 0 0 0 0 %s\n' "${FAKE_AVAIL:-20000}"
S
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
case "$*" in
  *is-active*)          [ "${FAKE_SCOPE:-}" = pressure ] && exit 0 || exit 3 ;;
  *show*MemoryCurrent*) echo "${FAKE_SCOPE_CUR:-19327352832}" ;;
  *)                    exit 0 ;;
esac
S
printf '#!/bin/bash\n:\n' > "$BIN/notify-send"
chmod +x "$BIN"/*
cat > "$TMP/teams/faketeam/config.json" <<'J'
{"members":[{"name":"luna","agentType":"lucid","isActive":false,"agentId":"luna@faketeam","cwd":"/tmp/x"}]}
J

# SubagentStop avoids the TeammateIdle branch's pane-organizer/scope-attach side
# effects, so it's safe to run with DREAMTEAM_TEST UNSET (voice enabled).
run_ev(){ # $1=extra env assignments (string), reads event JSON from $2
  echo "$2" | env $1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" \
    DREAMTEAM_CONFIG="$CFG_OK" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$BIN:$PATH" bash "$EVENTS"
}
STOP='{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"faketeam"}'

# RED host tier (avail 5000 < floor 8000), scope inactive, DREAMTEAM_TEST unset.
rm -f "$TMP/state/.last-notify"; : > "$REC"
OUT="$(run_ev 'FAKE_AVAIL=5000' "$STOP")"
case "$OUT" in *"RED TIER"*) pass "team-events RED still emits the systemMessage tier line (stdout intact)";; *) fail "RED tier stdout missing ($OUT)";; esac
if wait_lines 1 && grep -qi 'red tier' "$REC" && grep -q '5000' "$REC" && grep -q 'en-US-DavisNeural' "$REC"; then
  pass "team-events RED fires the spoken davis line via speak.sh (DREAMTEAM_TEST unset)"
else
  fail "RED did not speak (rec: $(tr '\t' '|' < "$REC" 2>/dev/null))"
fi

# Shared throttle: an immediate 2nd RED (marker < 600s) must NOT speak again.
run_ev 'FAKE_AVAIL=5000' "$STOP" >/dev/null
sleep 0.4
[ "$(wc -l < "$REC")" -eq 1 ] && pass "2nd RED within 600s throttled — voice speaks once (shared marker, no double-throttle)" || fail "voice throttle failed ($(wc -l < "$REC") lines)"

# Scope pressure (host green) → the scope spoken line fires.
rm -f "$TMP/state/.last-notify"; : > "$REC"
run_ev 'FAKE_SCOPE=pressure FAKE_AVAIL=20000' "$STOP" >/dev/null
{ wait_lines 1 && grep -qi 'scope pressure' "$REC" && grep -q 'en-US-DavisNeural' "$REC"; } \
  && pass "team-events SCOPE PRESSURE fires the spoken davis line" || fail "scope pressure did not speak (rec: $(tr '\t' '|' < "$REC" 2>/dev/null))"

# DREAMTEAM_TEST set → voice suppressed on RED (the suite never speaks).
rm -f "$TMP/state/.last-notify"; : > "$REC"
run_ev 'FAKE_AVAIL=5000 DREAMTEAM_TEST=1' "$STOP" >/dev/null
{ sleep 0.3; [ ! -s "$REC" ]; } && pass "DREAMTEAM_TEST=1 suppresses voice on RED (suite never speaks)" || fail "voice spoke under DREAMTEAM_TEST (rec: $(cat "$REC"))"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
