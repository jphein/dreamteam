#!/usr/bin/env bash
# dreamteam — quota-resume-ctl: put the quota-resume timer on a lane host, as the user whose lanes it must see,
# ON THE SOCKET those lanes are on, and prove from inside the user manager that it reaches them.
#
#   quota-resume-ctl.sh install     find the lanes' tmux socket, PROVE the user manager reaches that server, write
#                                   the socket drop-in when it is not the default, link both units, enable the timer
#   quota-resume-ctl.sh status      timer state, the socket in force, the same proof, the last line
#   quota-resume-ctl.sh uninstall   disable and stop the timer, unlink the units, remove our drop-in
#
# WHY a user unit (Flow row 55bd0a23): scripts/quota_resume.py reads and types into tmux panes, and a tmux server
# belongs to one user. A system unit, another user, or root finds "no server running" and reports 0 panes: the
# silent miss of 2026-11-21 (familiar's lanes resumed, serialhub's sat 3.5 h because no timer ran there at all).
#
# WHY THE SOCKET IS NAMED (xreview #283 r2): the same user is NOT the same server. A lane started with `tmux -L`,
# `tmux -S` or under a TMUX_TMPDIR lives on another socket, and a user service does not have the login shell's
# environment. So nothing is left to discovery at run time:
#   • quota_resume.py always calls `tmux -S <socket>`: $QUOTA_RESUME_TMUX_SOCKET, else /tmp/tmux-<uid>/default;
#   • install takes the socket from $QUOTA_RESUME_TMUX_SOCKET, else from $TMUX (run it inside a lane's tmux), else
#     from the server `tmux` reaches in this shell, else the default path;
#   • when that is not the default path it is written to
#         ~/.config/systemd/user/quota-resume.service.d/10-tmux-socket.conf   (Environment=QUOTA_RESUME_TMUX_SOCKET=…)
#   • ONE SOCKET, PROVED AND ENABLED (ruling after round 3). After the units are linked and the manager reloaded,
#     install asks the manager which socket the SERVICE will really use (`systemctl --user show
#     quota-resume.service -p Environment`: its QUOTA_RESUME_TMUX_SOCKET, else the default path). That value must
#     be the socket install chose; a drop-in that is not ours and names another socket makes them differ → exit 3,
#     nothing enabled. The proof below then runs on that one value, $SOCK, and only then is the timer enabled.
#   • THE PROOF: `systemd-run --user --wait --pipe` starts a probe AS A CHILD OF THE USER MANAGER (its environment,
#     not this shell's). The probe lists the panes on the socket and then prints a last line `probe-ran rc=<tmux's
#     exit status>`. That line is the evidence that the probe RAN: without it (the manager unreachable,
#     systemd-run failing, no shell) the proof FAILS, whatever else is or is not printed; so does a tmux that
#     could not be executed there (rc 126/127). An empty answer is never a pass by itself.
#     The panes listed there must be the panes this shell lists on the same socket. Different → exit 3, the timer
#     NOT enabled. "No server on that socket" is accepted only when BOTH probes ran and both say so (a host whose
#     lanes are not up yet; the script's own line warns when claude processes run and no server is found).
# A refused install (exit 3) leaves the units linked and the timer NOT enabled: nothing runs; `uninstall` removes the links.
# One timer watches one socket. Lanes on a second server need a second instance with its own socket.
#
# Exit: 0 done · 1 a systemctl step failed · 2 refused (root, a unit file missing, a socket path that is not
# plain) · 3 the user manager does not reach the lanes' server · 22 bad argument.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UNITS=("$ROOT/systemd/quota-resume.service" "$ROOT/systemd/quota-resume.timer")
ME="${QUOTA_RESUME_CTL_UID:-$(id -u)}"
DEFAULT_SOCK="/tmp/tmux-$(id -u)/default"
DROPDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/quota-resume.service.d"
DROP="$DROPDIR/10-tmux-socket.conf"
MARK="# written by dreamteam scripts/quota-resume-ctl.sh"
uc() { systemctl --user "$@"; }
[ "$#" -eq 1 ] || { echo "usage: quota-resume-ctl.sh install|status|uninstall" >&2; exit 22; }
case "$1" in install|status|uninstall) ;; *) echo "usage: quota-resume-ctl.sh install|status|uninstall" >&2; exit 22 ;; esac
if [ "$1" != status ] && [ "$ME" -eq 0 ]; then
  echo "quota-resume-ctl: refused as root: the timer must run as the user whose tmux server holds the lanes" >&2; exit 2
fi

# the lanes' socket, by the order in the header; SOCK_FROM says where it came from
find_socket() {
  local s
  if [ -n "${QUOTA_RESUME_TMUX_SOCKET:-}" ]; then SOCK=$QUOTA_RESUME_TMUX_SOCKET; SOCK_FROM="QUOTA_RESUME_TMUX_SOCKET"
  elif [ -n "${TMUX:-}" ]; then SOCK=${TMUX%%,*}; SOCK_FROM="this shell's TMUX"
  elif s=$(tmux display-message -p '#{socket_path}' 2>/dev/null) && [ -n "$s" ]; then SOCK=$s; SOCK_FROM="the server tmux reaches from this shell"
  else SOCK=$DEFAULT_SOCK; SOCK_FROM="the default (no server found from this shell)"; fi
  [[ "$SOCK" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "quota-resume-ctl: the tmux socket path is not a plain absolute path: refused" >&2; exit 2; }
}
# the socket the installed service will use: our drop-in's, else the default
socket_in_force() {
  local s=""
  [ -f "$DROP" ] && s=$(sed -n 's/^Environment=QUOTA_RESUME_TMUX_SOCKET=//p' "$DROP" | head -1)
  SOCK=${s:-$DEFAULT_SOCK}; SOCK_FROM=$([ -n "$s" ] && echo "the drop-in $DROP" || echo "the default")
}
count() { awk 'NF {n++} END {print n + 0}'; }
# the socket the SERVICE will use, as the user manager reports it after a reload: sets EFFECTIVE
effective_socket() {
  local env v
  env=$(uc show quota-resume.service -p Environment --value 2>/dev/null) || return 1
  v=$(printf '%s\n' "$env" | tr ' ' '\n' | sed -n 's/^QUOTA_RESUME_TMUX_SOCKET=//p' | tail -1)
  EFFECTIVE=${v:-$DEFAULT_SOCK}
}
# The probe, the same text for both views: the pane ids, then one last line saying it ran and how tmux exited.
PROBE='tmux -S "$1" list-panes -a -F "#{pane_id}" 2>/dev/null; echo "probe-ran rc=$?"'
# prove: on $SOCK, this shell's view and the user manager's. 0 the same panes · 3 the manager's probe did not run,
# could not run tmux, or lists other panes · 4 both probes ran and neither finds a server
prove() {
  local here mgr hrc mrc
  here=$(sh -c "$PROBE" _ "$SOCK" 2>/dev/null)
  mgr=$(systemd-run --user --wait --pipe --quiet --collect sh -c "$PROBE" _ "$SOCK" 2>/dev/null)
  hrc=$(printf '%s\n' "$here" | sed -n 's/^probe-ran rc=//p' | tail -1); mrc=$(printf '%s\n' "$mgr" | sed -n 's/^probe-ran rc=//p' | tail -1)
  here=$(printf '%s\n' "$here" | grep -v '^probe-ran rc=' | sort); mgr=$(printf '%s\n' "$mgr" | grep -v '^probe-ran rc=' | sort)
  PANES_HERE=$(printf '%s\n' "$here" | count); PANES_MGR=$(printf '%s\n' "$mgr" | count)
  if [ -z "$mrc" ]; then
    echo "proof FAILED: the probe did not run in the user manager (no 'probe-ran' line came back from systemd-run --user): nothing is known about $SOCK there" >&2; return 3
  fi
  if [ "$mrc" = 126 ] || [ "$mrc" = 127 ] || [ "$hrc" = 126 ] || [ "$hrc" = 127 ] || [ -z "$hrc" ]; then
    echo "proof FAILED: tmux could not be run (this shell: rc ${hrc:-none}; the user manager: rc $mrc)" >&2; return 3
  fi
  if [ "$PANES_HERE" -eq 0 ] && [ "$PANES_MGR" -eq 0 ]; then
    echo "proof: both probes ran and neither finds a tmux server on $SOCK (no lanes up?)"; return 4
  fi
  if [ "$here" != "$mgr" ]; then
    echo "proof FAILED: on $SOCK this shell lists $PANES_HERE pane(s); a process started by the user manager lists $PANES_MGR, not the same ones" >&2; return 3
  fi
  echo "proof: a process started by the user manager lists the same $PANES_MGR pane(s) on $SOCK as this shell"; return 0
}

case "$1" in
  install)
    for u in "${UNITS[@]}"; do [ -f "$u" ] || { echo "quota-resume-ctl: $u is missing" >&2; exit 2; }; done
    find_socket
    echo "tmux socket: $SOCK (from $SOCK_FROM)"
    if [ "$SOCK" != "$DEFAULT_SOCK" ]; then
      mkdir -p "$DROPDIR" && printf '%s\n[Service]\nEnvironment=QUOTA_RESUME_TMUX_SOCKET=%s\n' "$MARK" "$SOCK" > "$DROP.tmp" && mv -f "$DROP.tmp" "$DROP" \
        || { echo "quota-resume-ctl: cannot write $DROP" >&2; exit 1; }
      echo "socket drop-in written: $DROP"
    elif [ -f "$DROP" ] && grep -qxF "$MARK" "$DROP"; then
      rm -f "$DROP"; echo "socket drop-in removed (the lanes are on the default socket)"
    fi
    uc link "${UNITS[@]}" || { echo "quota-resume-ctl: link failed" >&2; exit 1; }
    uc daemon-reload || exit 1
    # ONE socket: what the service will use must be what was chosen, and THAT is what gets proved
    effective_socket || { echo "quota-resume-ctl: the user manager does not say which socket the service will use: timer NOT enabled" >&2; exit 3; }
    if [ "$EFFECTIVE" != "$SOCK" ]; then
      echo "quota-resume-ctl: the service would use $EFFECTIVE, not $SOCK (a drop-in or setting that is not ours names it): timer NOT enabled. Remove it, or install with QUOTA_RESUME_TMUX_SOCKET=$EFFECTIVE" >&2; exit 3
    fi
    prove; p=$?
    [ "$p" -eq 3 ] && { echo "quota-resume-ctl: the user manager does not reach the lanes' tmux server: timer NOT enabled" >&2; exit 3; }
    uc enable --now quota-resume.timer || { echo "quota-resume-ctl: enable failed" >&2; exit 1; }
    echo "quota-resume.timer enabled for $(id -un); first run within 2 minutes" ;;
  uninstall)
    rc=0
    uc disable --now quota-resume.timer || rc=1
    uc disable quota-resume.service > /dev/null 2>&1 || true
    if [ -f "$DROP" ] && grep -qxF "$MARK" "$DROP"; then rm -f "$DROP" && rmdir "$DROPDIR" 2>/dev/null; echo "socket drop-in removed"; fi
    uc daemon-reload || rc=1
    exit "$rc" ;;
  status)
    echo "timer: enabled=$(uc is-enabled quota-resume.timer 2>/dev/null || true) active=$(uc is-active quota-resume.timer 2>/dev/null || true) as $(id -un)"
    if effective_socket; then SOCK=$EFFECTIVE; SOCK_FROM="what the user manager says the service uses; the default when it is not installed"; else socket_in_force; fi
    [[ "$SOCK" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo "quota-resume-ctl: the socket in force is not a plain path" >&2; exit 2; }
    echo "tmux socket in force: $SOCK (from $SOCK_FROM)"
    prove; p=$?
    . "$ROOT/scripts/lib/check-line.sh"
    f="${DREAMTEAM_CHECKS_DIR:-$HOME/.local/state/checks}/$(check_name quota-resume).line"
    if [ -f "$f" ]; then echo "line ($(date -r "$f" '+%a %H:%M')): $(cat "$f")"; else echo "line: none yet at $f"; fi
    [ "$p" -eq 3 ] && exit 3
    exit 0 ;;
esac
