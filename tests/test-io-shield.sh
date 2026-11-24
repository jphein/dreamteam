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
  *"--user list-units lane-"*) cat "'"$T"'/lane-units" 2>/dev/null ;;
  *"--user list-units dreamteam-"*) cat "'"$T"'/fleet-units" 2>/dev/null ;;
  *"-p ControlGroup"*) cat "'"$T"'/controlgroup" 2>/dev/null ;;
  *"-p TasksCurrent"*) cat "'"$T"'/tasks" 2>/dev/null || echo 1 ;;
  *"--user daemon-reload"*) [ ! -e "'"$T"'/reload-fails" ] ;;
esac'
mkdir -p "$T/run0"
run_sh() { rm -f "$T/run0/dreamteam-io-shield.off"; IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_RUN_DIR="$T/run0" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" bash "$SH" "$@" > "$T/out" 2> "$T/err"; }

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
ok "status: counts each session's processes in the slice, and names the excluded one" 'grep -qx "session alpha: 0 of 4 processes in lanes.slice" "$T/out" && grep -qx "session beta: 1 of 1 processes in lanes.slice" "$T/out" && grep -qx "session lead: not a lane, outside the slice (2 processes)" "$T/out"'
run_ls bogus; ok "an unknown verb is exit 22" '[ "$?" -eq 22 ]'

echo "── never a lane · budgets · fleet scopes · the hook · reconcile · rollback (xreview #282 r1) ─"
UM="user.slice/user-$(id -u).slice/user@$(id -u).service"
# a session that is NOT a lane but has processes inside the slice (it was attached once) is moved OUT
pcg 900 "lanes.slice/lane-lead.scope"; pcg 901 "lanes.slice/lane-lead.scope"
cfg '{"lanes":{"enabled":true,"exclude":[],"lead":["lead"]}}'; : > "$LOG"; rm -f "$T/scope-up"; run_ls status
ok "status: a lead session found inside the slice is said so" 'grep -qx "session lead: NOT a lane, but 2 of 2 processes are in lanes.slice (the next attach moves them out)" "$T/out"'
run_ls attach; rc=$?
ok "attach: a .lanes.lead session's processes inside the slice are moved OUT, into a scope outside it" '[ "$rc" -eq 0 ] && grep -q "AttachProcessesToUnit ssau out-lead.scope / 2 900 901$" "$LOG" && grep -q "systemd-run --user --quiet --scope --unit=out-lead -p Delegate=yes" "$LOG" && ! grep -q -- "--unit=out-lead --slice" "$LOG"'
ok "…and it is never placed in a lane scope" '! grep -q "lane-lead.scope / " "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; : > "$LOG"; run_ls attach
ok "the same for a session named only in .lanes.exclude" 'grep -q "AttachProcessesToUnit ssau out-lead.scope / 2 900 901$" "$LOG"'
touch "$T/busctl-fails"; run_ls attach; rc=$?; rm -f "$T/busctl-fails"
ok "a move OUT that fails is exit 1 and names the session" '[ "$rc" -eq 1 ] && grep -q "session lead is not a lane but its processes could not be moved out" "$T/err"'
pcg 900 "app.slice/tmux-spawn-lead.scope"; pcg 901 "app.slice/tmux-spawn-lead.scope"; : > "$LOG"; run_ls attach; run_ls status
ok "a lead that is outside the slice is left exactly where it is" '! grep -q "out-lead\| 900\| 901" "$LOG" && grep -qx "session lead: not a lane, outside the slice (2 processes)" "$T/out"'
ok "lane-slice marks and protects nothing (that is the watchdog's scope and the root helper)" '! grep -q "oomd_avoid\|setxattr\|oom_score" "$LS"'

# each lane's OWN budget, on its own scope, also for a lane that is already placed
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"perLane":{"memoryHigh":"5G","memorySwapMax":"1G"}}}'; : > "$LOG"; touch "$T/scope-up"; run_ls attach
ok "per-lane budget: set on the lane's own scope" 'grep -qxF "systemctl --user set-property --runtime lane-alpha.scope MemoryHigh=5G MemorySwapMax=1G" "$LOG"'
ok "…and on a lane that was placed earlier (a changed config reaches a running lane)" 'grep -qxF "systemctl --user set-property --runtime lane-beta.scope MemoryHigh=5G MemorySwapMax=1G" "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; : > "$LOG"; run_ls attach
ok "no perLane: no budget is set" '! grep -q "set-property --runtime lane-" "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"perLane":{"memoryHigh":"5G; rm"}}}'; run_ls attach
ok "a bad per-lane value is refused" '[ "$?" -eq 2 ]'
rm -f "$T/scope-up"

# a fleet scope holding a lane's processes is not moved; it gets the lanes' weights
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"cpuWeight":40,"ioWeight":20}}'; : > "$LOG"; run_ls attach
ok "a dreamteam-*.scope with a lane's processes gets the slice's CPUWeight and IOWeight" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight=40 IOWeight=20" "$LOG"'
run_ls status
ok "status counts a lane's processes that sit in a fleet scope" 'grep -q "^session gamma: 1 of 2 processes in lanes.slice, 1 in a fleet scope (weights only)$" "$T/out"'

# the SessionStart form: silent, exit 0 whatever happens
touch "$T/busctl-fails"; : > "$LOG"; out=$(DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" PATH="$B:$PATH" bash "$LS" attach --hook 2>&1); rc=$?; rm -f "$T/busctl-fails"
ok "attach --hook: silent and exit 0 even when a move fails, and it did try (through its own time-box)" '[ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q "AttachProcessesToUnit ssau lane-alpha.scope" "$LOG"'
# a tmux that never answers cannot hold a session start: the hook form is killed at its bound and still exits 0
mkdir -p "$T/slow"; printf '#!/bin/sh\nsleep 30\n' > "$T/slow/tmux"; chmod +x "$T/slow/tmux"
t0=$(date +%s); DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" LANE_SLICE_HOOK_SECS=2 PATH="$T/slow:$B:$PATH" bash "$LS" attach --hook; rc=$?; t1=$(date +%s)
ok "attach --hook with a tmux that hangs: exit 0 within its bound ($((t1 - t0)) s)" '[ "$rc" -eq 0 ] && [ "$((t1 - t0))" -le 5 ]'
run_ls attach --bogus; ok "attach with another word is exit 22" '[ "$?" -eq 22 ]'
hooked() { jq -e --arg c 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/lane-slice.sh" attach --hook' '.hooks.SessionStart[].hooks[] | select(.command == $c and .timeout <= 10)' "$ROOT/hooks/hooks.json" > /dev/null; }
ok "hooks.json runs it at SessionStart in the plain bash form, under a timeout in seconds" 'hooked'

# install reconciles: a unit dropped from the list loses the drop-in this tool wrote
cfg '{"lanes":{"enabled":true,"exclude":[],"units":["a-gate.service","b-gate.service"]}}'; rm -rf "$U"; run_ls install
cfg '{"lanes":{"enabled":true,"exclude":[],"units":["a-gate.service"]}}'; mkdir -p "$U/c-gate.service.d"; echo "[Service]" > "$U/c-gate.service.d/20-lanes-slice.conf"; run_ls install; rc=$?
ok "install again with a shorter list: the dropped unit's drop-in is removed, the kept one stays" '[ ! -e "$U/b-gate.service.d/20-lanes-slice.conf" ] && [ -e "$U/a-gate.service.d/20-lanes-slice.conf" ]'
ok "…a drop-in of that name that is not ours is left, and said (exit 1)" '[ "$rc" -eq 1 ] && [ -e "$U/c-gate.service.d/20-lanes-slice.conf" ]'
rm -rf "$U/c-gate.service.d"

# uninstall is the rollback, and works with a config that cannot be read
run_ls install
LC="$T/cg/$UM/lanes.slice/lane-alpha.scope"; mkdir -p "$LC"; printf '100\n101\n777\n' > "$LC/cgroup.procs"; echo "/$UM/lanes.slice/lane-alpha.scope" > "$T/controlgroup"
mkdir -p "$P/777"; echo sleep > "$P/777/comm"; printf 'sleep\0infinity\0' > "$P/777/cmdline"; for p in 100 101; do echo claude > "$P/$p/comm"; printf 'claude\0' > "$P/$p/cmdline"; done
printf 'lane-alpha.scope loaded active running x\n' > "$T/lane-units"; printf 'dreamteam-proj.scope loaded active running x\n' > "$T/fleet-units"
echo '{ this is not json' > "$T/config.json"; : > "$LOG"; rm -f "$T/scope-up"; run_ls uninstall; rc=$?
ok "uninstall with an unreadable config still runs (exit 0)" '[ "$rc" -eq 0 ]'
ok "uninstall: the attach timer is disabled" 'grep -qxF "systemctl --user disable --now dreamteam-lane-slice.timer" "$LOG"'
ok "uninstall: each lane's processes are moved out of the slice (the anchor is not)" 'grep -q "AttachProcessesToUnit ssau out-alpha.scope / 2 100 101$" "$LOG" && ! grep "AttachProcessesToUnit" "$LOG" | grep -q " 777"'
ok "uninstall: the lane scope is stopped, by name" 'grep -qxF "systemctl --user stop lane-alpha.scope" "$LOG"'
ok "uninstall: the weights set on a fleet scope are reset" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight= IOWeight=" "$LOG"'
ok "uninstall: the slice file and drop-ins are gone" '[ ! -e "$U/lanes.slice" ] && [ ! -e "$U/a-gate.service.d/20-lanes-slice.conf" ]'
touch "$T/busctl-fails"; cfg '{"lanes":{"enabled":true,"exclude":[]}}'; run_ls install; echo '{ broken' > "$T/config.json"; : > "$LOG"; run_ls uninstall; rc=$?; rm -f "$T/busctl-fails"
ok "uninstall: a lane that cannot be moved out is NOT stopped (its processes would be ended), exit 1" '[ "$rc" -eq 1 ] && ! grep -q "stop lane-alpha.scope" "$LOG"'
rm -f "$T/lane-units" "$T/fleet-units" "$T/controlgroup"; rm -rf "$T/cg/$UM/lanes.slice"

echo "── io-shield oomprotect: only the watchdog's named unit (xreview #282 r1) ───────"
LD="$T/cg/$UM/app.slice/lead-spire.scope"; mkdir -p "$LD/sub" "$T/cg/$UM/app.slice/tmux-spawn-x.scope" "$T/cg/$UM/app.slice/lead-spire.scope-x" "$T/cg/$UM/lanes.slice/lead-spire.scope" "$T/run"
PR="$T/fproc"; rm -rf "$PR"
fp() { mkdir -p "$PR/$1"; echo "${3:-0}" > "$PR/$1/oom_score_adj"; echo "0::/$UM/$2" > "$PR/$1/cgroup"; }
scores() { local p o=""; for p in "$@"; do o="$o$(cat "$PR/$p/oom_score_adj") "; done; printf '%s' "$o"; }
fixture() { rm -rf "$PR"; fp 900 app.slice/lead-spire.scope; fp 901 app.slice/lead-spire.scope; fp 902 app.slice/lead-spire.scope/sub; fp 100 app.slice/tmux-spawn-x.scope; fp 101 app.slice/tmux-spawn-x.scope
            fp 200 app.slice/lead-spire.scope-x; fp 201 lanes.slice/lead-spire.scope; fp 202 app.slice; rm -f "$T/run/dreamteam-io-shield.off"
            # a SYSTEM service that runs as this user with its unit's own negative score, and a login-session process
            mkdir -p "$PR/300" "$PR/301"; echo -500 > "$PR/300/oom_score_adj"; echo "0::/system.slice/palace-daemon.service" > "$PR/300/cgroup"
            echo -700 > "$PR/301/oom_score_adj"; echo "0::/user.slice/user-$(id -u).slice/session-4.scope" > "$PR/301/cgroup"; }
run_op() { IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" bash "$SH" "$@" > "$T/out" 2> "$T/err"; }
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
fixture; run_op apply; rc=$?
ok "every process in the named unit, sub-cgroups included, gets the score" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "-500 -500 -500 " ] && grep -q "3 process(es) set to -500, 1 outside it put back to 0" "$T/out"'
ok "a lane's scope, a unit whose name only STARTS like it, the same name under another slice, and the parent slice earn nothing" '[ "$(scores 100 101 200 201 202)" = "0 0 0 0 0 " ]'
ok "a SYSTEM service running as the user keeps its unit's own negative score (serialhub 11-23: the first version reset three)" '[ "$(scores 300)" = "-500 " ]'
ok "a negative score in the user's own login session is undone (only root's hand puts one there)" '[ "$(scores 301)" = "0 " ]'
run_op apply; ok "a second run changes nothing" 'grep -q "0 process(es) set to -500, 0 outside" "$T/out"'
if python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.oomd_avoid", b"1")' "$T/cg/$UM/app.slice/tmux-spawn-x.scope" 2>/dev/null; then
  run_op apply; ok "a lane that MARKS its own scope (user.oomd_avoid) earns nothing: no mark is read" '[ "$(scores 100 101)" = "0 0 " ]'
fi
ok "no attribute is read anywhere in the tool" '! grep -q "getxattr\|oomd_avoid" "$SH"'
echo -500 > "$PR/100/oom_score_adj"; run_op apply
ok "a process OUTSIDE the unit that holds a negative score is put back to 0" '[ "$(scores 100)" = "0 " ] && grep -q ", 1 outside it put back to 0" "$T/out"'
echo "0::/$UM/app.slice/tmux-spawn-x.scope" > "$PR/901/cgroup"; run_op apply
ok "a process that LEFT the unit loses the score at the next run (migration is undone)" '[ "$(scores 901)" = "0 " ] && [ "$(scores 900)" = "-500 " ]'
fixture; echo "0::/$UM/app.slice/tmux-spawn-x.scope" > "$PR/901/cgroup"; run_op apply
ok "a pid listed nowhere but whose process is not in the unit is not scored (the cgroup is read through the held descriptor)" '[ "$(scores 901)" = "0 " ]'
fixture; mv "$LD" "$LD.away"; ln -s "$T/cg/$UM/app.slice/tmux-spawn-x.scope" "$LD"; run_op apply; rm -f "$LD"; mv "$LD.away" "$LD"
ok "the unit path being a symlink: nobody is scored" '[ "$(scores 900 901 902 100 101)" = "0 0 0 0 0 " ]'
fixture; mv "$LD" "$LD.away"; echo -500 > "$PR/900/oom_score_adj"; run_op apply; mv "$LD.away" "$LD"
ok "the unit not existing (the lead is down): nobody is scored, and a leftover score is undone" '[ "$(scores 900 901)" = "0 0 " ]'
fixture; rm -rf "$PR/901"; run_op apply; rc=$?
ok "a process that has exited is skipped quietly" '[ "$rc" -eq 0 ] && [ "$(scores 900 902)" = "-500 -500 " ]'
fixture; printf 'oomprotect %s lead-spire.scope -500\n' "$(( $(id -u) + 1 ))" > "$T/conf"; echo -300 > "$PR/100/oom_score_adj"; run_op apply
ok "a line for another uid neither scores nor resets this user's processes" '[ "$(scores 900 100)" = "0 -300 " ]'
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"; fixture; run_op apply; echo -500 > "$PR/100/oom_score_adj"; cp -r "$PR" "$T/before"; run_op status
ok "status lists who is in the unit and any negative score outside it in the user's slice (not the system service's), and writes nothing" 'grep -q "in:900=-500 901=-500 902=-500; out:100=-500$" "$T/out" && diff -r "$PR" "$T/before" > /dev/null'
rm -rf "$T/before"
ok "owner, cgroup and the write all go through one /proc/<pid> directory descriptor" 'grep -q "os.O_DIRECTORY" "$SH" && grep -q "dir_fd=fd" "$SH" && ! grep -q "stat -c %u" "$SH"'
# the rollback
printf 'device nvme0n1\nunit syncthing@jp.service 20\ndocker mempalace-db 20\noomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
fixture; run_op apply; : > "$LOG"; run_op off; rc=$?
ok "off: io.cost disabled, the unit and container weights reset, every score back to 0, a stamp written" '[ "$rc" -eq 0 ] && grep -qxF "259:0 enable=0" "$T/qos" && grep -qxF "systemctl set-property --runtime syncthing@jp.service IOWeight=" "$LOG" && grep -qxF "systemctl set-property --runtime docker-'"$ID"'.scope IOWeight=" "$LOG" && [ "$(scores 900 901 902)" = "0 0 0 " ] && [ -e "$T/run/dreamteam-io-shield.off" ] && [ "$(scores 300)" = "-500 " ]'
: > "$LOG"; run_op apply; rc=$?
ok "after off, the timer's apply does NOTHING (the rollback is not undone 5 minutes later)" '[ "$rc" -eq 0 ] && grep -q "nothing applied" "$T/out" && grep -qxF "259:0 enable=0" "$T/qos" && [ "$(scores 900)" = "0 " ] && [ ! -s "$LOG" ]'
run_op status; ok "status says it is off" 'grep -q "^OFF: " "$T/out"'
run_op on; run_op apply
ok "on, then apply: applied again" '[ ! -e "$T/run/dreamteam-io-shield.off" ] && grep -q "^259:0 enable=1" "$T/qos" && [ "$(scores 900)" = "-500 " ]'
for bad in "oomprotect $(id -u) -500" "oomprotect $(id -u) tmux-spawn-x.scope -500" "oomprotect $(id -u) app.slice -500" "oomprotect $(id -u) lead-spire.service -500" \
           "oomprotect $(id -u) ../lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope 100" "oomprotect $(id -u) lead-spire.scope -2000" "oomprotect jp lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope -500 extra"; do
  fixture; printf '%s\n' "$bad" > "$T/conf"; run_op apply; rc=$?
  if [ "$rc" -eq 22 ] && [ "$(scores 900 100)" = "0 0 " ]; then pass "bad oomprotect line refused: $bad"; else fail "bad oomprotect '$bad': rc $rc"; fi
done

echo "── host-io-check.sh ─────────────────────────────────────────────"
ok "passes bash -n" 'bash -n "$HC"'
C="$T/checks"; printf 'some avg10=1.00 avg60=2.00 avg300=1.00 total=1\nfull avg10=0.50 avg60=3.40 avg300=1.00 total=1\n' > "$T/psi"
run_hc() { DREAMTEAM_CHECKS_DIR="$C" DREAMTEAM_CHECK_HOST=Familiar DREAMTEAM_IO_PROBE_DIR="$T/probe" DREAMTEAM_IO_PROBE_SECS=1 DREAMTEAM_PSI_IO="$T/psi" "$@" bash "$HC" > "$T/out" 2> "$T/err"; }
# the fsync threshold is lifted for this case: the probe is REAL, and on a busy test host its p99 is whatever the
# host is doing (the full suite failed here once for that reason); the thresholds have their own cases below
run_hc env DREAMTEAM_IO_FSYNC_WARN_MS=600000; rc=$?
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
