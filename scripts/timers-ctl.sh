#!/usr/bin/env bash
# dreamteam — timer control (issues #12–#15): install/manage the user timers.
#
#   timers-ctl.sh install     # link the 8 units (retiring the 02:11 pilot pair) into the user manager, enable+start the timers
#   timers-ctl.sh uninstall   # disable+stop the timers, unlink the units
#   timers-ctl.sh retire-pilot [--retired-on YYYY-MM-DD]  # on THIS host: disable --now the 02:11 pilot pair if
#                               # systemd still has it, unlink it; --retired-on records an earlier retirement of an
#                               # absent pilot (a real, non-future date) so its CHECK line says when
#                               # (host-local and idempotent; run it on every host that ever had the pilot)
#   timers-ctl.sh start|stop  # start/stop all four timers
#   timers-ctl.sh status      # list-timers + per-unit is-active
#   timers-ctl.sh logs [N]    # last N journal lines per service (default 20)
#
# A `systemctl --user` install — no root. The units live in the repo (source of
# truth) and are symlinked into ~/.config/systemd/user; install falls back to a
# copy if linking isn't available. Mirrors dashboard-ctl.sh (issue #11).
# NOTE: luna owns dreamteam-dashboard.service in systemd/ — this touches only the
# dreamteam-{briefing,audit,nightly-guarded,nightly-watch} pairs.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# ONE nightly start: the guarded 23:30 pair (JP's 2026-11-14 "go"). The 02:11 PILOT pair
# (dreamteam-nightly.*) is no longer installed; `uninstall` and `install` both retire it if found.
TIMERS="dreamteam-briefing.timer dreamteam-audit.timer dreamteam-nightly-guarded.timer dreamteam-nightly-watch.timer"
SERVICES="dreamteam-briefing.service dreamteam-audit.service dreamteam-nightly-guarded.service dreamteam-nightly-watch.service"
RETIRED="dreamteam-nightly.timer dreamteam-nightly.service"
UNITS="$TIMERS $SERVICES"

uc() { systemctl --user "$@"; }
. "$ROOT/scripts/lib/check-line.sh"

# Retire the PILOT pair on this host. Asks SYSTEMD whether each unit is still enabled (a file test misses a
# dangling link, and a unit loaded from outside the user dir), disables it --now if so, and removes any link or
# copy in the user dir, dangling or not. katana kept the 02:11 timer armed until 2026-11-17 because install ran
# only on familiar and its old test was [ -e ], false for a dangling link.
# pilot_gone <unit>: rc 0 only when systemd ANSWERS that the unit is in no active state per is-active (active,
# activating, reloading, deactivating, refreshing) and not enabled (is-enabled not-found or disabled); rc 1 when it
# is; rc 3 when systemd cannot answer (empty stdout). A start job queued behind an inactive unit is not inspected.
pilot_gone() {
  local act en
  act=$(uc is-active "$1" 2>/dev/null | head -n 1); en=$(uc is-enabled "$1" 2>/dev/null | head -n 1)
  { [ -n "$act" ] && [ -n "$en" ]; } || return 3
  case "$act" in active|activating|reloading|deactivating|refreshing) return 1 ;; esac
  case "$en" in not-found|disabled) return 0 ;; *) return 1 ;; esac
}

retire_pilot() {   # retire_pilot [--retired-on YYYY-MM-DD]
  local u st rc any=0 on=""
  # exactly no arguments, or exactly `--retired-on DATE`; anything else is refused BEFORE systemd is asked anything
  if [ "$#" -ne 0 ] && { [ "$#" -ne 2 ] || [ "$1" != "--retired-on" ]; }; then
    echo "retire-pilot: usage: retire-pilot [--retired-on YYYY-MM-DD]" >&2; return 22
  fi
  if [ "$#" -eq 2 ]; then
    on="$2"
    # an operator's record of a retirement already done: a real date, not in the future
    if ! [[ "$on" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [ "$(date -d "$on" +%F 2>/dev/null)" != "$on" ] || [ "$on" \> "$(date +%F)" ]; then
      echo "retire-pilot: --retired-on needs a real past date YYYY-MM-DD (got '${on//[^0-9-]/}')" >&2; return 22
    fi
  fi
  for u in $RETIRED; do
    st=$(uc is-enabled "$u" 2>/dev/null); rc=$?
    st=$(printf '%s' "$st" | head -n 1)
    # systemd answers a state word on stdout (exit 4 + "not-found" for an absent unit). Empty stdout means it could
    # not answer (no user bus, a manager error): that is NOT absence, so stop rather than report "pilot absent".
    if [ -z "$st" ]; then echo "retire-pilot: cannot ask systemd about $u (rc=$rc); nothing changed" >&2; return 3; fi
    case "$st" in
      not-found) ;;
      *) # disable's exit code decides NOTHING: on katana (2026-11-17) disabling a LINKED unit removed its link and
         # still exited 1, and a "successful" disable can leave a unit running. The final gate below decides.
         uc disable --now "$u" >/dev/null 2>&1; echo "disable --now $u attempted (was $st)"; any=1 ;;
    esac
    if [ -e "$USER_DIR/$u" ] || [ -L "$USER_DIR/$u" ]; then
      if rm -f -- "$USER_DIR/$u" 2>/dev/null && [ ! -e "$USER_DIR/$u" ] && [ ! -L "$USER_DIR/$u" ]; then echo "unlinked $u"; any=1
      else echo "retire-pilot: could not remove $USER_DIR/$u" >&2; return 3; fi
    fi
  done
  # ONE final verification of BOTH units gates every outcome (retired, reported, absent): a unit can be not-found
  # as a file yet still running; a leftover link is removed above, and retirement is claimed only after this gate.
  for u in $RETIRED; do
    pilot_gone "$u"; rc=$?
    case "$rc" in
      0) ;;
      3) echo "retire-pilot: cannot ask systemd whether $u is gone; nothing claimed" >&2; return 3 ;;
      *) echo "retire-pilot: $u is still running or enabled; nothing claimed" >&2; return 3 ;;
    esac
  done
  if [ "$any" -eq 1 ]; then
    # docs/CHECKS.md row dreamteam-nightly-pilot: the retired pilot says so instead of staying "none" (cadence
    # "retired", so the Watch never calls it stale). Written only when this run retired something (today's date), or
    # when an operator REPORTS an earlier retirement (--retired-on) of a pilot this run verified absent: that date is
    # the operator's word, and the line says so ("reported as"); only the absence is verified.
    check_line "$(check_name dreamteam-nightly-pilot)" ok \
      "retired $(date +%F): dreamteam-nightly.timer and .service disabled and unlinked on $(hostname 2>/dev/null)" \
      "no further runs (the guarded 23:30 sweep on familiar replaced it), owner Sen" >/dev/null || true
  elif [ -n "$on" ]; then
    check_line "$(check_name dreamteam-nightly-pilot)" ok \
      "retirement reported as $on (recorded $(date +%F), date given by the operator): dreamteam-nightly.timer and .service verified absent on $(hostname 2>/dev/null)" \
      "no further runs (the guarded 23:30 sweep on familiar replaced it), owner Sen" >/dev/null || true
    echo "pilot absent: retirement recorded as reported, $on"
  else
    echo "pilot absent: nothing to retire"
  fi
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
  retire-pilot) shift; retire_pilot "$@"; exit $?;;
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
