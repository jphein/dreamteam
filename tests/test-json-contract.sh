#!/usr/bin/env bash
# dreamteam — CONTRACT LOCK for the public team-state oracle (issue #23).
#
# roster.sh --json and idle-agents.sh --json are a versioned public contract
# consumed cross-repo (guildmaster, dashboards, reuse routing). This suite
# FREEZES their JSON shape and pins the contract doc so the three can never drift
# apart:
#   • exact top-level keys, exact per-object key sets (the rename-drift guard)
#   • field types, the `status` enum, and the pid==null iff lead|dead rule
#   • the empty (no-team / no-idle) payloads and the always-exit-0 promise
#   • docs/json-contract.md exists, carries a semver `contract-version` marker,
#     and names every frozen key
#
# A rename/remove/retype in either script — or a doc that forgets a key — breaks
# this suite until the doc AND the contract version are bumped in lockstep. That
# is the whole point of the freeze.
#
# Self-contained: fixture team configs under $TMP + PATH-stubbed ps/pgrep for
# deterministic liveness (no dependence on the host's real process table). NO
# production script is edited; isolation is via the scripts' own DREAMTEAM_* env
# seams, mirroring tests/test-roster.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
# assert_eq DESC EXPECTED ACTUAL
assert_eq(){ if [ "$2" = "$3" ]; then pass "$1 (=$3)"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dreamteam-contract.XXXXXX")"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ── prerequisites ────────────────────────────────────────────────────────────
for bin in jq python3 grep bash; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'FAIL: prerequisite missing: %s\n' "$bin"; exit 1; }
done
ROSTER="$ROOT/scripts/roster.sh"; IDLE="$ROOT/scripts/idle-agents.sh"
DOC="$ROOT/docs/json-contract.md"
for f in "$ROSTER" "$IDLE"; do
  [ -f "$f" ] || { printf 'FAIL: production script not found: %s\n' "$f"; exit 1; }
done

jqok(){ printf '%s' "$1" | jq -e . >/dev/null 2>&1; }   # valid JSON?
jqr(){  printf '%s' "$1" | jq -r "$2" 2>/dev/null; }     # raw scalar
jqc(){  printf '%s' "$1" | jq -c "$2" 2>/dev/null; }     # compact JSON

# ── the frozen contract: exact key sets (jq `keys` → codepoint-sorted) ───────
ROSTER_TOP='["agents","counts","team"]'
ROSTER_COUNTS='["active","dead","idle","lead"]'
ROSTER_AGENT='["agentId","agentType","cwd","name","pid","status"]'
IDLE_ELEM='["agentId","context","cwd","name","score","why"]'

# ── PATH stubs → deterministic liveness (roster uses `ps`, idle uses `pgrep`) ─
# Both honour FAKE_ALIVE_IDS (space-separated agent-ids to report as running).
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "  PID COMMAND"
n=99000
for id in ${FAKE_ALIVE_IDS:-}; do n=$((n+1)); printf '%s\n' "$n claude --agent-id $id --session s"; done
exit 0
SH
cat > "$STUB/pgrep" <<'SH'
#!/usr/bin/env bash
pat=""; for a in "$@"; do pat="$a"; done   # idle-agents calls: pgrep -f "agent-id <id>"
for id in ${FAKE_ALIVE_IDS:-}; do case "$pat" in *"$id"*) echo 99999; exit 0;; esac; done
exit 1
SH
chmod +x "$STUB/ps" "$STUB/pgrep"

# ── populated fixture: lead + active + 2 live-idle + 1 dead-idle ─────────────
# Alphanumeric agent-ids (no re.escape surprises, no prefix collisions).
mkdir -p "$TMP/teams/cx"
cat > "$TMP/teams/cx/config.json" <<'JSON'
{
  "members": [
    { "name": "cx-lead",   "agentType": "team-lead", "agentId": "IDLEAD",   "isActive": true,  "cwd": "/tmp/lead" },
    { "name": "cx-active", "agentType": "morpheus",  "agentId": "IDACTIVE", "isActive": true,  "cwd": "/tmp/act",   "prompt": "task: busy building" },
    { "name": "idle-hi",   "agentType": "nebula",    "agentId": "IDHI",     "isActive": false, "cwd": "/tmp/match", "prompt": "task: own the parser rewrite" },
    { "name": "idle-lo",   "agentType": "luna",      "agentId": "IDLO",     "isActive": false, "cwd": "/tmp/other", "prompt": "task: handle billing exports" },
    { "name": "idle-dead", "agentType": "lucid",     "agentId": "IDDEAD",   "isActive": false, "cwd": "/tmp/gone",  "prompt": "task: exited already" }
  ]
}
JSON
# Alive: the active + the two live-idle. NOT IDLEAD (lead is typed, not probed);
# NOT IDDEAD (must classify dead / be filtered from idle).
ALIVE="IDACTIVE IDHI IDLO"

# ══ roster.sh --json — populated ═════════════════════════════════════════════
echo "== roster.sh --json: shape + status enum + pid rule (populated) =="
RJ="$(FAKE_ALIVE_IDS="$ALIVE" PATH="$STUB:$PATH" DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROSTER" --team cx --json 2>/dev/null)"; RRC=$?
assert_eq "roster exits 0" "0" "$RRC"
if jqok "$RJ"; then
  pass "roster emits valid JSON"
  assert_eq "top-level keys frozen"                 "$ROSTER_TOP"    "$(jqc "$RJ" 'keys')"
  assert_eq "counts keys frozen"                    "$ROSTER_COUNTS" "$(jqc "$RJ" '.counts|keys')"
  assert_eq "all agent objects share one key set"   "1"              "$(jqc "$RJ" '[.agents[]|keys]|unique|length')"
  assert_eq "agent key set frozen"                  "$ROSTER_AGENT"  "$(jqc "$RJ" '[.agents[]|keys]|unique[0]')"
  # types
  assert_eq "team is string|null"                   "true" "$(jqr "$RJ" '(.team|type)=="string" or .team==null')"
  assert_eq "counts values all integers"            "true" "$(jqr "$RJ" '[.counts[]|type]|all(.=="number")')"
  assert_eq "counts sum == agents length"           "$(jqr "$RJ" '.agents|length')" "$(jqr "$RJ" '.counts.lead+.counts.active+.counts.idle+.counts.dead')"
  assert_eq "name never null (string)"              "true" "$(jqr "$RJ" '[.agents[].name]|all(type=="string")')"
  # status enum + all four exercised by the fixture (non-vacuous)
  assert_eq "every status in enum"                  "true" "$(jqr "$RJ" '[.agents[].status]|all(. as $s|(["lead","active","idle","dead"]|index($s))!=null)')"
  assert_eq "lead exercised"                        "1" "$(jqr "$RJ" '[.agents[]|select(.status=="lead")]|length')"
  assert_eq "active exercised"                      "1" "$(jqr "$RJ" '[.agents[]|select(.status=="active")]|length')"
  assert_eq "idle exercised (2)"                    "2" "$(jqr "$RJ" '[.agents[]|select(.status=="idle")]|length')"
  assert_eq "dead exercised"                        "1" "$(jqr "$RJ" '[.agents[]|select(.status=="dead")]|length')"
  # pid contract: null iff lead|dead ; integer iff active|idle
  assert_eq "pid null for every lead|dead"          "true" "$(jqr "$RJ" '[.agents[]|select(.status=="lead" or .status=="dead")|.pid]|all(.==null)')"
  assert_eq "pid integer for every active|idle"     "true" "$(jqr "$RJ" '[.agents[]|select(.status=="active" or .status=="idle")|.pid]|all(type=="number")')"
else
  fail "roster emits valid JSON (got: ${RJ:0:200})"
fi

# ══ roster.sh --json — empty (no team) ═══════════════════════════════════════
echo "== roster.sh --json: empty payload (no team) =="
mkdir -p "$TMP/empty"
RE="$(DREAMTEAM_TEAMS_DIR="$TMP/empty" bash "$ROSTER" --json 2>/dev/null)"; RERC=$?
assert_eq "roster no-team exits 0" "0" "$RERC"
if jqok "$RE"; then
  pass "roster no-team emits valid JSON"
  assert_eq "no-team top-level keys frozen" "$ROSTER_TOP" "$(jqc "$RE" 'keys')"
  assert_eq "no-team team == null"          "true"        "$(jqr "$RE" '.team==null')"
  assert_eq "no-team agents == []"          "0"           "$(jqr "$RE" '.agents|length')"
  assert_eq "no-team counts all zero"       "true"        "$(jqr "$RE" '[.counts[]]|all(.==0)')"
else
  fail "roster no-team emits valid JSON (got: ${RE:0:200})"
fi

# ══ idle-agents.sh --json — populated ════════════════════════════════════════
echo "== idle-agents.sh --json: shape + filter + descending-score sort (populated) =="
IJ="$(FAKE_ALIVE_IDS="$ALIVE" PATH="$STUB:$PATH" DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$IDLE" --team cx --task "refactor the parser in /tmp/match" --json 2>/dev/null)"; IRC=$?
assert_eq "idle exits 0" "0" "$IRC"
if jqok "$IJ"; then
  pass "idle emits valid JSON"
  assert_eq "top-level is array"                    "array"       "$(jqr "$IJ" 'type')"
  # only idle+alive survive: lead/active excluded, dead-idle filtered by liveness → 2
  assert_eq "excludes lead/active/dead-idle (=2)"   "2"           "$(jqr "$IJ" 'length')"
  assert_eq "all elements share one key set"        "1"           "$(jqc "$IJ" '[.[]|keys]|unique|length')"
  assert_eq "element key set frozen"                "$IDLE_ELEM"  "$(jqc "$IJ" '[.[]|keys]|unique[0]')"
  # types (note the deliberate divergence from roster: agentId/cwd never null here)
  assert_eq "agentId always non-empty string"       "true" "$(jqr "$IJ" '[.[].agentId]|all(type=="string" and length>0)')"
  assert_eq "cwd always string (never null)"        "true" "$(jqr "$IJ" '[.[].cwd]|all(type=="string")')"
  assert_eq "score always integer"                  "true" "$(jqr "$IJ" '[.[].score]|all(type=="number")')"
  assert_eq "why always string"                     "true" "$(jqr "$IJ" '[.[].why]|all(type=="string")')"
  assert_eq "context always string"                 "true" "$(jqr "$IJ" '[.[].context]|all(type=="string")')"
  # sort contract: descending by score
  assert_eq "sorted by descending score"            "true"     "$(jqr "$IJ" '([.[].score]) == ([.[].score]|sort|reverse)')"
  assert_eq "warmest-context agent ranks first"     "idle-hi"  "$(jqr "$IJ" '.[0].name')"
  assert_eq "higher affinity outscores lower"       "true"     "$(jqr "$IJ" '.[0].score > .[1].score')"
else
  fail "idle emits valid JSON (got: ${IJ:0:200})"
fi

# ══ idle-agents.sh --json — empty (no idle) ══════════════════════════════════
echo "== idle-agents.sh --json: empty payload (no idle) =="
IE="$(DREAMTEAM_TEAMS_DIR="$TMP/empty" bash "$IDLE" --json 2>/dev/null)"; IERC=$?
assert_eq "idle no-team exits 0" "0" "$IERC"
if jqok "$IE"; then
  pass "idle no-team emits valid JSON"
  assert_eq "idle no-team is array" "array" "$(jqr "$IE" 'type')"
  assert_eq "idle no-team is []"    "0"     "$(jqr "$IE" 'length')"
else
  fail "idle no-team emits valid JSON (got: ${IE:0:200})"
fi

# ══ docs/json-contract.md — versioned + names every frozen key ═══════════════
echo "== docs/json-contract.md: exists, semver-versioned, names every frozen key =="
if [ -f "$DOC" ]; then
  pass "contract doc exists"
  VER="$(grep -oE 'contract-version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$DOC" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$VER" ]; then pass "contract doc carries semver version marker (=$VER)"; else fail "contract doc missing 'contract-version: X.Y.Z' marker"; fi
  # every frozen key must be named in the doc → doc cannot silently drift from the lock
  miss=""
  for k in team counts lead active idle dead agents name status agentId agentType cwd pid score why context; do
    grep -q -- "$k" "$DOC" || miss="$miss $k"
  done
  if [ -z "$miss" ]; then pass "contract doc names every frozen key"; else fail "contract doc missing keys:$miss"; fi
else
  fail "contract doc exists (expected $DOC)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────"
printf 'summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
