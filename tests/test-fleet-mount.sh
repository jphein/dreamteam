#!/usr/bin/env bash
# dreamteam tests — scripts/fleet-mount.sh (the client side of the fleet share) against a FAKE root and a stub
# systemctl. Nothing under the real /etc is read or written; no mount is attempted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/fleet-mount.sh"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
R="$TMP/root"; mkdir -p "$R/usr/sbin" "$TMP/bin"
cat > "$TMP/bin/sc" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/sc.log"
case "\$1" in
  is-enabled) cat "$TMP/enabled" 2>/dev/null || echo disabled ;;
  is-active)  cat "$TMP/active" 2>/dev/null || echo inactive ;;
  enable)     [ -e "$TMP/enable.broken" ] && exit 1; echo enabled > "$TMP/enabled"; echo active > "$TMP/active" ;;
  disable)    echo disabled > "$TMP/enabled"; echo inactive > "$TMP/active" ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/sc"
export FLEET_MOUNT_ROOT="$R" FLEET_MOUNT_SYSTEMCTL="$TMP/bin/sc" FLEET_MOUNT_SKIP_ROOT=1
# no nfs client anywhere this test can see: an empty PATH dir plus the basics
BASE_PATH="$TMP/bin:/usr/bin:/bin"
run() { PATH="$BASE_PATH" bash "$S" "$@"; }
U="$R/etc/systemd/system"

# --- no NFS client: install stops before writing anything ------------------------------------------------------
if PATH="$BASE_PATH" command -v mount.nfs4 >/dev/null 2>&1; then
  ok "no-client case skipped: this machine has mount.nfs4 in /usr/bin or /bin"
else
  out=$(run install 2>&1); rc=$?
  [ "$rc" = 2 ] && grep -q "apt-get install -y nfs-common" <<< "$out" && [ ! -e "$U/srv-fleet.mount" ] \
    && ok "no NFS client: exit 2, names the apt line, writes nothing" || bad "no client: rc=$rc '$out'"
fi
printf '#!/bin/sh\nexit 0\n' > "$R/usr/sbin/mount.nfs4"; chmod +x "$R/usr/sbin/mount.nfs4"

# --- check before install: drift ------------------------------------------------------------------------------
run check >/dev/null; [ $? = 1 ] && ok "check before install: rc 1" || bad "check before install"

# --- install ---------------------------------------------------------------------------------------------------
out=$(run install); rc=$?
[ "$rc" = 0 ] && [ -f "$U/srv-fleet.mount" ] && [ -f "$U/srv-fleet.automount" ] && ok "install writes both units" || bad "install: rc=$rc '$out'"
grep -qx "What=10.0.6.11:/srv/fleet" "$U/srv-fleet.mount" && grep -qx "Where=/srv/fleet" "$U/srv-fleet.mount" && grep -qx "Type=nfs4" "$U/srv-fleet.mount" \
  && ok "mount unit: source, mount point, type" || bad "mount unit content"
grep -qx "Options=rw,soft,timeo=50,retrans=3,noatime,_netdev" "$U/srv-fleet.mount" && ok "mount unit: soft with a bounded timeout (an error, not a hang)" || bad "mount options: $(grep Options "$U/srv-fleet.mount")"
grep -qx "TimeoutIdleSec=600" "$U/srv-fleet.automount" && grep -qx "WantedBy=multi-user.target" "$U/srv-fleet.automount" && ok "automount unit: idle release, wanted at boot" || bad "automount unit"
! grep -q "WantedBy" "$U/srv-fleet.mount" && ok "the mount unit itself is NOT wanted at boot (automount only)" || bad "mount unit is wanted at boot"
[ "$(stat -c %a "$U/srv-fleet.mount")" = 644 ] && [ -d "$R/srv/fleet" ] && ok "units are 0644; the mount point exists" || bad "modes or mount point"
grep -qx "daemon-reload" "$TMP/sc.log" && grep -qx "enable --now srv-fleet.automount" "$TMP/sc.log" && ok "daemon-reload, then enable --now the AUTOMOUNT" || bad "systemctl calls: $(tr '\n' '|' < "$TMP/sc.log")"
! grep -q "srv-fleet.mount" "$TMP/sc.log" && ok "install never starts the mount itself" || bad "install touched the mount unit"
run check >/dev/null; [ $? = 0 ] && ok "check after install: rc 0" || bad "check after install"

# --- idempotent -------------------------------------------------------------------------------------------------
: > "$TMP/sc.log"; i1=$(stat -c %i "$U/srv-fleet.mount")
out=$(run install)
[ "$(stat -c %i "$U/srv-fleet.mount")" = "$i1" ] && ! grep -qx "daemon-reload" "$TMP/sc.log" && grep -q "^ok " <<< "$out" && ok "a second install rewrites nothing and does not reload" || bad "second install: $(tr '\n' '|' < "$TMP/sc.log")"

# --- drift is seen and repaired --------------------------------------------------------------------------------
sed -i 's/soft,/hard,/' "$U/srv-fleet.mount"
run check >/dev/null; [ $? = 1 ] && ok "check sees an edited unit (hard for soft)" || bad "check missed an edited unit"
run install >/dev/null; grep -q "soft," "$U/srv-fleet.mount" && ok "install repairs it" || bad "install did not repair"
echo disabled > "$TMP/enabled"; run check >/dev/null; [ $? = 1 ] && ok "check sees a disabled automount" || bad "check missed a disabled automount"
run install >/dev/null
touch "$TMP/enable.broken"; echo disabled > "$TMP/enabled"
run install >/dev/null 2>&1; [ $? = 3 ] && ok "an enable that does not work is exit 3, not a quiet success" || bad "broken enable rc"
rm -f "$TMP/enable.broken"; run install >/dev/null

# --- refuses to write through a symlink ------------------------------------------------------------------------
echo sentinel > "$TMP/sentinel"; rm -f "$U/srv-fleet.mount"; ln -s "$TMP/sentinel" "$U/srv-fleet.mount"
run install >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$TMP/sentinel")" = sentinel ] && ok "a symlink at the unit path is refused; its target is untouched" || bad "symlink unit: rc=$rc"
rm -f "$U/srv-fleet.mount"; run install >/dev/null

# --- uninstall removes only its own files ----------------------------------------------------------------------
echo "[Unit]" > "$U/other.mount"; : > "$TMP/sc.log"
out=$(run uninstall); rc=$?
[ "$rc" = 0 ] && [ ! -e "$U/srv-fleet.mount" ] && [ ! -e "$U/srv-fleet.automount" ] && [ -f "$U/other.mount" ] && [ -d "$R/srv/fleet" ] \
  && ok "uninstall: both units gone, other units and the mount point stay" || bad "uninstall: rc=$rc '$out'"
grep -qx "disable --now srv-fleet.automount" "$TMP/sc.log" && grep -qx "stop srv-fleet.mount" "$TMP/sc.log" && grep -qx "daemon-reload" "$TMP/sc.log" && ok "uninstall: disable the automount, stop the mount, reload" || bad "uninstall calls"
echo "# someone else's unit" > "$U/srv-fleet.mount"
out=$(run uninstall)
[ -f "$U/srv-fleet.mount" ] && grep -q "left .*srv-fleet.mount" <<< "$out" && ok "uninstall leaves a unit it did not write" || bad "uninstall removed a foreign unit"
rm -f "$U/srv-fleet.mount"

# --- arguments and values --------------------------------------------------------------------------------------
run >/dev/null 2>&1; [ $? = 2 ] && ok "no argument: exit 2" || bad "no argument rc"
run install extra >/dev/null 2>&1; [ $? = 2 ] && ok "extra argument: exit 2" || bad "extra argument rc"
FLEET_SHARE_SOURCE=$'10.0.6.11:/srv/fleet\nExecStart=/bin/true' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a source with a newline is refused (no injected directive)" || bad "newline source"
FLEET_SHARE_SOURCE='host:/a b' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a source with a space is refused" || bad "space source"
FLEET_SHARE_MOUNTPOINT='srv/fleet' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a relative mount point is refused" || bad "relative mount point"
FLEET_SHARE_MOUNTPOINT='/srv/../etc' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a mount point with .. is refused" || bad "dotdot mount point"
( unset FLEET_MOUNT_SKIP_ROOT; [ "$(id -u)" = 0 ] && exit 0; PATH="$BASE_PATH" bash "$S" install >/dev/null 2>&1; [ $? = 2 ] ) && ok "install without root: exit 2" || bad "non-root install rc"
if command -v systemd-analyze >/dev/null 2>&1; then
  run install >/dev/null
  # only complaints about OUR units count: verify also reports every other unit on the machine it loads
  v=$(systemd-analyze verify "$U/srv-fleet.automount" "$U/srv-fleet.mount" 2>&1 | grep "srv-fleet\." | grep -v "mount.nfs4" || true)
  [ -z "$v" ] && ok "systemd-analyze verify has no complaint about the two units" || bad "systemd-analyze verify: $(head -3 <<< "$v")"
fi

echo "----"; echo "fleet-mount: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
