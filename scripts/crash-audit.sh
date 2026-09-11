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

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
MARKER="$STATE/active"

# Inject the TRUE live roster from the AUTHORITATIVE harness team config so the
# coordinator starts aware of every prior agent AND its real status. Replaces the
# retired state/agents.json (lossy — only saw new spawns, never marked idle/dead,
# so it reported live agents as "stale"). roster.sh reads liveness live and always
# exits 0; it prints "no team roster found" when there's nothing, which we skip.
ROSTER_OUT=$(bash "$ROOT/scripts/roster.sh" 2>/dev/null || true)
case "$ROSTER_OUT" in
  "dreamteam roster"*)
    echo "$ROSTER_OUT"
    echo "    (live from harness team config — 'idle' agents are alive & REUSABLE via SendMessage)"
    echo ""
    ;;
esac

# ── #58 (spec S8): proactive silent-death detection ─────────────────────────
# An OOM SIGKILL skips the SubagentStop hook, so a dead agent can be treated as
# live for a whole session. roster.sh --json marks a member "dead" when its
# agentId has no live pid; surface those explicitly. SessionStart fires on
# startup AND /clear, so this also reconciles a mid-session context reset.
ROSTER_JSON=$(bash "$ROOT/scripts/roster.sh" --json 2>/dev/null || true)
DEAD=$(printf '%s' "$ROSTER_JSON" | jq -r '(.agents // [])[] | select(.status=="dead") | .name' 2>/dev/null || true)
if [ -n "$DEAD" ]; then
  N=$(printf '%s\n' "$DEAD" | grep -c .)
  echo "⚠️  DREAMTEAM LIVENESS — $N roster member(s) are DEAD (agentId has no live process):"
  printf '       • %s\n' $DEAD
  echo "    An OOM SIGKILL skips SubagentStop, so a silently-dead agent still looks live to reuse/roster."
  echo "    Do NOT route work to these — mark them dead in roster.md; re-spawn only if work is unfinished."
  echo ""
fi

# ── #54: shared-checkout branch guard (non-blocking warn) ───────────────────
# No-worktree agents (reused workers, standing managers) inherit the shared
# checkout's branch; if it's left off the default they can commit onto a stale
# base. SessionStart can't fix it, but it surfaces it. $PWD = the session cwd =
# the shared checkout; a LINKED worktree is expected on a feature branch (its
# git-dir != git-common-dir), so skip it. DREAMTEAM_CWD overrides for tests.
CWD="${DREAMTEAM_CWD:-$PWD}"
if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GD=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null || true)
  GCD=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null || true)
  if [ "$GD" = "$GCD" ]; then   # main checkout, not a linked worktree
    CUR=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
    DEF=$(git -C "$CWD" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    DEF="${DEF#origin/}"; [ -z "$DEF" ] && DEF="main"
    if [ -n "$CUR" ] && [ "$CUR" != "$DEF" ]; then
      echo "⚠️  DREAMTEAM CHECKOUT — shared checkout '$CWD' is on '$CUR', not the default '$DEF'."
      echo "    No-worktree agents (reused workers, standing managers) inherit '$CUR' and can commit"
      echo "    onto a stale base. Return before spawning:  git -C '$CWD' checkout $DEF"
      echo ""
    fi
  fi
fi

[ -f "$MARKER" ] || exit 0   # clean — nothing to recover

TEAM=$(jq -r '.team // "unknown"' "$MARKER" 2>/dev/null || echo unknown)
REPO=$(jq -r '.repo // empty' "$MARKER" 2>/dev/null || echo "")
STARTED=$(jq -r '.started // "?"' "$MARKER" 2>/dev/null || echo "?")

# ── concurrent-team guard (2026-09-09) ──────────────────────────────────────
# $STATE is HOST-WIDE (one marker dir for every project), so a session starting
# while ANOTHER project's team is still running sees a marker it does not own.
# That is a neighbour, not crash residue — yet this hook declared a crash and
# pointed the new lead at `rm MARKER`, which would have yanked the LIVE team's
# marker (false flag logged 2026-07-03 in HANDOFF.md; again 2026-09-09 with 21
# idle gnome-speaks agents alive in tmux 'spire'). So ask whether the owner is
# alive first. Instruments: its containment scope is active (systemd releases
# a scope once its last process exits, so is-active is a real liveness signal),
# or a tmux pane still sits in its repo. DREAMTEAM_SCOPE_NAME overrides the
# derived name (test seam, same precedence as lib.sh dreamteam_scope_name);
# DREAMTEAM_TEST=1 skips the tmux probe so fixtures stay hermetic.
owner_alive=""
if [ -n "$REPO" ]; then
  if [ -n "${DREAMTEAM_SCOPE_NAME:-}" ]; then
    OSCOPE="$DREAMTEAM_SCOPE_NAME"
  else
    _p="$(basename "$REPO" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    _p="$(printf '%s' "$_p" | sed 's/-*$//; s/^-*//' | cut -c1-32)"
    OSCOPE="dreamteam-${_p:-agents}"
  fi
  if systemctl --user is-active --quiet "$OSCOPE.scope" 2>/dev/null; then
    owner_alive="scope $OSCOPE.scope is active"
  elif [ -z "${DREAMTEAM_TEST:-}" ] && tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null | grep -qxF -- "$REPO"; then
    owner_alive="a tmux pane is still running in $REPO"
  fi
fi
if [ -n "$owner_alive" ]; then
  echo "ℹ️  DREAMTEAM CONCURRENT — team '$TEAM' (started $STARTED, repo $REPO) is still LIVE in another session ($owner_alive)."
  echo "    Its marker '$MARKER' is NOT crash residue — do NOT rm it; that session's SessionEnd owns it."
  echo "    If that team is finished, wind it down from its own session (tmux pane in $REPO), not from here."
  echo ""
  exit 0
fi

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
echo "  5) Re-spawn missing roles — standing managers (Hypnos/Nyx) + overnight (Reeve/Hermes); resume from the next un-merged item."
echo ""
echo "    After recovery, clear this notice:  rm '$MARKER'"
exit 0
