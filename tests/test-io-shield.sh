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

echo "── io-shield oomprotect: scores only the watchdog's unit, undoes only its own records (xreview #282 r2) ──"
# THE RULE under test: a negative score this helper did not write is NEVER written to, anywhere. "Untouched" is
# observed, not inferred from the final value: each such fixture file's content, mtime and inode are compared
# before and after (sig), so a write of the very same value would be seen.
LD="$T/cg/$UM/app.slice/lead-spire.scope"; XD="$T/cg/$UM/app.slice/tmux-spawn-x.scope"
mkdir -p "$LD/sub" "$XD" "$T/cg/$UM/app.slice/lead-spire.scope-x" "$T/cg/$UM/lanes.slice/lead-spire.scope" "$T/run"
PR="$T/fproc"; LG="$T/run/dreamteam-io-shield"
fp() {  # fp <pid> <cgroup path as in /proc> <score> [starttime]
  mkdir -p "$PR/$1"; echo "${3:-0}" > "$PR/$1/oom_score_adj"; echo "0::$2" > "$PR/$1/cgroup"
  echo "$1 (fix ture) S 1 $1 $1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 ${4:-5000$1} 0 0" > "$PR/$1/stat"
}
scores() { local p o=""; for p in "$@"; do o="$o$(cat "$PR/$p/oom_score_adj") "; done; printf '%s' "$o"; }
sig() { local p; for p in "$@"; do printf '%s:%s:%s ' "$p" "$(cat "$PR/$p/oom_score_adj")" "$(stat -c '%y %i' "$PR/$p/oom_score_adj")"; done; }
# the processes that must NEVER be written: a lane's, lookalike units, a login session with its own negative
# score, an unrelated user-slice process with one, five system services running as the user with their units'
# own scores (familiar's four and serialhub's octoprint), and two INSIDE the lead unit that already had one
STAY="100 101 200 201 202 301 302 310 311 312 313 314 903 904"
fixture() {
  rm -rf "$PR" "$LG"; rm -f "$T/run/dreamteam-io-shield.off"
  fp 900 "/$UM/app.slice/lead-spire.scope" 0; fp 901 "/$UM/app.slice/lead-spire.scope" 200; fp 902 "/$UM/app.slice/lead-spire.scope/sub" 0
  fp 903 "/$UM/app.slice/lead-spire.scope" -900; fp 904 "/$UM/app.slice/lead-spire.scope" -500
  fp 100 "/$UM/app.slice/tmux-spawn-x.scope" 0; fp 101 "/$UM/app.slice/tmux-spawn-x.scope" 0
  fp 200 "/$UM/app.slice/lead-spire.scope-x" 0; fp 201 "/$UM/lanes.slice/lead-spire.scope" 0; fp 202 "/$UM/app.slice" 0
  fp 301 "/user.slice/user-$(id -u).slice/session-4.scope" -700; fp 302 "/$UM/app.slice/tmux-spawn-x.scope" -500
  fp 310 /system.slice/palace-daemon.service -500; fp 311 /system.slice/qwen3-coder.service -500
  fp 312 /system.slice/familiar-loadguard.service -800; fp 313 /system.slice/donkey-llm.service -100; fp 314 /system.slice/octoprint.service -900
  printf '900\n901\n903\n904\n' > "$LD/cgroup.procs"; echo 902 > "$LD/sub/cgroup.procs"; printf '100\n101\n302\n' > "$XD/cgroup.procs"
  sleep 0.02   # so that a later write has a later mtime
}
run_op() { IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" bash "$SH" "$@" > "$T/out" 2> "$T/err"; }
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"

fixture; before=$(sig $STAY); run_op apply; rc=$?
ok "apply: the unit's processes with a non-negative score get it (sub-cgroup too)" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "-500 -500 -500 " ] && grep -q "3 process(es) scored -500 and recorded; 0 of OUR records undone" "$T/out"'
ok "apply: a record per scored process: pid, start time, unit, score, the score it had before" 'grep -qx "start=5000900 unit=lead-spire.scope score=-500 prev=0 uid=$(id -u)" "$LG/900" && grep -q "prev=200 " "$LG/901" && [ "$(ls "$LG" | tr "\n" " ")" = "900 901 902 " ]'
ok "apply: NOTHING else is written to: lane, lookalike units, the login session's -700, an unrelated -500 in the user slice, palace-daemon, qwen3-coder, familiar-loadguard, donkey-llm, octoprint (content, mtime, inode)" '[ "$(sig $STAY)" = "$before" ]'
ok "apply: inside the unit, a process that already had a negative score (ours by inheritance or anyone else's) is left as found, unrecorded" '[ "$(scores 903 904)" = "-900 -500 " ] && [ ! -e "$LG/903" ] && [ ! -e "$LG/904" ] && grep -q "2 in the unit left as found" "$T/out"'
all=$(sig 900 901 902 $STAY); run_op apply
ok "a second apply writes to nobody at all" '[ "$(sig 900 901 902 $STAY)" = "$all" ] && grep -q "0 process(es) scored" "$T/out"'

# undo: ONLY a recorded process, the same process, still holding our score
echo "0::/$UM/app.slice/tmux-spawn-x.scope" > "$PR/901/cgroup"; printf '900\n903\n904\n' > "$LD/cgroup.procs"; before=$(sig $STAY 900 902); run_op apply
ok "a process WE scored that left the unit gets its PREVIOUS score back (200, not 0), and its record goes" '[ "$(scores 901)" = "200 " ] && [ ! -e "$LG/901" ] && grep -q "1 of OUR records undone" "$T/out"'
ok "…and that undo wrote to nobody else" '[ "$(sig $STAY 900 902)" = "$before" ]'
fixture; run_op apply
echo "900 (other) S 1 900 900 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 7777777 0 0" > "$PR/900/stat"; echo "0::/$UM/app.slice/tmux-spawn-x.scope" > "$PR/900/cgroup"; s900=$(sig 900); run_op apply
ok "a record whose pid now is ANOTHER process (start time differs) is dropped and that process is not written" '[ "$(sig 900)" = "$s900" ] && [ ! -e "$LG/900" ]'
echo "0::/$UM/app.slice/tmux-spawn-x.scope" > "$PR/902/cgroup"; : > "$LD/sub/cgroup.procs"; echo -300 > "$PR/902/oom_score_adj"; sleep 0.02; s902=$(sig 902); run_op apply
ok "a recorded process whose score someone has CHANGED since is not ours any more: not written, record dropped" '[ "$(sig 902)" = "$s902" ] && [ ! -e "$LG/902" ]'
fixture; run_op apply; rm -rf "$PR/901"; run_op apply; rc=$?
ok "a recorded process that has exited: record dropped, no error" '[ "$rc" -eq 0 ] && [ ! -e "$LG/901" ]'

# off: every record undone, and STILL nothing unrecorded is touched
printf 'device nvme0n1\nunit syncthing@jp.service 20\ndocker mempalace-db 20\noomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
fixture; run_op apply; before=$(sig $STAY); : > "$LOG"; run_op off; rc=$?
ok "off: each score WE recorded goes back to what it was (0, 200, 0); the ledger is empty; a stamp is written" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "0 200 0 " ] && [ -z "$(ls "$LG")" ] && [ -e "$T/run/dreamteam-io-shield.off" ]'
ok "off: the login session's -700, the user-slice -500, the five system services and the two unrecorded in-unit scores are NOT written (content, mtime, inode)" '[ "$(sig $STAY)" = "$before" ]'
ok "off: io.cost disabled, unit and container weights reset" 'grep -qxF "259:0 enable=0" "$T/qos" && grep -qxF "systemctl set-property --runtime syncthing@jp.service IOWeight=" "$LOG" && grep -qxF "systemctl set-property --runtime docker-'"$ID"'.scope IOWeight=" "$LOG"'
all=$(sig 900 901 902 $STAY); : > "$LOG"; run_op apply; rc=$?
ok "after off, the timer's apply does NOTHING" '[ "$rc" -eq 0 ] && grep -q "nothing applied" "$T/out" && [ "$(sig 900 901 902 $STAY)" = "$all" ] && [ ! -s "$LOG" ]'
run_op status; ok "status says it is off" 'grep -q "^OFF: " "$T/out"'
run_op on; run_op apply
ok "on, then apply: applied again" '[ ! -e "$T/run/dreamteam-io-shield.off" ] && grep -q "^259:0 enable=1" "$T/qos" && [ "$(scores 900)" = "-500 " ]'
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"

# the ledger itself is not something a user can plant
fixture; mkdir -p -m 700 "$T/elsewhere"; chmod 700 "$T/elsewhere"; ln -s "$T/elsewhere" "$LG"; before=$(sig 900 901 902 $STAY); run_op apply
ok "a ledger path that is a SYMLINK is not trusted: nothing is scored, nothing undone" '[ "$(sig 900 901 902 $STAY)" = "$before" ] && [ -z "$(ls "$T/elsewhere")" ]'
rm -f "$LG"
fixture; mkdir -p "$LG"; chmod 777 "$LG"; before=$(sig 900 901 902 $STAY); run_op apply
ok "a ledger directory that others can write is not trusted: nothing is scored, nothing recorded" '[ "$(sig 900 901 902 $STAY)" = "$before" ] && [ -z "$(ls "$LG")" ]'
fixture; run_op apply; printf 'start=5000100 unit=lead-spire.scope score=0 prev=-999 uid=%s\n' "$(id -u)" > "$T/planted"; ln -s "$T/planted" "$LG/100"; echo garbage > "$LG/101"
printf 'start=5000302 unit=lead-spire.scope score=-500 prev=77 uid=%s\n' "$(( $(id -u) + 1 ))" > "$LG/302"; before=$(sig $STAY); run_op apply; run_op off
ok "a record that is a symlink, one that is garbage, and one for another uid are ignored: those processes are not written" '[ "$(sig $STAY)" = "$before" ]'

# who can be scored at all
fixture; run_op apply
ok "a lane's scope, a unit whose name only STARTS like it, the same name under another slice, and the parent slice earn nothing" '[ "$(scores 100 101 200 201 202)" = "0 0 0 0 0 " ]'
if python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.oomd_avoid", b"1")' "$XD" 2>/dev/null; then
  run_op apply; ok "a lane that MARKS its own scope (user.oomd_avoid) earns nothing" '[ "$(scores 100 101)" = "0 0 " ]'
fi
ok "no attribute is read anywhere in the tool, and no blanket reset is left in it" '! grep -q "getxattr\|oomd_avoid" "$SH" && ! grep -q "startswith(mine)\|wr(fd, \"0\")" "$SH"'
fixture; mv "$LD" "$LD.away"; ln -s "$LD.away" "$LD"; before=$(sig 900 901 902 $STAY); run_op apply; rm -f "$LD"; mv "$LD.away" "$LD"
ok "the unit path being a symlink (to a directory listing processes whose own cgroup IS the unit): nobody is scored" '[ "$(sig 900 901 902 $STAY)" = "$before" ] && [ ! -e "$LG/900" ]'
# a process the unit's cgroup.procs still lists but whose OWN cgroup is already elsewhere (it moved while we read):
# a unit whose name only starts like the lead's, and the same unit name under another slice
fixture; printf '900\n901\n903\n904\n200\n201\n' > "$LD/cgroup.procs"; before=$(sig $STAY); run_op apply
ok "listed in the unit but its own cgroup is lead-spire.scope-x, or lanes.slice/lead-spire.scope: not scored, not recorded" '[ "$(sig $STAY)" = "$before" ] && [ ! -e "$LG/200" ] && [ ! -e "$LG/201" ] && [ "$(scores 900)" = "-500 " ]'
# …and the undo side of the same two shapes: a process we scored that is NOW in a lookalike is outside the unit
echo "0::/$UM/app.slice/lead-spire.scope-x" > "$PR/901/cgroup"; echo "0::/$UM/lanes.slice/lead-spire.scope" > "$PR/900/cgroup"; printf '903\n904\n' > "$LD/cgroup.procs"; run_op apply
ok "a process we scored that moved to lead-spire.scope-x, and one that moved to the same name under another slice, are both undone (200, 0)" '[ "$(scores 901 900)" = "200 0 " ] && [ ! -e "$LG/901" ] && [ ! -e "$LG/900" ] && grep -q "2 of OUR records undone" "$T/out"'
fixture; mv "$LD" "$LD.away"; before=$(sig 900 901 902 $STAY); run_op apply; mv "$LD.away" "$LD"
ok "the unit not existing (the lead is down): nobody is scored" '[ "$(sig 900 901 902 $STAY)" = "$before" ]'
fixture; printf 'oomprotect %s lead-spire.scope -500\n' "$(( $(id -u) + 1 ))" > "$T/conf"; before=$(sig 900 901 902 $STAY); run_op apply; run_op off
ok "a line for another uid writes to none of this user's processes (apply and off)" '[ "$(sig 900 901 902 $STAY)" = "$before" ]'
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"; fixture; run_op apply; all=$(sig 900 901 902 $STAY); cp -r "$LG" "$T/lg.before"; run_op status
ok "status: who is in the unit (and which are not ours), the ledger; it writes nothing, not even the ledger" 'grep -q "in:900=-500 901=-500 903=-900(not ours) 904=-500(not ours) 902=-500; recorded:900(lead-spire.scope) 901(lead-spire.scope) 902(lead-spire.scope)" "$T/out" && [ "$(sig 900 901 902 $STAY)" = "$all" ] && diff -r "$LG" "$T/lg.before" > /dev/null'
rm -rf "$T/lg.before"
ok "owner, start time, cgroup and the write all go through one /proc/<pid> directory descriptor" 'grep -q "os.O_DIRECTORY" "$SH" && grep -q "dir_fd=fd" "$SH" && ! grep -q "stat -c %u" "$SH"'
for bad in "oomprotect $(id -u) -500" "oomprotect $(id -u) tmux-spawn-x.scope -500" "oomprotect $(id -u) app.slice -500" "oomprotect $(id -u) lead-spire.service -500" \
           "oomprotect $(id -u) ../lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope 100" "oomprotect $(id -u) lead-spire.scope -2000" "oomprotect jp lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope -500 extra"; do
  fixture; printf '%s\n' "$bad" > "$T/conf"; before=$(sig 900 $STAY); run_op apply; rc=$?
  if [ "$rc" -eq 22 ] && [ "$(sig 900 $STAY)" = "$before" ]; then pass "bad oomprotect line refused: $bad"; else fail "bad oomprotect '$bad': rc $rc"; fi
done

# the acceptance check that goes with an apply or an off on a real host (scripts/host/io-shield-accept)
AC="$ROOT/scripts/host/io-shield-accept"
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"; fixture
run_ac() { IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_BIN="$SH" PATH="$B:$PATH" bash "$AC" "$@" > "$T/out" 2> "$T/err"; }
run_ac "$(id -u)" apply; rc=$?
ok "io-shield-accept apply: exit 0, and it names palace-daemon, qwen3-coder, familiar-loadguard and donkey-llm as untouched with their scores" '[ "$rc" -eq 0 ] && for u in "palace-daemon.service 310 -500" "qwen3-coder.service 311 -500" "familiar-loadguard.service 312 -800" "donkey-llm.service 313 -100"; do set -- $u; grep -q "untouched  $1 pid $2 $3" "$T/out" || exit 1; done'
ok "…and counts every other pre-existing negative score as untouched too" 'grep -q "ACCEPT: 9 negative score(s) existed before, all 9 unchanged; 3 scored in lead-spire.scope" "$T/out"'
run_ac "$(id -u)" off; rc=$?
ok "io-shield-accept off: exit 0, the same nine unchanged" '[ "$rc" -eq 0 ] && grep -q "all 9 unchanged" "$T/out"'
cat > "$T/evil-shield" <<EOF
#!/usr/bin/env bash
echo 0 > "$PR/310/oom_score_adj"
EOF
cat > "$T/reuse-shield" <<EOF
#!/usr/bin/env bash
# palace-daemon's process exits and its pid is taken by a new, unrelated process with score 0
echo "310 (new one) S 1 310 310 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 8888888 0 0" > "$PR/310/stat"; echo 0 > "$PR/310/oom_score_adj"
EOF
chmod +x "$T/reuse-shield"; fixture
IO_SHIELD_CONF="$T/conf" IO_SHIELD_PROC="$PR" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_BIN="$T/reuse-shield" bash "$AC" "$(id -u)" apply > "$T/out" 2>&1; rc=$?
ok "io-shield-accept follows the PROCESS (pid and start time): a pid taken by a new process is 'exited since', not a change" '[ "$rc" -eq 0 ] && grep -q "untouched  palace-daemon.service pid 310 -500 (the process has exited since)" "$T/out" && grep -q "^ACCEPT" "$T/out"'
chmod +x "$T/evil-shield"; fixture
IO_SHIELD_CONF="$T/conf" IO_SHIELD_PROC="$PR" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_BIN="$T/evil-shield" bash "$AC" "$(id -u)" apply > "$T/out" 2>&1; rc=$?
ok "io-shield-accept is not vacuous: a helper that DOES reset palace-daemon is exit 1 and named" '[ "$rc" -eq 1 ] && grep -q "CHANGED    palace-daemon.service pid 310 -500 → 0" "$T/out" && grep -q "^REJECT" "$T/out"'

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
