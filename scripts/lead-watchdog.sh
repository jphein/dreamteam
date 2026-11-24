#!/bin/bash
# lead-watchdog.sh — relaunch the fleet lead's Claude Code when it has exited in its tmux pane.
#
# Why (2026-11-18 05:51): a planned restart of the lead (jp-2f) was run from the lead's OWN teammate; the SIGTERM to the
# lead killed the teammate and its script (exit 137) before the relaunch line, and the pane sat at "Resume this session
# with: claude --resume <id>" for 2.5 h until Squire relaunched it by hand. Nothing watched the lead's pane. This does.
#
# What: every tick, look at the lead pane. Alive (a child of the pane's shell is running) → `ok`. Dead at a shell prompt
# with the resume hint in the pane history → type the pane's own launch line (`claude --resume <id> …`) and verify.
# Dead with no hint → the id and pane recorded in lead.session by the lead's own SessionStart hook (2026-11-19: the
# lead died 14:07 and nothing relaunched it); neither → `fail`: mail, never guess an id.
# Session or pane GONE (2026-11-22 04:26: systemd-oomd killed the lead's pane scope, the session went with its only
# pane, and this script said "relaunch by hand" every 2 minutes for 37 hours): the session, or a window in it, is
# made again and the lead resumed there from lead.session's id. With no id nothing is made and nothing is guessed.
# Pane there but dead (remain-on-exit) or not at a shell prompt (a killed TUI's leftovers, an unfinished `if`): the
# pane is respawned, which ends only its childless shell, and the lead resumed in the fresh one. The first version
# only warned in that state, on every tick.
# Guards: a kill-switch file; no relaunch while a client typed in the session within 60 s; at most 3 relaunches/hour,
# whichever way the lead is brought back.
#
# CHECK lead-liveness <ok|warn|fail> · <detail> · every 2 min, owner Sen      (dreamteam docs/CHECKS.md)
set -u
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
# lead.session (written by scripts/lead-session-write.sh at the lead's SessionStart): where the lead really runs and
# its session id. Read as data, line by line, each value checked against a strict shape; never sourced. ONLY the id
# and the pane are taken from it. The command typed into the shell is always built here, from this script's own
# launch-env path and the validated id: the file's `launch=` line is information for a person and is never typed
# (a line of the right shape could still name another file to source).
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
f_sid=""; f_pane=""
LS="$STATE/lead.session"
if [ -f "$LS" ] && [ ! -L "$LS" ]; then
    while IFS= read -r l; do
        case "$l" in
            session=*) [[ "${l#session=}" =~ ^$UUID$ ]] && f_sid="${l#session=}" ;;
            pane=*)    [[ "${l#pane=}" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] && f_pane="${l#pane=}" ;;
        esac
    done < "$LS"
fi
PANE="${LEAD_PANE:-${f_pane:-spire:0.0}}"
SESSION="${PANE%%:*}"
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

# The loop guard, shared by every way of bringing the lead back: at most MAX_PER_HOUR in the last hour.
budget_left() {
    local t; t=$(date +%s)
    touch "$HIST"; awk -v t="$((t - 3600))" '$1 >= t' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    [ "$(wc -l < "$HIST")" -lt "$MAX_PER_HOUR" ]
}
# Does the pane show a shell prompt as its last non-empty line (not a pager, not `> `, not a dead TUI's remains)?
prompt_now() {
    local l; l=$(tm capture-pane -p -t "$PANE" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
    case "$l" in *'$'|*'$ '|*'# '|*'#') return 0 ;; esac
    return 1
}
wait_prompt() { local i; for i in $(seq 1 25); do prompt_now && return 0; sleep 0.2; done; return 1; }
# LEAD_SHELL_CMD: what a pane made here runs (default: the user's shell). LEAD_SCOPE_RUN: how a tmux SERVER is
# started when none is running: as a child of this unit systemd would end it with the unit, so it gets a scope.
SHELL_CMD="${LEAD_SHELL_CMD:-}"
if [ -n "${LEAD_SCOPE_RUN+x}" ]; then SCOPE_RUN="$LEAD_SCOPE_RUN"
elif command -v systemd-run >/dev/null 2>&1; then SCOPE_RUN="systemd-run --user --scope --quiet --collect"
else SCOPE_RUN=""; fi
made=""                                     # how the pane came to be, when this run had to make it
if ! tm has-session -t "=$SESSION" 2>/dev/null; then
    [ -n "$f_sid" ] || { line fail "no tmux session '$SESSION' and no lead.session id to resume: relaunch by hand"; tell "no tmux session $SESSION and no lead.session id; relaunch by hand"; exit 0; }
    budget_left || { line fail "no tmux session '$SESSION'; $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"; tell "lead relaunch loop: $MAX_PER_HOUR in an hour; session $SESSION not recreated"; exit 0; }
    if tm list-sessions >/dev/null 2>&1; then
        tm new-session -d -s "$SESSION" -x 200 -y 50 -c "$HOME" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null
    else
        # shellcheck disable=SC2086
        $SCOPE_RUN tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} new-session -d -s "$SESSION" -x 200 -y 50 -c "$HOME" ${SHELL_CMD:+"$SHELL_CMD"} >/dev/null 2>&1
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do tm has-session -t "=$SESSION" 2>/dev/null && break; sleep 0.3; done
    PANE=$(tm list-panes -t "=$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | head -1)
    [ -n "$PANE" ] || { line fail "no tmux session '$SESSION' and it could not be recreated"; tell "tmux session $SESSION could not be recreated; relaunch by hand"; exit 0; }
    made="session recreated"
# The pane is looked up by EXACT name in the session's own list: `tmux display -t session:0.0` resolves a
# missing window loosely and answers for another pane (seen in the test for this case).
elif ! tm list-panes -s -t "=$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | grep -qxF "$PANE"; then
    [ -n "$f_sid" ] || { line fail "pane $PANE not found and no lead.session id to resume: relaunch by hand"; tell "pane $PANE not found and no lead.session id; relaunch by hand"; exit 0; }
    budget_left || { line fail "pane $PANE not found; $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"; tell "lead relaunch loop: $MAX_PER_HOUR in an hour; pane $PANE not recreated"; exit 0; }
    PANE=$(tm new-window -d -P -F '#{session_name}:#{window_index}.#{pane_index}' -t "=$SESSION:" -c "$HOME" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null)
    [[ "$PANE" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] || { line fail "the lead's pane is gone and a window for it could not be made in '$SESSION'"; tell "no window could be made in $SESSION; relaunch by hand"; exit 0; }
    made="window recreated"
fi
[ -n "$made" ] && wait_prompt
pane_pid=$(tm display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || { line fail "pane $PANE not found"; tell "pane $PANE not found"; exit 0; }

# Alive = the pane's shell has a running child (claude, or whatever the lead runs). The process table is the instrument
# here on purpose: the question is "is anything running in that shell", not "is it healthy".
if [ -n "$(pgrep -P "$pane_pid" 2>/dev/null)" ]; then
    line ok "pane $PANE has a running child (pid $(pgrep -P "$pane_pid" | head -1))"
    exit 0
fi

text=$(tm capture-pane -p -t "$PANE" -S -300 2>/dev/null)
sid=$(grep -oE 'claude --resume [0-9a-f-]{36}' <<<"$text" | tail -1 | awk '{print $3}')
src="the pane's hint"
if [ -z "$sid" ] && [ -n "$f_sid" ] && { [ "$PANE" = "${f_pane:-}" ] || [ -n "$made" ]; }; then sid="$f_sid"; src="lead.session"; fi   # no hint needed
if [ -z "$sid" ]; then
    line fail "pane $PANE is at a shell with no 'Resume this session with' hint and no lead.session for it: not relaunching"
    tell "lead pane $PANE is dead with no resume hint and no lead.session; relaunch by hand"
    exit 0
fi
[[ "$LAUNCH_ENV" =~ ^/[A-Za-z0-9_./-]+$ && "$sid" =~ ^$UUID$ ]] || { line fail "the launch-env path or the session id is not in a plain form: not typing anything"; tell "lead-watchdog: launch env or id not plain; relaunch by hand"; exit 0; }
launch=". $LAUNCH_ENV; claude --resume $sid --permission-mode bypassPermissions"

# Someone typing in the session? (a human may be at the keys)
act=$(tm display -p -t "$PANE" '#{client_activity}' 2>/dev/null || echo 0); now=$(date +%s)
if [ "${act:-0}" -gt 0 ] && [ $((now - act)) -lt 60 ]; then
    line warn "pane $PANE dead (resume hint for ${sid:0:8}) but a client typed $((now - act)) s ago: retry next tick"
    exit 0
fi

# Loop protection: at most MAX_PER_HOUR relaunches in the last hour.
if ! budget_left; then
    line fail "pane $PANE dead (resume hint for ${sid:0:8}); $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"
    tell "lead relaunch loop: $MAX_PER_HOUR in an hour; not relaunching ${sid:0:8}"
    exit 0
fi

# The pane must show a shell prompt as its last non-empty line before anything is typed. A pane that is dead
# (remain-on-exit), or whose childless shell shows anything else, is RESPAWNED: that ends only that shell, and the
# fresh one is at a prompt. Typing into the old one could continue an unfinished command.
if [ "$(tm display -p -t "$PANE" '#{pane_dead}' 2>/dev/null)" = 1 ] || ! prompt_now; then
    tm respawn-pane -k -t "$PANE" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null || { line fail "pane $PANE is dead or not at a prompt and could not be respawned"; tell "lead pane $PANE could not be respawned; relaunch by hand"; exit 0; }
    wait_prompt || { line fail "pane $PANE was respawned but shows no shell prompt: nothing typed"; tell "lead pane $PANE respawned, no prompt; relaunch by hand"; exit 0; }
    pane_pid=$(tm display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || { line fail "pane $PANE not found after its respawn"; exit 0; }
    made="${made:+$made, }pane respawned"
fi

# The input line must be EMPTY before anything is typed: a prompt-looking last line can still hold a half-typed
# command (e.g. `rm x #`), and our Enter would run it. Ctrl-E moves to the end of the line and Ctrl-U then discards
# everything before the cursor, i.e. the whole line, wherever the cursor was (default bash/readline and zsh/zle
# bindings; a shell with other bindings or a multi-line edit in progress is not covered). Then the pane is looked
# at again and must still be a shell with no child.
tm send-keys -t "$PANE" C-e
tm send-keys -t "$PANE" C-u
sleep 0.3
if [ -n "$(pgrep -P "$pane_pid" 2>/dev/null)" ]; then line warn "pane $PANE started something while being checked: nothing typed"; exit 0; fi
echo "$now" >> "$HIST"
tm send-keys -t "$PANE" -l "$launch"
sleep 0.3
tm send-keys -t "$PANE" Enter
for i in $(seq 1 "${LEAD_WATCHDOG_WAIT:-20}"); do
    sleep 1
    [ -n "$(pgrep -P "$pane_pid" 2>/dev/null)" ] && { line ok "relaunched ${sid:0:8} in $PANE at $(date +%H:%M:%S) from $src${made:+, $made} (child pid $(pgrep -P "$pane_pid" | head -1))"; tell "relaunched the lead (${sid:0:8}) in $PANE${made:+ ($made)}"; exit 0; }
done
line fail "typed the relaunch for ${sid:0:8} in $PANE but no child appeared in ${LEAD_WATCHDOG_WAIT:-20} s"
tell "relaunch of ${sid:0:8} typed but nothing started; look at $PANE"
exit 0
