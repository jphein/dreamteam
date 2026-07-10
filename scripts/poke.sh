#!/usr/bin/env bash
# poke.sh — immediate message delivery to a dreamteam agent by typing into its
# tmux pane, bypassing SendMessage's "delivered at next tool round" lag.
#
# WHY: SendMessage (built-in) queues until the TARGET agent's next tool round, so a
# busy or idle agent receives it late; and background forks are not name-addressable
# via SendMessage at all (only by agentId). `poke` resolves the agent's pane and
# types the message straight in (as if a human typed it), so it lands immediately
# AND works by NAME for any agent — forks included.
#
# SCOPE: use `poke` for SHORT, single-line nudges/unblocks ("run X now", "you're
# unblocked", "report status"). Use SendMessage for full multi-line briefs (poke
# submits on Enter, so newlines would split a long message).
#
# PANE RESOLUTION (#35): resolve FRESH per call via pane-peek.sh (pid-ancestry:
# roster NAME→pid→owning pane across every tmux socket — the #32 technique), which
# also carries an @handle-footer fallback so forks (not in the roster) still resolve.
# We then print the pane pane-peek ACTUALLY resolved — never a stale/guessed index.
# If pane-peek is unavailable we fall back to a self-contained @handle scan so poke
# still works standalone.
#
# SUBMIT VERIFICATION (#28): a fixed `sleep` before Enter is a timing GUESS — when the
# target is mid-turn the Enter can arrive while the TUI is still ingesting the paste,
# so the text lands on the `❯` input line but never submits ("queued-without-submit";
# observed live). Instead of a longer guess, we VERIFY: after each Enter we re-capture
# the pane and check whether our message is still sitting on the bottom-most `❯` input
# line. If so we retry Enter; if a queued-acceptance indicator appears we stop (the
# message was taken, will deliver at turn end — retrying would double-submit); and if
# it never submits after N attempts we exit NON-ZERO with a real failure — never a
# silent "poked".
#
# Usage: poke.sh [--dry-run] <agent-name> <message...>
#   --dry-run : resolve + show the target pane, do NOT type (safe to test live).
# Env: POKE_SUBMIT_RETRIES (default 4), DREAMTEAM_PANE_PEEK (resolver path).
# Exit: 0 delivered · 3 no pane · 4 failed-to-submit (real) · 22 usage.
set -euo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PANE_PEEK="${DREAMTEAM_PANE_PEEK:-$ROOT/scripts/pane-peek.sh}"
RETRIES="${POKE_SUBMIT_RETRIES:-4}"
SETTLE="${POKE_SETTLE:-0.3}"                          # per-step settle (tests set 0)

dry=0
[ "${1:-}" = "--dry-run" ] && { dry=1; shift; }
agent="${1:?usage: poke.sh [--dry-run] <agent-name> <message...>}"; shift
agent="${agent#@}"                                   # tolerate `@name`
msg="$*"
[ -n "$msg" ] || { echo "poke: empty message" >&2; exit 22; }

# ── resolve the pane FRESH (#35) ─────────────────────────────────────────────
socket=""; pane=""
if [ -f "$PANE_PEEK" ]; then
  # pane-peek --json → {found, socket (full path), pane (addr)}; pid-ancestry + @handle.
  read -r pk_found socket pane < <(
    bash "$PANE_PEEK" --json "$agent" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("0 - -"); sys.exit(0)
print(("1" if d.get("found") else "0"), d.get("socket") or "-", d.get("pane") or "-")
' 2>/dev/null || echo "0 - -")
  [ "${pk_found:-0}" = "1" ] || { socket=""; pane=""; }
  [ "$pane" = "-" ] && pane=""
  [ "$socket" = "-" ] && socket=""
fi
if [ -z "$pane" ] && [ ! -f "$PANE_PEEK" ]; then
  # fallback ONLY when pane-peek is absent (else its own @handle fallback already ran):
  # self-contained @handle footer scan on the default socket.
  while IFS= read -r p; do
    if tmux capture-pane -p -t "$p" -S -5 2>/dev/null | grep -F "@${agent}" | grep -q '─'; then
      pane="$p"; break
    fi
  done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
fi
[ -n "$pane" ] || { echo "poke: no live pane found for @${agent}" >&2; exit 3; }

# tmux addressed at the resolved socket (empty ⇒ default server).
tmux_s() { if [ -n "$socket" ]; then tmux -S "$socket" "$@"; else tmux "$@"; fi; }
disp="${socket:+$(basename "$socket")@}${pane}"

if [ "$dry" = 1 ]; then
  echo "poke[dry-run]: would type into @${agent} at ${disp}:"
  echo "  ${msg}"
  exit 0
fi

# ── submit verification (#28) ────────────────────────────────────────────────
probe="${msg//$'\n'/ }"; probe="${probe:0:24}"       # fixed-string prefix, single-lined

# our message still sitting on the LIVE (bottom-most) ❯ input line ⇒ not submitted
still_on_input() {
  local lastprompt
  lastprompt="$(tmux_s capture-pane -p -t "$pane" 2>/dev/null | grep -F '❯' | tail -n1)"
  printf '%s' "$lastprompt" | grep -Fq "$probe"
}
# mid-turn queued-acceptance indicator near the input box ⇒ taken (don't re-Enter)
accepted_as_queued() {
  tmux_s capture-pane -p -t "$pane" 2>/dev/null | tail -n 6 \
    | grep -qiE 'queued|press up to edit'
}

tmux_s send-keys -t "$pane" -l "$msg"
sleep "$SETTLE"
ok=0
for _ in $(seq 1 "$RETRIES"); do
  tmux_s send-keys -t "$pane" Enter
  sleep "$SETTLE"
  if ! still_on_input || accepted_as_queued; then ok=1; break; fi
done

if [ "$ok" != 1 ]; then
  echo "poke: FAILED to submit to @${agent} at ${disp} — message still on the ❯ input line after ${RETRIES} Enter attempts. Pane may be mid-turn/stuck; check it (pane-peek ${agent})." >&2
  exit 4
fi
echo "poked @${agent} -> ${disp}: ${msg}"
