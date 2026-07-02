#!/usr/bin/env bash
# dreamteam — dashboard service control (issue #11).
#
#   dashboard-ctl.sh install    # link the unit into the user manager, enable + start
#   dashboard-ctl.sh start|stop|restart
#   dashboard-ctl.sh status     # systemd status + the live URL
#   dashboard-ctl.sh logs [N]   # last N journal lines (default 50)
#   dashboard-ctl.sh url        # print the dashboard URL
#
# A `systemctl --user` service — no root. The unit lives in the repo (source of
# truth) and is symlinked into ~/.config/systemd/user; `install` falls back to a
# copy if linking isn't available. Port comes from config.json .dashboard.port
# (default 8383), matching dashboard-server.py.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UNIT="dreamteam-dashboard.service"
UNIT_SRC="$ROOT/systemd/$UNIT"
USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

port() {
  local p
  p=$(jq -r '.dashboard.port // 8383' "$ROOT/config.json" 2>/dev/null)
  case "$p" in ''|null) p=8383;; esac
  printf '%s' "$p"
}
url() { printf 'http://127.0.0.1:%s' "$(port)"; }

case "${1:-}" in
  install)
    [ -f "$UNIT_SRC" ] || { echo "unit not found: $UNIT_SRC" >&2; exit 1; }
    mkdir -p "$USER_DIR"
    # Idempotent: clear any prior install (a symlink from an older `link`, or a
    # stale materialized copy) so the token substitution below always wins.
    systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -f "$USER_DIR/$UNIT"
    # The committed unit is a TEMPLATE (portable — no hardcoded home). Materialize
    # it with THIS checkout's plugin root so it runs wherever the repo lives.
    sed "s#__PLUGIN_ROOT__#$ROOT#g" "$UNIT_SRC" > "$USER_DIR/$UNIT"
    echo "installed unit → $USER_DIR/$UNIT (root: $ROOT)"
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT"
    echo "enabled + started → $(url)"
    ;;
  start)   systemctl --user start   "$UNIT" && echo "started → $(url)";;
  stop)    systemctl --user stop    "$UNIT" && echo "stopped";;
  restart) systemctl --user restart "$UNIT" && echo "restarted → $(url)";;
  status)
    systemctl --user --no-pager status "$UNIT" || true
    echo
    echo "URL: $(url)"
    ;;
  logs)    journalctl --user -u "$UNIT" -n "${2:-50}" --no-pager;;
  url)     url; echo;;
  ""|-h|--help)
    sed -n '2,14p' "$0"
    ;;
  *)
    echo "usage: dashboard-ctl.sh {install|start|stop|restart|status|logs [N]|url}" >&2
    exit 2
    ;;
esac
