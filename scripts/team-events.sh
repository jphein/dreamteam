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
# Per-project containment scope name (#19) — shared derivation; env seam wins.
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh" 2>/dev/null || true
DT_SCOPE="$(command -v dreamteam_scope_name >/dev/null 2>&1 && dreamteam_scope_name || echo dreamteam-agents)"

IN="$(cat 2>/dev/null || true)"
jf() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }

EVENT="$(jf '.hook_event_name')"
[ -n "$EVENT" ] || exit 0

# Best-effort identity — field names differ per event; take the first that exists.
WHO="$(jf '.teammate_name // .agent_name // .agent_id // .name // .subagent_type // .tool_input.name')"
PATHISH="$(jf '.worktree_path // .path // .cwd')"
# Per-session roster (#4): the team THIS event belongs to. Without it roster.sh
# defaults to the mtime-newest team config, which on a multi-fleet day injects
# the WRONG team's roster into the session; TeammateIdle/SubagentStop carry
# team_name (confirmed via events.log capture), so thread it through.
TEAM="$(jf '.team_name')"
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
  bash "$ROOT/scripts/roster.sh" ${TEAM:+--team "$TEAM"} --json 2>/dev/null \
    | jq -r 'if (.agents|length) > 0 then [.agents[] | "\(.name)(\(.status))"] | join(" ") else "" end' 2>/dev/null || true
}

# scope_high_bytes: config .scope.memoryHigh ("20G"/"512M"/bare bytes) → bytes on
# stdout; empty when unset/unparseable (caller then skips the scope check).
scope_high_bytes() {
  local v n
  v=$(jq -r '.scope.memoryHigh // empty' "${1:?}" 2>/dev/null)
  n=${v%[GgMm]}                                   # strip a trailing unit if any
  case "$n" in *[!0-9]*|'') return 0;; esac       # non-integer mantissa → skip
  case "$v" in
    *[Gg]) printf '%s' $(( n * 1073741824 ));;
    *[Mm]) printf '%s' $(( n * 1048576 ));;
    *)     printf '%s' "$n";;                      # already bytes
  esac
}

# human_bytes: bytes → compact human string for the message (e.g. 18.0G / 512M).
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b+0 >= 1073741824) printf "%.1fG", b/1073741824;
    else if (b+0 >= 1048576) printf "%.0fM", b/1048576;
    else printf "%dB", b+0;
  }'
}

# notify_red: throttled (600s) MULTI-CHANNEL critical attention for RED / scope
# pressure — ONE marker gates ALL channels (desktop notify + voice): a single
# attention event, do NOT double-throttle. $1 = desktop text; $2 = spoken sentence
# (optional; one sentence, Davis voice). Failure-tolerant by contract — writes no
# stdout (it's called inside a $(…) capture), never changes the exit code; each
# channel is independently best-effort; voice is detached (never blocks) and is
# suppressed under DREAMTEAM_TEST so the suite never speaks.
notify_red() {
  local marker="$STATE/.last-notify" now mtime bus
  if [ -f "$marker" ]; then
    now=$(date +%s 2>/dev/null || printf 0)
    mtime=$(stat -c %Y "$marker" 2>/dev/null || printf 0)
    [ $(( now - mtime )) -lt 600 ] && return 0    # inside throttle window → all channels quiet
  fi
  # channel 1 — desktop notification (best-effort; an absent notify-send is fine).
  # #51: hook/cron contexts inherit NO session-bus address, so notify-send silently
  # no-ops (it can't reach the user's D-Bus). Point it at the systemd user bus
  # (/run/user/<uid>/bus), respecting an already-inherited value; add DISPLAY too.
  # Harmless when the socket is absent (headless) — notify-send just fails → || true.
  bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
  command -v notify-send >/dev/null 2>&1 \
    && DBUS_SESSION_BUS_ADDRESS="$bus" DISPLAY="${DISPLAY:-:0}" \
       notify-send -u critical "dreamteam" "$1" >/dev/null 2>&1 || true
  # channel 2 — voice (SAME attention event; detached so it never blocks; quiet in tests)
  if [ -z "${DREAMTEAM_TEST:-}" ] && [ -n "${2:-}" ]; then
    # #52: cap the attention utterance short — it's one sentence, and a hung synth
    # must not pin a proc for speak.sh's 180s manual default at the worst moment.
    # (--timeout <sec> is reverie's speak.sh contract; ignored until that lands.)
    bash "$ROOT/scripts/speak.sh" "$2" --voice davis --timeout 15 >/dev/null 2>&1 || true
  fi
  touch "$marker" 2>/dev/null || true
}

# Memory-tier check — gives the skill's degradation tiers an ACTOR. Before the
# 2026-07-01 16:06 oomd kill, admitted agents grew ~10GB of build-tool memory
# while no orchestrator was watching /dreamteam-status; the tiers were prose.
# TeammateIdle/SubagentStop fire constantly during fleet work, so piggybacking
# the tier warning here means every active orchestrator hears it in-context.
tier_note() {
  local avail floor cfg cur high nd_desk="" nd_voice=""
  cfg="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

  # Scope-pressure tier (#3): THIS PROJECT'S containment cgroup ($DT_SCOPE, #19)
  # is the REAL boundary — MemoryHigh throttles reclaim, MemoryMax hard-kills the
  # WHOLE team's cgroup. The host can look healthy while the scope sits at its
  # High water mark, so check the scope first and independently — this is additive
  # to the host tiers below (both can fire in one message).
  if systemctl --user is-active --quiet "$DT_SCOPE.scope" 2>/dev/null; then
    cur=$(systemctl --user show "$DT_SCOPE.scope" -p MemoryCurrent --value 2>/dev/null)
    cur=${cur//[!0-9]/}                            # "[not set]"/"infinity" → empty
    high=$(scope_high_bytes "$cfg")
    if [ -n "$cur" ] && [ -n "$high" ] && [ "$high" -gt 0 ] && [ "$cur" -ge $(( high * 85 / 100 )) ]; then
      printf ' 🚨 SCOPE PRESSURE: %s of %s MemoryHigh — reclaim throttling imminent and a scope kill takes the WHOLE team; quiesce now (no new tasks, let agents finish + merge).' \
        "$(human_bytes "$cur")" "$(human_bytes "$high")"
      # #50: accumulate — do NOT fire notify_red here. A co-firing RED (host-floor
      # breach) is more urgent and must win the single 600s-gated slot; firing here
      # would touch the shared marker and throttle-drop that RED.
      nd_desk="SCOPE PRESSURE: $(human_bytes "$cur")/$(human_bytes "$high") MemoryHigh — quiesce, a scope kill takes the whole team"
      nd_voice="Scope pressure: team memory near the cap."
    fi
  fi

  floor=$(jq -r '.memory.minAvailableMB // 8000' "$cfg" 2>/dev/null); floor=${floor//[!0-9]/}; floor=${floor:-8000}
  avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); avail=${avail//[!0-9]/}
  if [ -n "$avail" ]; then
    if [ "$avail" -lt "$floor" ]; then
      printf ' 🚨 RED TIER: %sMiB avail < %sMiB floor — CHECKPOINT NOW (commit+push WIP), then shutdown_request newest/lowest-priority agents until pressure clears.' "$avail" "$floor"
      # #50: RED (host floor → OOM imminent) OUTRANKS scope-pressure — it overwrites
      # the pending notify so the single delivery is the more-urgent one.
      nd_desk="RED TIER: ${avail}MiB avail < ${floor}MiB floor — checkpoint WIP + shed agents"
      nd_voice="Dreamteam red tier: ${avail} megabytes available — checkpoint and shed now."
    elif [ "$avail" -lt $(( floor * 3 / 2 )) ]; then
      printf ' ⚠ ORANGE TIER: %sMiB avail — quiesce: no new tasks, let in-flight agents finish + merge, investigate any balloon (incl. gradle/build daemons).' "$avail"
    fi
  fi

  # #50: exactly ONE notify_red per event. Co-firing scope-pressure + RED collapse to
  # a single multi-channel delivery (RED prioritized), so the shared 600s marker can
  # no longer drop the more-urgent RED. ORANGE never notifies (stdout only) — unchanged.
  [ -n "$nd_desk" ] && notify_red "$nd_desk" "$nd_voice"
}

# ── liveness stamps (#20; hardened for #21): these hooks report agent state to
# the cross-project fleet observer (fleet.sh LIVE column; a stamp beats its
# CPU-time heuristic). One tiny "<state> <epoch>" file per agent in a GLOBAL dir,
# keyed <project>__<agent>; fleet.sh joins on project+agent and age-prunes.
# Never blocks, never fails the hook.
#
# #21 — WHY TeammateIdle is NOT stamped "idle": TeammateIdle is a TURN-BOUNDARY
# event. It fires every time a teammate ends a turn and waits for input, which
# recurs CONTINUOUSLY throughout active work (events.log: one live teammate fired
# it ~20× across hours of work) — it is NOT proof the agent is done/available.
# 51f0f07 stamped a hard "idle" here; but the only name-keyed "working" writer is
# the one-shot spawn (SubagentStart is keyed by agent_id — a DIFFERENT file; the
# two event families share no join key), so the stamp LATCHED working→idle at the
# first turn boundary and never returned — reporting a live, working teammate as
# "idle" for the rest of its life. We stamp only from the UNAMBIGUOUS signals and
# treat a turn boundary as "still working" (the SAFE direction — never falsely
# "free" for reuse):
#   TaskCreated / SubagentStart / (spawn) → working  ("picked up / doing work")
#   TeammateIdle                          → working  (turn boundary ≠ idle)
#   TaskCompleted                         → idle      (the one HONEST "task done,
#                                                       now reusable" signal)
#   SubagentStop                          → stopped
# Ground-truth idle for pure-SendMessage teammates (queued-inbox / transcript
# inspection) is a documented follow-up (issue #21 remedy a/c).
FLEET_STATE="${DREAMTEAM_FLEET_STATE:-$HOME/.claude/dreamteam-fleet}"
stamp_live() {
  [ -n "${WHO:-}" ] || return 0
  local proj key
  proj="$(basename "$(dreamteam_project_root 2>/dev/null || echo "$PWD")")"
  key="$(printf '%s__%s' "$proj" "${WHO%%@*}" | tr '/' '_')"
  mkdir -p "$FLEET_STATE" 2>/dev/null || return 0
  printf '%s %s\n' "$1" "$(date +%s)" > "$FLEET_STATE/$key" 2>/dev/null || true
}
case "$EVENT" in
  TeammateIdle)  stamp_live working ;;   # #21: turn boundary ≠ idle (was: idle)
  TaskCreated)   stamp_live working ;;   # #21: name-keyed "picked up work"
  SubagentStart) stamp_live working ;;
  TaskCompleted) stamp_live idle ;;      # #21: the honest "task done → reusable"
  SubagentStop)  stamp_live stopped ;;
esac

case "$EVENT" in
  TeammateIdle)
    # Containment sweep: idle events fire constantly during fleet work, so any
    # agent that slipped past its spawn-time attach gets caught here (cheap —
    # scope-attach only busctl's pids not already in the scope). DREAMTEAM_TEST
    # guard: the suite must never create/modify REAL scopes (it did — an empty
    # dreamteam-projx.scope appeared on the host the moment the fixtures pinned
    # a fake project; caught live 2026-07-04).
    [ -n "${DREAMTEAM_TEST:-}" ] || bash "$ROOT/scripts/scope-attach.sh" 2>/dev/null || true
    # Pane sweep: the harness sometimes creates an agent's tmux pane AFTER the
    # spawn's PostToolUse fires, so it stayed in the orchestrator window ("not
    # making the agents tab"). By idle time the pane exists → sweep it here.
    # </dev/null: the hook's stdin was already consumed and pane-organizer reads
    # stdin. DREAMTEAM_TEST guard: the suite runs inside a live tmux, so skip the
    # sweep under test to never reorganize JP's / a sibling's real panes.
    [ -n "${DREAMTEAM_TEST:-}" ] || bash "$ROOT/scripts/pane-organizer.sh" --sweep </dev/null 2>/dev/null || true
    R="$(roster_line)"; T="$(tier_note)"
    # #21: TeammateIdle is a TURN BOUNDARY, not a "task complete / free" signal —
    # it fires whenever a teammate ends a turn (incl. between steps while an inbox
    # message is queued). Announcing "is IDLE — reusable" here misled the
    # orchestrator into retasking a live, working agent (issue #21). State it as a
    # heartbeat and route reuse decisions through the authoritative live check.
    jq -n --arg msg "🕯 dreamteam: ${WHO:-a teammate} hit a turn boundary (alive; may still be mid-task — a teammate between turns is NOT done). Don't retask on this signal alone: confirm it's genuinely free via /dreamteam-roster \"<task>\" (live isActive) or its tmux pane first. Roster: ${R:-n/a}${T}" \
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
