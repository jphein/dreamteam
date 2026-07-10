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
echo "== defaults agreement: dashboard-data / mem-budget / mem-gate (+ scope caps) =="
# Guards the 600/4000 drift class. Anchored on the default LITERALS themselves —
#   dashboard-data.sh:  m("KEY", N)
#   mem-budget.sh:      getcfg KEY N
#   mem-gate.sh:        getcfg KEY N   (#55 — the ACTUAL admission gate)
# — so a concurrent edit that moves the roster section doesn't affect this parse.
DASH="$ROOT/scripts/dashboard-data.sh"; BUD="$ROOT/scripts/mem-budget.sh"; GATE="$ROOT/scripts/mem-gate.sh"
extract_dash(){ grep -oE "m\\(\"$1\", *[0-9]+\\)" "$DASH" | head -1 | grep -oE '[0-9]+' | head -1; }
extract_bud(){  grep -oE "getcfg +$1 +[0-9]+"      "$BUD"  | head -1 | grep -oE '[0-9]+' | head -1; }
extract_gate(){ grep -oE "getcfg +$1 +[0-9]+"      "$GATE" | head -1 | grep -oE '[0-9]+' | head -1; }
# All THREE consumers of the .memory defaults must agree. mem-gate.sh is the
# PreToolUse admission gate — if its baked default drifts from mem-budget /
# dashboard, the gate ADMITS on a different budget than /dreamteam-status and the
# dashboard REPORT (#55: same drift class, on the script that decides admission).
for k in perAgentMB hostReserveMB balloonReserveMB minAvailableMB maxAgents; do
  d="$(extract_dash "$k")"; b="$(extract_bud "$k")"; g="$(extract_gate "$k")"
  if   [ -z "$d" ]; then fail "defaults: '$k' default not found in dashboard-data.sh"
  elif [ -z "$b" ]; then fail "defaults: '$k' default not found in mem-budget.sh"
  elif [ -z "$g" ]; then fail "defaults: '$k' default not found in mem-gate.sh"
  elif [ "$d" = "$b" ] && [ "$b" = "$g" ]; then pass "defaults agree: $k = $d (dashboard-data, mem-budget, mem-gate)"
  else fail "defaults DRIFT: $k dashboard-data=$d mem-budget=$b mem-gate=$g"
  fi
done

# Local-lane reserve (#37): .local.reserveMB is read in THREE places — dashboard-data
# (ml("reserveMB", N)), mem-budget + mem-gate (getlocal reserveMB N). All must agree,
# or the dashboard shows a budget the gate won't enforce (same drift class, new knob).
# (GATE defined above, with DASH/BUD.)
dl="$(grep -oE 'ml\("reserveMB", *[0-9]+\)' "$DASH" | grep -oE '[0-9]+' | head -1)"
bl="$(grep -oE 'getlocal +reserveMB +[0-9]+'  "$BUD"  | grep -oE '[0-9]+' | head -1)"
gl="$(grep -oE 'getlocal +reserveMB +[0-9]+'  "$GATE" | grep -oE '[0-9]+' | head -1)"
if   [ -z "$dl" ]; then fail "defaults: '.local.reserveMB' default not found in dashboard-data.sh"
elif [ -z "$bl" ]; then fail "defaults: '.local.reserveMB' default not found in mem-budget.sh"
elif [ -z "$gl" ]; then fail "defaults: '.local.reserveMB' default not found in mem-gate.sh"
elif [ "$dl" = "$bl" ] && [ "$bl" = "$gl" ]; then pass "defaults agree: .local.reserveMB = $dl (dashboard-data, mem-budget, mem-gate)"
else fail "defaults DRIFT: reserveMB dashboard-data=$dl mem-budget=$bl mem-gate=$gl"
fi

# ── scope caps agreement (#55) ───────────────────────────────────────────────
# memoryHigh/memoryMax set the cgroup ceiling in BOTH launch-dreamteam.sh (getcfg,
# reads .scope) and scope-attach.sh (getscope), and are REPORTED by mem-budget.sh
# (getscope). memorySwapMax is set by launch + scope-attach only. Drift = the
# whole-session scope and the per-spawn attach cap the team differently — a silent
# containment inconsistency in the config-absent fallback path. Same literal-anchored
# parse as above; values carry a unit (20G/24G/8G).
LAUNCH="$ROOT/scripts/launch-dreamteam.sh"; ATTACH="$ROOT/scripts/scope-attach.sh"
sval(){ grep -oE "$2 +$1 +[0-9]+[A-Za-z]*" "$3" | head -1 | grep -oE '[0-9]+[A-Za-z]*' | head -1; }
for k in memoryHigh memoryMax; do
  l="$(sval "$k" getcfg "$LAUNCH")"; a="$(sval "$k" getscope "$ATTACH")"; m="$(sval "$k" getscope "$BUD")"
  if   [ -z "$l" ]; then fail "scope: '$k' default not found in launch-dreamteam.sh"
  elif [ -z "$a" ]; then fail "scope: '$k' default not found in scope-attach.sh"
  elif [ -z "$m" ]; then fail "scope: '$k' default not found in mem-budget.sh"
  elif [ "$l" = "$a" ] && [ "$a" = "$m" ]; then pass "scope caps agree: $k = $l (launch, scope-attach, mem-budget)"
  else fail "scope caps DRIFT: $k launch=$l scope-attach=$a mem-budget=$m"
  fi
done
# memorySwapMax: launch + scope-attach only (mem-budget doesn't cap swap).
sl="$(sval memorySwapMax getcfg "$LAUNCH")"; sa="$(sval memorySwapMax getscope "$ATTACH")"
if   [ -z "$sl" ]; then fail "scope: 'memorySwapMax' default not found in launch-dreamteam.sh"
elif [ -z "$sa" ]; then fail "scope: 'memorySwapMax' default not found in scope-attach.sh"
elif [ "$sl" = "$sa" ]; then pass "scope caps agree: memorySwapMax = $sl (launch, scope-attach)"
else fail "scope caps DRIFT: memorySwapMax launch=$sl scope-attach=$sa"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────"
printf 'summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
