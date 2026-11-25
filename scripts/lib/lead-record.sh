#!/bin/bash
# lib/lead-record.sh — the ONE reader of lead.session and the ONE "is the lead alive on this host" search, shared
# by scripts/lead-watchdog.sh and scripts/lead-launch.sh so the two can never disagree (xreview #281 round 2).
# Sourced; defines functions only.
#
# lead.session is DATA: read line by line, never sourced, every value checked against a strict shape. The record is
# valid only when it is COMPLETE and UNAMBIGUOUS: exactly one session=, one pane=, one cwd= (at most one launch=,
# which is for a person and is never used), no other line, a plain file of ours that nobody else can write, and a
# working directory that exists. Anything else is "no valid record": the callers fail closed, they never fall back
# to a default pane or to the home directory.
LR_UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
LR_PLAIN='^/[A-Za-z0-9_./-]+$'

# lead_record_read <file> → 0 and LR_SID LR_PANE LR_CWD set; else 1 and LR_ERR says why (a fixed phrase, no data)
lead_record_read() {
    local f=$1 l v ns=0 np=0 nc=0 nl=0 mode
    LR_SID=""; LR_PANE=""; LR_CWD=""; LR_ERR=""
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then LR_ERR="there is no lead.session"; return 1; fi
    if [ -L "$f" ] || [ ! -f "$f" ]; then LR_ERR="lead.session is not a plain file"; return 1; fi
    [ -O "$f" ] || { LR_ERR="lead.session is not owned by this user"; return 1; }
    mode=$(stat -c %a "$f" 2>/dev/null) || { LR_ERR="lead.session cannot be read"; return 1; }
    case "$mode" in *[2367][0-7]|*[2367]) LR_ERR="lead.session can be written by others (mode $mode)"; return 1 ;; esac
    [ -r "$f" ] || { LR_ERR="lead.session cannot be read"; return 1; }
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in
            session=*) ns=$((ns + 1)); v=${l#session=}
                       [[ "$v" =~ ^$LR_UUID$ ]] || { LR_ERR="its session= line is not a session id"; return 1; }; LR_SID=$v ;;
            pane=*)    np=$((np + 1)); v=${l#pane=}
                       [[ "$v" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] || { LR_ERR="its pane= line is not session:window.pane"; return 1; }; LR_PANE=$v ;;
            cwd=*)     nc=$((nc + 1)); v=${l#cwd=}
                       [[ "$v" =~ $LR_PLAIN ]] || { LR_ERR="its cwd= line is not a plain absolute path"; return 1; }; LR_CWD=$v ;;
            launch=*)  nl=$((nl + 1)) ;;
            *)         LR_ERR="it has a line that is none of session, pane, cwd, launch"; return 1 ;;
        esac
    done < "$f"
    if [ "$ns" != 1 ] || [ "$np" != 1 ] || [ "$nc" != 1 ] || [ "$nl" -gt 1 ]; then
        LR_ERR="session, pane and cwd must each be there exactly once (session $ns, pane $np, cwd $nc, launch $nl)"; return 1
    fi
    [ -d "$LR_CWD" ] || { LR_ERR="its working directory does not exist"; return 1; }
    return 0
}

# lead_unit <pane> → the lead's scope unit name (without .scope); $LEAD_SCOPE_UNIT replaces it. 1 when not plain.
lead_unit() {
    local s=${1%%:*}
    LR_UNIT="${LEAD_SCOPE_UNIT:-lead-${s//[^A-Za-z0-9_-]/_}}"
    [[ "$LR_UNIT" =~ ^[A-Za-z0-9_-]{1,80}$ ]]
}

# lead_runner → 0 and the array LR_RUN = how a command is put in a named scope; 1 and LR_ERR when there is no way.
# THE LEAD IS NEVER STARTED OUTSIDE A SCOPE: no runner means no launch. $LEAD_SCOPE_RUN (tests) replaces the
# runner with a plain path; set and empty it stands for "this host has no systemd-run".
lead_runner() {
    LR_RUN=(); LR_ERR=""
    if [ -n "${LEAD_SCOPE_RUN+x}" ]; then
        [ -n "$LEAD_SCOPE_RUN" ] || { LR_ERR="no systemd-run here"; return 1; }
        [[ "$LEAD_SCOPE_RUN" =~ $LR_PLAIN ]] && [ -x "$LEAD_SCOPE_RUN" ] || { LR_ERR="the scope runner is not a plain path to a program"; return 1; }
        LR_RUN=("$LEAD_SCOPE_RUN"); return 0
    fi
    command -v systemd-run >/dev/null 2>&1 || { LR_ERR="no systemd-run here"; return 1; }
    LR_RUN=(systemd-run --user --scope --quiet --collect)
}

# lead_id_holders <session id> → one "pid(name)" per process ON THE HOST whose command line contains the id:
# any program name, any owner, any argument form (`--resume ID`, `--resume=ID`, a wrapper, an interpreter).
# Only this process and its own descendants are left out (a subshell of a caller carries the caller's command
# line). Returns 0 when there is at least one. The id is fixed-shape hex and dashes, so a fixed-string search is exact.
lead_id_holders() {
    local sid=$1 f p q st n found=1 name
    [[ "$sid" =~ ^$LR_UUID$ ]] || return 1
    while IFS= read -r f; do
        p=${f#/proc/}; p=${p%/cmdline}; q=$p; n=0
        while [ "$q" != "$$" ] && [ "$q" -gt 1 ] 2>/dev/null && [ "$n" -lt 16 ]; do
            st=""; { read -r st < "/proc/$q/stat"; } 2>/dev/null || break
            st=${st##*) }; set -- $st; q=${2:-1}; n=$((n + 1))
        done
        [ "$q" = "$$" ] && continue
        [ -d "/proc/$p" ] || continue                     # it ended while we looked
        name=""; { read -r name < "/proc/$p/comm"; } 2>/dev/null
        printf '%s(%s)\n' "$p" "${name//[^A-Za-z0-9_.-]/_}"; found=0
    done < <(grep -laF -e "$sid" /proc/[0-9]*/cmdline 2>/dev/null)
    return "$found"
}
