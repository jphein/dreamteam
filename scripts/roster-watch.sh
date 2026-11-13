#!/usr/bin/env bash
# roster-watch.sh — debounced, self-aware roster-health watcher (#81; contract #79)
#
# A standing manager (Hypnos/Nyx) runs this under the `Monitor` tool. It polls
# `roster.sh --json` and prints ONE line per meaningful transition, nothing else:
#
#   SETTLED-IDLE       an agent idle for DEBOUNCE consecutive polls (a VERIFY-FIRST
#                      prompt, never a conclusion: peek its pane before telling the
#                      lead it finished)
#   AGENT-DEAD         status dead (no live process): unreachable, escalate
#   MEMBERSHIP-CHANGE  an agent joined or left the team
#   ROSTER-POLL-ERROR  roster.sh returned nothing or invalid JSON
#   WATCH-END          the deadline or poll limit was reached (always the last line)
#
# Because a Monitor wakes its owner on output, this doubles as the manager's
# heartbeat: event-driven, silent while nothing changes.
#
# THE FIVE RULES (each was a live failure first; session-6738192a, 2026-07-11):
#   1. Debounce `isActive`: the harness flips it false at every tool-round boundary (#33).
#   2. DEBOUNCE=4 polls, not 2: max-effort agents pause ~2 min to think mid-turn.
#   3. Skip SELF: a manager is idle by design; counting itself is a ~4-min self-wake loop.
#   4. Baseline-seed: agents already idle at the first poll are known, not announced.
#   5. The pane is the oracle: SETTLED-IDLE names the pane-peek command to verify with.
#
# STOP (#79): TaskStop the Monitor, or pass --until <epoch> / --polls <n>; the
# watcher prints WATCH-END and exits 0. RESUME = re-arm (state is re-derived from
# the roster; the baseline seed makes a re-arm quiet about already-idle agents).
#
# Usage: roster-watch.sh [--team NAME] [--self NAME] [--debounce N] [--interval SEC]
#                        [--until EPOCH] [--polls N]
#   --team     defaults to roster.sh's own choice on the first poll, then PINNED
#              (a newer team appearing mid-watch must not swap the roster under us)
#   --self     defaults to this process's teammate name (scripts/lib/agent-id.sh)
# Env seams (tests): DREAMTEAM_ROSTER_CMD replaces scripts/roster.sh.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/scripts/lib/agent-id.sh"

TEAM="${DREAMTEAM_TEAM:-}"
SELF="${DREAMTEAM_SELF:-}"
DEBOUNCE="${ROSTER_WATCH_DEBOUNCE:-4}"
INTERVAL="${ROSTER_WATCH_INTERVAL:-60}"
UNTIL=""
POLLS=""
ROSTER_CMD="${DREAMTEAM_ROSTER_CMD:-$ROOT/scripts/roster.sh}"

usage() { sed -n '/^# Usage:/,/^# Env seams/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
need() { [ -n "${2:-}" ] || { echo "roster-watch: $1 needs a value" >&2; exit 22; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --team)     need "$1" "${2:-}"; TEAM="$2"; shift 2 ;;
    --self)     need "$1" "${2:-}"; SELF="$2"; shift 2 ;;
    --debounce) need "$1" "${2:-}"; DEBOUNCE="$2"; shift 2 ;;
    --interval) need "$1" "${2:-}"; INTERVAL="$2"; shift 2 ;;
    --until)    need "$1" "${2:-}"; UNTIL="$2"; shift 2 ;;
    --polls)    need "$1" "${2:-}"; POLLS="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "roster-watch: unknown argument: $1" >&2; usage >&2; exit 22 ;;
  esac
done
for v in DEBOUNCE INTERVAL; do
  case "${!v}" in ''|*[!0-9]*) echo "roster-watch: $v must be a whole number" >&2; exit 22 ;; esac
done
[ "$DEBOUNCE" -ge 1 ] || { echo "roster-watch: DEBOUNCE must be >= 1" >&2; exit 22; }
for v in UNTIL POLLS; do
  case "${!v}" in ''|*[!0-9]*) [ -z "${!v}" ] || { echo "roster-watch: $v must be a whole number" >&2; exit 22; } ;; esac
done
if [ -z "$SELF" ]; then
  SELF="$(dt_agent_id)"; SELF="${SELF%%@*}"
fi

ts() { date +%H:%M:%S; }

declare -A idlecnt idle_reported dead_reported
prevnames=""; first=1; n=0

while :; do
  if [ -n "$UNTIL" ] && [ "$(date +%s)" -ge "$UNTIL" ]; then
    echo "WATCH-END @ $(ts): deadline reached"; exit 0
  fi
  n=$((n + 1))

  if [ -n "$TEAM" ]; then json="$("$ROSTER_CMD" --team "$TEAM" --json 2>/dev/null)"
  else                    json="$("$ROSTER_CMD" --json 2>/dev/null)"; fi
  rows="$(printf '%s' "$json" | jq -r '.agents[] | "\(.name)\t\(.status)"' 2>/dev/null)"
  team_seen="$(printf '%s' "$json" | jq -r '.team // empty' 2>/dev/null)"

  if [ -z "$rows" ]; then
    echo "ROSTER-POLL-ERROR @ $(ts): roster.sh returned no/invalid data${TEAM:+ for team $TEAM}"
  else
    # rule: pin the team on the first good poll
    [ -z "$TEAM" ] && [ -n "$team_seen" ] && TEAM="$team_seen"

    names="$(printf '%s\n' "$rows" | cut -f1 | sort | paste -sd, -)"
    if [ "$first" -eq 0 ] && [ "$names" != "$prevnames" ]; then
      echo "MEMBERSHIP-CHANGE @ $(ts): was[$prevnames] now[$names]"
    fi
    prevnames="$names"

    while IFS=$'\t' read -r name st; do
      [ -n "$name" ] || continue
      [ -n "$SELF" ] && [ "$name" = "$SELF" ] && continue      # rule 3
      case "$st" in
        idle)
          idlecnt[$name]=$(( ${idlecnt[$name]:-0} + 1 ))
          [ "$first" -eq 1 ] && idle_reported[$name]=1           # rule 4
          if [ "${idlecnt[$name]}" -ge "$DEBOUNCE" ] && [ "${idle_reported[$name]:-0}" -eq 0 ]; then
            echo "SETTLED-IDLE @ $(ts): $name idle ${idlecnt[$name]} polls; VERIFY before reporting: scripts/pane-peek.sh $name"
            idle_reported[$name]=1
          fi
          ;;
        dead)
          if [ "${dead_reported[$name]:-0}" -eq 0 ]; then
            echo "AGENT-DEAD @ $(ts): $name status=dead (no live process); unreachable, escalate"
            dead_reported[$name]=1
          fi
          ;;
        *) idlecnt[$name]=0; idle_reported[$name]=0; dead_reported[$name]=0 ;;  # active/lead: re-arm
      esac
    done <<< "$rows"
    first=0
  fi

  if [ -n "$POLLS" ] && [ "$n" -ge "$POLLS" ]; then
    echo "WATCH-END @ $(ts): poll limit $POLLS reached"; exit 0
  fi
  sleep "$INTERVAL"
done
