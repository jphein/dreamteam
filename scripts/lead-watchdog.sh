#!/bin/bash
# lead-watchdog.sh — bring the fleet lead's Claude Code back when it is gone from its tmux pane.
#
# Why (2026-11-18 05:51): a planned restart of the lead was run from the lead's OWN teammate; the SIGTERM to the
# lead killed the teammate and its script before the relaunch line, and the pane sat dead for 2.5 h.
# Why (2026-11-19 14:07): the lead died in a pane the watchdog did not watch and with no resume hint on screen.
# Why (2026-11-22 04:26): systemd-oomd killed the lead's pane scope; the session went with its only pane, and
# this script said "no tmux session, relaunch by hand" every 2 minutes for 37 hours.
#
# IDENTITY: lead.session, written by the lead's own SessionStart hook (scripts/lead-session-write.sh), is the ONLY
# source of who the lead is and where it lives: session id, pane, working directory. Nothing shown in a pane is
# ever used as an id (pane history is text anyone can print). No valid lead.session → nothing is made or typed.
#
# WHAT IT DOES, every tick, under ONE lock held from the first look to the last key:
#   the recorded pane has a running child                         → ok
#   a process resuming the lead's id is alive ANYWHERE on the host,
#     or the lead's named scope is active                         → warn, nothing made, nothing typed
#   otherwise the lead is gone. The place is restored as recorded (the session, the window at its recorded index,
#     the working directory), a pane that is dead or not at a shell prompt is respawned, and the lead is resumed
#     there INSIDE its own named scope:
#         systemd-run --user --scope --unit=lead-<session> -p ManagedOOMPreference=avoid claude --resume <id> …
#     so the lead's cgroup is a unit this script named and created (oomd passes it over; the root helper of
#     dreamteam io-shield gives exactly that unit its OOM score), whichever tmux server or pane it runs in.
#
# NEVER TWO LEADS. The check "is a lead alive" (pane child, host-wide process, named scope) is repeated inside the
# lock immediately before each step that creates, respawns or types; a lead that starts in between stops the run.
# The lock also serializes this script against itself. A person starting the lead by hand does not take the lock;
# the repeated host-wide check is what sees them.
#
# Guards: a kill-switch file; no relaunch while a client typed in the session within 60 s; at most 3 an hour.
# A tmux SERVER this script has to start is started in a scope of its own (a child of this unit would be ended
# with the unit); with no systemd-run it does not start one.
#
# CHECK lead-liveness <ok|warn|fail> · <detail> · every 2 min, owner Sen      (dreamteam docs/CHECKS.md)
set -u
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
PLAIN='^/[A-Za-z0-9_./-]+$'
# lead.session is read as data, line by line, each value checked against a strict shape; never sourced. Its
# `launch=` line is information for a person and is never typed: the command is always built here.
f_sid=""; f_pane=""; f_cwd=""
LS="$STATE/lead.session"
if [ -f "$LS" ] && [ ! -L "$LS" ]; then
    while IFS= read -r l; do
        case "$l" in
            session=*) [[ "${l#session=}" =~ ^$UUID$ ]] && f_sid="${l#session=}" ;;
            pane=*)    [[ "${l#pane=}" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] && f_pane="${l#pane=}" ;;
            cwd=*)     [[ "${l#cwd=}" =~ $PLAIN ]] && f_cwd="${l#cwd=}" ;;
        esac
    done < "$LS"
fi
PANE="${LEAD_PANE:-${f_pane:-spire:0.0}}"
SESSION="${PANE%%:*}"; WIN="${PANE#*:}"; WIN="${WIN%%.*}"
CWD="${f_cwd:-$HOME}"
CHECKS="${CHECKS_DIR:-$HOME/.local/state/checks}"
OFF="$STATE/lead-watchdog.off"
HIST="$STATE/lead-watchdog.relaunches"      # one epoch per relaunch
LINE="$CHECKS/lead-liveness.line"
LAUNCH_ENV="${LEAD_LAUNCH_ENV:-$HOME/.config/claude-code/env.sh}"
MAIL="${LEAD_WATCHDOG_MAIL:-agent-mail}"    # `agent-mail send sen "<text>"`; set to "true" in tests
UNIT="${LEAD_SCOPE_UNIT:-lead-${SESSION//[^A-Za-z0-9_-]/_}}"      # the lead's named scope (without .scope)
# LEAD_TMUX_SOCKET: a private server (tests). `9>&-`: nothing this script starts gets a copy of the lock's
# descriptor (see the lock below); a tmux server or any other process that outlived the run would hold the lock.
tm() { tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} "$@" 9>&-; }
MAX_PER_HOUR=3
mkdir -p "$STATE" "$CHECKS"

line() {  # <status> <detail>: the one fixed-shape line
    printf 'CHECK lead-liveness %s · %s · every 2 min, owner Sen\n' "$1" "$2" | tee "$LINE"
}
tell() { "$MAIL" send sen "lead-watchdog $(date +%H:%M): $1" >/dev/null 2>&1 9>&- || true; }

[ -e "$OFF" ] && { line warn "watchdog off ($OFF present)"; exit 0; }

# ONE lock from here to the end: the looks and the acts below are one critical section. Every process started
# below is started with `9>&-`, so the lock is held by this script alone and ends with it.
exec 9>"$STATE/lead-watchdog.lock" || { line fail "cannot open the lock file in $STATE"; exit 0; }
flock -n 9 || { line warn "another lead-watchdog run holds the lock: nothing done this tick"; exit 0; }

# How the lead is put in its scope, and how a tmux server is started when none runs. LEAD_SCOPE_RUN replaces the
# runner (tests); it must be a plain path. LEAD_SHELL_CMD: what a pane made here runs (default: the user's shell).
if [ -n "${LEAD_SCOPE_RUN+x}" ]; then SCOPE_RUN="$LEAD_SCOPE_RUN"
elif command -v systemd-run >/dev/null 2>&1; then SCOPE_RUN="systemd-run --user --scope --quiet --collect"
else SCOPE_RUN=""; fi
SHELL_CMD="${LEAD_SHELL_CMD:-}"

budget_left() {
    local t; t=$(date +%s)
    touch "$HIST"; awk -v t="$((t - 3600))" '$1 >= t' "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
    [ "$(wc -l < "$HIST")" -lt "$MAX_PER_HOUR" ]
}
panes_of() { tm list-panes -s -t "=$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null; }
# The pane is looked up by EXACT name in the session's own list: `tmux display -t s:0.0` resolves a missing window
# loosely and answers for another pane.
pane_exists() { panes_of | grep -qxF "$PANE"; }
pane_child() { local pp; pp=$(tm display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) && [ -n "$pp" ] && pgrep -P "$pp" 2>/dev/null | head -1; }
prompt_now() {
    local l; l=$(tm capture-pane -p -t "$PANE" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -1)
    case "$l" in *'$'|*'$ '|*'# '|*'#') return 0 ;; esac
    return 1
}
wait_prompt() { local i; for i in $(seq 1 25); do prompt_now && return 0; sleep 0.2; done; return 1; }
# A process of ours named claude whose arguments are `--resume <the lead's id>`: the lead, wherever it runs
# (another pane, another session, detached from its shell). Prints its pid.
lead_process() {
    [ -n "$f_sid" ] || return 1
    local d p
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        [ "$(cat "$d/comm" 2>/dev/null)" = claude ] || continue
        [ "$(stat -c %u "$d" 2>/dev/null)" = "$(id -u)" ] || continue
        if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -A1 -xF -- '--resume' | grep -qxF -- "$f_sid"; then echo "$p"; return 0; fi
    done
    return 1
}
scope_active() { systemctl --user is-active --quiet "$UNIT.scope" 2>/dev/null; }
# THE GATE, run inside the lock right before every step that creates, respawns or types. LEAD_WATCHDOG_BEFORE_GATE
# (tests only, a plain path) runs first: it lets a test start a lead "between the check and the act".
alive=""
gate() {
    [[ "${LEAD_WATCHDOG_BEFORE_GATE:-}" =~ $PLAIN ]] && "$LEAD_WATCHDOG_BEFORE_GATE" >/dev/null 2>&1 9>&-
    local p
    if pane_exists && p=$(pane_child) && [ -n "$p" ]; then alive="pane $PANE has a running child (pid $p)"; return 1; fi
    if p=$(lead_process); then alive="a process resuming ${f_sid:0:8} is alive (pid $p) outside $PANE"; return 1; fi
    if scope_active; then alive="the lead's scope $UNIT.scope is active"; return 1; fi
    return 0
}
stop_alive() { line warn "$alive: nothing made, nothing typed${1:+ ($1)}"; tell "$alive; not relaunching"; exit 0; }

# 1. The recorded pane has a running child: alive. (The process table is the instrument on purpose: "is anything
#    running in that shell", not "is it healthy".)
if tm has-session -t "=$SESSION" 2>/dev/null && pane_exists && c=$(pane_child) && [ -n "$c" ]; then
    line ok "pane $PANE has a running child (pid $c)"; exit 0
fi

# 2. The lead is not in its pane. Everything below needs the recorded identity.
if [ -z "$f_sid" ]; then
    if ! tm has-session -t "=$SESSION" 2>/dev/null; then what="no tmux session '$SESSION'"; elif ! pane_exists; then what="pane $PANE not found"; else what="pane $PANE is at a shell"; fi
    line fail "$what and no valid lead.session (the only source of the lead's id): not relaunching"
    tell "$what and no valid lead.session; relaunch by hand"; exit 0
fi
[[ "$LAUNCH_ENV" =~ $PLAIN && "$CWD" =~ $PLAIN ]] || { line fail "the launch-env path or the working directory is not in a plain form: not typing anything"; tell "lead-watchdog: launch env or cwd not plain; relaunch by hand"; exit 0; }
[ -z "$SCOPE_RUN" ] || [ "$SCOPE_RUN" = "systemd-run --user --scope --quiet --collect" ] || [[ "$SCOPE_RUN" =~ $PLAIN ]] || { line fail "the scope runner is not in a plain form: not typing anything"; exit 0; }
[[ "$UNIT" =~ ^[A-Za-z0-9_-]{1,80}$ ]] || { line fail "the scope unit name is not in a plain form: not typing anything"; exit 0; }
sid="$f_sid"

# 3. Is the lead alive somewhere else? Asked BEFORE anything is made.
gate || stop_alive

# Someone typing in the session? (a human may be at the keys)
now=$(date +%s)
if tm has-session -t "=$SESSION" 2>/dev/null; then
    act=$(tm display -p -t "=$SESSION:" '#{client_activity}' 2>/dev/null || echo 0)
    if [ "${act:-0}" -gt 0 ] && [ $((now - act)) -lt 60 ]; then
        line warn "the lead (${sid:0:8}) is gone from $PANE but a client typed $((now - act)) s ago: retry next tick"; exit 0
    fi
fi
if ! budget_left; then
    line fail "the lead (${sid:0:8}) is gone from $PANE; $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"
    tell "lead relaunch loop: $MAX_PER_HOUR in an hour; not relaunching ${sid:0:8}"; exit 0
fi

# 4. Restore the place as recorded: the session, the window at its recorded index, the working directory.
made=""
if ! tm has-session -t "=$SESSION" 2>/dev/null; then
    gate || stop_alive
    if tm list-sessions >/dev/null 2>&1; then
        tm new-session -d -s "$SESSION" -x 200 -y 50 -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null
    elif [ -n "$SCOPE_RUN" ]; then
        # shellcheck disable=SC2086
        $SCOPE_RUN --unit="tmux-${UNIT#lead-}-$now" tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} new-session -d -s "$SESSION" -x 200 -y 50 -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} >/dev/null 2>&1 9>&-
    else
        line fail "no tmux server and no systemd-run: a server started here would end with this unit; not recreating '$SESSION'"
        tell "no tmux server and no systemd-run; relaunch by hand"; exit 0
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do tm has-session -t "=$SESSION" 2>/dev/null && break; sleep 0.3; done
    cur=$(tm list-windows -t "=$SESSION" -F '#{window_index}' 2>/dev/null | head -1)
    [ -n "$cur" ] || { line fail "no tmux session '$SESSION' and it could not be recreated"; tell "tmux session $SESSION could not be recreated; relaunch by hand"; exit 0; }
    [ "$cur" = "$WIN" ] || tm move-window -s "=$SESSION:$cur" -t "=$SESSION:$WIN" 2>/dev/null
    made="session recreated"
elif ! pane_exists; then
    gate || stop_alive
    if tm list-windows -t "=$SESSION" -F '#{window_index}' 2>/dev/null | grep -qx "$WIN"; then
        tm split-window -d -t "=$SESSION:$WIN" -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null; made="pane recreated in window $WIN"
    else
        tm new-window -d -t "=$SESSION:$WIN" -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null; made="window $WIN recreated"
    fi
fi
if [ -n "$made" ] && ! pane_exists; then
    # the recorded pane index cannot be given to a fresh pane (a new window has one pane; a split takes the next
    # free index): the lead goes to the newest pane of the recorded window, and the line says so
    np=$(tm list-panes -t "=$SESSION:$WIN" -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | tail -1)
    [[ "$np" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] || { line fail "the lead's place ($PANE) could not be restored in '$SESSION'"; tell "the lead's pane $PANE could not be restored; relaunch by hand"; exit 0; }
    made="$made (recorded $PANE, restored as $np)"; PANE="$np"
fi
[ -n "$made" ] && wait_prompt

# 5. Nothing is typed into a pane that is dead (remain-on-exit) or whose childless shell does not show a prompt:
#    it is respawned, which ends only that shell, and the fresh one is at a prompt in the recorded directory.
if [ "$(tm display -p -t "$PANE" '#{pane_dead}' 2>/dev/null)" = 1 ] || ! prompt_now; then
    gate || stop_alive "before the respawn"
    tm respawn-pane -k -t "$PANE" -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null || { line fail "pane $PANE is dead or not at a prompt and could not be respawned"; tell "lead pane $PANE could not be respawned; relaunch by hand"; exit 0; }
    wait_prompt || { line fail "pane $PANE was respawned but shows no shell prompt: nothing typed"; tell "lead pane $PANE respawned, no prompt; relaunch by hand"; exit 0; }
    made="${made:+$made, }pane respawned"
fi

# 6. The input line must be EMPTY before anything is typed (Ctrl-E, then Ctrl-U: the whole line, wherever the
#    cursor was). Then THE GATE once more, immediately before the keys: a lead that started meanwhile stops us.
tm send-keys -t "$PANE" C-e
tm send-keys -t "$PANE" C-u
sleep 0.3
gate || stop_alive "it started while the pane was being prepared"
if [ -n "$SCOPE_RUN" ]; then inscope="$SCOPE_RUN --unit=$UNIT -p ManagedOOMPreference=avoid "; where=" in scope $UNIT.scope"
else inscope=""; where=" (no systemd-run here: NOT in its named scope)"; fi
launch="cd $CWD && . $LAUNCH_ENV; ${inscope}claude --resume $sid --permission-mode bypassPermissions"
echo "$now" >> "$HIST"
tm send-keys -t "$PANE" -l "$launch"
sleep 0.3
tm send-keys -t "$PANE" Enter
for i in $(seq 1 "${LEAD_WATCHDOG_WAIT:-20}"); do
    sleep 1
    if c=$(pane_child) && [ -n "$c" ]; then
        line ok "relaunched ${sid:0:8} in $PANE at $(date +%H:%M:%S) from lead.session${made:+, $made}$where (child pid $c)"
        tell "relaunched the lead (${sid:0:8}) in $PANE${made:+ ($made)}"; exit 0
    fi
done
line fail "typed the relaunch for ${sid:0:8} in $PANE but no child appeared in ${LEAD_WATCHDOG_WAIT:-20} s"
tell "relaunch of ${sid:0:8} typed but nothing started; look at $PANE"
exit 0
