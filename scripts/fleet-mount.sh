#!/usr/bin/env bash
# dreamteam — the CLIENT side of the fleet share (sync replacement, phase 1; server = ubox0-kit fleet-share).
#
#   sudo scripts/fleet-mount.sh install     write the two systemd units, enable the automount (idempotent)
#   scripts/fleet-mount.sh check            read only: units as shipped? automount active? rc 1 on drift
#   sudo scripts/fleet-mount.sh uninstall   stop and disable both units, remove exactly the files written here;
#                                           the mount point directory and the package stay
#
# What it installs: /etc/systemd/system/srv-fleet.mount and srv-fleet.automount for
#   10.0.6.11:/srv/fleet  on  /srv/fleet   (nfs4; override with FLEET_SHARE_SOURCE / FLEET_SHARE_MOUNTPOINT)
# - AUTOMOUNT, not a boot-time mount: a host that boots while the server is away boots normally, and the share is
#   mounted at first use and released after 10 idle minutes.
# - `soft,timeo=50,retrans=3`: when the server is away a read or write gets an ERROR after about 15 s; with a hard
#   mount every lane touching its scratch would hang until the server returned. The price: a write in flight during an
#   outage can be lost and the writer is told so. That is the right trade for scratch and reports, and the reason
#   nothing that must not lose a write (databases, git dirs) belongs on the share.
# - It never installs a package: without mount.nfs4 it stops and names the apt line (apt is a visible, separate step).
# Seams for the tests: FLEET_MOUNT_ROOT (a fake /), FLEET_MOUNT_SYSTEMCTL (a stub), FLEET_MOUNT_SKIP_ROOT=1.
# Exit: 0 ok · 1 drift (check) · 2 precondition (not root, no nfs client, bad argument) · 3 a step did not work.
set -uo pipefail
MODE="${1:-}"
case "$MODE" in install|check|uninstall) ;; *) echo "usage: fleet-mount.sh install|check|uninstall" >&2; exit 2 ;; esac
[ "$#" -eq 1 ] || { echo "usage: fleet-mount.sh install|check|uninstall" >&2; exit 2; }

ROOT="${FLEET_MOUNT_ROOT:-}"
SRC="${FLEET_SHARE_SOURCE:-10.0.6.11:/srv/fleet}"
MP="${FLEET_SHARE_MOUNTPOINT:-/srv/fleet}"
SC="${FLEET_MOUNT_SYSTEMCTL:-systemctl}"
# the values go into unit files: one plain token each, nothing a unit parser could read as a second directive
case "$SRC" in *[!A-Za-z0-9._:/-]*|"") echo "fleet-mount: source has characters outside [A-Za-z0-9._:/-]" >&2; exit 2 ;; esac
case "$MP" in /*) ;; *) echo "fleet-mount: the mount point must be absolute" >&2; exit 2 ;; esac
case "$MP" in *[!A-Za-z0-9._/-]*|*/../*|*/..|*//*) echo "fleet-mount: mount point has characters outside [A-Za-z0-9._/-]" >&2; exit 2 ;; esac
unit="$(systemd-escape --path "$MP" 2>/dev/null)" || unit=""
[ -n "$unit" ] || { u="${MP#/}"; u="${u%/}"; unit="${u//\//-}"; }   # same answer for plain paths such as /srv/fleet
UDIR="$ROOT/etc/systemd/system"
MOUNT_U="$UDIR/$unit.mount"; AUTO_U="$UDIR/$unit.automount"

mount_text() {
  cat <<EOF
# written by dreamteam scripts/fleet-mount.sh (sync replacement, phase 1); remove with: fleet-mount.sh uninstall
[Unit]
Description=Fleet share (shared scratch and state for lane hosts) from $SRC
After=network-online.target
Wants=network-online.target

[Mount]
What=$SRC
Where=$MP
Type=nfs4
Options=rw,soft,timeo=50,retrans=3,noatime,_netdev
TimeoutSec=30
EOF
}
auto_text() {
  cat <<EOF
# written by dreamteam scripts/fleet-mount.sh (sync replacement, phase 1); remove with: fleet-mount.sh uninstall
[Unit]
Description=Automount the fleet share at $MP on first use

[Automount]
Where=$MP
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
}
same() { [ -f "$2" ] && [ ! -L "$2" ] && [ "$(printf '%s\n' "$1")" = "$(cat -- "$2")" ]; }   # same <text> <file>
need_root() {
  [ "${FLEET_MOUNT_SKIP_ROOT:-0}" = 1 ] || [ "$(id -u)" = 0 ] || { echo "fleet-mount: $MODE needs root (sudo)" >&2; exit 2; }
}

case "$MODE" in
  check)
    drift=0
    same "$(mount_text)" "$MOUNT_U" && echo "ok    $MOUNT_U" || { echo "DRIFT $MOUNT_U (absent or not as shipped)"; drift=1; }
    same "$(auto_text)" "$AUTO_U" && echo "ok    $AUTO_U" || { echo "DRIFT $AUTO_U (absent or not as shipped)"; drift=1; }
    en=$("$SC" is-enabled "$unit.automount" 2>/dev/null); ac=$("$SC" is-active "$unit.automount" 2>/dev/null)
    [ "$en" = enabled ] && [ "$ac" = active ] && echo "ok    $unit.automount enabled and active" \
      || { echo "DRIFT $unit.automount is ${en:-unknown} / ${ac:-unknown}"; drift=1; }
    exit "$drift"
    ;;
  install)
    need_root
    command -v mount.nfs4 >/dev/null 2>&1 || [ -x "$ROOT/sbin/mount.nfs4" ] || [ -x "$ROOT/usr/sbin/mount.nfs4" ] \
      || { echo "fleet-mount: no NFS client on this host; first: sudo apt-get install -y nfs-common" >&2; exit 2; }
    mkdir -p "$UDIR" "$ROOT$MP" || exit 3
    changed=0
    for pair in "mount:$MOUNT_U" "auto:$AUTO_U"; do
      kind="${pair%%:*}"; dst="${pair#*:}"
      text="$([ "$kind" = mount ] && mount_text || auto_text)"
      if same "$text" "$dst"; then echo "ok    $dst"; continue; fi
      [ ! -L "$dst" ] || { echo "fleet-mount: $dst is a symlink; refusing to write through it" >&2; exit 3; }
      tmp="$(mktemp "$UDIR/.fleet-mount.XXXXXX")" && printf '%s\n' "$text" > "$tmp" && chmod 644 "$tmp" && mv -T -f -- "$tmp" "$dst" \
        || { rm -f -- "${tmp:-}"; echo "fleet-mount: could not write $dst" >&2; exit 3; }
      echo "wrote $dst"; changed=1
    done
    [ "$changed" = 0 ] || "$SC" daemon-reload || exit 3
    "$SC" enable --now "$unit.automount" >/dev/null 2>&1 || { echo "fleet-mount: could not enable $unit.automount" >&2; exit 3; }
    echo "enabled $unit.automount (the share mounts at first use of $MP)"
    ;;
  uninstall)
    need_root
    "$SC" disable --now "$unit.automount" >/dev/null 2>&1 || true
    "$SC" stop "$unit.mount" >/dev/null 2>&1 || true
    for f in "$AUTO_U" "$MOUNT_U"; do
      if [ -f "$f" ] && [ ! -L "$f" ] && grep -q '^# written by dreamteam scripts/fleet-mount.sh' "$f"; then rm -f -- "$f" && echo "removed $f"
      elif [ -e "$f" ] || [ -L "$f" ]; then echo "left $f (not written by this script)"; fi
    done
    "$SC" daemon-reload || exit 3
    echo "uninstalled; $MP and the nfs client package are left in place"
    ;;
esac
