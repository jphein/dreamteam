#!/usr/bin/env bash
# dreamteam test runner — executes every tests/test-*.sh and aggregates results.
#
# Each suite is standalone (own PASS:/FAIL: lines, exits non-zero on any failure)
# and self-isolating (PATH-stubbed free/ps/pgrep, fixture team configs, temp
# state via the scripts' DREAMTEAM_* env seams — no production script is touched).
#
# Usage: bash tests/run.sh        # exit 0 iff every suite is green
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

fail=0; ran=0; failed_suites=""
for t in "$DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  ran=$((ran + 1))
  name="$(basename "$t")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ $name"
  if bash "$t"; then
    echo "  → $name: OK"
  else
    echo "  → $name: FAILED (exit $?)"
    fail=$((fail + 1)); failed_suites="$failed_suites $name"
  fi
  echo ""
done

echo "═══════════════════════════════════════════════"
if [ "$ran" -eq 0 ]; then
  echo "no test suites found in $DIR"; exit 1
fi
if [ "$fail" -eq 0 ]; then
  echo "ALL SUITES PASS ($ran/$ran)"; exit 0
fi
echo "FAILED: $fail/$ran suites —$failed_suites"; exit 1
