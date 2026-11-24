#!/bin/bash
# lead-launch.sh — the ONE way the fleet lead's Claude Code is started again: by the watchdog (which types exactly
# `bash <this file>` into the lead's pane and nothing else) or by a person (lead.session's launch= line names it).
#
#   bash scripts/lead-launch.sh          (no arguments: who the lead is comes from lead.session, read here)
#
# Why a launcher (xreview #281 round 2): a watchdog that checks "is a lead alive" and then types a command can
# always lose to a lead that starts in between; no number of repeated checks makes that atomic. So the last check
# is made HERE, at launch time, under a lock every launch takes:
#   1. lead.session must be a complete, unambiguous record (lib/lead-record.sh), else refuse;
#   2. take THE lead lock, <state>/lead.lock: the same lock scripts/lead-watchdog.sh holds for its whole
#      check-and-act section. While the watchdog is between a gate and its act, this launcher WAITS (up to
#      $LEAD_LAUNCH_LOCK_WAIT seconds, default 30) and starts nothing; two launches run one after the other;
#   3. no process on the host may carry the lead's session id in its command line, and the lead's named scope must
#      not be active, else refuse: a lead is already there;
#   4. there must be a scope runner (systemd-run), the recorded directory must be entered, the launch-env file must
#      be readable, else refuse. Every step is chained: a failed step starts nothing;
#   4b. whatever was typed at this terminal while the launcher waited or checked is DISCARDED (the watchdog may have
#      typed its own launch line into this very pane): the lead never receives keys that were meant for a shell;
#   5. exec  systemd-run --user --scope --unit=lead-<session> -p ManagedOOMPreference=avoid  claude --resume <id> …
#      The exec keeps the pid: from that instant this process's own command line carries the id, so every later
#      launch (and the watchdog) sees it; if the scope cannot be created, systemd-run exits and no claude ran; a
#      second scope of the same name cannot be created while the first lives. The lead never runs outside its scope.
# The lock's descriptor is closed for everything this script starts (the body runs as `launch 8>&-`), so the lock
# ends at the exec and nothing else ever holds it.
#
# A refusal prints one line on stderr and writes it to lead-launch.last (for the watchdog's line). Exit: 3 no
# valid record · 4 a lead is already there · 5 no scope runner · 6 the directory or the env file · 75 another
# launch holds the lock · 126 the exec did not happen.
# THE CONTRACT: the lead is started ONLY through this launcher, by the watchdog and by people alike. A bare
# `claude --resume <id>` takes no lock, so nothing here can make it atomic with anyone's check; the host-wide
# search sees it once it runs, and that is all.
set -u
shopt -s execfail                       # a failed exec comes back here and is refused, by name
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
# shellcheck source=lib/lead-record.sh
. "$here/lib/lead-record.sh" || exit 2
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
ENVF="${LEAD_LAUNCH_ENV:-$HOME/.config/claude-code/env.sh}"
refuse() {  # <exit code> <reason>
    echo "lead-launch: refused: $2" >&2
    printf '%s %s\n' "$(date +%s)" "$2" > "$STATE/lead-launch.last" 2>/dev/null
    exit "$1"
}
[ -d "$STATE" ] || { echo "lead-launch: refused: no state directory $STATE" >&2; exit 3; }
lead_record_read "$STATE/lead.session" || refuse 3 "no valid lead.session: $LR_ERR"
lead_unit "$LR_PANE" || refuse 3 "the scope unit name is not in a plain form"
[[ "$ENVF" =~ $LR_PLAIN ]] || refuse 6 "the launch-env path is not in a plain form"
LOCKWAIT="${LEAD_LAUNCH_LOCK_WAIT:-30}"; [[ "$LOCKWAIT" =~ ^[0-9]{1,3}$ ]] || LOCKWAIT=30
exec 8>"$STATE/lead.lock" || refuse 75 "cannot open the lead lock"
flock -w "$LOCKWAIT" 8 || { exec 8>&-; refuse 75 "the lead lock is still held after $LOCKWAIT s (the watchdog or another launch)"; }      # closed first: no child of the refusal holds it

launch() {
    local holders
    # tests only (a plain path): runs after the lock is taken, before the look
    [[ "${LEAD_LAUNCH_TEST_HOOK:-}" =~ $LR_PLAIN ]] && "$LEAD_LAUNCH_TEST_HOOK" >/dev/null 2>&1
    if holders=$(lead_id_holders "$LR_SID"); then
        refuse 4 "a lead is already there: the session id is in the command line of $(echo $holders)"
    fi
    if [ -z "${LEAD_SCOPE_RUN+x}" ] && systemctl --user is-active --quiet "$LR_UNIT.scope" 2>/dev/null; then
        refuse 4 "a lead is already there: its scope $LR_UNIT.scope is active"
    fi
    lead_runner || refuse 5 "$LR_ERR: the lead is never started outside its named scope"
    cd "$LR_CWD" || refuse 6 "cannot enter the recorded directory"
    [ -f "$ENVF" ] && [ -r "$ENVF" ] || refuse 6 "the launch-env file is not readable"
    set +u
    # shellcheck disable=SC1090
    . "$ENVF"                   # its last command's status is not a verdict; a missing file was refused above
    set -u
    rm -f "$STATE/lead-launch.last"
    # 4b. discard what was typed at this terminal meanwhile: the kernel's input queue (tcflush), then any whole
    #     line already handed to this shell's reader. The lead must not receive a line that was meant for a shell.
    if [ -t 0 ]; then
        python3 -I -c 'import termios; termios.tcflush(0, termios.TCIFLUSH)' 2>/dev/null || true
        while IFS= read -r -s -t 0.05 _typed; do :; done
    fi
    exec "${LR_RUN[@]}" --unit="$LR_UNIT" -p ManagedOOMPreference=avoid claude --resume "$LR_SID" --permission-mode bypassPermissions
    refuse 126 "the scope runner could not be started"
}
launch 8>&-
