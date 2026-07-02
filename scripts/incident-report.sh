#!/usr/bin/env bash
# dreamteam — one-command OOM/incident forensics (issue #7).
#
# Assembles the evidence the 2026-07-01 16:06 incident required by hand:
# systemd-oomd kills, earlyoom activity, the plugin's own pre-crash traces,
# the live roster, containment-scope state, and a memory snapshot. Markdown
# to stdout. Read-only; always exits 0.
#
# Usage: incident-report.sh [--since "24 hours ago"]
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
SINCE="24 hours ago"
[ "${1:-}" = "--since" ] && [ -n "${2:-}" ] && SINCE="$2"

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
echo "## containment scope"
if systemctl --user is-active --quiet dreamteam-agents.scope 2>/dev/null; then
  CUR=$(systemctl --user show dreamteam-agents.scope -p MemoryCurrent --value 2>/dev/null); CUR=${CUR//[!0-9]/}
  echo "    dreamteam-agents.scope: ACTIVE, MemoryCurrent=$(( ${CUR:-0} / 1048576 ))MiB"
  systemctl --user show dreamteam-agents.scope -p MemoryHigh -p MemoryMax -p MemorySwapMax --no-pager 2>/dev/null | sed 's/^/    /'
else
  echo "    dreamteam-agents.scope: not active"
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
exit 0
