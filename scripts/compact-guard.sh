#!/usr/bin/env bash
# dreamteam — compaction guard (PreCompact + PostCompact hooks).
#
# PreCompact  → snapshot everything a post-compaction orchestrator needs into
#               state/HANDOFF-auto.md BEFORE the context is summarized: live
#               roster, git branch/dirty-state, recent footprint. A summary can
#               drop the roster; this file cannot.
# PostCompact → re-arm the fresh context immediately: systemMessage with the
#               live roster + pointer to the snapshot, so the orchestrator never
#               starts a post-compaction turn blind (the 2026-06-29 failure:
#               15 agents running, orchestrator couldn't name one of them).
#
# Routed by hook_event_name; always exits 0 (never block a compaction).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
mkdir -p "$STATE"
SNAP="$STATE/HANDOFF-auto.md"

IN="$(cat 2>/dev/null || true)"
jf() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }
EVENT="$(jf '.hook_event_name')"
TRIGGER="$(jf '.trigger // .matcher')"
CWD="$(jf '.cwd')"; [ -n "$CWD" ] || CWD="$PWD"
TS=$(date +%FT%T)

roster_json() { bash "$ROOT/scripts/roster.sh" --json 2>/dev/null || true; }
roster_line() {
  roster_json | jq -r 'if (.agents|length) > 0 then [.agents[] | "\(.name)(\(.status))"] | join(" ") else "no team" end' 2>/dev/null || echo "n/a"
}

case "$EVENT" in
  PreCompact)
    {
      echo "# dreamteam HANDOFF (auto) — written by PreCompact hook"
      echo "Updated: $TS   trigger: ${TRIGGER:-?}   cwd: $CWD"
      echo ""
      echo "## Roster (authoritative, at snapshot time)"
      bash "$ROOT/scripts/roster.sh" 2>/dev/null || echo "(roster unavailable)"
      echo ""
      echo "## Git"
      if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
        echo "branch: $(git -C "$CWD" branch --show-current 2>/dev/null)"
        echo "dirty:  $(git -C "$CWD" status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
        git -C "$CWD" worktree list 2>/dev/null | sed 's/^/  /'
      else
        echo "(not a git repo)"
      fi
      echo ""
      echo "## Recent footprint (dreamteam.log tail)"
      tail -n 5 "$STATE/dreamteam.log" 2>/dev/null || echo "(no spawns logged)"
      echo ""
      echo "## Post-compaction first actions"
      echo "1. Read this file + scratch/<team>/roster.md if present."
      echo "2. Verify roster liveness: bash \"$ROOT/scripts/roster.sh\""
      echo "3. Idle agents are REUSABLE via SendMessage — do not respawn them."
    } > "$SNAP" 2>/dev/null || true
    jq -n --arg msg "🕯 dreamteam: pre-compaction snapshot written → $SNAP (roster: $(roster_line))" \
      '{"systemMessage": $msg}'
    ;;
  PostCompact)
    jq -n --arg msg "🕯 dreamteam: context was COMPACTED. Live roster (authoritative, do not trust summarized memory of it): $(roster_line). Full snapshot: $SNAP — idle agents are reusable via SendMessage." \
      '{"systemMessage": $msg}'
    ;;
esac
exit 0
