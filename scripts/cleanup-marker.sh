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
rm -f "$STATE/active"
exit 0
