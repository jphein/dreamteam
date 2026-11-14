#!/usr/bin/env bash
# dreamteam — timer control (issues #12–#15): install/manage the user timers.
#
#   timers-ctl.sh install     # link the 6 units (retiring the 02:11 pilot pair) into the user manager, enable+start the timers
#   timers-ctl.sh uninstall   # disable+stop the timers, unlink the units
#   timers-ctl.sh start|stop  # start/stop all three timers
#   timers-ctl.sh status      # list-timers + per-unit is-active
#   timers-ctl.sh logs [N]    # last N journal lines per service (default 20)
#
# A `systemctl --user` install — no root. The units live in the repo (source of
# truth) and are symlinked into ~/.config/systemd/user; install falls back to a
# copy if linking isn't available. Mirrors dashboard-ctl.sh (issue #11).
# NOTE: luna owns dreamteam-dashboard.service in systemd/ — this touches only the
# dreamteam-{briefing,audit,nightly-guarded} pairs.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# ONE nightly start: the guarded 23:30 pair (JP's 2026-11-14 "go"). The 02:11 PILOT pair
# (dreamteam-nightly.*) is no longer installed; `uninstall` and `install` both retire it if found.
TIMERS="dreamteam-briefing.timer dreamteam-audit.timer dreamteam-nightly-guarded.timer"
SERVICES="dreamteam-briefing.service dreamteam-audit.service dreamteam-nightly-guarded.service"
RETIRED="dreamteam-nightly.timer dreamteam-nightly.service"
UNITS="$TIMERS $SERVICES"

uc() { systemctl --user "$@"; }

case "${1:-}" in
  install)
    mkdir -p "$USER_DIR"
    for u in $RETIRED; do   # the PILOT pair must not stay armed beside the guarded one
      if [ -e "$USER_DIR/$u" ]; then uc disable --now "$u" >/dev/null 2>&1; rm -f "$USER_DIR/$u"; echo "retired $u"; fi
    done
    for u in $UNITS; do
      src="$ROOT/systemd/$u"
      [ -f "$src" ] || { echo "unit not found: $src" >&2; exit 1; }
      if uc link "$src" >/dev/null 2>&1; then echo "linked  $u"
      else cp -f "$src" "$USER_DIR/$u" && echo "copied  $u → $USER_DIR/$u"; fi
    done
    uc daemon-reload
    # Enable+start the TIMERS only (services are oneshot, triggered by their timer).
    for t in $TIMERS; do uc enable --now "$t" >/dev/null 2>&1 && echo "enabled $t"; done
    echo "--- active dreamteam timers ---"
    uc list-timers 'dreamteam-*' --no-pager || true
    ;;
  uninstall)
    for t in $TIMERS; do uc disable --now "$t" >/dev/null 2>&1 && echo "disabled $t"; done
    for u in $UNITS $RETIRED; do uc stop "$u" >/dev/null 2>&1 || true; rm -f "$USER_DIR/$u"; done
    uc daemon-reload
    echo "uninstalled dreamteam timers"
    ;;
  start)   for t in $TIMERS; do uc start "$t" && echo "started $t"; done;;
  stop)    for t in $TIMERS; do uc stop  "$t" && echo "stopped $t"; done;;
  status)
    uc list-timers 'dreamteam-*' --no-pager || true
    echo
    for u in $UNITS; do printf '%-32s %s\n' "$u" "$(uc is-active "$u" 2>/dev/null || echo inactive)"; done
    ;;
  logs)
    for s in $SERVICES; do
      echo "── $s ──"
      journalctl --user -u "$s" -n "${2:-20}" --no-pager 2>/dev/null || echo "  (no journal)"
    done
    ;;
  ""|-h|--help) sed -n '2,17p' "$0";;
  *) echo "usage: timers-ctl.sh {install|uninstall|start|stop|status|logs [N]}" >&2; exit 2;;
esac
