#!/usr/bin/env bash
# dreamteam — MANUAL / BATCH agent-pane re-tiler for a launch-dreamteam.sh session.
#
# WHAT IT IS
#   A hand-invoked tool that sweeps EVERY stray agent pane out of the
#   orchestrator window into a single 'agents' window in ONE shot, then tiles.
#
# HOW IT DIFFERS FROM scripts/pane-organizer.sh (the automatic path)
#   pane-organizer.sh is a PostToolUse(Agent) hook: it fires once per spawn and
#   moves only the ONE newest pane, on whatever server $TMUX points at. This
#   script is the other end of that spectrum — no hook, invoked by hand, moves
#   ALL accumulated panes at once. The per-spawn hook can only chip one pane per
#   FUTURE spawn, so it cannot batch-clean a backlog; this can.
#
# WHEN TO REACH FOR IT
#   Rarely, as a recovery lever, when a launch-dreamteam.sh window has several
#   stray agent panes and you want them tidied NOW — e.g. the auto-hook was
#   disabled/timed out, DREAMTEAM_INLINE_PANE=1 was set during spawns, or panes
#   piled up before the hook was wired in. Normal operation needs nothing: the
#   hook handles each spawn automatically.
#
# SOCKET
#   Targets the dedicated 'dreamteam' server (launch-dreamteam.sh runs
#   `tmux -L dreamteam`), so this works even when run from an OUTSIDE terminal
#   (the auto-hook can't — it only fires from inside, on a spawn). Run from
#   inside the session, $TMUX already points here, so the default is right
#   either way. Override with DREAMTEAM_TMUX_SOCKET.
#
# Usage: tmux-layout.sh [orchestrator-window-index]   (default: 1)
set -uo pipefail
SOCKET="${DREAMTEAM_TMUX_SOCKET:-dreamteam}"
ORCH="${1:-1}"   # window index the orchestrator + auto-panes landed in
T() { tmux -L "$SOCKET" "$@"; }

# Bail cleanly if the target server isn't running (nothing to tidy).
T list-sessions >/dev/null 2>&1 || { echo "no tmux server on socket '$SOCKET' — nothing to do" >&2; exit 0; }

# Find-or-create the 'agents' window BY NAME and capture its REAL index.
# Never assume it lands at :2 — base-index, pre-existing windows, and
# renumber-windows all shift it (the old hardcoded :2 silently mis-targeted).
find_agents() { T list-windows -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="agents"{print $1; exit}'; }
AGENTS=$(find_agents)
CREATED=0
if [ -z "$AGENTS" ]; then
  T new-window -n agents 2>/dev/null || { echo "could not create 'agents' window on '$SOCKET'" >&2; exit 0; }
  CREATED=1
  AGENTS=$(find_agents)
fi
[ -n "$AGENTS" ] || { echo "could not resolve 'agents' window on '$SOCKET'" >&2; exit 0; }

# Move every agent pane (all but pane 0 of the orchestrator window) into 'agents'.
# Work high→low so indices don't shift mid-loop.
for p in $(T list-panes -t ":$ORCH" -F '#{pane_index}' 2>/dev/null | tail -n +2 | sort -rn); do
  T join-pane -s ":$ORCH.$p" -t ":$AGENTS" 2>/dev/null || true
done
T select-layout -t ":$AGENTS" tiled 2>/dev/null || true

# If WE just created the window, kill the leftover empty default shell pane it
# spawned with. Only when freshly created — otherwise we could kill a real agent
# pane that happens to be sitting at a bash prompt.
if [ "$CREATED" = "1" ]; then
  EMPTY=$(T list-panes -t ":$AGENTS" -F '#{pane_index} #{pane_current_command}' 2>/dev/null | awk '$2=="bash"{print $1; exit}')
  [ -n "${EMPTY:-}" ] && T kill-pane -t ":$AGENTS.$EMPTY" 2>/dev/null && T select-layout -t ":$AGENTS" tiled 2>/dev/null || true
fi

echo "agent panes tiled in window :$AGENTS ('agents'); orchestrator stays in :$ORCH"
