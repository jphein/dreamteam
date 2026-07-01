#!/usr/bin/env bash
# dreamteam — regression test for CLAUDE_PLUGIN_ROOT self-location.
#
# BUG (fixed): run from a bare terminal with CLAUDE_PLUGIN_ROOT UNSET, the old
# fallback `ROOT="$HOME/.claude/plugins/dreamteam"` pointed at a dir that does
# not exist on this box → CFG missing → scripts silently used baked-in defaults
# instead of the real config.json. Hooks/commands always export the env var, so
# only manual CLI use was affected.
#
# FIX: ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
#   Lazy default — evaluated ONLY when the env var is unset, so the hook path
#   (env always set) is byte-identical. Scripts live in scripts/, so ../ = the
#   real plugin dir with config.json, regardless of the caller's cwd.
#
# PROOF (matched pair + syntax):
#   • env UNSET from a foreign cwd (/tmp) → mem-budget.sh must report the real
#     config.json perAgentMB, NOT the 400 baked-in default. (self-location works)
#   • env SET to an empty dir → must fall back to the default. (the `:-` fires
#     ONLY on the unset branch → env-set/hook behavior is unchanged)
#   • bash -n clean on all 7 edited scripts.
#
# Standalone: bash tests/test-root.sh  (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
CONFIG="$ROOT/config.json"
BAKED_DEFAULT=400          # perAgentMB default baked into mem-budget.sh's getcfg

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BOGUS="$TMP/bogus-root"; mkdir -p "$BOGUS"   # empty: no config.json, no scripts/lib.sh

EDITED=(mem-budget.sh mem-gate.sh reuse-gate.sh spawn-accounting.sh
        crash-audit.sh cleanup-marker.sh launch-dreamteam.sh)

# extract the integer from a "  per-agent plan: N MiB ..." line
per_agent_of() { printf '%s\n' "$1" | sed -n 's/.*per-agent plan: \([0-9][0-9]*\).*/\1/p' | head -1; }

echo "── syntax (bash -n) of all 7 self-location-edited scripts ───────"
for s in "${EDITED[@]}"; do
  if bash -n "$SCRIPTS/$s" 2>"$TMP/nerr"; then
    pass "bash -n clean: scripts/$s"
  else
    fail "bash -n FAILED: scripts/$s — $(head -1 "$TMP/nerr")"
  fi
done

echo "── self-location proof (mem-budget.sh reads real config.json) ───"
CFG_VAL="$(jq -r '.memory.perAgentMB' "$CONFIG" 2>/dev/null || echo '')"

# Discriminator guard: the proof only distinguishes config-read from fallback
# while the config value differs from the baked default.
if [ -z "$CFG_VAL" ]; then
  fail "could not read .memory.perAgentMB from $CONFIG"
elif [ "$CFG_VAL" = "$BAKED_DEFAULT" ]; then
  fail "INCONCLUSIVE: config perAgentMB ($CFG_VAL) == baked default ($BAKED_DEFAULT) — cannot distinguish a real config read from a fallback. Set config perAgentMB != $BAKED_DEFAULT to keep this test meaningful."
else
  pass "discriminator valid: config perAgentMB=$CFG_VAL differs from baked default $BAKED_DEFAULT"
fi

# Core: run from /tmp with CLAUDE_PLUGIN_ROOT (and DREAMTEAM_CONFIG) UNSET.
# Self-location must find the real config.json → report perAgentMB=$CFG_VAL.
OUT_UNSET="$( cd /tmp && env -u CLAUDE_PLUGIN_ROOT -u DREAMTEAM_CONFIG bash "$SCRIPTS/mem-budget.sh" 2>&1 )"
REP_UNSET="$(per_agent_of "$OUT_UNSET")"
if [ -n "$REP_UNSET" ] && [ "$REP_UNSET" = "$CFG_VAL" ]; then
  pass "CLAUDE_PLUGIN_ROOT UNSET + cwd=/tmp → per-agent=$REP_UNSET (real config), NOT the $BAKED_DEFAULT default → self-location works"
else
  fail "self-location broken: expected per-agent=$CFG_VAL, got '$REP_UNSET' (unset run from /tmp). Output head: $(printf '%s' "$OUT_UNSET" | head -1)"
fi

# Contrast: CLAUDE_PLUGIN_ROOT SET to an empty dir (config missing there) → the
# `:-` default is NOT evaluated, ROOT stays the bogus dir → falls to the baked
# default. Proves the fix touches ONLY the unset branch (hook path unchanged).
OUT_SET="$( cd /tmp && env -u DREAMTEAM_CONFIG CLAUDE_PLUGIN_ROOT="$BOGUS" bash "$SCRIPTS/mem-budget.sh" 2>&1 )"
REP_SET="$(per_agent_of "$OUT_SET")"
if [ "$REP_SET" = "$BAKED_DEFAULT" ]; then
  pass "CLAUDE_PLUGIN_ROOT SET to empty dir → per-agent=$REP_SET (baked default) → env-set branch honored, unchanged by the fix"
else
  fail "contrast unexpected: with a bogus ROOT expected default $BAKED_DEFAULT, got '$REP_SET'. Output head: $(printf '%s' "$OUT_SET" | head -1)"
fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
