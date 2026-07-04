#!/usr/bin/env bash
# dreamteam — fleet.sh: FLEET-WIDE agent observer (issue #18).
#
# WHAT / WHY
#   JP runs many independent Claude Code instances (one per project) that all
#   spawn agents into shared infrastructure: dreamteam-*.scope cgroups and
#   multiple tmux sockets. No single instance could see the whole board — a
#   candela orchestrator (2026-07-04) saw 14 procs in the shared scope, could
#   attribute only its own 4, and nearly reaped techempower's and memorypalace's
#   LIVE fleets as orphans. This is the passive, cross-owner observer that
#   near-miss demanded: one command → every agent on the host, with project,
#   tmux pane, liveness signals, and scope.
#
#   OBSERVER ONLY — this tool contains no reap path BY DESIGN (test-fleet.sh
#   greps for one as a tripwire — reword, don't weaken, if you trip it) and must
#   never grow one. --stale marks candidates for a HUMAN to inspect.
#
# USAGE
#   fleet.sh                 # human table (agents from OTHER projects marked NOT-YOURS)
#   fleet.sh --json          # machine output for orchestrators
#   fleet.sh --project P     # only agents whose project matches P (substring)
#   fleet.sh --stale         # only stale candidates (old + idle-cpu + no pane)
#
# HOW (the three discovery layers, per #18 + the OSS-survey recs)
#   1. cgroups  — every dreamteam-*.scope under the user slice: cgroup.procs
#                 gives PID→scope; memory.current gives the scope's true
#                 footprint. Anchor procs (sleep infinity) are excluded.
#   2. procs    — the agent population is `claude` processes host-wide
#                 (same 'claude/versions' signal the accounting uses), so
#                 unscoped agents still appear (scope column: "-").
#   3. tmux     — panes across ALL sockets in /tmp/tmux-<uid>/: pane_pid is the
#                 pane's ROOT proc; agents are descendants, so each agent PID
#                 walks its PPid chain (via /proc) until it hits a pane_pid.
#
# ATTRIBUTION
#   project  = /proc/PID/cwd → ~/Projects/<name>; a cwd under .claude/worktrees/
#              maps to the OWNING repo, and the worktree dir doubles as the
#              agent name. Caller's own project (from $PWD) prints as "yours";
#              everything else is labelled NOT-YOURS — the reap-safety rail.
#   stale?   = etimes > staleAfterSec (default 3600) AND cputime/etimes < 1%
#              AND no pane. A heuristic, not a verdict — hence observer-only.
#
# SEAMS (tests): DREAMTEAM_CGROUP_ROOT, DREAMTEAM_TMUX_DIR, DREAMTEAM_PROC,
#   DREAMTEAM_CALLER_CWD; ps/pgrep/tmux resolve via PATH (stubbable).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

CGROOT="${DREAMTEAM_CGROUP_ROOT:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service}"
TMUXDIR="${DREAMTEAM_TMUX_DIR:-/tmp/tmux-$(id -u)}"
PROC="${DREAMTEAM_PROC:-/proc}"
CALLER_CWD="${DREAMTEAM_CALLER_CWD:-$PWD}"
STALE_SEC="$(jq -r '.fleet.staleAfterSec // 3600' "$CFG" 2>/dev/null || echo 3600)"

JSON=0; FILTER=""; STALE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)      JSON=1; shift ;;
    --project)   FILTER="${2:-}"; shift 2 2>/dev/null || shift ;;
    --project=*) FILTER="${1#--project=}"; shift ;;
    --stale)     STALE_ONLY=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           shift ;;
  esac
done

# ── layer 1: scopes ──────────────────────────────────────────────────────────
# pid→scope map + per-scope memory. Anchors (sleep) excluded from agent math
# but scopes with only an anchor still list, so an empty per-project scope is
# visible rather than invisible.
declare -A PID_SCOPE SCOPE_MEM
# Scopes live under app.slice/ (systemd-run --user) or deeper — find, don't
# glob one level. Delegate=yes scopes can hold sub-cgroups, so collect procs
# from every cgroup.procs beneath each scope, not just the top one.
while IFS= read -r d; do
  s="$(basename "$d")"
  SCOPE_MEM[$s]=$(( $(cat "$d/memory.current" 2>/dev/null || echo 0) / 1048576 ))
  while IFS= read -r p; do
    [ -n "$p" ] && PID_SCOPE[$p]="$s"
  done < <(find "$d" -name cgroup.procs -exec cat {} + 2>/dev/null || true)
done < <(find "$CGROOT" -maxdepth 4 -type d -name 'dreamteam-*.scope' 2>/dev/null)

# ── layer 3 first: panes across every socket (pane_pid → address) ────────────
declare -A PANE_ADDR
for sock in "$TMUXDIR"/*; do
  [ -S "$sock" ] || [ -e "$sock" ] || continue
  sname="$(basename "$sock")"
  while IFS= read -r line; do
    addr="${line% *}"; ppid="${line##* }"
    [ -n "$ppid" ] && PANE_ADDR[$ppid]="${sname}@${addr}"
  done < <(tmux -S "$sock" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null || true)
done

# Walk a PID's PPid chain (via $PROC) until a pane_pid matches. Max 20 hops.
pane_of() {
  local p="$1" hops=0 ppid
  while [ "$p" != "0" ] && [ "$p" != "1" ] && [ $hops -lt 20 ]; do
    [ -n "${PANE_ADDR[$p]:-}" ] && { printf '%s' "${PANE_ADDR[$p]}"; return; }
    ppid="$(awk '/^PPid:/{print $2}' "$PROC/$p/status" 2>/dev/null)" || return
    [ -n "$ppid" ] || return
    p="$ppid"; hops=$((hops+1))
  done
}

# cwd → "project|agent" (worktree-aware). Empty project for unmappable cwds.
attr_of() {
  local cwd="$1" proj="" agent="-"
  case "$cwd" in
    */.claude/worktrees/*)
      agent="${cwd##*/.claude/worktrees/}"; agent="${agent%%/*}"
      proj="${cwd%%/.claude/worktrees/*}"; proj="$(basename "$proj")" ;;
    "$HOME"/Projects/*)
      proj="${cwd#"$HOME"/Projects/}"; proj="${proj%%/*}" ;;
    *) proj="$(basename "$cwd" 2>/dev/null || echo '?')" ;;
  esac
  printf '%s|%s' "$proj" "$agent"
}

CALLER_PROJ="$(attr_of "$CALLER_CWD")"; CALLER_PROJ="${CALLER_PROJ%%|*}"

# ── layer 2: the agent population ────────────────────────────────────────────
AGENT_PIDS="$(pgrep -f 'claude/versions' 2>/dev/null || true)"

rows=()   # jq-ready JSON objects, one per agent
for pid in $AGENT_PIDS; do
  [ -d "$PROC/$pid" ] || continue
  cwd="$(readlink "$PROC/$pid/cwd" 2>/dev/null || echo '?')"
  IFS='|' read -r proj agent <<< "$(attr_of "$cwd")"
  # agent name: --agent-id from cmdline beats the worktree-dir fallback
  cid="$(tr '\0' ' ' < "$PROC/$pid/cmdline" 2>/dev/null | grep -oE -- '--agent-id [^ ]+' | cut -d' ' -f2 || true)"
  [ -n "$cid" ] && agent="${cid%%@*}"
  read -r etimes cputimes rss <<< "$(ps -o etimes=,cputimes=,rss= -p "$pid" 2>/dev/null | awk '{print $1, $2, $3}')"
  etimes="${etimes//[!0-9]/}"; etimes="${etimes:-0}"
  cputimes="${cputimes//[!0-9]/}"; cputimes="${cputimes:-0}"
  rss="${rss//[!0-9]/}"; rss="${rss:-0}"
  pane="$(pane_of "$pid")"; pane="${pane:--}"
  scope="${PID_SCOPE[$pid]:--}"
  yours="false"; [ -n "$proj" ] && [ "$proj" = "$CALLER_PROJ" ] && yours="true"
  stale="false"
  if [ "$pane" = "-" ] && [ "$etimes" -gt "$STALE_SEC" ] && [ "$((cputimes * 100))" -lt "$etimes" ]; then
    stale="true"
  fi
  [ -n "$FILTER" ] && [[ "$proj" != *"$FILTER"* ]] && continue
  [ "$STALE_ONLY" = "1" ] && [ "$stale" != "true" ] && continue
  rows+=("$(jq -cn --argjson pid "$pid" --arg proj "$proj" --arg agent "$agent" \
      --arg pane "$pane" --arg scope "$scope" --argjson etimes "$etimes" \
      --argjson cputimes "$cputimes" --argjson rssMB "$((rss / 1024))" \
      --argjson yours "$yours" --argjson stale "$stale" \
      '{pid:$pid, project:$proj, agent:$agent, pane:$pane, scope:$scope,
        uptimeSec:$etimes, cpuSec:$cputimes, rssMB:$rssMB, yours:$yours, stale:$stale}')")
done

# ── output ───────────────────────────────────────────────────────────────────
scopes_json="$(for s in "${!SCOPE_MEM[@]}"; do
  jq -cn --arg name "$s" --argjson memMB "${SCOPE_MEM[$s]}" '{name:$name, memMB:$memMB}'
done | jq -cs 'sort_by(.name)')"
[ -z "$scopes_json" ] && scopes_json='[]'

if [ "$JSON" = "1" ]; then
  printf '%s\n' "${rows[@]:-}" | jq -cs --arg caller "$CALLER_PROJ" --argjson scopes "$scopes_json" \
    '{caller:$caller, scopes:$scopes, agents:(map(select(.!=null)) | sort_by(.project, .pid))}'
  exit 0
fi

{
  echo "dreamteam fleet — caller project: ${CALLER_PROJ:-?}   (observer only — NEVER auto-reap)"
  for s in $(printf '%s\n' "${!SCOPE_MEM[@]}" | sort); do
    echo "  scope ${s}: ${SCOPE_MEM[$s]} MiB"
  done
  printf '%s\n' "${rows[@]:-}" | jq -rs '
    (map(select(.!=null)) | sort_by([(.yours | not), .project, .pid]))[] |
    [ (.pid|tostring), .project, .agent, .pane, .scope,
      "\(.uptimeSec / 60 | floor)m", "\(.cpuSec)s", "\(.rssMB)M",
      (if .yours then "yours" else "NOT-YOURS" end),
      (if .stale then "stale?" else "" end) ] | @tsv' \
    | column -t -s $'\t' -N PID,PROJECT,AGENT,PANE,SCOPE,UP,CPU,RSS,OWNER,FLAG 2>/dev/null \
    || printf '%s\n' "${rows[@]:-}" | jq -rs '.[] | "\(.pid) \(.project) \(.agent) \(.pane) \(.scope)"'
  n_stale="$(printf '%s\n' "${rows[@]:-}" | jq -rs '[.[] | select(.!=null and .stale)] | length')"
  [ "${n_stale:-0}" -gt 0 ] && echo "  ⚠ ${n_stale} stale candidate(s) — inspect by hand (pane-less + old + idle CPU). Observer only: this tool terminates nothing."
}
exit 0
