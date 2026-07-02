#!/usr/bin/env bash
# dreamteam — dashboard SERVER integration test (issue #11).
#
# Boots scripts/dashboard-server.py on an ephemeral port (bind 127.0.0.1 only),
# curls the three routes + a 404, asserts shape, then SIGTERMs it and confirms a
# clean exit. Hermetic: private $TMP, DREAMTEAM_REPO pointed at $TMP so the data
# collector never makes a network gh call, no systemd, config.json untouched.
# Skips (does not fail) when python3 or curl is unavailable.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/scripts/dashboard-server.py"

pass=0; fail=0; skip=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
sk(){ echo "SKIP: $1"; skip=$((skip+1)); }

command -v python3 >/dev/null 2>&1 || { sk "python3 not installed — server test skipped"; echo "PASS=$pass FAIL=$fail SKIP=$skip"; exit 0; }
command -v curl    >/dev/null 2>&1 || { sk "curl not installed — server test skipped";    echo "PASS=$pass FAIL=$fail SKIP=$skip"; exit 0; }
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dt-srv-test.XXXXXX")"
LOG="$TMP/server.log"
SRV=""
cleanup(){ [ -n "$SRV" ] && kill -TERM "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Stub the data collector (DREAMTEAM_DATA_SCRIPT seam) so the server test is
# hermetic + instant — no real teams/ps/gh/network. It emits exactly the keys the
# template + this test read, and bumps a counter file per invocation so we can
# prove the 5s response cache (two rapid calls → collector runs once).
cat > "$TMP/fake-data.sh" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "$TMP/collector-calls" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$TMP/collector-calls"
cat <<'JSON'
{"generatedAt":"2026-07-02T12:00:00-07:00","host":"testhost","team":"session-fake","waydroidRunning":false,"tier":"Green",
 "memory":{"totalMb":32000,"usedMb":12000,"availableMb":20000,"swapTotalMb":8000,"swapUsedMb":0,
   "agentTotalRssMb":900,"perAgentMb":300,"hostReserveMb":6000,"balloonReserveMb":8000,"minAvailableMb":8000,
   "maxAgents":36,"budget":10,"cap":10,"liveAgents":2,"room":8,
   "thresholds":{"redBelowMb":3200,"orangeBelowMb":8000,"yellowBelowMb":12000},
   "scopeActive":false,"scopeCurrentMb":null,"scopeMemoryHigh":"20G","scopeMemoryMax":"24G"},
 "agents":[],"prs":[],"timeline":{"shipped":[],"inFlight":[],"pending":[]},
 "teams":[{"team":"session-fake","counts":{"lead":1,"active":2,"idle":0,"dead":0},
   "agents":[{"name":"Luna","status":"active"},{"name":"Morpheus","status":"active"}]}]}
JSON
STUB
chmod +x "$TMP/fake-data.sh"

# Boot: ephemeral port (0 → OS picks, race-free — we read the actual port back from
# the startup line), localhost bind, stubbed collector (no systemd, no network).
CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_DASHBOARD_PORT=0 DREAMTEAM_DASHBOARD_HOST=127.0.0.1 \
  DREAMTEAM_DATA_SCRIPT="$TMP/fake-data.sh" python3 "$SERVER" >"$LOG" 2>&1 &
SRV=$!

PORT=""
for _ in $(seq 1 50); do
  PORT=$(sed -n 's#.*serving on http://127\.0\.0\.1:\([0-9]\{1,\}\).*#\1#p' "$LOG" 2>/dev/null | head -1)
  [ -n "$PORT" ] && break
  kill -0 "$SRV" 2>/dev/null || break     # server died during startup
  sleep 0.1
done
if [ -z "$PORT" ]; then
  no "server never reported a listening port (log: $(tr '\n' ' ' <"$LOG" | head -c 200))"
  echo "──────────────── summary ────────────────"; echo "PASS=$pass  FAIL=$fail  SKIP=$skip"; exit 1
fi
ok "server booted, reported port $PORT"
BASE="http://127.0.0.1:$PORT"

# GET / → 200 text/html, is the dashboard template
code=$(curl -s -o "$TMP/root.html" -w '%{http_code}' "$BASE/")
[ "$code" = "200" ] && ok "GET / → 200" || no "GET / → $code"
grep -q 'DREAMTEAM_DATA' "$TMP/root.html" && ok "GET / serves the dashboard template" || no "GET / body is not the template"

# GET /api/data → 200 JSON with the keys the template reads. Two rapid calls must
# hit the ~5s cache (collector runs once) — the "don't hammer ps" guarantee.
: > "$TMP/collector-calls"
code=$(curl -s -o "$TMP/data.json" -w '%{http_code}' "$BASE/api/data")   # cold → collector runs
curl -s -o /dev/null "$BASE/api/data"                                    # warm → must be served from cache
[ "$code" = "200" ] && ok "GET /api/data → 200" || no "GET /api/data → $code (body: $(head -c 120 "$TMP/data.json"))"
calls=$(cat "$TMP/collector-calls" 2>/dev/null || echo "?")
[ "$calls" = "1" ] && ok "two rapid /api/data calls hit the 5s cache (collector ran once)" || no "cache: collector ran ${calls}× for 2 calls"
if [ "$HAVE_JQ" -eq 1 ]; then
  jq . "$TMP/data.json" >/dev/null 2>&1 && ok "/api/data is valid JSON" || no "/api/data is not valid JSON"
  jq -e 'has("memory")' "$TMP/data.json" >/dev/null 2>&1 && ok "/api/data has .memory" || no "/api/data missing .memory"
  jq -e 'has("teams") and (.teams|type=="array")' "$TMP/data.json" >/dev/null 2>&1 && ok "/api/data has .teams (array)" || no "/api/data missing .teams array"
  jq -e '.teams[0].team=="session-fake" and .memory.availableMb==20000' "$TMP/data.json" >/dev/null 2>&1 \
    && ok "/api/data returns the collector output verbatim (stub flows through)" || no "/api/data did not return stub content"
else
  grep -q '"memory"' "$TMP/data.json" && ok "/api/data mentions memory (no jq)" || no "/api/data missing memory (no jq)"
  grep -q '"teams"'  "$TMP/data.json" && ok "/api/data mentions teams (no jq)"  || no "/api/data missing teams (no jq)"
fi

# GET /api/version → 200 JSON with name + version
code=$(curl -s -o "$TMP/ver.json" -w '%{http_code}' "$BASE/api/version")
[ "$code" = "200" ] && ok "GET /api/version → 200" || no "GET /api/version → $code"
if [ "$HAVE_JQ" -eq 1 ]; then
  jq -e 'has("name") and has("version")' "$TMP/ver.json" >/dev/null 2>&1 && ok "/api/version has name+version" || no "/api/version missing name/version"
  jq -e '.name=="dreamteam-dashboard"' "$TMP/ver.json" >/dev/null 2>&1 && ok "/api/version name is dreamteam-dashboard" || no "/api/version wrong name"
else
  { grep -q '"name"' "$TMP/ver.json" && grep -q '"version"' "$TMP/ver.json"; } && ok "/api/version has name+version (no jq)" || no "/api/version missing name/version (no jq)"
fi

# unknown path → 404
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nope")
[ "$code" = "404" ] && ok "GET /nope → 404" || no "GET /nope → $code"

# graceful SIGTERM
kill -TERM "$SRV" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$SRV" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$SRV" 2>/dev/null; then no "server did not exit on SIGTERM"; kill -9 "$SRV" 2>/dev/null; else ok "server exits cleanly on SIGTERM"; fi
wait "$SRV" 2>/dev/null; SRV=""

echo "──────────────── summary ────────────────"
echo "PASS=$pass  FAIL=$fail  SKIP=$skip"
[ "$fail" -eq 0 ]
