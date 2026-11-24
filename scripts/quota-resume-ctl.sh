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
#   • THE PROOF: `systemd-run --user --wait --pipe` starts `tmux -S <socket> list-panes -a` AS A CHILD OF THE USER
#     MANAGER (its environment, not this shell's) and its pane count must equal what this shell sees on that
#     socket. Not equal, or the manager cannot run it → exit 3 and the timer is NOT enabled. No server on the
#     socket in either view → said, and enabled (a host whose lanes are not up yet; the script's own line warns
#     when claude processes run and no server is found).
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
# prove: PANES_HERE (this shell) and PANES_MGR (a child of the user manager) on $SOCK; 0 reach · 3 they differ or
# the manager cannot run it · 4 no server in either view
prove() {
  local here mgr rc
  here=$(tmux -S "$SOCK" list-panes -a -F '#{pane_id}' 2>/dev/null); PANES_HERE=$(printf '%s\n' "$here" | count)
  mgr=$(systemd-run --user --wait --pipe --quiet --collect tmux -S "$SOCK" list-panes -a -F '#{pane_id}' 2>/dev/null); rc=$?
  PANES_MGR=$(printf '%s\n' "$mgr" | count)
  if [ "$PANES_HERE" -eq 0 ] && [ "$PANES_MGR" -eq 0 ]; then
    echo "proof: no tmux server on $SOCK, from this shell and from the user manager alike (no lanes up?)"; return 4
  fi
  if [ "$rc" -ne 0 ] || [ "$(printf '%s\n' "$here" | sort)" != "$(printf '%s\n' "$mgr" | sort)" ]; then
    echo "proof FAILED: on $SOCK this shell lists $PANES_HERE pane(s); a process started by the user manager lists $PANES_MGR (systemd-run exit $rc)" >&2; return 3
  fi
  echo "proof: a process started by the user manager lists the same $PANES_MGR pane(s) on $SOCK as this shell"; return 0
}

case "$1" in
  install)
    for u in "${UNITS[@]}"; do [ -f "$u" ] || { echo "quota-resume-ctl: $u is missing" >&2; exit 2; }; done
    find_socket
    echo "tmux socket: $SOCK (from $SOCK_FROM)"
    prove; p=$?
    [ "$p" -eq 3 ] && { echo "quota-resume-ctl: the user manager does not reach the lanes' tmux server: timer NOT enabled" >&2; exit 3; }
    if [ "$SOCK" != "$DEFAULT_SOCK" ]; then
      mkdir -p "$DROPDIR" && printf '%s\n[Service]\nEnvironment=QUOTA_RESUME_TMUX_SOCKET=%s\n' "$MARK" "$SOCK" > "$DROP.tmp" && mv -f "$DROP.tmp" "$DROP" \
        || { echo "quota-resume-ctl: cannot write $DROP" >&2; exit 1; }
      echo "socket drop-in written: $DROP"
    elif [ -f "$DROP" ] && grep -qxF "$MARK" "$DROP"; then
      rm -f "$DROP"; echo "socket drop-in removed (the lanes are on the default socket)"
    fi
    uc link "${UNITS[@]}" || { echo "quota-resume-ctl: link failed" >&2; exit 1; }
    uc daemon-reload || exit 1
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
    socket_in_force
    echo "tmux socket in force: $SOCK (from $SOCK_FROM)"
    prove; p=$?
    . "$ROOT/scripts/lib/check-line.sh"
    f="${DREAMTEAM_CHECKS_DIR:-$HOME/.local/state/checks}/$(check_name quota-resume).line"
    if [ -f "$f" ]; then echo "line ($(date -r "$f" '+%a %H:%M')): $(cat "$f")"; else echo "line: none yet at $f"; fi
    [ "$p" -eq 3 ] && exit 3
    exit 0 ;;
esac
