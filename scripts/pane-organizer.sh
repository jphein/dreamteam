#!/usr/bin/env bash
# dreamteam — move agent panes into their own "agents" tmux window.
#
# SWEEP semantics (2026-07-01 rewrite): originally this moved only the NEWEST
# pane at PostToolUse(Agent) — but the harness sometimes creates the pane
# AFTER the hook fires, so spawns raced the hook and agents stayed in the
# orchestrator's window (JP: "not always making the agents tab"). Now every
# invocation sweeps ALL agent panes in the current window, and it's invoked
# from BOTH PostToolUse(Agent) (async) and the TeammateIdle sweep in
# team-events.sh — by idle time the pane definitely exists.
#
# An "agent pane" is one whose process tree contains a `claude/versions`
# process carrying `--agent-id` — never a shell, editor, or JP's own splits.
# Skips: not in tmux, DREAMTEAM_INLINE_PANE=1 (agent output meant for JP),
# and the pane this very session lives in.
set -uo pipefail

[ -n "${TMUX:-}" ] || exit 0
[ "${DREAMTEAM_INLINE_PANE:-0}" = "1" ] && exit 0

# Invoked as a hook (stdin JSON) or directly (--sweep): act either way, but
# for hook calls only on Agent/Task spawns.
INPUT="$(cat 2>/dev/null || true)"
if [ -n "$INPUT" ] && [ "${1:-}" != "--sweep" ]; then
  TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  case "$TOOL" in Agent|Task|"") ;; *) exit 0 ;; esac
fi

SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
ORCH_WIN=$(tmux display-message -p '#{window_index}' 2>/dev/null || true)
[ -n "$SESSION" ] && [ -n "$ORCH_WIN" ] || exit 0

# Never disturb a dedicated 'manager' window — the fleet-coordinator agent lives
# there on purpose (its own tab). Without this, the sweep reclaims it into 'agents'
# (esp. when the async hook lacks TMUX_PANE so the SELF_PANE skip below misses).
if [ "$(tmux display-message -p -t "$SESSION:$ORCH_WIN" '#{window_name}' 2>/dev/null || true)" = "manager" ]; then
  exit 0
fi
SELF_PANE="${TMUX_PANE:-}"

# Is this pane's process tree an agent? (pane pid, a child, or a grandchild
# runs claude/versions with --agent-id)
is_agent_pane() {
  local pid=$1 p c
  for p in $pid $(pgrep -P "$pid" 2>/dev/null); do
    if grep -qa -- 'claude/versions' "/proc/$p/cmdline" 2>/dev/null \
       && grep -qa -- '--agent-id' "/proc/$p/cmdline" 2>/dev/null; then
      return 0
    fi
    for c in $(pgrep -P "$p" 2>/dev/null); do
      if grep -qa -- 'claude/versions' "/proc/$c/cmdline" 2>/dev/null \
         && grep -qa -- '--agent-id' "/proc/$c/cmdline" 2>/dev/null; then
        return 0
      fi
    done
  done
  return 1
}

# Collect agent panes in the orchestrator window (never our own pane).
MOVERS=""
while IFS=' ' read -r pane_id pane_pid; do
  [ -n "$pane_id" ] || continue
  [ "$pane_id" = "$SELF_PANE" ] && continue
  is_agent_pane "$pane_pid" && MOVERS="$MOVERS $pane_id"
done < <(tmux list-panes -t "$SESSION:$ORCH_WIN" -F '#{pane_id} #{pane_pid}' 2>/dev/null)
[ -n "${MOVERS// /}" ] || exit 0

# Find or create the agents window.
AGENTS_WIN=$(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="agents"{print $1; exit}')
CREATED=0
if [ -z "$AGENTS_WIN" ]; then
  tmux new-window -d -t "$SESSION" -n agents 2>/dev/null || exit 0
  AGENTS_WIN=$(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="agents"{print $1; exit}')
  [ -n "$AGENTS_WIN" ] || exit 0
  CREATED=1
fi

for pid in $MOVERS; do
  tmux join-pane -d -s "$pid" -t "$SESSION:$AGENTS_WIN" 2>/dev/null || true
done
tmux select-layout -t "$SESSION:$AGENTS_WIN" tiled 2>/dev/null || true

# Only when WE just created the window: kill its empty default shell pane.
if [ "$CREATED" = "1" ]; then
  EMPTY=$(tmux list-panes -t "$SESSION:$AGENTS_WIN" -F '#{pane_id} #{pane_current_command}' 2>/dev/null | awk '$2=="bash"||$2=="zsh"{print $1; exit}')
  [ -n "${EMPTY:-}" ] && tmux kill-pane -t "$EMPTY" 2>/dev/null && tmux select-layout -t "$SESSION:$AGENTS_WIN" tiled 2>/dev/null
fi

# Stay on the orchestrator window.
tmux select-window -t "$SESSION:$ORCH_WIN" 2>/dev/null || true
exit 0
