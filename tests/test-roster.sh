#!/usr/bin/env bash
# dreamteam — self-contained tests for roster.sh, spawn-accounting.sh, and the
# dashboard/mem-budget defaults-agreement invariant.
#
# NO production script is edited. Isolation is achieved entirely through the
# scripts' own env seams — DREAMTEAM_TEAMS_DIR, CLAUDE_PLUGIN_ROOT, DREAMTEAM_STATE
# — plus a PATH-prepended stub `ps` for the spawn-accounting fault-injection case
# (reproducing the restricted-`ps` hook sandbox that caused the line-21 crash).
#
# Contract: PASS:/FAIL: per check, summary line, exit 1 if any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
# assert_eq DESC EXPECTED ACTUAL
assert_eq(){ if [ "$2" = "$3" ]; then pass "$1 (=$3)"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dreamteam-test.XXXXXX")"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ── prerequisites (can't test without these) ────────────────────────────────
for bin in jq python3 grep bash; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'FAIL: prerequisite missing: %s\n' "$bin"; exit 1; }
done
for f in scripts/roster.sh scripts/spawn-accounting.sh scripts/dashboard-data.sh scripts/mem-budget.sh; do
  [ -f "$ROOT/$f" ] || { printf 'FAIL: production script not found: %s\n' "$f"; exit 1; }
done

jqok(){ printf '%s' "$1" | jq -e . >/dev/null 2>&1; }  # valid JSON?
jqr(){  printf '%s' "$1" | jq -r "$2" 2>/dev/null; }    # raw scalar

# ─────────────────────────────────────────────────────────────────────────────
echo "== roster.sh: fixture team (liveness classification) =="
mkdir -p "$TMP/teams/faketeam"
# agentId that provably matches no running process → must classify `dead`.
# (isActive:true on purpose — proves the ps-liveness check overrides the config flag.)
GHOST_ID="bogus-agentid-$$-does-not-exist-DEADBEEF"
cat > "$TMP/teams/faketeam/config.json" <<JSON
{
  "members": [
    { "name": "faketeam-lead", "agentType": "team-lead", "agentId": "lead-$$-nonexistent", "isActive": true, "cwd": "/tmp/lead" },
    { "name": "ghost-member",  "agentType": "nebula",    "agentId": "$GHOST_ID",           "isActive": true, "cwd": "/tmp/ghost" }
  ]
}
JSON

RJSON="$(DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROOT/scripts/roster.sh" --team faketeam --json 2>/dev/null)"; RRC=$?
assert_eq "roster fixture exits 0" "0" "$RRC"
if jqok "$RJSON"; then
  pass "roster fixture emits valid JSON"
  assert_eq "roster team name is faketeam"    "faketeam" "$(jqr "$RJSON" '.team')"
  assert_eq "bogus-id member classified dead" "dead"     "$(jqr "$RJSON" '.agents[]|select(.name=="ghost-member")|.status')"
  assert_eq "team-lead classified lead"       "lead"     "$(jqr "$RJSON" '.agents[]|select(.agentType=="team-lead")|.status')"
  assert_eq "member count == 2"               "2"        "$(jqr "$RJSON" '.agents|length')"
  assert_eq "counts.lead == 1"                "1"        "$(jqr "$RJSON" '.counts.lead')"
  assert_eq "counts.dead == 1"                "1"        "$(jqr "$RJSON" '.counts.dead')"
  assert_eq "counts sum == member count" \
    "$(jqr "$RJSON" '.agents|length')" \
    "$(jqr "$RJSON" '.counts.lead + .counts.active + .counts.idle + .counts.dead')"
else
  fail "roster fixture emits valid JSON (got: ${RJSON:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== roster.sh: real current team (live integration) =="
# No DREAMTEAM_TEAMS_DIR override → reads the real ~/.claude/teams newest config.
RREAL="$(bash "$ROOT/scripts/roster.sh" --json 2>/dev/null)"
if jqok "$RREAL"; then
  pass "roster real-team emits valid JSON"
  LEN="$(jqr "$RREAL" '.agents|length')"
  if [ "${LEN:-0}" -ge 1 ] 2>/dev/null; then
    pass "roster real-team has >=1 agent (=$LEN)"
  else
    fail "roster real-team has >=1 agent (got '$LEN' — this check requires an active dreamteam)"
  fi
else
  fail "roster real-team emits valid JSON (got: ${RREAL:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== spawn-accounting.sh: line-21 regression (restricted/failing ps) =="
# The crash: under `set -o pipefail`, a failing `ps` made `ps|awk||echo 0` emit a
# multiline "0\n0" that broke the arithmetic below. Fixed by letting awk own the
# default. Lock it down: with `ps` stubbed to fail, the hook must still exit 0 and
# emit valid JSON carrying a `.systemMessage` string.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$STUB/ps"
if "$STUB/ps" >/dev/null 2>&1; then fail "stub ps must exit non-zero"; else pass "stub ps exits non-zero (fault injected)"; fi

SA_OUT="$(
  export PATH="$STUB:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_STATE="$TMP/sa-state"
  printf '%s' '{"tool_name":"Agent","tool_input":{"name":"t"}}' \
    | bash "$ROOT/scripts/spawn-accounting.sh" 2>/dev/null
)"; SARC=$?
assert_eq "spawn-accounting exits 0 under failing ps" "0" "$SARC"
if jqok "$SA_OUT"; then
  pass "spawn-accounting emits valid JSON under failing ps"
  assert_eq "spawn-accounting .systemMessage is a string" "true" "$(jqr "$SA_OUT" '.systemMessage|type=="string"')"
else
  fail "spawn-accounting emits valid JSON under failing ps (got: ${SA_OUT:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== defaults agreement: dashboard-data.sh vs mem-budget.sh =="
# Guards the 600/4000 drift class. Anchored on the default LITERALS themselves —
#   dashboard-data.sh:  m("KEY", N)
#   mem-budget.sh:      getcfg KEY N
# — so a concurrent edit that moves the roster section doesn't affect this parse.
DASH="$ROOT/scripts/dashboard-data.sh"; BUD="$ROOT/scripts/mem-budget.sh"
extract_dash(){ grep -oE "m\\(\"$1\", *[0-9]+\\)" "$DASH" | head -1 | grep -oE '[0-9]+' | head -1; }
extract_bud(){  grep -oE "getcfg +$1 +[0-9]+"      "$BUD"  | head -1 | grep -oE '[0-9]+' | head -1; }
for k in perAgentMB hostReserveMB balloonReserveMB minAvailableMB maxAgents; do
  d="$(extract_dash "$k")"; b="$(extract_bud "$k")"
  if   [ -z "$d" ]; then fail "defaults: '$k' default not found in dashboard-data.sh"
  elif [ -z "$b" ]; then fail "defaults: '$k' default not found in mem-budget.sh"
  elif [ "$d" = "$b" ]; then pass "defaults agree: $k = $d"
  else fail "defaults DRIFT: $k dashboard-data=$d mem-budget=$b"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────"
printf 'summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
