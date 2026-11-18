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
  disable)    [ -e "$TMP/disable.broken" ] && exit 1; echo disabled > "$TMP/enabled"; echo inactive > "$TMP/active" ;;
  stop)       [ -e "$TMP/stop.broken" ] && exit 1 ;;
  daemon-reload) [ -e "$TMP/reload.broken" ] && exit 1 ;;
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
grep -qx "Options=rw,soft,timeo=50,retrans=3,noatime,nosuid,nodev,noexec,_netdev" "$U/srv-fleet.mount" && ok "mount unit: soft with a bounded timeout; nosuid, nodev, noexec" || bad "mount options: $(grep Options "$U/srv-fleet.mount")"
grep -qx "TimeoutIdleSec=600" "$U/srv-fleet.automount" && grep -qx "WantedBy=multi-user.target" "$U/srv-fleet.automount" && ok "automount unit: idle release, wanted at boot" || bad "automount unit"
! grep -q "WantedBy" "$U/srv-fleet.mount" && ok "the mount unit itself is NOT wanted at boot (automount only)" || bad "mount unit is wanted at boot"
[ "$(stat -c %a "$U/srv-fleet.mount")" = 644 ] && [ -d "$R/srv/fleet" ] && ok "units are 0644; the mount point exists" || bad "modes or mount point"
grep -qx "daemon-reload" "$TMP/sc.log" && grep -qx "enable --now srv-fleet.automount" "$TMP/sc.log" && ok "daemon-reload, then enable --now the AUTOMOUNT" || bad "systemctl calls: $(tr '\n' '|' < "$TMP/sc.log")"
! grep -q "srv-fleet.mount" "$TMP/sc.log" && ok "install never starts the mount itself" || bad "install touched the mount unit"
run check >/dev/null; [ $? = 0 ] && ok "check after install: rc 0" || bad "check after install"

# --- idempotent -------------------------------------------------------------------------------------------------
: > "$TMP/sc.log"; i1=$(stat -c %i "$U/srv-fleet.mount")
out=$(run install)
[ "$(stat -c %i "$U/srv-fleet.mount")" = "$i1" ] && grep -q "^ok " <<< "$out" && ok "a second install rewrites nothing" || bad "second install rewrote a unit"
[ "$(tr '\n' '|' < "$TMP/sc.log")" = "daemon-reload|enable --now srv-fleet.automount|" ] && ok "every install reloads BEFORE it enables" || bad "second install calls: $(tr '\n' '|' < "$TMP/sc.log")"
touch "$TMP/reload.broken"; : > "$TMP/sc.log"
run install >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ! grep -q "^enable" "$TMP/sc.log" && ok "a reload that does not work is exit 3 and nothing is enabled" || bad "broken reload: rc=$rc $(tr '\n' '|' < "$TMP/sc.log")"
rm -f "$TMP/reload.broken"; : > "$TMP/sc.log"; run install >/dev/null
grep -qx "daemon-reload" "$TMP/sc.log" && ok "the next install reloads again (no stale definitions enabled)" || bad "no reload after a broken one"

# --- drift is seen and repaired --------------------------------------------------------------------------------
sed -i 's/soft,/hard,/' "$U/srv-fleet.mount"
run check >/dev/null; [ $? = 1 ] && ok "check sees an edited unit (hard for soft)" || bad "check missed an edited unit"
run install >/dev/null; grep -q "soft," "$U/srv-fleet.mount" && ok "install repairs it" || bad "install did not repair"
echo disabled > "$TMP/enabled"; run check >/dev/null; [ $? = 1 ] && ok "check sees a disabled automount" || bad "check missed a disabled automount"
run install >/dev/null
touch "$TMP/enable.broken"; echo disabled > "$TMP/enabled"
run install >/dev/null 2>&1; [ $? = 3 ] && ok "an enable that does not work is exit 3, not a quiet success" || bad "broken enable rc"
rm -f "$TMP/enable.broken"; run install >/dev/null

# --- install never writes over a unit it did not write (preflight on BOTH paths, before any change) -----------
for victim in srv-fleet.mount srv-fleet.automount; do
  run uninstall >/dev/null 2>&1; rm -f "$U/srv-fleet.mount" "$U/srv-fleet.automount"
  printf '[Unit]\nDescription=someone else\n' > "$U/$victim"; : > "$TMP/sc.log"
  run install >/dev/null 2>&1; rc=$?
  other=$([ "$victim" = srv-fleet.mount ] && echo srv-fleet.automount || echo srv-fleet.mount)
  [ "$rc" = 3 ] && grep -qx "Description=someone else" "$U/$victim" && [ ! -e "$U/$other" ] && [ ! -s "$TMP/sc.log" ] \
    && ok "a foreign $victim: install refuses, writes neither unit, calls no systemctl" || bad "foreign $victim: rc=$rc log=$(tr '\n' '|' < "$TMP/sc.log")"
  : > "$TMP/sc.log"; run uninstall >/dev/null 2>&1; rc=$?
  [ "$rc" = 3 ] && grep -qx "Description=someone else" "$U/$victim" && [ ! -s "$TMP/sc.log" ] \
    && ok "a foreign $victim: uninstall refuses and stops or disables nothing" || bad "uninstall over a foreign $victim: rc=$rc log=$(tr '\n' '|' < "$TMP/sc.log")"
  rm -f "$U/$victim"
done
echo sentinel > "$TMP/sentinel"; ln -s "$TMP/sentinel" "$U/srv-fleet.mount"; : > "$TMP/sc.log"
run install >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$TMP/sentinel")" = sentinel ] && [ ! -s "$TMP/sc.log" ] && ok "a symlink at the unit path is refused; its target is untouched" || bad "symlink unit: rc=$rc"
run uninstall >/dev/null 2>&1; [ $? = 3 ] && [ -L "$U/srv-fleet.mount" ] && [ ! -s "$TMP/sc.log" ] && ok "uninstall also refuses a symlinked unit path" || bad "uninstall over a symlink"
rm -f "$U/srv-fleet.mount"; run install >/dev/null

# --- uninstall: its own files only, both units disabled, and no success after a step that did not work ----------
echo "[Unit]" > "$U/other.mount"
for broken in stop disable; do
  touch "$TMP/$broken.broken"; out=$(run uninstall 2>&1); rc=$?; rm -f "$TMP/$broken.broken"
  [ "$rc" = 3 ] && [ -f "$U/srv-fleet.mount" ] && [ -f "$U/srv-fleet.automount" ] && ! grep -q "^uninstalled" <<< "$out" \
    && ok "uninstall with a $broken that does not work: exit 3, both definitions kept" || bad "uninstall, broken $broken: rc=$rc '$out'"
done
touch "$TMP/reload.broken"; run uninstall >/dev/null 2>&1; rc=$?; rm -f "$TMP/reload.broken"
[ "$rc" = 3 ] && ok "uninstall with a reload that does not work: exit 3" || bad "uninstall, broken reload: rc=$rc"
run install >/dev/null; : > "$TMP/sc.log"
out=$(run uninstall); rc=$?
[ "$rc" = 0 ] && [ ! -e "$U/srv-fleet.mount" ] && [ ! -e "$U/srv-fleet.automount" ] && [ -f "$U/other.mount" ] && [ -d "$R/srv/fleet" ] \
  && ok "uninstall: both units gone, other units and the mount point stay" || bad "uninstall: rc=$rc '$out'"
[ "$(tr '\n' '|' < "$TMP/sc.log")" = "disable --now srv-fleet.automount|stop srv-fleet.mount|disable srv-fleet.mount|daemon-reload|" ] \
  && ok "uninstall: disable the automount, stop and disable the mount, reload (in that order)" || bad "uninstall calls: $(tr '\n' '|' < "$TMP/sc.log")"
: > "$TMP/sc.log"; out=$(run uninstall); rc=$?
[ "$rc" = 0 ] && [ "$(tr '\n' '|' < "$TMP/sc.log")" = "daemon-reload|" ] && grep -q "nothing installed" <<< "$out" && ok "uninstall with nothing installed: says so, only reloads" || bad "empty uninstall: rc=$rc $(tr '\n' '|' < "$TMP/sc.log")"
# a reload that did not work at the END of an uninstall is retried by the next uninstall, not reported as done
run install >/dev/null; touch "$TMP/reload.broken"; run uninstall >/dev/null 2>&1; rc1=$?
[ "$rc1" = 3 ] && [ ! -e "$U/srv-fleet.mount" ] && ok "uninstall whose final reload does not work: exit 3 (files already gone)" || bad "uninstall, final reload: rc=$rc1"
run uninstall >/dev/null 2>&1; [ $? = 3 ] && ok "retrying while the reload still does not work: still exit 3" || bad "retry reported success with a broken reload"
rm -f "$TMP/reload.broken"; : > "$TMP/sc.log"; run uninstall >/dev/null; rc=$?
[ "$rc" = 0 ] && grep -qx "daemon-reload" "$TMP/sc.log" && ok "once the reload works, the retry reloads and succeeds" || bad "retry after the reload works: rc=$rc"
# one run at a time
run install >/dev/null
( exec 8>> "$U/.fleet-mount.lock"; flock -n 8 || exit 9; : > "$TMP/sc.log"; PATH="$BASE_PATH" bash "$S" uninstall 8>&- >/dev/null 2>&1; echo $? > "$TMP/locked.rc" )
[ "$(cat "$TMP/locked.rc")" = 3 ] && [ -f "$U/srv-fleet.mount" ] && [ ! -s "$TMP/sc.log" ] && ok "a second run while one holds the lock: exit 3, nothing changed" || bad "lock: rc=$(cat "$TMP/locked.rc")"

# --- xreview r3: the ownership line is matched whole; the lock is never opened through a symlink -----------------
run uninstall >/dev/null 2>&1; rm -f "$U/srv-fleet.mount" "$U/srv-fleet.automount"
head -1 "$TMP/unit.sample" > /dev/null 2>&1 || true
for victim in srv-fleet.mount srv-fleet.automount; do
  printf '%s\n[Unit]\nDescription=other tool\n' '# written by dreamteam scripts/fleet-mount.sh (sync replacement, phase 1); remove with: fleet-mount.sh uninstall-other-tool' > "$U/$victim"
  : > "$TMP/sc.log"; run install >/dev/null 2>&1; r1=$?; run uninstall >/dev/null 2>&1; r2=$?
  [ "$r1" = 3 ] && [ "$r2" = 3 ] && grep -qx "Description=other tool" "$U/$victim" && [ ! -s "$TMP/sc.log" ] \
    && ok "a first line that only STARTS like ours ($victim) is foreign: install and uninstall refuse" || bad "prefix collision $victim: $r1 $r2"
  rm -f "$U/$victim"
done
rm -f "$U/.fleet-mount.lock"; ln -s "$TMP/lock-target" "$U/.fleet-mount.lock"
: > "$TMP/sc.log"; run install >/dev/null 2>&1; r1=$?; run uninstall >/dev/null 2>&1; r2=$?
[ "$r1" = 3 ] && [ "$r2" = 3 ] && [ ! -e "$TMP/lock-target" ] && [ ! -s "$TMP/sc.log" ] && [ ! -e "$U/srv-fleet.mount" ] \
  && ok "a dangling symlink at the lock path: both modes refuse and its target is never created" || bad "lock symlink: $r1 $r2 target=$([ -e "$TMP/lock-target" ] && echo created)"
rm -f "$U/.fleet-mount.lock"; run install >/dev/null
[ "$(head -1 "$U/srv-fleet.mount")" = "$(head -1 "$U/srv-fleet.automount")" ] && run check >/dev/null && ok "both units carry the one ownership line and check is clean" || bad "ownership line"

# --- a file that APPEARS at an absent unit path after the preflight is not replaced (xreview r2) -----------------
run uninstall >/dev/null 2>&1; rm -f "$U/srv-fleet.mount" "$U/srv-fleet.automount"
mkdir -p "$TMP/racebin"; REALCHMOD="$(command -v chmod)"
cat > "$TMP/racebin/chmod" <<EOF
#!/bin/sh
# stands in for "another administrator": creates the mount unit between the preflight and the publication
[ -e "$U/srv-fleet.mount" ] || printf '[Unit]\nDescription=appeared mid-run\n' > "$U/srv-fleet.mount"
exec "$REALCHMOD" "\$@"
EOF
chmod +x "$TMP/racebin/chmod"; : > "$TMP/sc.log"
PATH="$TMP/racebin:$BASE_PATH" bash "$S" install >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && grep -qx "Description=appeared mid-run" "$U/srv-fleet.mount" && [ ! -s "$TMP/sc.log" ] \
  && ok "a unit that appears mid-install survives; exit 3; nothing reloaded or enabled" || bad "mid-install file: rc=$rc $(head -2 "$U/srv-fleet.mount" | tr '\n' '|')"
[ -z "$(ls -A "$U" | grep '^\.fleet-mount\.[A-Za-z0-9]\{6\}$')" ] && ok "no temp file is left behind" || bad "temp file left: $(ls -A "$U")"
rm -f "$U/srv-fleet.mount" "$U/srv-fleet.automount"; run install >/dev/null

# --- arguments and values --------------------------------------------------------------------------------------
run >/dev/null 2>&1; [ $? = 2 ] && ok "no argument: exit 2" || bad "no argument rc"
run install extra >/dev/null 2>&1; [ $? = 2 ] && ok "extra argument: exit 2" || bad "extra argument rc"
FLEET_SHARE_SOURCE=$'10.0.6.11:/srv/fleet\nExecStart=/bin/true' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a source with a newline is refused (no injected directive)" || bad "newline source"
FLEET_SHARE_SOURCE='host:/a b' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a source with a space is refused" || bad "space source"
FLEET_SHARE_MOUNTPOINT='srv/fleet' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a relative mount point is refused" || bad "relative mount point"
FLEET_SHARE_MOUNTPOINT='/srv/../etc' run install >/dev/null 2>&1; [ $? = 2 ] && ok "a mount point with .. is refused" || bad "dotdot mount point"
FLEET_SHARE_MOUNTPOINT='/' run install >/dev/null 2>&1; [ $? = 2 ] && ok "the mount point / is refused" || bad "root mount point"
for mp in /. /./ /srv/ /srv/./fleet; do
  : > "$TMP/sc.log"; FLEET_SHARE_MOUNTPOINT="$mp" run install >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && [ ! -e "$U/-.mount" ] && [ ! -s "$TMP/sc.log" ] && ok "mount point '$mp' is refused: no unit written, no systemctl call" || bad "mount point '$mp': rc=$rc"
done
printf '#!/bin/sh\necho -\n' > "$TMP/bin/rootescape"; chmod +x "$TMP/bin/rootescape"
FLEET_MOUNT_ESCAPE="$TMP/bin/rootescape" run install >/dev/null 2>&1; [ $? = 2 ] && [ ! -e "$U/-.mount" ] && ok "an escaped name of '-' (the root unit) is refused whatever the path" || bad "root unit name"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/noescape"; chmod +x "$TMP/bin/noescape"
FLEET_MOUNT_ESCAPE="$TMP/bin/noescape" run install >/dev/null 2>&1; [ $? = 2 ] && ok "no working systemd-escape: exit 2, no guessed unit name" || bad "escape fallback"
if command -v systemd-escape >/dev/null 2>&1; then
  FLEET_SHARE_MOUNTPOINT='/srv/fleet-cache' run install >/dev/null; n='srv-fleet\x2dcache'
  [ -f "$U/$n.mount" ] && grep -qx "Where=/srv/fleet-cache" "$U/$n.mount" && ok "a hyphen in the mount point is escaped in the unit name (systemd's own rule)" || bad "hyphenated mount point: $(ls "$U")"
  FLEET_SHARE_MOUNTPOINT='/srv/fleet-cache' run uninstall >/dev/null
fi
( unset FLEET_MOUNT_SKIP_ROOT; [ "$(id -u)" = 0 ] && exit 0; PATH="$BASE_PATH" bash "$S" install >/dev/null 2>&1; [ $? = 2 ] ) && ok "install without root: exit 2" || bad "non-root install rc"
if command -v systemd-analyze >/dev/null 2>&1; then
  run install >/dev/null
  # Verify against OUR unit dir plus the distribution's units only: the machine's own /etc units are not loaded, so
  # the verifier's exit status is about these two files and is asserted as it is.
  v=$(SYSTEMD_UNIT_PATH="$U:/usr/lib/systemd/system:/lib/systemd/system" systemd-analyze verify "$U/srv-fleet.automount" "$U/srv-fleet.mount" 2>&1); vrc=$?
  [ "$vrc" = 0 ] && ! grep -q "srv-fleet" <<< "$v" && ok "systemd-analyze verify: exit 0 and no complaint about the two units" || bad "systemd-analyze verify rc=$vrc: $(head -3 <<< "$v")"
  sed -i 's/^Type=nfs4$/Typo=nfs4/' "$U/srv-fleet.mount"
  v=$(SYSTEMD_UNIT_PATH="$U:/usr/lib/systemd/system:/lib/systemd/system" systemd-analyze verify "$U/srv-fleet.mount" 2>&1); vrc=$?
  { [ "$vrc" != 0 ] || grep -q "srv-fleet" <<< "$v"; } && ok "positive control: the same verify call objects to a broken unit" || bad "verify did not object to a broken unit"
  run install >/dev/null
fi

echo "----"; echo "fleet-mount: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
