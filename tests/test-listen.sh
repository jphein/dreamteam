#!/usr/bin/env bash
# dreamteam — regression tests for the LISTEN seam (#71): mic → text so an agent
# can HEAR JP. Exercises the REAL scripts/listen.sh via its config seams.
#
# HERMETIC — no real mic, no Azure, no global lock file:
#   • A fake STT (records "<mode> <seconds>" + prints a canned transcript; never
#     touches a mic) is wired through listen.sh via config .speech.sttPath, and
#     .speech.cliDir is pinned to $TMP so the real speech-to-cli dir/venv is never
#     probed. The mic flock is redirected to a temp file via DREAMTEAM_MIC_LOCK.
#   • Serialization is proven by HOLDING that temp lock in a background shell and
#     asserting listen.sh gives up with exit 3 within --lock-wait.
#
# Run standalone:  bash tests/test-listen.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LISTEN="$ROOT/scripts/listen.sh"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STTREC="$TMP/stt-rec.log"; LOCKF="$TMP/mic.lock"

# fake STT: records the forwarded "<mode> <seconds>", prints a canned transcript.
cat > "$TMP/fake-stt.py" <<PY
import sys
mode = sys.argv[1] if len(sys.argv) > 1 else ""
secs = sys.argv[2] if len(sys.argv) > 2 else ""
open("$STTREC", "a").write("mode=%s secs=%s\n" % (mode, secs))
sys.stdout.write("yes ship it")
PY

# configs (unquoted heredoc → $TMP expands). cliDir=$TMP isolates from real speech-to-cli.
cat > "$TMP/cfg-ok.json"      <<J
{"speech":{"sttPath":"$TMP/fake-stt.py","cliDir":"$TMP"}}
J
cat > "$TMP/cfg-missing.json" <<J
{"speech":{"sttPath":"$TMP/nope-does-not-exist.py","cliDir":"$TMP"}}
J
cat > "$TMP/cfg-off.json"     <<J
{"speech":{"enabled":false,"sttPath":"$TMP/fake-stt.py","cliDir":"$TMP"}}
J

run(){ # $1=config ; rest=args → runs listen.sh with the temp mic lock, echoes stdout
  DREAMTEAM_MIC_LOCK="$LOCKF" DREAMTEAM_CONFIG="$1" bash "$LISTEN" "${@:2}" 2>/dev/null
}

echo "── listen.sh (mic → text seam) ──────────────────────────────────"

bash -n "$LISTEN" && pass "listen.sh passes bash -n" || fail "listen.sh syntax error"

# 1) happy path — transcript on stdout + mode/seconds forwarded to the STT seam
: > "$STTREC"
OUT="$(run "$TMP/cfg-ok.json" --mode whisper --seconds 5)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'yes ship it' && grep -q 'mode=whisper secs=5' "$STTREC"; then
  pass "listen.sh prints the transcript to stdout + forwards --mode/--seconds to the STT seam"
else
  fail "happy path (rc=$rc, out='$OUT', rec: $(tr '\n' '|' < "$STTREC" 2>/dev/null))"
fi

# 2) unknown --mode is normalized to '' (auto-select) — not passed through verbatim
: > "$STTREC"
run "$TMP/cfg-ok.json" --mode bogus --seconds 9 >/dev/null
grep -q 'mode= secs=9' "$STTREC" && pass "listen.sh normalizes an unknown --mode to auto-select ('')" \
  || fail "mode normalization (rec: $(cat "$STTREC" 2>/dev/null))"

# 3) ONE-MIC serialization — a held lock makes listen.sh give up with exit 3 (MIC_BUSY),
#    and it does so BEFORE touching the STT seam (no capture attempted).
if command -v flock >/dev/null 2>&1; then
  : > "$STTREC"
  ( exec 9>"$LOCKF"; flock 9; sleep 3 ) &   # hold the mic ~3s
  HOLDER=$!
  sleep 0.4                                  # let the holder acquire first
  run "$TMP/cfg-ok.json" --lock-wait 1 >/dev/null; rc=$?
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true
  { [ "$rc" -eq 3 ] && [ ! -s "$STTREC" ]; } \
    && pass "listen.sh mic-busy → exit 3 within --lock-wait, STT seam untouched (serialized)" \
    || fail "mic-busy serialization (rc=$rc, rec: $(cat "$STTREC" 2>/dev/null))"
  # 3b) once the holder released, the mic is available again (lock is not sticky)
  : > "$STTREC"
  OUT="$(run "$TMP/cfg-ok.json" --seconds 3)"; rc=$?
  { [ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'yes ship it'; } \
    && pass "listen.sh acquires the mic once the prior holder releases (lock auto-freed)" \
    || fail "post-release acquire (rc=$rc, out='$OUT')"
else
  echo "SKIP: flock absent — cannot exercise mic serialization"
fi

# 4) graceful no-op — missing STT script → exit 0, empty stdout, never bricks the caller
: > "$STTREC"
OUT="$(run "$TMP/cfg-missing.json" --seconds 5)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$STTREC" ]; } \
  && pass "listen.sh missing STT → graceful no-op (exit 0, empty stdout, seam untouched)" \
  || fail "missing-STT no-op (rc=$rc, out='$OUT')"

# 5) master mute — speech.enabled=false silences listen too (exit 0, empty, seam untouched)
: > "$STTREC"
OUT="$(run "$TMP/cfg-off.json" --seconds 5)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$STTREC" ]; } \
  && pass "listen.sh speech.enabled=false → muted (exit 0, empty stdout, ==false switch)" \
  || fail "mute switch (rc=$rc, out='$OUT', rec: $(cat "$STTREC" 2>/dev/null))"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
