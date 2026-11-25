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
# source of who the lead is and where it lives: session id, pane, working directory. It is read by
# lib/lead-record.sh and must be COMPLETE and UNAMBIGUOUS (one session=, one pane=, one cwd=, nothing unknown, a
# plain file of ours, a directory that exists). There is NO default pane and NO default directory: without a valid
# record this script says fail and looks at nothing, makes nothing, types nothing. Nothing shown in a pane is ever
# used as an id.
#
# WHAT IT DOES, every tick, under ONE lock held from the first look to the last key:
#   the recorded pane has a running child                         → ok
#   ANY process on the host carries the lead's id in its command
#     line (any name, owner, argument form), or the lead's named
#     scope is active, or a launch is in progress                 → warn, nothing made, nothing typed
#   otherwise the lead is gone. The place is restored as recorded (the session, the window at its recorded index,
#     the working directory), a pane that is dead or not at a shell prompt is respawned, and ONE line is typed:
#         bash <this repo>/scripts/lead-launch.sh <the state directory this run locked>
#     The launcher reads lead.session itself and makes the LAST check at launch time, under the launch lock every
#     launch takes, then execs the lead inside its own named scope (lead-<session>.scope, oomd preference set at
#     creation). No scope runner → nothing is typed: the lead is never started outside its scope.
#
# NEVER TWO LEADS, AND NO ACT WITHOUT ITS GATE (the ruling after review round 3). There is ONE lock on this host
# for everything that can start or disturb the lead: <state>/lead.lock. This script takes it for its whole
# CHECK-AND-ACT section, and scripts/lead-launch.sh (the one way the lead is started, by this script or by a
# person) takes the SAME lock for its own check-and-exec. So while this script is between a gate and its act,
# no launch can start a lead: a launcher run at that moment waits for the lock. Inside the lock the gate (pane
# child, host-wide command-line search, named scope) runs again IMMEDIATELY before `respawn-pane` and
# IMMEDIATELY before `send-keys`; not one key reaches the pane before that last gate, and what is sent is one
# tmux call. The lock is released right after the keys: the launcher this script just typed takes it, makes
# its own look, discards anything typed at its terminal meanwhile, and execs the lead.
# What the lock cannot cover is a process that does not take it: a bare `claude --resume <id>` typed by hand.
# The contract is that the lead is started ONLY through lead-launch.sh (lead.session's launch= line names it).
#
# THE LOCK'S DESCRIPTOR REACHES NO CHILD: the check-and-act section runs as `act 9>&-`, so no program started
# there (tmux, systemctl, date, awk, a pipeline, a sleep, the mailer, a tmux server) ever holds it.
#
# Guards: a kill-switch file; no relaunch while a client typed in the session within 60 s; at most 3 an hour.
# A tmux SERVER this script has to start is started in a scope of its own (a child of this unit would be ended
# with the unit).
#
# CHECK lead-liveness <ok|warn|fail> · <detail> · every 2 min, owner Sen      (dreamteam docs/CHECKS.md)
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 0
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
CHECKS="${CHECKS_DIR:-$HOME/.local/state/checks}"
OFF="$STATE/lead-watchdog.off"
HIST="$STATE/lead-watchdog.relaunches"      # one epoch per relaunch
LINE="$CHECKS/lead-liveness.line"
LAUNCHER="$here/lead-launch.sh"
LAUNCH_ENV="${LEAD_LAUNCH_ENV:-$HOME/.config/claude-code/env.sh}"
MAIL="${LEAD_WATCHDOG_MAIL:-agent-mail}"    # `agent-mail send sen "<text>"`; set to "true" in tests
MAX_PER_HOUR=3
mkdir -p "$STATE" "$CHECKS"

line() {  # <status> <detail>: the one fixed-shape line
    printf 'CHECK lead-liveness %s · %s · every 2 min, owner Sen\n' "$1" "$2" | tee "$LINE"
}
tell() { "$MAIL" send sen "lead-watchdog $(date +%H:%M): $1" >/dev/null 2>&1 || true; }
# shellcheck source=lib/lead-record.sh
. "$here/lib/lead-record.sh" || { line fail "cannot read $here/lib/lead-record.sh: nothing done"; exit 0; }

[ -e "$OFF" ] && { line warn "watchdog off ($OFF present)"; exit 0; }

LOCK="$STATE/lead.lock"                     # the ONE lock: this script and lead-launch.sh (lib/lead-record.sh names it too)
exec 9>"$LOCK" || { line fail "cannot open the lead lock in $STATE"; exit 0; }
flock -n 9 || { exec 9>&-; line warn "the lead lock is held (a launch of the lead, or another lead-watchdog run): nothing done this tick"; exit 0; }

tm() { tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} "$@"; }   # LEAD_TMUX_SOCKET: a private server (tests)
SHELL_CMD="${LEAD_SHELL_CMD:-}"                                    # what a pane made here runs (default: the user's shell)
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
scope_active() { systemctl --user is-active --quiet "$UNIT.scope" 2>/dev/null; }
# Test seam (a plain path, tests only; unset in production, where it is one failed pattern match): called with
# `gate` before every gate, with `respawn` between the gate and respawn-pane, and with `send` between the LAST
# gate and the keys. It lets a test start a launch at exactly the moments the lock has to cover.
hook() { [[ "${LEAD_WATCHDOG_TEST_HOOK:-}" =~ $LR_PLAIN ]] && "$LEAD_WATCHDOG_TEST_HOOK" "$1" >/dev/null 2>&1; return 0; }
# THE GATE: is a lead alive, anywhere, in any form? Run inside the lock right before every step that creates,
# respawns or types.
alive=""
gate() {
    hook gate
    local p
    if pane_exists && p=$(pane_child) && [ -n "$p" ]; then alive="pane $PANE has a running child (pid $p)"; return 1; fi
    if p=$(lead_id_holders "$SID"); then alive="the lead's id ${SID:0:8} is in the command line of $(echo $p), outside $PANE"; return 1; fi
    if scope_active; then alive="the lead's scope $UNIT.scope is active"; return 1; fi
    return 0
}
stop_alive() { line warn "$alive: nothing made, nothing typed${1:+ ($1)}"; tell "$alive; not relaunching"; exit 0; }

typed=0
act() {
    # 0. THE RECORD FIRST. Not valid → fail, before any pane, session or process is looked at.
    if ! lead_record_read "$STATE/lead.session"; then
        line fail "no valid lead.session ($LR_ERR): the record is the only source of the lead's id, pane and directory, so nothing is looked at, made or typed"
        tell "no valid lead.session ($LR_ERR); relaunch by hand"; exit 0
    fi
    SID=$LR_SID; PANE=$LR_PANE; CWD=$LR_CWD
    SESSION="${PANE%%:*}"; WIN="${PANE#*:}"; WIN="${WIN%%.*}"
    lead_unit "$PANE" || { line fail "the scope unit name is not in a plain form: nothing done"; exit 0; }
    UNIT=$LR_UNIT

    # 1. The recorded pane has a running child: alive. (The process table is the instrument on purpose: "is
    #    anything running in that shell", not "is it healthy".)
    if tm has-session -t "=$SESSION" 2>/dev/null && pane_exists && c=$(pane_child) && [ -n "$c" ]; then
        line ok "pane $PANE has a running child (pid $c)"; exit 0
    fi

    # 2. The lead is not in its pane. What a relaunch needs must all be there BEFORE anything is made: the
    #    launcher, a plain launch-env path, and a scope runner (no runner → no launch, never a lead outside its scope).
    [[ "$LAUNCHER" =~ $LR_PLAIN ]] && [ -f "$LAUNCHER" ] || { line fail "the launcher ($LAUNCHER) is missing or its path is not plain: nothing typed"; tell "lead launcher missing; relaunch by hand"; exit 0; }
    # THE SAME LOCK, NOT BY LUCK (ruling after round 3): the launcher runs in the pane, with the PANE's environment,
    # which need not be this script's. So the state directory this run locked is passed on the typed line, and
    # the launcher refuses when it would derive another one.
    STATE_REAL=$(cd "$STATE" 2>/dev/null && pwd -P) || STATE_REAL=""
    [[ "$STATE_REAL" =~ $LR_PLAIN ]] || { line fail "the state directory ($STATE) is not a plain path: nothing typed"; tell "state dir not plain; relaunch by hand"; exit 0; }
    [[ "$LAUNCH_ENV" =~ $LR_PLAIN ]] || { line fail "the launch-env path is not in a plain form: nothing typed"; tell "launch env path not plain; relaunch by hand"; exit 0; }
    if ! lead_runner; then
        line fail "the lead (${SID:0:8}) is gone from $PANE and $LR_ERR: the lead is only ever started inside its named scope, so nothing is made or typed"
        tell "$LR_ERR; the lead is not relaunched outside its scope; relaunch by hand"; exit 0
    fi

    # 3. Is the lead alive somewhere else? Asked BEFORE anything is made.
    gate || stop_alive

    # Someone typing in the session? (a human may be at the keys)
    now=$(date +%s)
    if tm has-session -t "=$SESSION" 2>/dev/null; then
        act=$(tm display -p -t "=$SESSION:" '#{client_activity}' 2>/dev/null || echo 0)
        if [ "${act:-0}" -gt 0 ] && [ $((now - act)) -lt 60 ]; then
            line warn "the lead (${SID:0:8}) is gone from $PANE but a client typed $((now - act)) s ago: retry next tick"; exit 0
        fi
    fi
    if ! budget_left; then
        line fail "the lead (${SID:0:8}) is gone from $PANE; $MAX_PER_HOUR relaunches already in the last hour: stopping (clear $HIST)"
        tell "lead relaunch loop: $MAX_PER_HOUR in an hour; not relaunching ${SID:0:8}"; exit 0
    fi

    # 4. Restore the place as recorded: the session, the window at its recorded index, the working directory.
    made=""
    if ! tm has-session -t "=$SESSION" 2>/dev/null; then
        gate || stop_alive
        if tm list-sessions >/dev/null 2>&1; then
            tm new-session -d -s "$SESSION" -x 200 -y 50 -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null
        else
            # no server: it is started in a scope of its own, never as a child of this unit
            "${LR_RUN[@]}" --unit="tmux-${UNIT#lead-}-$now" tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} new-session -d -s "$SESSION" -x 200 -y 50 -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} >/dev/null 2>&1
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
        gate || stop_alive "before the respawn"; hook respawn
        tm respawn-pane -k -t "$PANE" -c "$CWD" ${SHELL_CMD:+"$SHELL_CMD"} 2>/dev/null || { line fail "pane $PANE is dead or not at a prompt and could not be respawned"; tell "lead pane $PANE could not be respawned; relaunch by hand"; exit 0; }
        wait_prompt || { line fail "pane $PANE was respawned but shows no shell prompt: nothing typed"; tell "lead pane $PANE respawned, no prompt; relaunch by hand"; exit 0; }
        made="${made:+$made, }pane respawned"
    fi

    # 6. THE LAST GATE, and immediately after it the keys. Not one key reaches the pane before this gate. What is
    #    sent is ONE tmux call: Ctrl-E Ctrl-U (the input line emptied, wherever the cursor was), the launcher's
    #    line, Enter; no wait, no check, no other step between them. The launcher makes the launch-time check.
    rm -f "$STATE/lead-launch.last"
    gate || stop_alive "it started while the pane was being prepared"
    hook send
    tm send-keys -t "$PANE" C-e C-u \; send-keys -t "$PANE" -l "bash $LAUNCHER $STATE_REAL" \; send-keys -t "$PANE" Enter \
        || { line fail "the keys could not be sent to $PANE: nothing typed"; tell "could not type into $PANE; relaunch by hand"; exit 0; }
    echo "$now" >> "$HIST"
    typed=1
}
act 9>&-
[ "$typed" = 1 ] || exit 0
# THE LOCK ENDS HERE, right after the keys: the launcher just typed needs it for its own check-and-exec.
exec 9>&-

await() {
    for i in $(seq 1 "${LEAD_WATCHDOG_WAIT:-20}"); do
        sleep 1
        # started = the pane's child carries the lead's id AND (with real systemd) the named scope is active
        if c=$(pane_child) && [ -n "$c" ] && grep -qaF -e "$SID" "/proc/$c/cmdline" 2>/dev/null && { [ -n "${LEAD_SCOPE_RUN+x}" ] || scope_active; }; then
            line ok "relaunched ${SID:0:8} in $PANE at $(date +%H:%M:%S) from lead.session${made:+, $made} in scope $UNIT.scope (child pid $c)"
            tell "relaunched the lead (${SID:0:8}) in $PANE${made:+ ($made)}"; exit 0
        fi
        [ -s "$STATE/lead-launch.last" ] && break
    done
    why=""; [ -s "$STATE/lead-launch.last" ] && { read -r _ why < "$STATE/lead-launch.last"; why=${why//[^A-Za-z0-9 _.,:()\/-]/_}; }
    if [ -n "$why" ] && ! gate; then
        line warn "$alive: the launcher refused to start a second lead ($why)"; tell "$alive; the launcher refused a second lead"; exit 0
    fi
    line fail "typed the launcher for ${SID:0:8} in $PANE but no lead started in ${LEAD_WATCHDOG_WAIT:-20} s${why:+: the launcher refused: $why}"
    tell "launch of ${SID:0:8} typed but nothing started${why:+ ($why)}; look at $PANE"
    exit 0
}
await
