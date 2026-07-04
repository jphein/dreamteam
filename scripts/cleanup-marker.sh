#!/usr/bin/env bash
# dreamteam — clean-shutdown marker clear  (SessionEnd hook)
#
# Clears the active-marker so the next SessionStart's crash-audit does NOT
# false-positive. A SessionEnd firing means the session ended through the normal
# harness path (not a kill), so any team it owned shut down cleanly.
#
# NOTE: an OOM kill / terminal loss does NOT fire SessionEnd — which is exactly
# the point: the marker survives an unclean exit and crash-audit detects it.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"

# #10: a marker present at SessionEnd means a team ran this session AND it's a
# clean exit (an OOM/terminal-loss never fires SessionEnd). File a completion card
# BEFORE clearing the marker. palace-file.sh self-gates (DREAMTEAM_TEST / no daemon
# → silent queue) and writes no stdout. No marker → no team ran → no card.
if [ -f "$STATE/active" ]; then
  _MTEAM="$(jq -r '.team // "?"' "$STATE/active" 2>/dev/null || echo '?')"; [ -n "$_MTEAM" ] || _MTEAM="?"
  _COUNTS="$(bash "$ROOT/scripts/roster.sh" --json 2>/dev/null \
    | jq -r '.counts | "\(.lead) lead, \(.active) active, \(.idle) idle, \(.dead) dead"' 2>/dev/null || true)"
  [ -n "$_COUNTS" ] || _COUNTS="roster unavailable"
  bash "$ROOT/scripts/palace-file.sh" --topic dreamteam \
    "clean shutdown — team ${_MTEAM} · roster: ${_COUNTS} · $(date +%FT%T)" \
    >/dev/null 2>&1 || true
fi

rm -f "$STATE/active"

# Tear down containment scopes that hold nothing but their anchor. Two targets:
#   1. THIS project's scope (#19: per-project name via lib.sh) — same-project
#      sibling sessions may still have agents there, so only stop when empty.
#   2. The LEGACY shared scope (dreamteam-agents) — transition sweeper: every
#      project's agents are migrating to per-project scopes, so once no agent
#      proc lives in the shared one, any clean session-end may retire it.
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh" 2>/dev/null || true
DT_SCOPE="$(command -v dreamteam_scope_name >/dev/null 2>&1 && dreamteam_scope_name || echo dreamteam-agents)"
stop_scope_if_empty() {
  local scope="$1" pid
  systemctl --user is-active --quiet "$scope.scope" 2>/dev/null || return 0
  for pid in $(pgrep -f 'claude/versions' 2>/dev/null); do
    grep -q "$scope.scope" "/proc/$pid/cgroup" 2>/dev/null && return 0   # occupied — leave it
  done
  systemctl --user stop "$scope.scope" 2>/dev/null || true
}
if command -v systemctl >/dev/null 2>&1; then
  stop_scope_if_empty "$DT_SCOPE"
  [ "$DT_SCOPE" != "dreamteam-agents" ] && stop_scope_if_empty "dreamteam-agents"
fi
exit 0
