#!/usr/bin/env bash
# dreamteam — lib/agent-id.sh : the canonical "which agent am I?" resolver.
#
# Teammate identity is NOT in a hook's stdin payload — the payload describes the
# tool call, not the caller. It lives in the process argv: every teammate proc
# carries `--agent-id <name@team>`, which orchestrators and main sessions lack.
# That argv flag is the same signal scope-attach.sh / idle-agents.sh / roster.sh
# use to tell teammates from orchestrators, so it is the only in-session answer
# to "who am I".
#
# This is the SECOND consumer of that walk (worktree-guard.sh was the first), so
# it lives here for the same reason lib/pane-resolve.sh does (#53): two copies of
# an ancestry walk drift, and a guard that resolves identity differently from the
# guard beside it fails in ways nobody can reproduce.
#
# Usage:
#   . "$ROOT/scripts/lib/agent-id.sh"
#   AGENT_ID="$(dt_agent_id)"        # "" when not a teammate (or unknowable)
#   [ -n "$AGENT_ID" ] || exit 0     # callers FAIL OPEN on an empty answer
#
# Honours the DREAMTEAM_AGENT_ID env seam first — the test seam, and the escape
# hatch for any harness that stops passing the flag.
#
# FAIL OPEN: every failure path returns empty. A guard bug must never brick an
# agent; a rare missed block costs far less than a wedged fleet.

# dt_find_agent_id <pid> — walk up to 8 ancestors for --agent-id. Pure bash: no
# subprocess per hop, so it stays inside the <100ms hook budget.
dt_find_agent_id() {
  local cur="${1:-$$}" hops=0 i ppid k v
  local -a args
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ "$hops" -lt 8 ]; do
    if [ -r "/proc/$cur/cmdline" ]; then
      args=()
      mapfile -d '' -t args < "/proc/$cur/cmdline" 2>/dev/null || args=()
      for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
          --agent-id)
            if [ $((i + 1)) -lt ${#args[@]} ] && [ -n "${args[i + 1]}" ]; then
              printf '%s' "${args[i + 1]}"; return 0
            fi ;;
          --agent-id=*)
            printf '%s' "${args[i]#--agent-id=}"; return 0 ;;
        esac
      done
    fi
    ppid=""
    while read -r k v _; do
      [ "$k" = "PPid:" ] && { ppid="$v"; break; }
    done < "/proc/$cur/status" 2>/dev/null
    [ -z "$ppid" ] && break
    [ "$ppid" -le 1 ] 2>/dev/null && break
    cur="$ppid"; hops=$((hops + 1))
  done
  return 1
}

# dt_agent_id — env seam, else the ancestry walk. Empty = not a teammate.
dt_agent_id() {
  if [ -n "${DREAMTEAM_AGENT_ID:-}" ]; then
    printf '%s' "$DREAMTEAM_AGENT_ID"; return 0
  fi
  dt_find_agent_id "$$" 2>/dev/null || true
}

# dt_is_teammate — true only for a resolvable `name@team` identity. Anything
# ambiguous (no id, no '@') is treated as NOT a teammate, i.e. fail open.
dt_is_teammate() {
  local id; id="$(dt_agent_id)"
  [ -n "$id" ] || return 1
  case "$id" in *@*) return 0 ;; *) return 1 ;; esac
}
