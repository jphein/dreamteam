#!/usr/bin/env bash
# dreamteam — one-command OOM/incident forensics (issue #7).
#
# Assembles the evidence the 2026-07-01 16:06 incident required by hand:
# systemd-oomd kills, earlyoom activity, the plugin's own pre-crash traces,
# the live roster, containment-scope state, and a memory snapshot. Markdown
# to stdout. Read-only; always exits 0.
#
# Usage: incident-report.sh [--since "24 hours ago"] [--save]
#   --save  after printing, file a one-line index card into the palace (#10):
#           first oomd kill (or "no kills"), live claude-proc count, marker state.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
SINCE="24 hours ago"; SAVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ -n "${2:-}" ] && { SINCE="$2"; shift 2; } || shift;;
    --save)  SAVE=1; shift;;
    *) shift;;
  esac
done

echo "# dreamteam incident report — $(hostname) — $(date +'%F %T %Z')"
echo ""
echo "## systemd-oomd kills (since $SINCE)"
KILLS=$(journalctl -u systemd-oomd --since "$SINCE" --no-pager 2>/dev/null | grep -E 'Killed .* due to' || true)
if [ -n "$KILLS" ]; then
  printf '%s\n' "$KILLS" | sed 's/^/    /'
  echo ""
  echo "### last kill context"
  journalctl -u systemd-oomd --since "$SINCE" --no-pager 2>/dev/null | tail -20 | sed 's/^/    /'
else
  echo "    (none)"
fi
echo ""
echo "## earlyoom activity (since $SINCE)"
{ journalctl -u earlyoom --since "$SINCE" --no-pager 2>/dev/null | grep -iE 'sending|kill|low memory' || echo "    (none)"; } | sed 's/^ *//;s/^/    /'
echo ""
echo "## plugin pre-crash traces"
echo "### dreamteam.log (last 15)"
tail -n 15 "$STATE/dreamteam.log" 2>/dev/null | sed 's/^/    /' || echo "    (no log)"
echo "### events.log (last 15)"
tail -n 15 "$STATE/events.log" 2>/dev/null | sed 's/^/    /' || echo "    (no events)"
echo ""
echo "## live roster"
bash "$ROOT/scripts/roster.sh" 2>/dev/null | sed 's/^/    /' || echo "    (unavailable)"
echo ""
echo "## containment scopes"
# Forensics wants EVERY dreamteam scope (#19: per-project scopes coexist with
# the draining legacy shared one), not just this project's.
_SCOPES=$(systemctl --user list-units 'dreamteam-*.scope' --no-legend --plain 2>/dev/null | awk '{print $1}')
if [ -n "$_SCOPES" ]; then
  for _s in $_SCOPES; do
    CUR=$(systemctl --user show "$_s" -p MemoryCurrent --value 2>/dev/null); CUR=${CUR//[!0-9]/}
    echo "    ${_s}: ACTIVE, MemoryCurrent=$(( ${CUR:-0} / 1048576 ))MiB"
    systemctl --user show "$_s" -p MemoryHigh -p MemoryMax -p MemorySwapMax --no-pager 2>/dev/null | sed 's/^/      /'
  done
else
  echo "    no dreamteam-*.scope active"
fi
[ -f "$STATE/active" ] && echo "    ⚠ crash marker PRESENT: $(cat "$STATE/active")" || echo "    crash marker: clear"
echo ""
echo "## memory snapshot"
free -m 2>/dev/null | sed 's/^/    /'
echo "### top RSS"
ps -eo rss,comm --sort=-rss 2>/dev/null | head -6 | sed 's/^/    /'
echo "### claude procs"
echo "    count: $(pgrep -fc 'claude/versions' 2>/dev/null || echo 0)"
pgrep -af 'claude/versions' 2>/dev/null | grep -oE -- '--agent-name [^ ]+' | sed 's/^/    /' || true

# --save (#10): file a one-line index card AFTER the report. palace-file.sh is
# silent + self-gating, so it never disturbs the report on stdout above.
if [ "$SAVE" -eq 1 ]; then
  FIRSTKILL="$(printf '%s\n' "$KILLS" | grep -m1 'Killed' 2>/dev/null || true)"
  [ -n "$FIRSTKILL" ] || FIRSTKILL="no kills since $SINCE"
  NPROCS="$(pgrep -fc 'claude/versions' 2>/dev/null || echo 0)"; NPROCS="${NPROCS//[!0-9]/}"; NPROCS="${NPROCS:-0}"
  MARKER="clear"; [ -f "$STATE/active" ] && MARKER="PRESENT"
  bash "$ROOT/scripts/palace-file.sh" --topic dreamteam \
    "incident report ($(hostname), since ${SINCE}) — oomd: $(printf '%s' "$FIRSTKILL" | tr -s ' ' | cut -c1-160) · claude procs: ${NPROCS} · crash marker: ${MARKER}" \
    >/dev/null 2>&1 || true
fi
exit 0
