#!/usr/bin/env bash
# dreamteam — PostToolUse hook for Agent spawns.
# Auto-moves new agent panes into an "agents" tmux window so they don't
# crowd the orchestrator. Skips if not in tmux or if DREAMTEAM_INLINE_PANE=1
# (for agents producing output directly for JP).
set -uo pipefail

# Skip if not in tmux
[ -n "${TMUX:-}" ] || exit 0

# Skip if this agent should stay inline (orchestrator sets this env var)
[ "${DREAMTEAM_INLINE_PANE:-0}" = "1" ] && exit 0

# Only act on Agent tool calls
INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL" = "Agent" ] || exit 0

# Find our tmux session
SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
[ -n "$SESSION" ] || exit 0

# Find orchestrator window (the one we're in)
ORCH_WIN=$(tmux display-message -p '#{window_index}' 2>/dev/null || true)
[ -n "$ORCH_WIN" ] || exit 0

# Count panes in orchestrator window — if only 1, no agent pane to move
PANE_COUNT=$(tmux list-panes -t "$SESSION:$ORCH_WIN" -F '#{pane_index}' 2>/dev/null | wc -l)
[ "$PANE_COUNT" -gt 1 ] || exit 0

# Find or create agents window
AGENTS_WIN=$(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="agents"{print $1; exit}')
if [ -z "$AGENTS_WIN" ]; then
  tmux new-window -t "$SESSION" -n agents 2>/dev/null || exit 0
  AGENTS_WIN=$(tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null | awk '$2=="agents"{print $1; exit}')
  [ -n "$AGENTS_WIN" ] || exit 0
fi

# Move the newest agent pane (highest index) from orchestrator to agents window
LAST_PANE=$(tmux list-panes -t "$SESSION:$ORCH_WIN" -F '#{pane_index}' 2>/dev/null | sort -rn | head -1)
[ "$LAST_PANE" != "0" ] && tmux join-pane -s "$SESSION:$ORCH_WIN.$LAST_PANE" -t "$SESSION:$AGENTS_WIN" 2>/dev/null || true

# Clean layout
tmux select-layout -t "$SESSION:$AGENTS_WIN" tiled 2>/dev/null || true

# Kill empty shell pane if agents window was just created
EMPTY=$(tmux list-panes -t "$SESSION:$AGENTS_WIN" -F '#{pane_index} #{pane_current_command}' 2>/dev/null | grep ' bash$' | head -1 | cut -d' ' -f1)
[ -n "${EMPTY:-}" ] && tmux kill-pane -t "$SESSION:$AGENTS_WIN.$EMPTY" 2>/dev/null && tmux select-layout -t "$SESSION:$AGENTS_WIN" tiled 2>/dev/null

# Stay on orchestrator window
tmux select-window -t "$SESSION:$ORCH_WIN" 2>/dev/null || true

exit 0
