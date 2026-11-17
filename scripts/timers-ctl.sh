#!/usr/bin/env bash
# dreamteam — timer control (issues #12–#15): install/manage the user timers.
#
#   timers-ctl.sh install     # link the 6 units (retiring the 02:11 pilot pair) into the user manager, enable+start the timers
#   timers-ctl.sh uninstall   # disable+stop the timers, unlink the units
#   timers-ctl.sh retire-pilot  # on THIS host: disable --now the 02:11 pilot pair if systemd still has it, unlink it
#                               # (host-local and idempotent; run it on every host that ever had the pilot)
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

# Retire the PILOT pair on this host. Asks SYSTEMD whether each unit is still enabled (a file test misses a
# dangling link, and a unit loaded from outside the user dir), disables it --now if so, and removes any link or
# copy in the user dir, dangling or not. katana kept the 02:11 timer armed until 2026-11-17 because install ran
# only on familiar and its old test was [ -e ], false for a dangling link.
retire_pilot() {
  local u st rc any=0
  for u in $RETIRED; do
    st=$(uc is-enabled "$u" 2>/dev/null); rc=$?
    st=$(printf '%s' "$st" | head -n 1)
    # systemd answers a state word on stdout (exit 4 + "not-found" for an absent unit). Empty stdout means it could
    # not answer (no user bus, a manager error): that is NOT absence, so stop rather than report "pilot absent".
    if [ -z "$st" ]; then echo "retire-pilot: cannot ask systemd about $u (rc=$rc); nothing changed" >&2; return 3; fi
    case "$st" in
      not-found) ;;
      *) if uc disable --now "$u" >/dev/null 2>&1; then echo "retired $u (was $st)"; any=1
         else echo "retire-pilot: disable --now $u failed" >&2; return 3; fi ;;
    esac
    if [ -e "$USER_DIR/$u" ] || [ -L "$USER_DIR/$u" ]; then
      if rm -f -- "$USER_DIR/$u" 2>/dev/null && [ ! -e "$USER_DIR/$u" ] && [ ! -L "$USER_DIR/$u" ]; then echo "unlinked $u"; any=1
      else echo "retire-pilot: could not remove $USER_DIR/$u" >&2; return 3; fi
    fi
  done
  [ "$any" -eq 1 ] || echo "pilot absent: nothing to retire"
}

case "${1:-}" in
  install)
    mkdir -p "$USER_DIR"
    retire_pilot || { echo "install stopped: the 02:11 pilot could not be confirmed retired" >&2; exit 3; }   # one nightly start
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
  retire-pilot) retire_pilot; exit $?;;
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
  ""|-h|--help) sed -n '2,19p' "$0";;
  *) echo "usage: timers-ctl.sh {install|uninstall|retire-pilot|start|stop|status|logs [N]}" >&2; exit 2;;
esac
