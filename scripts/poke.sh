#!/usr/bin/env bash
# poke.sh — immediate message delivery to a dreamteam agent by typing into its
# tmux pane, bypassing SendMessage's "delivered at next tool round" lag.
#
# WHY: SendMessage (built-in) queues until the TARGET agent's next tool round, so a
# busy or idle agent receives it late; and background forks are not name-addressable
# via SendMessage at all (only by agentId). `poke` resolves the agent's pane by its
# @handle footer and types the message straight in (as if a human typed it), so it
# lands immediately AND works by NAME for any agent — forks included.
#
# SCOPE: use `poke` for SHORT, single-line nudges/unblocks ("run X now", "you're
# unblocked", "report status"). Use SendMessage for full multi-line briefs (poke
# submits on the first Enter, so newlines would split a long message).
#
# Usage: poke.sh [--dry-run] <agent-name> <message...>
#   --dry-run : resolve + show the target pane, do NOT type (safe to test live).
set -euo pipefail

dry=0
[ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
agent="${1:?usage: poke.sh [--dry-run] <agent-name> <message...>}"; shift
msg="$*"
[ -n "$msg" ] || { echo "poke: empty message" >&2; exit 22; }

# Resolve the agent's pane: the pane whose FOOTER (last few lines) shows "@<agent>".
# Footer-only match (-S -6) avoids false hits on roster listings higher up a pane.
target=""
while IFS= read -r p; do
  # Footer @handle line is box-drawing-flanked ("──── @agent ──"); require BOTH
  # "@agent" AND a box-dash on the line so a roster listing elsewhere in a pane
  # (e.g. "@agent(active)" in another agent's fleet view) never false-matches.
  if tmux capture-pane -p -t "$p" -S -5 2>/dev/null | grep -F "@${agent}" | grep -q '─'; then
    target="$p"; break
  fi
done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)

[ -n "$target" ] || { echo "poke: no live pane found for @${agent}" >&2; exit 3; }

if [ "$dry" = 1 ]; then
  echo "poke[dry-run]: would type into @${agent} at ${target}:"
  echo "  ${msg}"
  exit 0
fi

# Type the message literally, then submit with Enter. A brief settle between the
# paste and the Enter is REQUIRED: without it the Enter can arrive while the TUI is
# still ingesting the paste, so the text lands in the input box but never submits
# ("queued-without-submit"). 0.4s reliably lets the paste register first.
tmux send-keys -t "$target" -l "$msg"
sleep 0.4
tmux send-keys -t "$target" Enter
echo "poked @${agent} -> ${target}: ${msg}"
