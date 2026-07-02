#!/usr/bin/env bash
# dreamteam tests — incident-report.sh (read-only forensics bundle).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IR="$ROOT/scripts/incident-report.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$IR" && ok "bash -n incident-report.sh" || bad "bash -n"

OUT=$(DREAMTEAM_STATE="$TMP" bash "$IR" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || bad "exit $RC"
for sec in "# dreamteam incident report" "## systemd-oomd kills" "## plugin pre-crash traces" "## live roster" "## containment scope" "## memory snapshot"; do
  case "$OUT" in *"$sec"*) ok "section present: $sec";; *) bad "missing section: $sec";; esac
done
# empty state dir must degrade gracefully, not error
case "$OUT" in *"(no log)"*|*"dreamteam.log"*) ok "empty state handled";; *) bad "empty state handling ($OUT)";; esac
OUT2=$(DREAMTEAM_STATE="$TMP" bash "$IR" --since "1 hour ago" 2>&1) && ok "--since accepted" || bad "--since"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
