#!/usr/bin/env bash
# dreamteam — CRASH RECOVERY  (SessionStart hook, matcher: startup|clear)
#
# ⚠ ARCHITECTURE NOTE: there is no "post-crash" hook event. We detect crash
# RESIDUE instead: a team that shuts down cleanly clears its active-marker
# (SessionEnd → cleanup-marker.sh). If the marker is still present at the next
# SessionStart, the prior dreamteam session died uncleanly (OOM, terminal loss,
# kill). SessionStart stdout is injected into the new session's context, so this
# surfaces the recovery checklist automatically — no human has to remember it.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/dreamteam}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
MARKER="$STATE/active"

# Always inject the last-known roster so the coordinator starts aware of prior agents
ROSTER="$STATE/agents.json"
if [ -f "$ROSTER" ] && [ -s "$ROSTER" ]; then
  ROSTER_LINE=$(jq -r '[.[] | "\(.name)(\(.status))"] | join(" ")' "$ROSTER" 2>/dev/null || true)
  if [ -n "$ROSTER_LINE" ]; then
    NAGENTS=$(jq 'length' "$ROSTER" 2>/dev/null || echo 0)
    echo "dreamteam roster from prior session: ${NAGENTS} agents — ${ROSTER_LINE}"
    echo "    Verify which are still alive: check tmux panes or spawn-accounting log."
    echo ""
  fi
fi

[ -f "$MARKER" ] || exit 0   # clean — nothing to recover

TEAM=$(jq -r '.team // "unknown"' "$MARKER" 2>/dev/null || echo unknown)
REPO=$(jq -r '.repo // empty' "$MARKER" 2>/dev/null || echo "")
STARTED=$(jq -r '.started // "?"' "$MARKER" 2>/dev/null || echo "?")

echo "⚠️  DREAMTEAM CRASH RECOVERY — team '$TEAM' (started $STARTED) did not shut down cleanly."
echo "    Likely an OOM cascade or terminal loss. Do these BEFORE starting new work:"
echo ""
echo "  1) Uncommitted work in worktrees (agents may have died mid-edit — STASH before touching):"
if [ -n "$REPO" ] && [ -d "$REPO/.claude/worktrees" ]; then
  for w in "$REPO"/.claude/worktrees/*/; do
    [ -d "$w" ] || continue
    dirty=$(git -C "$w" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    flag=""; [ "${dirty:-0}" -gt 0 ] && flag="   ← STASH FIRST: git -C '$w' stash push -u -m crash-$(date +%F)"
    echo "       ${w}: ${dirty} uncommitted file(s)${flag}"
  done
else
  echo "       (repo path unknown — check .claude/worktrees in the active project manually)"
fi
echo ""
echo "  2) Reconcile the merge cascade: gh pr list --state merged --limit 40 ; gh pr list --state open"
echo "  3) Read $STATE/HANDOFF.md (continuous checkpoint) and the team roster.md"
echo "  4) Tail $STATE/dreamteam.log for the pre-crash footprint trace (agent count + total RSS growth)"
echo "  5) Re-spawn missing overnight roles (Reeve/Hermes/Argus); resume from the next un-merged item."
echo ""
echo "    After recovery, clear this notice:  rm '$MARKER'"
exit 0
