#!/bin/bash
# lead-watchdog.sh — relaunch the fleet lead's Claude Code when it has exited in its tmux pane.
#
# Why (2026-11-18 05:51): a planned restart of the lead (jp-2f) was run from the lead's OWN teammate; the SIGTERM to the
# lead killed the teammate and its script (exit 137) before the relaunch line, and the pane sat at "Resume this session
# with: claude --resume <id>" for 2.5 h until Squire relaunched it by hand. Nothing watched the lead's pane. This does.
#
# What: every tick, look at the lead pane. Alive (a child of the pane's shell is running) → `ok`. Dead at a shell prompt
# with the resume hint in the pane history → type the pane's own launch line (`claude --resume <id> …`) and verify.
# Dead with no hint → `fail` (a human exited it on purpose, or the history is gone): mail, never guess an id.
# Guards: a kill-switch file; no relaunch while a client typed in the session within 60 s; at most 3 relaunches/hour.
#
# CHECK lead-liveness <ok|warn|fail> · <detail> · every 2 min, owner Sen      (dreamteam docs/CHECKS.md)
set -u
PANE="${LEAD_PANE:-spire:0.0}"
SESSION="${PANE%%:*}"
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
CHECKS="${CHECKS_DIR:-$HOME/.local/state/checks}"
OFF="$STATE/lead-watchdog.off"
HIST="$STATE/lead-watchdog.relaunches"      # one epoch per relaunch
LINE="$CHECKS/lead-liveness.line"
LAUNCH_ENV="${LEAD_LAUNCH_ENV:-$HOME/.config/claude-code/env.sh}"
MAIL="${LEAD_WATCHDOG_MAIL:-agent-mail}"    # `agent-mail send sen "<text>"`; set to "true" in tests
tm() { tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} "$@"; }   # LEAD_TMUX_SOCKET: a private server (tests)
MAX_PER_HOUR=3
mkdir -p "$STATE" "$CHECKS"

line() {  # <status> <detail>: the one fixed-shape line
    printf 'CHECK lead-liveness %s · %s · every 2 min, owner Sen\n' "$1" "$2" | tee "$LINE"
}
tell() { "$MAIL" send sen "lead-watchdog $(date +%H:%M): $1" >/dev/null 2>&1 || true; }

[ -e "$OFF" ] && { line warn "watchdog off ($OFF present)"; exit 0; }
tm has-session -t "=$SESSION" 2>/dev/null || { line fail "no tmux session '$SESSION' (the lead's window is gone; relaunch by hand)"; tell "no tmux session $SESSION"; exit 0; }
pane_pid=$(tm display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || { line fail "pane $PANE not found"; tell "pane $PANE not found"; exit 0; }

# Alive = the pane's shell has a running child (claude, or whatever the lead runs). The process table is the instrument
# here on purpose: the question is "is anything running in that shell", not "is it healthy".
if [ -n "$(pgrep -P "$pane_pid" 2>/dev/null)" ]; then
    line ok "pane $PANE has a running child (pid $(pgrep -P "$pane_pid" | head -1))"
    exit 0
fi

text=$(tm capture-pane -p -t "$PANE" -S -300 2>/dev/null)
sid=$(grep -oE 'claude --resume [0-9a-f-]{36}' <<<"$text" | tail -1 | awk '{print $3}')
if [ -z "$sid" ]; then
    line fail "pane $PANE is at a shell with no 'Resume this session with' hint: not relaunching (an exit on purpose, or history lost)"
    tell "lead pane $PANE is dead with no resume hint; relaunch by hand"
    exit 0
fi

# Someone typing in the session? (a human may be at the keys)
act=$(tm display -p -t "$PANE" '#{client_activity}' 2>/dev/null || echo 0); now=$(date +%s)
if [ "${act:-0}" -gt 0 ] && [ $((now - act)) -lt 60 ]; then
    line warn "pane $PANE dead (resume hint for ${sid:0:8}) but a client typed $((now - act)) s ago: retry next tick"
    exit 0
fi

# Loop protection: at most MAX_PER_HOUR relaunches in the last hour.
touch "$HIST"; awk -v t="$((now - 3600))" '$1 >= t' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
if [ "$(wc -l < "$HIST")" -ge "$MAX_PER_HOUR" ]; then
    line fail "pane $PANE dead (resume hint for ${sid:0:8}); $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"
    tell "lead relaunch loop: $MAX_PER_HOUR in an hour; not relaunching ${sid:0:8}"
    exit 0
fi

# The pane must show a shell prompt as its last non-empty line (not a pager, not a half-typed command).
last=$(grep -v '^[[:space:]]*$' <<<"$text" | tail -1)
case "$last" in
    *'$'|*'$ '|*'# '|*'#') ;;
    *) line warn "pane $PANE dead (resume hint for ${sid:0:8}) but the last line is not a prompt: '${last:0:60}'"; exit 0 ;;
esac

echo "$now" >> "$HIST"
tm send-keys -t "$PANE" -l ". $LAUNCH_ENV; claude --resume $sid --permission-mode bypassPermissions"
sleep 0.3
tm send-keys -t "$PANE" Enter
for i in $(seq 1 "${LEAD_WATCHDOG_WAIT:-20}"); do
    sleep 1
    [ -n "$(pgrep -P "$pane_pid" 2>/dev/null)" ] && { line ok "relaunched ${sid:0:8} in $PANE at $(date +%H:%M:%S) (child pid $(pgrep -P "$pane_pid" | head -1))"; tell "relaunched the lead (${sid:0:8}) in $PANE"; exit 0; }
done
line fail "typed the relaunch for ${sid:0:8} in $PANE but no child appeared in ${LEAD_WATCHDOG_WAIT:-20} s"
tell "relaunch of ${sid:0:8} typed but nothing started; look at $PANE"
exit 0
