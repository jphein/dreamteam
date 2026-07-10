#!/usr/bin/env bash
# dreamteam — regression tests for the MANAGER-ROLES gate change (issue #40, R1).
#
#   scripts/spawn-standards.sh — the PreToolUse Agent|Task standards gate.
#
# THE BUG R1 CLOSES (manager-roles design spec §2, Revision 2 R1):
#   The gate keeps two lists — a ROSTER (names allowed) and a TYPED list (names
#   FORCED to spawn with subagent_type dreamteam:<name>, which is what makes the
#   persona system prompt actually load). Before R1, `hypnos`/`nyx` were absent
#   from BOTH. Consequence: `hypnos-agent-manager` spawned with NO subagent_type
#   passed the name check and loaded NO persona — the exact hole the manager
#   pilot fell through (papered over live with STANDARDS-EXEMPT:). R1 adds hypnos
#   to ROSTER and hypnos|nyx to TYPED so a typeless manager spawn is now BLOCKED.
#
# ISOLATION STRATEGY — zero edits to production scripts:
#   spawn-standards.sh observes the world only through stdin JSON + env-overridable
#   paths (DREAMTEAM_CONFIG, CLAUDE_PLUGIN_ROOT) + TMUX. We feed hand-built tool_input
#   JSON on stdin and set TMUX (Rule 0 blocks teammate spawns outside tmux — we set
#   it so the TYPED-persona rule, not the tmux rule, is the deciding factor). The
#   REAL gate logic runs unmodified. Escape hatch STANDARDS-EXEMPT is deliberately
#   NEVER used here — these tests exercise the gate, not the bypass.
#
# NON-VACUOUS CONTROL: `vesper-helper` (a roster name that is NOT typed) with no
#   subagent_type PASSES — proving the hypnos/nyx blocks fire specifically because
#   those names are in the TYPED list, not because the gate blocks every typeless
#   teammate spawn. Paired PASS-with-type / BLOCK-without-type on the SAME name
#   isolates the missing type as the sole cause.
#
# Run standalone:  bash tests/test-manager-gate.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config.json"                 # real config → spawn.enforceStandards=true (gate armed)
GATE="$ROOT/scripts/spawn-standards.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# TMUX must be non-empty so Rule 0 (teammate-requires-tmux) passes and Rule 2
# (typed persona) is what decides. DREAMTEAM_CONFIG points at the real config so
# enforceStandards reads true. CLAUDE_PLUGIN_ROOT is irrelevant once CONFIG is set.
export TMUX="dreamteam-test" DREAMTEAM_CONFIG="$CONFIG" CLAUDE_PLUGIN_ROOT="$ROOT"

# run_gate <stdin-json> — captures exit code in GRC, stderr in $TMP/err.
GRC=0
run_gate() {
  GRC=0
  printf '%s' "$1" | bash "$GATE" 2>"$TMP/err" || GRC=$?
}

# tool_input helpers: a teammate spawn (team_name present) named $1, with ($2) or
# without a subagent_type. Managers are addressable teammates, so team_name models
# the real spawn shape.
spawn_json() {  # $1=name  $2=subagent_type (optional)
  local name="$1" type="${2:-}"
  if [ -n "$type" ]; then
    printf '{"tool_name":"Agent","tool_input":{"name":"%s","team_name":"dream","subagent_type":"%s","prompt":"boot as manager"}}' "$name" "$type"
  else
    printf '{"tool_name":"Agent","tool_input":{"name":"%s","team_name":"dream","prompt":"boot as manager"}}' "$name"
  fi
}

echo "── spawn-standards.sh — manager roles (hypnos/nyx) gate ─────────"

# 1) PASS — hypnos with its type. Roster name ✓, role suffix ✓, TYPE matches ✓.
run_gate "$(spawn_json hypnos-agent-manager dreamteam:hypnos)"
if [ "$GRC" -eq 0 ]; then
  pass "hypnos-agent-manager + subagent_type dreamteam:hypnos PASSES (exit 0)"
else
  fail "hypnos WITH type should pass — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 2) BLOCK — hypnos WITHOUT a type. THE R1 HOLE, now closed. Must block on the
#    typed-persona rule specifically (stderr names dreamteam:hypnos), NOT on the
#    tmux rule (TMUX is set) or the name rule (hypnos is a valid roster name).
run_gate "$(spawn_json hypnos-agent-manager)"
if [ "$GRC" -eq 2 ] && grep -q 'dreamteam:hypnos' "$TMP/err" && grep -qi 'typed persona' "$TMP/err"; then
  pass "hypnos-agent-manager with NO subagent_type is BLOCKED (exit 2, typed-persona reason) — R1 hole closed"
else
  fail "typeless hypnos should block on typed-persona rule — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 3) PASS — nyx with its type.
run_gate "$(spawn_json nyx-resource-manager dreamteam:nyx)"
if [ "$GRC" -eq 0 ]; then
  pass "nyx-resource-manager + subagent_type dreamteam:nyx PASSES (exit 0)"
else
  fail "nyx WITH type should pass — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 4) BLOCK — nyx WITHOUT a type (nyx was already in ROSTER pre-R1; R1 added it to
#    TYPED, so a typeless nyx now blocks too).
run_gate "$(spawn_json nyx-resource-manager)"
if [ "$GRC" -eq 2 ] && grep -q 'dreamteam:nyx' "$TMP/err" && grep -qi 'typed persona' "$TMP/err"; then
  pass "nyx-resource-manager with NO subagent_type is BLOCKED (exit 2, typed-persona reason)"
else
  fail "typeless nyx should block on typed-persona rule — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 5) NON-VACUOUS CONTROL — a roster name that is NOT typed (vesper) with no type
#    PASSES. Proves 2)/4) block because hypnos/nyx are in the TYPED list, not
#    because the gate rejects every typeless teammate spawn.
run_gate "$(spawn_json vesper-helper)"
if [ "$GRC" -eq 0 ]; then
  pass "CONTROL: typeless vesper-helper (roster, NOT typed) PASSES (exit 0) — block in 2/4 is TYPED-specific"
else
  fail "typeless vesper should pass (not a typed name) — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 6) WRONG TYPE — hypnos with the wrong persona type still blocks (guards against
#    a spawn that sets *some* type but not the matching one).
run_gate "$(spawn_json hypnos-agent-manager dreamteam:morpheus)"
if [ "$GRC" -eq 2 ] && grep -q 'dreamteam:hypnos' "$TMP/err"; then
  pass "hypnos-agent-manager + WRONG type (dreamteam:morpheus) is BLOCKED (exit 2, must be dreamteam:hypnos)"
else
  fail "hypnos with wrong type should block — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
