#!/usr/bin/env bash
# PreToolUse hook for TaskStop.
# Before killing an agent, remind the orchestrator to check its tmux pane.
# An agent mid-tool-chain won't process SendMessage until the chain completes —
# silence does NOT mean stuck or dead.
set -euo pipefail

cat >&2 <<'EOF'
⚠️ Before killing this agent, check its tmux pane:

  tmux capture-pane -t :<window>.<pane> -p -S -50

An agent mid-tool-chain won't respond to SendMessage until the chain
completes. Non-response does NOT mean idle or broken. Only kill if the
pane shows the agent is truly idle, stuck, or working on something unrelated.
EOF
