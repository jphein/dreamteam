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

TMP="$(mktemp -d)"
BIN="$TMP/bin"; REC="$TMP/tts-rec.log"
mkdir -p "$BIN" "$TMP/state" "$TMP/teams/faketeam"
export DREAMTEAM_STATE="$TMP/state"      # speak.sh's voice.log lands here, never in the repo
# ── fake gnome-speaks QUEUE (2026-09-18: speak.sh posts here FIRST). Records every
# POST body; answers the code in $QCODE (200 by default, 503 = "gated").
QLOG="$TMP/queue.log"; QCODE="$TMP/queue.code"; echo 200 > "$QCODE"
QTOK="$TMP/queue.tok"   # one line per POST: the X-Speaks-Token it carried, or NONE
python3 - "$QLOG" "$QCODE" "$QTOK" > "$TMP/queue.port" 2>/dev/null <<'PY' &
import http.server, socketserver, sys
log, codef, tokf = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        open(tokf, "a").write((self.headers.get("X-Speaks-Token") or "NONE") + "\n")
        open(log, "ab").write(body + b"\n")
        code = int(open(codef).read().strip() or 200)
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True); srv.serve_forever()
PY
QPID=$!
trap 'kill $QPID 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/queue.port" ] && break; sleep 0.1; done
QPORT="$(cat "$TMP/queue.port" 2>/dev/null)"
[ -n "$QPORT" ] || { echo "FAIL: fake queue server did not start"; exit 1; }
QURL="http://127.0.0.1:$QPORT/speak"
DEAD_QURL="http://127.0.0.1:1/speak"     # nothing listens on port 1 -> connect refused fast
# Any fixture WITHOUT its own queueUrl must hit the dead port, never the real
# service on 7710 -- 2026-09-18 the engine-chain fixtures spoke "chain hi" x4
# through JP's live queue before this line existed.
export SPEAK_QUEUE_URL="$DEAD_QURL"
# Same rule for the gnome-speaks token (#186 phase 2): never read JP's real one.
export SPEAK_TOKEN_FILE="$TMP/no-such-token"
wait_qlines(){ local n="$1" i; for i in $(seq 1 40); do [ -f "$QLOG" ] && [ "$(wc -l < "$QLOG" 2>/dev/null || echo 0)" -ge "$n" ] && return 0; sleep 0.1; done; return 1; }

# fake tts.py — speak.sh runs `python3 <ttsPath>`, so this MUST be python.
# It records "<AZURE_SPEECH_VOICE>\t<argv...>" per call; never touches Azure/audio.
cat > "$TMP/tts.py" <<PY
import sys, os
with open("$REC", "a") as f:
    f.write(os.environ.get("AZURE_SPEECH_VOICE", "") + "\t" + " ".join(sys.argv[1:]) + "\n")
PY

# configs (unquoted heredoc → \$TMP expands)
# cfg-ok: the ENGINE-CHAIN fixture -- queue unreachable + directFallback on, so
# the pre-2026-09-18 tts.py contract tests still measure the chain. memoryAlerts
# on so the team-events voice tests still fire (default is off, tested below).
cat > "$TMP/cfg-ok.json" <<J
{"speech":{"ttsPath":"$TMP/tts.py","queueUrl":"$DEAD_QURL","directFallback":true,"memoryAlerts":true},"memory":{"minAvailableMB":8000},"scope":{"memoryHigh":"20G"}}
J
cat > "$TMP/cfg-missing.json" <<J
{"speech":{"ttsPath":"$TMP/nope-does-not-exist.py","queueUrl":"$DEAD_QURL","directFallback":true}}
J
cat > "$TMP/cfg-off.json" <<J
{"speech":{"enabled":false,"ttsPath":"$TMP/tts.py","queueUrl":"$QURL"}}
J
# cfg-queue: the DEFAULT route -- a reachable queue, direct fallback left at its default (off).
cat > "$TMP/cfg-queue.json" <<J
{"speech":{"ttsPath":"$TMP/tts.py","queueUrl":"$QURL"},"memory":{"minAvailableMB":8000},"scope":{"memoryHigh":"20G"}}
J
# cfg-dead: unreachable queue, directFallback at its default (off) -> must stay silent.
cat > "$TMP/cfg-dead.json" <<J
{"speech":{"ttsPath":"$TMP/tts.py","queueUrl":"$DEAD_QURL"}}
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

echo "── the gnome-speaks queue route (2026-09-18) ────────────────────"
# Q1) reachable queue: the line is POSTed with text + source + resolved voice; tts.py is NOT run
: > "$REC"; : > "$QLOG"; echo 200 > "$QCODE"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" bash "$SPEAK" "queue me please" --voice davis --source reverie; rc=$?
if [ "$rc" -eq 0 ] && wait_qlines 1 && grep -q '"text":"queue me please"' "$QLOG" && grep -q '"source":"reverie"' "$QLOG" \
   && grep -q '"voice":"en-US-DavisNeural"' "$QLOG" && no_rec; then
  pass "speak.sh POSTs text+source+voice to the gnome-speaks queue and never runs tts.py"
else
  fail "queue route (rc=$rc qlog: $(cat "$QLOG" 2>/dev/null | head -c 200) rec: $(cat "$REC" 2>/dev/null))"
fi
# Q1b) default source tag when --source is omitted
# ── token (gnome-speaks #186 phase 2): sent from the token file as X-Speaks-Token,
# absent when there is no file, withheld when the file holds anything but [A-Za-z0-9_-].
: > "$QLOG"; : > "$QTOK"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" bash "$SPEAK" "no token line" --voice davis
{ wait_qlines 1 && [ "$(cat "$QTOK")" = "NONE" ]; } && pass "no token file -> no X-Speaks-Token header (the pre-token request)" || fail "tokenless request carried a token ($(cat "$QTOK"))"
TOKV="tok_ABC-123xyz_0123456789abcdefghijKLMN"     # 40 chars of [A-Za-z0-9_-]
printf '%s\n' "$TOKV" > "$TMP/token"; chmod 600 "$TMP/token"
: > "$QLOG"; : > "$QTOK"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/token" bash "$SPEAK" "token line" --voice davis
{ wait_qlines 1 && [ "$(cat "$QTOK")" = "$TOKV" ]; } && pass "token file -> X-Speaks-Token sent (trailing newline stripped)" || fail "token not sent ($(cat "$QTOK"))"
# The token must NEVER be in curl's argv (/proc/<pid>/cmdline is world-readable):
# a PATH-stub curl records its argv and stdin, then runs the real curl unchanged.
REALCURL="$(command -v curl)"; SPY="$TMP/curlspy"; mkdir -p "$SPY"
cat > "$SPY/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/curl.argv"
cat > "$TMP/curl.stdin"
exec "$REALCURL" "\$@" < "$TMP/curl.stdin"
SH
chmod +x "$SPY/curl"; : > "$TMP/curl.argv"; : > "$QLOG"; : > "$QTOK"
env PATH="$SPY:$PATH" DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/token" bash "$SPEAK" "argv line" --voice davis
if wait_qlines 1 && [ "$(cat "$QTOK")" = "$TOKV" ] && [ -s "$TMP/curl.argv" ] \
   && ! grep -qF "$TOKV" "$TMP/curl.argv" && grep -qF "$TOKV" "$TMP/curl.stdin" \
   && grep -q -- '-q -K -' "$TMP/curl.argv"; then
  pass "the token reaches curl on stdin, never argv (spied curl; -q first so no curlrc can trace it)"
else
  fail "token argv check (argv: $(sed "s/$TOKV/<TOKEN>/g" "$TMP/curl.argv" 2>/dev/null | head -c 300))"
fi
# The token goes to loopback queue URLs only: 0.0.0.0 reaches the same fake
# server on Linux but is not a loopback literal, and userinfo is refused.
for qurl in "http://0.0.0.0:$QPORT/speak" "http://127.0.0.1:1@127.0.0.1:$QPORT/speak"; do
  printf '{"speech":{"ttsPath":"%s","queueUrl":"%s"}}\n' "$TMP/tts.py" "$qurl" > "$TMP/cfg-nonloop.json"
  : > "$QLOG"; : > "$QTOK"; : > "$TMP/state/voice.log"
  env DREAMTEAM_CONFIG="$TMP/cfg-nonloop.json" SPEAK_TOKEN_FILE="$TMP/token" bash "$SPEAK" "nonloop line" --voice davis
  if wait_qlines 1 && [ "$(cat "$QTOK")" = "NONE" ] && grep -q "token withheld" "$TMP/state/voice.log"; then
    pass "token withheld from a non-loopback queue url ($qurl)"
  else
    fail "token sent to $qurl ($(cat "$QTOK" | head -c 60))"
  fi
done
for bad in "short_token" "tok_ABC-123xyz 0123456789abcdefghijKLMN" "$(printf 'x%.0s' $(seq 1 257))"; do
  printf '%s\n' "$bad" > "$TMP/badlen"
  : > "$QLOG"; : > "$QTOK"
  env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/badlen" bash "$SPEAK" "badlen line" --voice davis
  { wait_qlines 1 && [ "$(cat "$QTOK")" = "NONE" ]; } && pass "an invalid token file (${#bad} chars) is not sent, not trimmed into one" || fail "invalid token file sent: $(cat "$QTOK" | head -c 60)"
done
printf 'bad;token"x\n' > "$TMP/badtoken"
: > "$QLOG"; : > "$QTOK"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/badtoken" bash "$SPEAK" "bad token line" --voice davis
{ wait_qlines 1 && [ "$(cat "$QTOK")" = "NONE" ]; } && pass "a token file with unexpected characters is not sent (no curl-config injection)" || fail "bad token was sent ($(cat "$QTOK"))"
grep -q 'printf "header = ' "$SPEAK" && ! grep -qE 'curl[^|]*(X-Speaks-Token|Authorization)' "$SPEAK" \
  && pass "lint: no curl line in speak.sh carries a token header in argv" || fail "speak.sh may put the token on curl's command line"
: > "$QLOG"; : > "$QTOK"; echo 401 > "$QCODE"; : > "$TMP/state/voice.log"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/token" bash "$SPEAK" "refused line" --voice davis
if wait_qlines 1 && no_rec && { for _ in $(seq 1 30); do grep -q 'refused 401' "$TMP/state/voice.log" 2>/dev/null && break; sleep 0.1; done; grep -q 'refused 401: token sent but wrong' "$TMP/state/voice.log"; }; then
  pass "401 -> logged as a token refusal, silent, no direct fallback"
else
  fail "401 handling (log: $(cat "$TMP/state/voice.log" 2>/dev/null))"
fi
echo 200 > "$QCODE"
# An http_proxy in the environment never receives the request (or the token):
# the proxy here is a dead port, so only a direct connection reaches the queue.
: > "$QLOG"; : > "$QTOK"
env http_proxy="http://127.0.0.1:1" HTTP_PROXY="http://127.0.0.1:1" all_proxy="http://127.0.0.1:1" \
  DREAMTEAM_CONFIG="$TMP/cfg-queue.json" SPEAK_TOKEN_FILE="$TMP/token" bash "$SPEAK" "proxy line" --voice davis
{ wait_qlines 1 && [ "$(cat "$QTOK")" = "$TOKV" ]; } && pass "an http_proxy is bypassed (--noproxy): the token goes straight to the local queue" \
  || fail "proxied request (qtok: $(cat "$QTOK" | head -c 20))"
# Across every token case above, voice.log never held the token itself.
! grep -rqF "$TOKV" "$TMP/state" && pass "the token never reaches voice.log or any state file" \
  || fail "the token leaked into $TMP/state"

: > "$QLOG"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" bash "$SPEAK" "default tag" --voice davis
{ wait_qlines 1 && grep -q '"source":"dreamteam"' "$QLOG"; } && pass "speak.sh tags the queue item source=dreamteam by default" || fail "default source tag (qlog: $(cat "$QLOG" 2>/dev/null))"
# Q2) queue answers 503 (quiet hours / on a call / extension off): silent by design, no tts fallback, reason logged
: > "$REC"; : > "$QLOG"; echo 503 > "$QCODE"; : > "$TMP/state/voice.log"
env DREAMTEAM_CONFIG="$TMP/cfg-queue.json" bash "$SPEAK" "gated line" --voice davis
if wait_qlines 1 && no_rec && { for _ in $(seq 1 30); do grep -q 'gated 503' "$TMP/state/voice.log" 2>/dev/null && break; sleep 0.1; done; grep -q 'gated 503' "$TMP/state/voice.log"; }; then
  pass "queue 503 (gated) -> silent: no tts.py fallback, voice.log names the gate"
else
  fail "503 handling (rec: $(cat "$REC" 2>/dev/null) log: $(cat "$TMP/state/voice.log" 2>/dev/null))"
fi
echo 200 > "$QCODE"
# Q3) queue unreachable + directFallback default (off) -> silent; the reason is logged
: > "$REC"; : > "$TMP/state/voice.log"
env DREAMTEAM_CONFIG="$TMP/cfg-dead.json" bash "$SPEAK" "nobody home" --voice davis
if no_rec && { for _ in $(seq 1 30); do grep -q 'directFallback=false' "$TMP/state/voice.log" 2>/dev/null && break; sleep 0.1; done; grep -q 'directFallback=false' "$TMP/state/voice.log"; }; then
  pass "queue unreachable + directFallback off (default) -> silent, reason logged"
else
  fail "dead-queue default (rec: $(cat "$REC" 2>/dev/null) log: $(cat "$TMP/state/voice.log" 2>/dev/null))"
fi
# Q4) master mute still wins before the queue is even tried
: > "$QLOG"
env DREAMTEAM_CONFIG="$TMP/cfg-off.json" bash "$SPEAK" "muted" --voice davis
{ sleep 0.4; [ ! -s "$QLOG" ]; } && pass "speech.enabled=false -> nothing reaches the queue" || fail "mute reached the queue ($(cat "$QLOG"))"

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
{"speech":{"ttsPath":"$TMP/tts-eng.py","engine":"azure","fallback":["piper"],"directFallback":true}}
J
cat > "$TMP/cfg-chain-override.json" <<J
{"speech":{"ttsPath":"$TMP/tts-eng.py","engine":"azure","fallback":["piper"],"directFallback":true,"voices":{"davis":{"piper":"en_US-custom-low"}}}}
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

echo "── --timeout flag (#52): explicit > config > 180, positive-int guard ─"

# Sleeper fake: sleeps 2s (baked), THEN records DONE. If `timeout` kills it before
# 2s, DONE is never written — that absence is the observable that a SHORT cap took
# effect; its presence proves the synth ran to completion under a LONG cap.
RECS="$TMP/tts-slow-rec.log"
cat > "$TMP/tts-slow.py" <<PY
import time
time.sleep(2)
open("$RECS", "a").write("DONE\n")
PY
# config cap is deliberately LONG (180) so any truncation must come from the flag.
cat > "$TMP/cfg-slow.json" <<J
{"speech":{"ttsPath":"$TMP/tts-slow.py","timeoutSec":180,"directFallback":true}}
J

# 10) explicit --timeout wins over config: 1s cap KILLS a 2s synth (config says 180).
#     If the flag were dropped, config 180 would let it finish → this would fail.
: > "$RECS"
env DREAMTEAM_CONFIG="$TMP/cfg-slow.json" bash "$SPEAK" "slow one" --voice davis --timeout 1
sleep 2.5
[ ! -s "$RECS" ] \
  && pass "--timeout 1 overrides config 180 → 2s synth killed before completion (flag wins, value applied)" \
  || fail "--timeout 1 not honored — synth completed under config (rec: $(cat "$RECS"))"

# 11) invalid --timeout is coerced (falls through to config 180) → 2s synth completes.
#     If the guard passed 'notanumber' to `timeout`, it would error out → no DONE.
: > "$RECS"
env DREAMTEAM_CONFIG="$TMP/cfg-slow.json" bash "$SPEAK" "slow two" --voice davis --timeout notanumber
if wait_file "$RECS" 1; then
  pass "--timeout notanumber → positive-int guard falls through to config 180, synth completes"
else
  fail "invalid --timeout not coerced — synth was killed/errored (no DONE recorded)"
fi

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

# memoryAlerts DEFAULT (absent) → RED does NOT speak (JP 2026-09-18: the memory gate
# "should not announce anyway"); the desktop notification and stdout tier line still fire.
rm -f "$TMP/state/.last-notify"; : > "$REC"; : > "$QLOG"
cat > "$TMP/cfg-noalerts.json" <<J
{"speech":{"ttsPath":"$TMP/tts.py","queueUrl":"$QURL"},"memory":{"minAvailableMB":8000},"scope":{"memoryHigh":"20G"}}
J
OUT="$(echo "$STOP" | env FAKE_AVAIL=5000 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" \
    DREAMTEAM_CONFIG="$TMP/cfg-noalerts.json" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$BIN:$PATH" bash "$EVENTS")"
case "$OUT" in *"RED TIER"*) pass "memoryAlerts default: RED tier line still on stdout";; *) fail "RED tier stdout missing with memoryAlerts default ($OUT)";; esac
{ sleep 0.4; [ ! -s "$REC" ] && [ ! -s "$QLOG" ]; } && pass "memoryAlerts default (off): RED does not speak -- not to tts, not to the queue" || fail "RED spoke with memoryAlerts off (rec: $(cat "$REC" 2>/dev/null) qlog: $(cat "$QLOG" 2>/dev/null))"
# DREAMTEAM_TEST set → voice suppressed on RED (the suite never speaks).
rm -f "$TMP/state/.last-notify"; : > "$REC"
run_ev 'FAKE_AVAIL=5000 DREAMTEAM_TEST=1' "$STOP" >/dev/null
{ sleep 0.3; [ ! -s "$REC" ]; } && pass "DREAMTEAM_TEST=1 suppresses voice on RED (suite never speaks)" || fail "voice spoke under DREAMTEAM_TEST (rec: $(cat "$REC"))"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
