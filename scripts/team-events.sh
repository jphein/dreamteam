#!/usr/bin/env bash
# dreamteam — team lifecycle events (one handler, routed by hook_event_name).
#
# Wired in hooks/hooks.json for: TeammateIdle, SubagentStart, SubagentStop,
# TaskCreated, TaskCompleted, WorktreeCreate, WorktreeRemove.
#
# Behavior by event:
#   TeammateIdle   → systemMessage: who went idle + live roster (reuse routing —
#                    the orchestrator learns of an idle agent the moment it goes
#                    idle, not when the next spawn's PostToolUse fires)
#   SubagentStop   → systemMessage: who stopped + live roster
#   SubagentStart  → log only (spawn-accounting already messages on spawns)
#   Task*/Worktree*→ log only (async in hooks.json — off the critical path);
#                    Worktree paths outside .claude/worktrees/ are flagged
#                    (offPattern) as a worktree-discipline audit trail.
#
# Every event appends one JSONL line to state/events.log including the payload's
# top-level keys — these event payloads are undocumented, so the log doubles as
# field discovery for tightening the parses later. Always exits 0.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
mkdir -p "$STATE"
EVLOG="$STATE/events.log"

IN="$(cat 2>/dev/null || true)"
jf() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }

EVENT="$(jf '.hook_event_name')"
[ -n "$EVENT" ] || exit 0

# Best-effort identity — field names differ per event; take the first that exists.
WHO="$(jf '.teammate_name // .agent_name // .agent_id // .name // .subagent_type // .tool_input.name')"
PATHISH="$(jf '.worktree_path // .path // .cwd')"
KEYS="$(printf '%s' "$IN" | jq -c 'keys' 2>/dev/null || echo '[]')"
TS=$(date +%FT%T)

# Worktree-discipline audit: dreamteam worktrees belong under .claude/worktrees/
OFFPAT=false
case "$EVENT" in
  Worktree*)
    if [ -n "$PATHISH" ]; then
      case "$PATHISH" in */.claude/worktrees/*) ;; *) OFFPAT=true ;; esac
    fi
  ;;
esac

jq -cn --arg ts "$TS" --arg ev "$EVENT" --arg who "${WHO:-}" --arg path "${PATHISH:-}" \
      --argjson keys "$KEYS" --argjson off "$OFFPAT" \
      '{ts:$ts, event:$ev, who:$who, path:$path, offPattern:$off, payloadKeys:$keys}' \
      >> "$EVLOG" 2>/dev/null || true

roster_line() {
  bash "$ROOT/scripts/roster.sh" --json 2>/dev/null \
    | jq -r 'if (.agents|length) > 0 then [.agents[] | "\(.name)(\(.status))"] | join(" ") else "" end' 2>/dev/null || true
}

# Memory-tier check — gives the skill's degradation tiers an ACTOR. Before the
# 2026-07-01 16:06 oomd kill, admitted agents grew ~10GB of build-tool memory
# while no orchestrator was watching /dreamteam-status; the tiers were prose.
# TeammateIdle/SubagentStop fire constantly during fleet work, so piggybacking
# the tier warning here means every active orchestrator hears it in-context.
tier_note() {
  local avail floor cfg
  cfg="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
  floor=$(jq -r '.memory.minAvailableMB // 8000' "$cfg" 2>/dev/null); floor=${floor//[!0-9]/}; floor=${floor:-8000}
  avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); avail=${avail//[!0-9]/}
  [ -n "$avail" ] || return 0
  if [ "$avail" -lt "$floor" ]; then
    printf ' 🚨 RED TIER: %sMiB avail < %sMiB floor — CHECKPOINT NOW (commit+push WIP), then shutdown_request newest/lowest-priority agents until pressure clears.' "$avail" "$floor"
  elif [ "$avail" -lt $(( floor * 3 / 2 )) ]; then
    printf ' ⚠ ORANGE TIER: %sMiB avail — quiesce: no new tasks, let in-flight agents finish + merge, investigate any balloon (incl. gradle/build daemons).' "$avail"
  fi
}

case "$EVENT" in
  TeammateIdle)
    R="$(roster_line)"; T="$(tier_note)"
    jq -n --arg msg "🕯 dreamteam: ${WHO:-a teammate} is IDLE — reusable via SendMessage (zero new RAM, warm context). Roster: ${R:-n/a}${T}" \
      '{"systemMessage": $msg}'
    ;;
  SubagentStop)
    R="$(roster_line)"; T="$(tier_note)"
    jq -n --arg msg "🕯 dreamteam: ${WHO:-an agent} stopped. Roster: ${R:-n/a}${T}" \
      '{"systemMessage": $msg}'
    ;;
  *) : ;;   # log-only events
esac
exit 0
