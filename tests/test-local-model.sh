#!/usr/bin/env bash
# dreamteam — regression tests for the OPTIONAL local-model (ollama) lane (#16).
#
#   • scripts/local-model.sh — consumer SEAM (not a hook): generate/embed against
#     ollama, gated by a default-OFF ==false-safe .local.enabled switch, signalling
#     by EXIT CODE (0 ok / 3 unavailable→fall-back / 1 usage) so a caller can fall
#     back to the cloud. Degrades to a clean exit-3 no-op when ollama is absent.
#
# HERMETIC — no real ollama, no network:
#   A fake `curl` (baked into $BIN, dispatches on the ollama endpoint in argv,
#   honors FAKE_DAEMON=up|down, records every request to $REC) is wired through
#   the REAL local-model.sh via PATH. `jq` stays REAL — we exercise the true
#   config-parse + JSON-build/parse contract, not a reimplementation. Config lanes
#   and enable/disable are driven through the DREAMTEAM_CONFIG / DREAMTEAM_LOCAL_*
#   env seams, so no production config is touched.
#
# NON-VACUOUS: the disabled-blocks (§2/§3) and the enabled-succeeds (§5) cases are
#   a matched pair on the SAME prompt — only .local.enabled differs (3 vs 0) — so
#   the block paths are proven not to be trivially always-failing.
#
# Run standalone:  bash tests/test-local-model.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LM="$ROOT/scripts/local-model.sh"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; REC="$TMP/curl-rec.log"
mkdir -p "$BIN"

# fake curl — records "$*" (incl. the --data-binary body → the model is visible)
# to $REC, then either mimics a connection failure (FAKE_DAEMON=down → exit 7, no
# output) or returns canned ollama JSON keyed on the endpoint. $REC is baked in at
# write time; FAKE_DAEMON is read live from the env the script passes through.
cat > "$BIN/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC"
[ "\${FAKE_DAEMON:-up}" = down ] && exit 7
case "\$*" in
  */api/tags*)       printf '%s' '{"models":[{"name":"qwen2.5:14b-instruct-q4_K_M"},{"name":"nomic-embed-text:v1.5"}]}';;
  */api/generate*)   printf '%s' '{"response":"MOCK COMPLETION","done":true}';;
  */api/embeddings*) printf '%s' '{"embedding":[0.1,0.2,0.3]}';;
  *)                 exit 0;;
esac
exit 0
CURL
chmod +x "$BIN/curl"

# config fixtures
CFG_ON="$TMP/on.json";     printf '%s' '{"local":{"enabled":true}}'  > "$CFG_ON"
CFG_OFF="$TMP/off.json";   printf '%s' '{"local":{"enabled":false}}' > "$CFG_OFF"
CFG_ABSENT="$TMP/none.json"; printf '%s' '{"memory":{"maxAgents":36}}' > "$CFG_ABSENT"

# runlm <cfg> <daemon up|down> [args...]  → sets OUT (stdout) + RC; resets $REC.
runlm(){
  : > "$REC"
  OUT="$(env FAKE_DAEMON="$2" PATH="$BIN:$PATH" DREAMTEAM_CONFIG="$1" \
         CLAUDE_PLUGIN_ROOT="$ROOT" bash "$LM" "${@:3}" </dev/null 2>/dev/null)"
  RC=$?
}

echo "── local-model.sh (ollama lane seam) ────────────────────────────"

bash -n "$LM" && pass "local-model.sh passes bash -n" || fail "local-model.sh syntax error"

# §2  disabled (.local.enabled=false) → exit 3, no stdout, curl NEVER called (no-op)
runlm "$CFG_OFF" up "hi there"
{ [ "$RC" -eq 3 ] && [ -z "$OUT" ] && [ ! -s "$REC" ]; } \
  && pass "disabled → exit 3, empty stdout, curl untouched (==false switch works, clean no-op)" \
  || fail "disabled path (rc=$RC out=[$OUT] rec_lines=$(wc -l <"$REC" 2>/dev/null))"

# §3  .local absent entirely → DEFAULT off → exit 3, curl never called
runlm "$CFG_ABSENT" up "hi there"
{ [ "$RC" -eq 3 ] && [ ! -s "$REC" ]; } \
  && pass "no .local section → default-OFF → exit 3, curl untouched" \
  || fail "default-off path (rc=$RC rec_lines=$(wc -l <"$REC" 2>/dev/null))"

# §4  enabled but daemon DOWN → graceful exit 3, no stdout (ollama absent contract)
runlm "$CFG_ON" down "hi there"
{ [ "$RC" -eq 3 ] && [ -z "$OUT" ]; } \
  && pass "enabled + daemon down → exit 3, empty stdout (graceful no-op, caller falls back)" \
  || fail "daemon-down path (rc=$RC out=[$OUT])"

# §5  enabled + daemon UP → generate → exit 0, completion on stdout (matched pair vs §2)
runlm "$CFG_ON" up "hi there"
{ [ "$RC" -eq 0 ] && [ "$OUT" = "MOCK COMPLETION" ]; } \
  && pass "enabled + up → exit 0, completion on stdout (same prompt §2 blocked → non-vacuous)" \
  || fail "generate happy path (rc=$RC out=[$OUT])"

# §6  --embed → exit 0, embedding JSON array on stdout
runlm "$CFG_ON" up --embed "hello world"
{ [ "$RC" -eq 0 ] && [ "$OUT" = "[0.1,0.2,0.3]" ]; } \
  && pass "--embed → exit 0, JSON embedding array on stdout" \
  || fail "embed path (rc=$RC out=[$OUT])"

# §7  enabled + up but NO prompt → usage error (exit 1)
runlm "$CFG_ON" up
[ "$RC" -eq 1 ] && pass "enabled + no prompt → exit 1 (usage error)" || fail "usage path (rc=$RC)"

# §8  --available quiet probe: usable=0, disabled=3, down=3 (no stdout ever)
runlm "$CFG_ON"  up   --available; A=$RC; AO="$OUT"
runlm "$CFG_OFF" up   --available; B=$RC
runlm "$CFG_ON"  down --available; C=$RC
{ [ "$A" -eq 0 ] && [ -z "$AO" ] && [ "$B" -eq 3 ] && [ "$C" -eq 3 ]; } \
  && pass "--available: usable→0 (silent), disabled→3, daemon-down→3" \
  || fail "--available probe (on=$A[$AO] off=$B down=$C)"

# §9  --check: exit 0 when ready, status goes to STDERR — STDOUT must stay clean
runlm "$CFG_ON" up --check
CHECK_ERR="$(env FAKE_DAEMON=up PATH="$BIN:$PATH" DREAMTEAM_CONFIG="$CFG_ON" \
             CLAUDE_PLUGIN_ROOT="$ROOT" bash "$LM" --check </dev/null 2>&1 >/dev/null)"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ] && printf '%s' "$CHECK_ERR" | grep -q 'READY'; } \
  && pass "--check → exit 0, stdout CLEAN, 'READY' status on stderr" \
  || fail "--check hygiene (rc=$RC stdout=[$OUT] stderr=[$CHECK_ERR])"

# §10  --model override lands in the request body (recorded by fake curl)
runlm "$CFG_ON" up --model my-coder:7b "sweep"
{ [ "$RC" -eq 0 ] && grep -q 'my-coder:7b' "$REC"; } \
  && pass "--model override reflected in the ollama request body" \
  || fail "--model override (rc=$RC rec: $(cat "$REC" 2>/dev/null))"

# §11  env DREAMTEAM_LOCAL_ENABLED=true OVERRIDES config enabled:false → armed
: > "$REC"
OUT="$(env FAKE_DAEMON=up DREAMTEAM_LOCAL_ENABLED=true PATH="$BIN:$PATH" \
       DREAMTEAM_CONFIG="$CFG_OFF" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$LM" "hi" </dev/null 2>/dev/null)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$OUT" = "MOCK COMPLETION" ]; } \
  && pass "env DREAMTEAM_LOCAL_ENABLED=true overrides config false (env wins)" \
  || fail "env-enable override (rc=$RC out=[$OUT])"

# §12  env DREAMTEAM_LOCAL_MODEL reflected in the request body
: > "$REC"
env FAKE_DAEMON=up DREAMTEAM_LOCAL_MODEL=envmodel-xyz PATH="$BIN:$PATH" \
    DREAMTEAM_CONFIG="$CFG_ON" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$LM" "hi" </dev/null >/dev/null 2>&1
grep -q 'envmodel-xyz' "$REC" \
  && pass "env DREAMTEAM_LOCAL_MODEL reflected in the ollama request body" \
  || fail "env-model override (rec: $(cat "$REC" 2>/dev/null))"

# §13  prompt via STDIN (no positional) → exit 0, prompt reaches the request body
: > "$REC"
OUT="$(printf 'STDIN-PROMPT-42' | env FAKE_DAEMON=up PATH="$BIN:$PATH" \
       DREAMTEAM_CONFIG="$CFG_ON" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$LM" 2>/dev/null)"; RC=$?
{ [ "$RC" -eq 0 ] && [ "$OUT" = "MOCK COMPLETION" ] && grep -q 'STDIN-PROMPT-42' "$REC"; } \
  && pass "prompt on stdin → exit 0, forwarded to the request body" \
  || fail "stdin prompt (rc=$RC out=[$OUT] rec: $(cat "$REC" 2>/dev/null))"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
