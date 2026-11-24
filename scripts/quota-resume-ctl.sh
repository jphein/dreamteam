#!/usr/bin/env bash
# dreamteam — quota-resume-ctl: put the quota-resume timer on a lane host, as the user whose lanes it must see.
#
#   quota-resume-ctl.sh install     link both units into the USER manager, enable and start the timer
#   quota-resume-ctl.sh status      is the timer enabled and active, does this user have a tmux server, the last line
#   quota-resume-ctl.sh uninstall   disable and stop the timer, unlink the units
#
# WHY this is a user unit and nothing else (Flow row 55bd0a23): scripts/quota_resume.py reads and types into tmux
# panes. A tmux server belongs to one user and one socket (/tmp/tmux-<uid>/default), so the timer must run as the
# lanes' own user, in that user's manager: then it sees exactly the lanes' server, with no socket to configure.
# A system unit, another user, or root would find "no server running" and report 0 panes: the silent miss of
# 2026-11-21 (familiar's lanes resumed, serialhub's sat 3.5 h because no timer ran there at all).
# So: refused as root; the units carry no User=, no socket setting; and quota_resume.py itself warns when it finds
# no tmux server while claude processes of the user run on the host.
#
# Exit: 0 done · 1 a systemctl step failed · 2 refused (root, or a unit file is missing) · 22 bad argument.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UNITS=("$ROOT/systemd/quota-resume.service" "$ROOT/systemd/quota-resume.timer")
uc() { systemctl --user "$@"; }
[ "$#" -eq 1 ] || { echo "usage: quota-resume-ctl.sh install|status|uninstall" >&2; exit 22; }
case "$1" in install|status|uninstall) ;; *) echo "usage: quota-resume-ctl.sh install|status|uninstall" >&2; exit 22 ;; esac
if [ "$1" != status ] && [ "${QUOTA_RESUME_CTL_UID:-$(id -u)}" -eq 0 ]; then
  echo "quota-resume-ctl: refused as root: the timer must run as the user whose tmux server holds the lanes" >&2; exit 2
fi
case "$1" in
  install)
    for u in "${UNITS[@]}"; do [ -f "$u" ] || { echo "quota-resume-ctl: $u is missing" >&2; exit 2; }; done
    uc link "${UNITS[@]}" || { echo "quota-resume-ctl: link failed" >&2; exit 1; }
    uc daemon-reload || exit 1
    uc enable --now quota-resume.timer || { echo "quota-resume-ctl: enable failed" >&2; exit 1; }
    echo "quota-resume.timer enabled for $(id -un); first run within 2 minutes" ;;
  uninstall)
    rc=0
    uc disable --now quota-resume.timer || rc=1
    uc disable quota-resume.service > /dev/null 2>&1 || true
    uc daemon-reload || rc=1
    exit "$rc" ;;
  status)
    echo "timer: enabled=$(uc is-enabled quota-resume.timer 2>/dev/null || true) active=$(uc is-active quota-resume.timer 2>/dev/null || true) as $(id -un)"
    if tmux list-sessions > /dev/null 2>&1; then echo "tmux: this user has a server with $(tmux list-panes -a 2>/dev/null | wc -l) pane(s)"; else echo "tmux: NO server for this user (the timer would read 0 panes)"; fi
    . "$ROOT/scripts/lib/check-line.sh"
    f="${DREAMTEAM_CHECKS_DIR:-$HOME/.local/state/checks}/$(check_name quota-resume).line"
    if [ -f "$f" ]; then echo "line ($(date -r "$f" '+%a %H:%M')): $(cat "$f")"; else echo "line: none yet at $f"; fi ;;
esac
