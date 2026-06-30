#!/usr/bin/env bash
# dreamteam — move auto-created agent panes into their own tmux window.
# Promotes the inline snippet from SKILL.md into a real, reusable script.
# Runs against the dreamteam socket. Usage: tmux-layout.sh [orchestrator-window-index]
set -uo pipefail
SOCKET="${DREAMTEAM_TMUX_SOCKET:-dreamteam}"
ORCH="${1:-1}"   # window index the orchestrator + auto-panes landed in
T() { tmux -L "$SOCKET" "$@"; }

T new-window -n agents
# Move every agent pane (all but pane 0 of the orchestrator window) into 'agents'.
# Work high→low so indices don't shift mid-loop.
for p in $(T list-panes -t ":$ORCH" -F '#{pane_index}' | tail -n +2 | sort -rn); do
  T join-pane -s ":$ORCH.$p" -t ":2" 2>/dev/null || true
done
T select-layout -t ":2" tiled
# Kill the empty default shell pane new-window created.
EMPTY=$(T list-panes -t ":2" -F '#{pane_index} #{pane_current_command}' | awk '$2=="bash"{print $1; exit}')
[ -n "${EMPTY:-}" ] && T kill-pane -t ":2.$EMPTY" && T select-layout -t ":2" tiled
echo "agent panes tiled in window :2 ('agents'); orchestrator stays in :$ORCH"
