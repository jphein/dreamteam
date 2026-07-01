#!/usr/bin/env bash
# dreamteam — isolated, memory-capped launcher.
#
# Solves the 06-30 blast-radius problem: the whole team ran in ONE Ghostty snap
# cgroup on the ONE default tmux server, so a single balloon thrashed the host
# and took every session with it. This launcher gives the team:
#   • its own systemd user scope with MemoryHigh/Max/SwapMax  → graceful throttle
#     + hard ceiling; a runaway is contained to the team's cgroup, host survives
#   • its own tmux server socket (-L dreamteam)               → if the team's tmux
#     dies, JP's main 'default' server + other work survive
#
# Usage: launch-dreamteam.sh [team-name] [repo-path]
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"; mkdir -p "$STATE"
TEAM="${1:-dream}"; REPO="${2:-$PWD}"
getcfg() { jq -r --arg k "$1" --arg d "$2" ".scope[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
HIGH=$(getcfg memoryHigh 20G); MAX=$(getcfg memoryMax 24G); SWAPMAX=$(getcfg memorySwapMax 8G)

# Write the active-marker (crash-audit reads this if we die uncleanly).
printf '{"team":"%s","repo":"%s","started":"%s"}\n' "$TEAM" "$REPO" "$(date +%FT%T)" > "$STATE/active"

echo "Launching dreamteam '$TEAM' — scope MemoryHigh=$HIGH MemoryMax=$MAX MemorySwapMax=$SWAPMAX, tmux -L dreamteam"
if systemctl --user show-environment >/dev/null 2>&1; then
  exec systemd-run --user --scope \
    -p MemoryHigh="$HIGH" -p MemoryMax="$MAX" -p MemorySwapMax="$SWAPMAX" \
    --unit="dreamteam-$TEAM" \
    tmux -L dreamteam new-session -s "$TEAM"
else
  echo "⚠ systemd --user unavailable — falling back to tmux -L only (NO memory cap; open in a separate Ghostty window for partial isolation)." >&2
  exec tmux -L dreamteam new-session -s "$TEAM"
fi
