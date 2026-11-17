#!/usr/bin/env bash
# dreamteam — weekly self-audit (issue #15).
#
# WHAT / WHY
#   A plugin this load-bearing rots silently: the test suite drifts, the
#   statusline payload shape changes under it (it already did — the .effort object
#   + nested context_window, 2026-07-01), the palace daemon goes unreachable, and
#   the append-only logs grow without bound. This is the weekly cron's health
#   sweep — it EXERCISES the guardrails and reports, so a regression surfaces as a
#   filed issue instead of a 3am surprise.
#
#   Checks (all report-only except the log prune):
#     1. tests/run.sh — the full regression suite; its exit code drives the summary.
#     2. statusline payload drift — the last captured payload still parses AND
#        carries the keys statusline.sh reads (model, context_window). We do NOT
#        `touch state/statusline-debug` — that arms a capture on JP's NEXT render
#        (interactive-only); we just inspect whatever is already there, if any.
#     3. palace reachability — probe the daemon health endpoint (report-only).
#     4. log hygiene — prune events.log + dreamteam.log to the last 2000 lines
#        in place (atomic same-dir temp+mv). The ONLY mutation this script makes.
#
#   Summary line → stdout (the SUITE's exit code is embedded in it) + a palace
#   index card. Always exits 0: a health check that fails the session is worse
#   than the rot it watches for; failures live in the summary, not the exit code.
#
# CONTRACTS CONSUMED (owned by siblings; silent no-op until they land):
#   • scripts/palace-file.sh --topic <t> "<entry>"   (morpheus)
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
mkdir -p "$STATE"

palace_card() {  # morpheus: scripts/palace-file.sh --topic <t> "<entry>"
  [ -f "$ROOT/scripts/palace-file.sh" ] && bash "$ROOT/scripts/palace-file.sh" --topic "$1" "$2" >/dev/null 2>&1 || true
}

# ── 1. regression suite ──────────────────────────────────────────────────────
TEST_OUT=""; TEST_RC=0
if [ -f "$ROOT/tests/run.sh" ]; then
  TEST_OUT=$(bash "$ROOT/tests/run.sh" 2>&1); TEST_RC=$?
else
  TEST_OUT="(tests/run.sh not found)"; TEST_RC=127
fi
[ "$TEST_RC" -eq 0 ] && TESTS="PASS" || TESTS="FAIL(rc=$TEST_RC)"

# ── 2. statusline payload drift (inspect only if a capture exists) ────────────
PAYLOAD="$STATE/statusline-payload.json"
if [ -f "$PAYLOAD" ]; then
  if jq -e 'has("model") and has("context_window")' "$PAYLOAD" >/dev/null 2>&1; then
    STATUSLINE="ok"
  elif jq -e '.' "$PAYLOAD" >/dev/null 2>&1; then
    STATUSLINE="DRIFT(parses, missing model/context_window)"
  else
    STATUSLINE="DRIFT(unparseable payload)"
  fi
else
  STATUSLINE="n/a(no capture)"
fi

# ── 3. palace reachability (report-only; 000 = no connection, any HTTP = up) ──
PALACE="unknown"
ENVF="$HOME/.config/palace-daemon/env"
if [ -f "$ENVF" ]; then
  # shellcheck disable=SC1090
  . "$ENVF" 2>/dev/null || true
  if [ -n "${PALACE_DAEMON_URL:-}" ]; then
    CODE=$(curl -m 5 -s -o /dev/null -w '%{http_code}' "$PALACE_DAEMON_URL/health" 2>/dev/null || echo 000)
    [ "$CODE" = "000" ] && PALACE="UNREACHABLE" || PALACE="reachable(HTTP $CODE)"
  else
    PALACE="no-url-in-env"
  fi
else
  PALACE="no-env-file"
fi

# ── 4. log hygiene — prune to last N lines in place (atomic same-dir temp+mv) ──
PRUNED=""
prune() {
  local f="$1" keep="${2:-2000}" n tmp
  [ -f "$f" ] || return 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); n=${n:-0}
  if [ "$n" -gt "$keep" ]; then
    tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
    if tail -n "$keep" "$f" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$f" && PRUNED="${PRUNED}$(basename "$f")($n→$keep) "
    else
      rm -f "$tmp"
    fi
  fi
}
prune "$STATE/events.log" 2000
prune "$STATE/dreamteam.log" 2000
[ -n "$PRUNED" ] || PRUNED="none-needed"

# ── summary → stdout + palace card ───────────────────────────────────────────
SUMMARY="self-audit $(date +%F): tests=${TESTS} · statusline=${STATUSLINE} · palace=${PALACE} · pruned=${PRUNED}"
echo "$SUMMARY"

# ── the CHECK line (docs/CHECKS.md row dreamteam-audit; fleet shape, FOR-AGENTS rule 24) ─────────────────────
# Suites: ONLY run.sh's last non-empty line counts, anchored, with consistent counts ("ALL SUITES PASS (n/n)", n>0, or
# "FAILED: k/n suites — names", 0<k<=n); anything else, or no run.sh, is "suites unreadable" → fail. An audit that
# could not tell must never print ok (xreview r1, 2026-11-17). Health: ok needs the statusline ok or not captured
# (n/a is by design: the audit never arms a capture) AND the palace answering; otherwise warn, naming what.
CHECK_NAME="${DREAMTEAM_CHECK_NAME:-dreamteam-audit$( [ "$(hostname 2>/dev/null)" = familiar ] || echo "-$(hostname 2>/dev/null)")}"
CHECKS_DIR="${DREAMTEAM_CHECKS_DIR:-$HOME/.local/state/checks}"
NAME_OK=1
[[ "$CHECK_NAME" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [[ "$CHECK_NAME" != *..* ]] || NAME_OK=0
[ "$NAME_OK" -eq 1 ] || { echo "self-audit: refusing check name '${CHECK_NAME//[^[:print:]]/?}' (not a plain basename); not publishing" >&2; CHECK_NAME="dreamteam-audit"; }
LAST=$(printf '%s\n' "$TEST_OUT" | awk 'NF {l=$0} END {print l}')
FAILING=""; STATUS=fail; SUITES="suites unreadable (run.sh rc=${TEST_RC})"
if [[ "$LAST" =~ ^ALL\ SUITES\ PASS\ \(([0-9]+)/([0-9]+)\)$ ]] && [ "$TEST_RC" -eq 0 ] \
   && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" -gt 0 ]; then
  STATUS=ok; SUITES="suites ${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$LAST" =~ ^FAILED:\ ([0-9]+)/([0-9]+)\ suites\ —\ ?(.*)$ ]] && [ "$TEST_RC" -ne 0 ] \
   && [ "${BASH_REMATCH[1]}" -gt 0 ] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ]; then
  k=$((10#${BASH_REMATCH[1]})); n=$((10#${BASH_REMATCH[2]}))   # base 10: "09" is nine, not a bad octal
  names=${BASH_REMATCH[3]}
  # trusted only when it names exactly k suites, each a plain test-*.sh basename (run.sh's own listing)
  if [[ "$names" =~ ^(\ *test-[A-Za-z0-9._-]+\.sh)+\ *$ ]] && [ "$(wc -w <<< "$names")" -eq "$k" ]; then
    FAILING=$(xargs <<< "$names" | tr ' ' ',')
    SUITES="suites $(( n - k ))/${n}, failing ${FAILING}"
  fi
fi
HEALTH=""
case "$STATUSLINE" in ok|"n/a(no capture)") ;; *) HEALTH="${HEALTH}statusline " ;; esac
case "$PALACE" in "reachable(HTTP 2"*) ;; *) HEALTH="${HEALTH}palace " ;; esac
[ "$STATUS" = ok ] && [ -n "$HEALTH" ] && STATUS=warn
case "$STATUS" in
  ok)   NEXT="next Sun 03:07, owner Sen" ;;
  warn) NEXT="check $(echo $HEALTH | tr ' ' '+'), owner Sen" ;;
  *)    NEXT="fix ${FAILING:-the suite run}, owner Sen" ;;
esac
CHECK_LINE="CHECK ${CHECK_NAME} ${STATUS} · ${SUITES} · statusline ${STATUSLINE} · palace ${PALACE} (run $(date '+%m-%d %H:%M')) · ${NEXT}"
CHECK_LINE=${CHECK_LINE//[$'\n\r']/ }
echo "$CHECK_LINE"
# Publication: a unique, exclusively created temp file in the same dir, then mv -T over the line (a symlink or a
# directory at the destination is replaced or refused, never followed). Overlapping audits never share a temp file.
publish_line() {
  local tmp
  [ "$NAME_OK" -eq 1 ] || return 1
  mkdir -p "$CHECKS_DIR" 2>/dev/null && [ -d "$CHECKS_DIR" ] || return 1
  tmp=$(mktemp "$CHECKS_DIR/.$CHECK_NAME.line.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$CHECK_LINE" > "$tmp" && mv -T -f "$tmp" "$CHECKS_DIR/$CHECK_NAME.line" 2>/dev/null; then return 0; fi
  rm -f "$tmp"; return 1
}
publish_line || echo "self-audit: could not write $CHECKS_DIR/$CHECK_NAME.line (the line above is the record)" >&2

# On failure, surface the suite output so the weekly cron can file a useful issue: each failing suite's own
# section first (the 2026-11-15 run kept only the last 40 lines, which cut the failing suite's FAIL lines off),
# then the tail.
if [ "$TEST_RC" -ne 0 ]; then
  echo "--- tests/run.sh output (rc=$TEST_RC) ---"
  for s in ${FAILING//,/ }; do
    echo "--- failing suite: $s ---"
    printf '%s\n' "$TEST_OUT" | awk -v s="$s" 'index($0, "━ " s) {on=1} on {print} on && index($0, "→ " s ":") {exit}' | head -n 200
  done
  echo "--- last 40 lines ---"
  printf '%s\n' "$TEST_OUT" | tail -n 40
fi
palace_card "self-audit" "$SUMMARY"
exit 0
