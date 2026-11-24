#!/usr/bin/env bash
# dreamteam — tests for the lane I/O work (Flow row 7e039111):
#   • scripts/host/io-shield      io.cost latency targets per device + IOWeight on named units and containers
#   • scripts/lane-slice.sh       lanes.slice from config, and moving lane sessions' processes into it
#   • scripts/host-io-check.sh    CHECK <host>-io: a victim probe beside the pressure number
#   • the unit files and the user@ drop-in
#
# Hermetic: io.cost.qos, /sys/block, /proc and the cgroup tree are fixture dirs through the scripts' seams;
# systemctl, systemd-run, busctl, docker, tmux and ps are PATH stubs that LOG what they were asked to do, so
# the tests assert what the tools DID. Nothing here touches a real unit, cgroup or session. The one real thing
# is the probe: it reads and writes a 1 MiB file in the test's temp dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SH="$ROOT/scripts/host/io-shield"; LS="$ROOT/scripts/lane-slice.sh"; HC="$ROOT/scripts/host-io-check.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
ok() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
B="$T/bin"; LOG="$T/calls.log"; mkdir -p "$B" "$T/sys/nvme0n1" "$T/sys/sda"; : > "$LOG"
echo "259:0" > "$T/sys/nvme0n1/dev"; echo "8:0" > "$T/sys/sda/dev"
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
ID=7d65ba827db467c06a6c9432b76d9bef1b9aa4255035aee5a0e7d593d1d399a4
stub docker 'echo "docker $*" >> "'"$LOG"'"; [ "$1" = inspect ] && [ "${4:-}" = mempalace-db ] && { echo '"$ID"'; exit 0; }; exit 1'
stub systemctl 'echo "systemctl $*" >> "'"$LOG"'"
case "$*" in
  *"show nosuch.service -p LoadState"*) echo not-found ;;
  *"-p LoadState"*) echo loaded ;;
  *"set-property --runtime broken.service"*) exit 1 ;;
  *"-p IOWeight"*) echo 20 ;;
  *"--user is-active --quiet"*) [ -e "'"$T"'/scope-up" ] ;;
  *"--user list-units"*) cat "'"$T"'/lane-units" 2>/dev/null ;;
  *"-p TasksCurrent"*) cat "'"$T"'/tasks" 2>/dev/null || echo 1 ;;
  *"--user daemon-reload"*) [ ! -e "'"$T"'/reload-fails" ] ;;
esac'
run_sh() { IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" bash "$SH" "$@" > "$T/out" 2> "$T/err"; }

echo "── io-shield ────────────────────────────────────────────────────"
ok "passes bash -n" 'bash -n "$SH"'
printf '# familiar\ndevice nvme0n1 rlat=2000 wlat=5000 min=25 max=100\n\nunit syncthing@jp.service 20\ndocker mempalace-db 20\nunit nosuch.service 30\ndocker gone 30\n' > "$T/conf"
: > "$T/qos"; : > "$LOG"; run_sh apply; rc=$?
ok "apply: exit 0" '[ "$rc" -eq 0 ]'
ok "apply: io.cost.qos gets the device by MAJ:MIN with the latency targets" 'grep -qxF "259:0 enable=1 ctrl=user rpct=95.00 rlat=2000 wpct=95.00 wlat=5000 min=25.00 max=100.00" "$T/qos"'
ok "apply: IOWeight set on the named unit, at runtime only" 'grep -qxF "systemctl set-property --runtime syncthing@jp.service IOWeight=20" "$LOG"'
ok "apply: the container is resolved to docker-<full id>.scope" 'grep -qxF "systemctl set-property --runtime docker-$ID.scope IOWeight=20" "$LOG"'
ok "apply: a unit or container that is not there is a note, not an error, and nothing is set for it" 'grep -q "nosuch.service is not loaded now" "$T/out" && grep -q "container gone is not there now" "$T/out" && ! grep -q "set-property.*nosuch" "$LOG"'
ok "apply: never a persistent set-property" '! grep "set-property" "$LOG" | grep -qv -- "--runtime"'
printf 'device nvme0n1\n' > "$T/conf"; run_sh apply
ok "device defaults are rlat 2000, wlat 5000, 25-100 %" 'grep -qF "rlat=2000 wpct=95.00 wlat=5000 min=25.00 max=100.00" "$T/qos"'
printf 'device nvme0n1\ndevice sdz\n' > "$T/conf"; : > "$T/qos"; run_sh apply; rc=$?
ok "a device this host does not have: exit 1, the others still applied" '[ "$rc" -eq 1 ] && grep -q "^259:0 enable=1" "$T/qos"'
printf 'unit broken.service 20\n' > "$T/conf"; run_sh apply; rc=$?
ok "a failing set-property is exit 1" '[ "$rc" -eq 1 ]'
printf 'device nvme0n1\n' > "$T/conf"; run_sh off; rc=$?
ok "off: writes enable=0 for the device" '[ "$rc" -eq 0 ] && grep -qxF "259:0 enable=0" "$T/qos"'
printf 'device nvme0n1\nunit syncthing@jp.service 20\ndocker mempalace-db 20\n' > "$T/conf"; echo "259:0 enable=1 x" > "$T/qos"; : > "$LOG"; cp "$T/qos" "$T/qos.before"; run_sh status; rc=$?
ok "status: prints, writes nothing, sets nothing" '[ "$rc" -eq 0 ] && cmp -s "$T/qos" "$T/qos.before" && ! grep -q "set-property" "$LOG" && grep -q "syncthing@jp.service: want 20" "$T/out"'
# bad configs: exit 22 and NOTHING written or set, even when an earlier line was fine
for bad in 'device nvme0n1 rlat=abc' 'device nvme0n1 speed=9' 'device ../nvme0n1' 'device nvme0n1 min=50 max=10' 'device nvme0n1 max=20000' \
           'unit syncthing@jp.service' 'unit syncthing@jp.service 0' 'unit syncthing@jp.service 20000' 'unit a;b.service 20' 'docker $(id) 20' 'weight everything 1'; do
  printf 'device nvme0n1\n%s\n' "$bad" > "$T/conf"; : > "$T/qos"; : > "$LOG"; run_sh apply; rc=$?
  if [ "$rc" -eq 22 ] && [ ! -s "$T/qos" ] && ! grep -q "set-property" "$LOG"; then pass "bad line refused before anything is written: $bad"
  else fail "bad line '$bad': rc $rc, qos $(cat "$T/qos"), log $(cat "$LOG")"; fi
done
printf 'device nvme0n1\n' > "$T/conf"
IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" PATH="$B:$PATH" bash "$SH" apply > /dev/null 2>&1; rc=$?
if [ "$(id -u)" -ne 0 ]; then ok "apply without root is exit 2" '[ "$rc" -eq 2 ]'; fi
IO_SHIELD_CONF="$T/absent" IO_SHIELD_ASSUME_ROOT=1 bash "$SH" apply > /dev/null 2>&1; ok "no config is exit 2" '[ "$?" -eq 2 ]'
bash "$SH" > /dev/null 2>&1; ok "no argument is exit 22" '[ "$?" -eq 22 ]'
bash "$SH" bogus > /dev/null 2>&1; ok "an unknown verb is exit 22" '[ "$?" -eq 22 ]'

echo "── lane-slice.sh ────────────────────────────────────────────────"
ok "passes bash -n" 'bash -n "$LS"'
X="$T/xdg"; P="$T/proc"; mkdir -p "$X" "$P"
U="$X/systemd/user"
cfg() { printf '%s\n' "$1" > "$T/config.json"; }
run_ls() { DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" PATH="$B:$PATH" bash "$LS" "$@" > "$T/out" 2> "$T/err"; }
# sessions: lead (excluded), alpha (panes 100 → 101 → 102, and 110), beta (200, already in the slice), gamma (300 in a dreamteam scope)
stub tmux 'case "$*" in
  *list-sessions*) printf "lead\nalpha\nbeta\ngamma\n" ;;
  *"list-panes -s -t =alpha"*) printf "100\n110\n" ;;
  *"list-panes -s -t =beta"*) echo 200 ;;
  *"list-panes -s -t =gamma"*) echo 300 ;;
  *"list-panes -s -t =lead"*) echo 900 ;;
esac'
stub ps 'printf "100 1\n101 100\n102 101\n110 1\n200 1\n300 1\n301 300\n900 1\n901 900\n555 1\n"'
stub busctl 'echo "busctl $*" >> "'"$LOG"'"; [ ! -e "'"$T"'/busctl-fails" ]'
stub systemd-run 'echo "systemd-run $*" >> "'"$LOG"'"; touch "'"$T"'/scope-up"'
pcg() { mkdir -p "$P/$1"; echo "0::/user.slice/user-1000.slice/user@1000.service/$2" > "$P/$1/cgroup"; }
for p in 100 101 102 110 900 901 555; do pcg $p "app.slice/tmux-spawn-x.scope"; done
pcg 200 "lanes.slice/lane-beta.scope"; pcg 300 "lanes.slice/lane-gamma.scope"; pcg 301 "app.slice/dreamteam-proj.scope"

cfg '{"lanes":{"enabled":false,"exclude":["lead"]}}'; : > "$LOG"; run_ls attach; rc=$?
ok "not enabled: attach does nothing, exit 0" '[ "$rc" -eq 0 ] && [ ! -s "$LOG" ]'
cfg '{}'; : > "$LOG"; run_ls install; rc=$?
ok "no .lanes at all: install writes nothing, exit 0" '[ "$rc" -eq 0 ] && [ ! -e "$U/lanes.slice" ]'
cfg '{"lanes":{"enabled":true}}'; : > "$LOG"; run_ls attach; rc=$?
ok "enabled without .lanes.exclude: REFUSED (exit 2), nothing moved" '[ "$rc" -eq 2 ] && [ ! -s "$LOG" ]'
cfg '{"lanes":{"enabled":true,"exclude":"lead"}}'; run_ls attach
ok "exclude that is not a list is refused" '[ "$?" -eq 2 ]'
for bad in '"cpuWeight":0' '"ioWeight":20000' '"memoryHigh":"lots"' '"memorySwapMax":"8G; rm"' '"units":["../x.service"]' '"units":["gate"]'; do
  cfg '{"lanes":{"enabled":true,"exclude":[],'"$bad"'}}'; rm -rf "$U"; run_ls install; rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$U/lanes.slice" ]; then pass "bad value refused, nothing written: $bad"; else fail "bad value '$bad': rc $rc"; fi
done

cfg '{"lanes":{"enabled":true,"exclude":["lead"],"cpuWeight":40,"ioWeight":20,"memoryHigh":"12G","memorySwapMax":"4G","units":["plan-gate.service"]}}'
rm -rf "$U"; : > "$LOG"; run_ls install; rc=$?
ok "install: exit 0 and the user manager is reloaded" '[ "$rc" -eq 0 ] && grep -qxF "systemctl --user daemon-reload" "$LOG"'
ok "install: the slice carries the four settings" 'grep -qx "CPUWeight=40" "$U/lanes.slice" && grep -qx "IOWeight=20" "$U/lanes.slice" && grep -qx "MemoryHigh=12G" "$U/lanes.slice" && grep -qx "MemorySwapMax=4G" "$U/lanes.slice" && grep -qx "\[Slice\]" "$U/lanes.slice"'
ok "install: the gate unit's drop-in puts it in the slice, under [Service]" 'grep -qx "\[Service\]" "$U/plan-gate.service.d/20-lanes-slice.conf" && grep -qx "Slice=lanes.slice" "$U/plan-gate.service.d/20-lanes-slice.conf"'
if command -v systemd-analyze > /dev/null 2>&1; then
  mkdir -p "$T/verify"; cp "$U/lanes.slice" "$T/verify/"
  if systemd-analyze --user verify "$T/verify/lanes.slice" > "$T/verify.out" 2>&1; then pass "systemd-analyze accepts the generated slice"; else fail "generated slice rejected: $(head -2 "$T/verify.out")"; fi
  printf '[Slice]\nCPUWeight=banana\n' > "$T/verify/broken.slice"
  if systemd-analyze --user verify "$T/verify/broken.slice" 2>&1 | grep -qi 'cpuweight\|invalid\|failed'; then pass "…and rejects a broken one (the verify is not vacuous)"; else fail "systemd-analyze accepted a broken slice"; fi
fi
cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; rm -rf "$U"; run_ls install
ok "install: empty memory settings are left out; weights default to 50 and 25" '! grep -q "Memory" "$U/lanes.slice" && grep -qx "CPUWeight=50" "$U/lanes.slice" && grep -qx "IOWeight=25" "$U/lanes.slice"'
echo "someone else's unit" > "$U/lanes.slice"; run_ls install; rc=$?
ok "install refuses to replace a slice file that is not ours" '[ "$rc" -eq 1 ] && grep -qx "someone else.s unit" "$U/lanes.slice"'
run_ls uninstall; rc=$?
ok "uninstall leaves a file that is not ours" '[ "$rc" -eq 1 ] && [ -e "$U/lanes.slice" ]'
rm -f "$U/lanes.slice"
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"units":["plan-gate.service"]}}'; run_ls install; run_ls uninstall; rc=$?
ok "uninstall removes the slice and the drop-in it wrote" '[ "$rc" -eq 0 ] && [ ! -e "$U/lanes.slice" ] && [ ! -e "$U/plan-gate.service.d/20-lanes-slice.conf" ]'

cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; : > "$LOG"; rm -f "$T/scope-up"; run_ls attach; rc=$?
ok "attach: exit 0" '[ "$rc" -eq 0 ]'
ok "attach: alpha's panes AND their descendants go in one call (4 pids: 100 101 102 110)" 'grep -q "AttachProcessesToUnit ssau lane-alpha.scope / 4 100 101 102 110$" "$LOG"'
ok "attach: the scope is created inside lanes.slice, delegated" 'grep -q "systemd-run --user --quiet --scope --unit=lane-alpha --slice=lanes.slice -p Delegate=yes" "$LOG"'
ok "attach: the excluded session (the lead) is never moved" '! grep -q "lane-lead\|[ /]900\b\|[ /]901\b" "$LOG"'
ok "attach: a process already in the slice is not moved again" '! grep -q "lane-beta" "$LOG"'
ok "attach: a process in a dreamteam-*.scope stays there" '! grep "AttachProcessesToUnit" "$LOG" | grep -q " 301"'
ok "attach: an unrelated process of the user is never moved" '! grep "AttachProcessesToUnit" "$LOG" | grep -q " 555"'
touch "$T/busctl-fails"; run_ls attach; rc=$?; rm -f "$T/busctl-fails"
ok "attach: a move the manager refuses is exit 1 and says which session" '[ "$rc" -eq 1 ] && grep -q "could not move session alpha" "$T/err"'
printf 'lane-alpha.scope loaded active running x\nlane-oldsession.scope loaded active running x\n' > "$T/lane-units"; echo 1 > "$T/tasks"; : > "$LOG"; run_ls attach
ok "attach: a lane scope whose session is gone and that holds only its anchor is stopped, by name" 'grep -qxF "systemctl --user stop lane-oldsession.scope" "$LOG" && ! grep -q "stop lane-alpha.scope" "$LOG"'
echo 3 > "$T/tasks"; : > "$LOG"; run_ls attach
ok "attach: …but not while it still holds processes" '! grep -q "systemctl --user stop" "$LOG"'
rm -f "$T/lane-units"
mkdir -p "$T/cg/user.slice/user-$(id -u).slice/user@$(id -u).service"; M="$T/cg/user.slice/user-$(id -u).slice/user@$(id -u).service"
echo "cpu memory pids" > "$M/cgroup.controllers"; echo "cpu memory pids" > "$M/cgroup.subtree_control"; : > "$T/cg/io.cost.qos"; : > "$LOG"; run_ls status
ok "status: says the io controller is not delegated and io.cost is off; moves nothing" 'grep -q "NOT delegated" "$T/out" && grep -q "io.cost: off" "$T/out" && ! grep -q "Attach\|systemd-run" "$LOG"'
echo "cpu io memory pids" > "$M/cgroup.controllers"; run_ls status
ok "status: delegated but not yet used by the running manager is said so" 'grep -q "delegated, NOT yet used" "$T/out"'
echo "cpu io memory pids" > "$M/cgroup.subtree_control"; echo "259:0 enable=1 ctrl=user" > "$T/cg/io.cost.qos"; run_ls status
ok "status: both in place" 'grep -q "in use by the user manager" "$T/out" && grep -q "io.cost: on (1 device" "$T/out"'
ok "status: counts each session's processes in the slice, and names the excluded one" 'grep -qx "session alpha: 0 of 4 processes in lanes.slice" "$T/out" && grep -qx "session beta: 1 of 1 processes in lanes.slice" "$T/out" && grep -qx "session lead: excluded (not a lane)" "$T/out"'
run_ls bogus; ok "an unknown verb is exit 22" '[ "$?" -eq 22 ]'

echo "── host-io-check.sh ─────────────────────────────────────────────"
ok "passes bash -n" 'bash -n "$HC"'
C="$T/checks"; printf 'some avg10=1.00 avg60=2.00 avg300=1.00 total=1\nfull avg10=0.50 avg60=3.40 avg300=1.00 total=1\n' > "$T/psi"
run_hc() { DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST=Familiar DREAMTEAM_IO_PROBE_DIR="$T/probe" DREAMTEAM_IO_PROBE_SECS=1 DREAMTEAM_PSI_IO="$T/psi" "$@" bash "$HC" > "$T/out" 2> "$T/err"; }
run_hc env; rc=$?
ok "a calm disk: ok, exit 0, the line is published under the host's own name" '[ "$rc" -eq 0 ] && grep -q "^CHECK familiar-io ok · fsync p99 [0-9]* ms (max [0-9]*), read p99 [0-9]* ms, io pressure full avg60 3%, on " "$C/familiar-io.line"'
ok "the line is exactly three segments" '[ "$(grep -o " · " "$C/familiar-io.line" | wc -l)" -eq 2 ]'
run_hc env DREAMTEAM_IO_FSYNC_WARN_MS=0
ok "fsync p99 over its threshold: warn" 'grep -q "^CHECK familiar-io warn · " "$C/familiar-io.line"'
printf 'full avg10=0.50 avg60=49.00 avg300=1.00 total=1\n' > "$T/psi"; run_hc env
ok "pressure over 20 %: warn, and the number is in the line" 'grep -q "^CHECK familiar-io warn · .*full avg60 49%" "$C/familiar-io.line"'
printf 'garbage\n' > "$T/psi"; run_hc env
ok "unreadable pressure: fail, never ok" 'grep -q "^CHECK familiar-io fail · pressure unreadable" "$C/familiar-io.line"'
printf 'full avg10=0.50 avg60=1.00 avg300=1.00 total=1\n' > "$T/psi"
echo "a file, not a dir" > "$T/notdir"; DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST=familiar DREAMTEAM_IO_PROBE_DIR="$T/notdir/x" DREAMTEAM_IO_PROBE_SECS=1 DREAMTEAM_PSI_IO="$T/psi" bash "$HC" > /dev/null 2>&1
ok "a probe that cannot run: fail with the reason" 'grep -q "^CHECK familiar-io fail · the probe could not run: io_probe: " "$C/familiar-io.line"'
run_hc env DREAMTEAM_IO_FSYNC_WARN_MS=abc
ok "a threshold that is not a number: fail" 'grep -q "^CHECK familiar-io fail · a warn threshold" "$C/familiar-io.line"'
bash "$HC" extra > /dev/null 2>&1; ok "an argument is exit 22" '[ "$?" -eq 22 ]'
out=$(python3 -I "$ROOT/scripts/lib/io_probe.py" "$T/probe" 1 1 2>&1)
ok "io_probe prints its numbers as one JSON object" 'printf "%s" "$out" | jq -e ".fsync_p99 > 0 and .read_p99 > 0 and .reads > 10 and .fsyncs > 2" > /dev/null'
python3 -I "$ROOT/scripts/lib/io_probe.py" "$T/probe" 0 > /dev/null 2>&1; ok "io_probe: zero seconds is exit 22" '[ "$?" -eq 22 ]'

echo "── units ────────────────────────────────────────────────────────"
D="$ROOT/systemd/system/user@.service.d/20-delegate-io.conf"
ok "the user@ drop-in adds io and keeps the vendor's three controllers" 'grep -qx "Delegate=pids memory cpu io" "$D" && grep -qx "\[Service\]" "$D"'
ok "io-shield's service runs apply from /usr/local/sbin and waits for its config" 'grep -qx "ExecStart=/usr/local/sbin/dreamteam-io-shield apply" "$ROOT/systemd/system/dreamteam-io-shield.service" && grep -qx "ConditionPathExists=/etc/dreamteam/io-shield.conf" "$ROOT/systemd/system/dreamteam-io-shield.service"'
ok "the probe's unit is at normal priority and outside the lanes slice" '! grep -qE "^(Nice|IOSchedulingClass|Slice)=" "$ROOT/systemd/dreamteam-host-io.service"'
ok "each timer has its service and a CHECKS.md row" 'for u in dreamteam-host-io dreamteam-lane-slice; do [ -f "$ROOT/systemd/$u.service" ] && [ -f "$ROOT/systemd/$u.timer" ] || exit 1; done; [ -f "$ROOT/systemd/system/dreamteam-io-shield.timer" ] && grep -q "dreamteam-host-io.timer" "$ROOT/docs/CHECKS.md" && grep -q "dreamteam-io-shield.timer" "$ROOT/docs/CHECKS.md" && grep -q "dreamteam-lane-slice.timer" "$ROOT/docs/CHECKS.md"'
if command -v systemd-analyze > /dev/null 2>&1; then
  V="$T/v"; mkdir -p "$V"
  for f in "$ROOT"/systemd/dreamteam-host-io.* "$ROOT"/systemd/dreamteam-lane-slice.*; do sed -E 's|^ExecStart=.*|ExecStart=/bin/true|; s|^WorkingDirectory=.*||' "$f" > "$V/$(basename "$f")"; done
  for f in "$ROOT"/systemd/system/dreamteam-io-shield.*; do sed -E 's|^ExecStart=.*|ExecStart=/bin/true|' "$f" > "$V/$(basename "$f")"; done
  if systemd-analyze --user verify "$V"/dreamteam-host-io.timer "$V"/dreamteam-lane-slice.timer > "$T/v.out" 2>&1 && systemd-analyze verify "$V"/dreamteam-io-shield.timer >> "$T/v.out" 2>&1; then pass "systemd-analyze accepts the six unit files"
  else fail "unit files rejected: $(grep -v '^$' "$T/v.out" | head -3)"; fi
fi

echo ""
echo "io-shield: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
