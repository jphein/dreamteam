#!/usr/bin/env bash
# dreamteam — tests for the lane slices (Flow row 7e039111; PR A of the #282 split, lead ruling 7128796049):
#   • scripts/lane-slice.sh       lanes.slice from config, lane sessions' processes moved into per-lane scopes with
#                                 their budgets, the lead and excluded sessions moved OUT, reconcile, rollback
#   • scripts/host-io-check.sh    CHECK <host>-io: a victim probe beside the pressure number
#   • the four USER unit files
# Nothing in this change runs as root: there is no root helper here, and the suite checks that none is shipped.
#
# Hermetic: /proc and the cgroup tree are fixture dirs through the scripts' seams; systemctl, systemd-run,
# busctl, tmux and ps are PATH stubs that LOG what they were asked to do, so the tests assert what the tools
# DID. Nothing here touches a real unit, cgroup or session. The one real thing is the probe: it reads and
# writes a 1 MiB file in the test's temp dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LS="$ROOT/scripts/lane-slice.sh"; HC="$ROOT/scripts/host-io-check.sh"
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
  *"-p InvocationID"*) cat "'"$T"'/inv/$3" 2>/dev/null || echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  *"-p Description"*) cat "'"$T"'/desc" 2>/dev/null ;;
  *"-p ControlGroup"*) cat "'"$T"'/cgof/$3" 2>/dev/null || cat "'"$T"'/controlgroup" 2>/dev/null ;;
  *"show nosuch.service -p LoadState"*) echo not-found ;;
  *"-p LoadState"*) echo loaded ;;
  *"set-property --runtime broken.service"*) exit 1 ;;
  *"-p IOWeight"*) echo 20 ;;
  *"--user is-active --quiet"*) [ -e "'"$T"'/up/$4" ] || { [ -e "'"$T"'/scope-up" ] && [ ! -e "'"$T"'/strict" ]; } ;;
  *"--user list-units lane-"*) cat "'"$T"'/lane-units" 2>/dev/null ;;
  *"--user list-units dreamteam-"*) cat "'"$T"'/fleet-units" 2>/dev/null ;;
  *"-p TasksCurrent"*) cat "'"$T"'/tasks" 2>/dev/null || echo 1 ;;
  *"--user daemon-reload"*) [ ! -e "'"$T"'/reload-fails" ] ;;
esac'

echo "── lane-slice.sh ────────────────────────────────────────────────"
ok "passes bash -n" 'bash -n "$LS"'
X="$T/xdg"; P="$T/proc"; mkdir -p "$X" "$P"
U="$X/systemd/user"
cfg() { printf '%s\n' "$1" > "$T/config.json"; }
run_ls() { LANE_SLICE_STATE="$T/state" LANE_SLICE_LOCK="$T/lane.lock" LANE_SLICE_UID=1000 DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" PATH="$B:$PATH" bash "$LS" "$@" > "$T/out" 2> "$T/err"; }
# sessions: lead (excluded), alpha (panes 100 → 101 → 102, and 110), beta (200, already in the slice), gamma (300 in a dreamteam scope)
# every discovery call (tmux, ps) notes whether the run's lock was HELD at that moment (xreview #288 r2 item 3)
LSTATE='if flock -n "'"$T"'/lane.lock" true 2>/dev/null; then echo free; else echo held; fi >> "'"$T"'/lockstate"'
stub tmux "$LSTATE"'
case "$*" in
  *list-sessions*) cat "'"$T"'/sessions" 2>/dev/null || printf "lead\nalpha\nbeta\ngamma\n" ;;
  *"list-panes -s -t =a.b"*) echo 400 ;;
  *"list-panes -s -t =a_b"*) echo 410 ;;
  *"list-panes -s -t =alpha"*) printf "100\n110\n" ;;
  *"list-panes -s -t =beta"*) echo 200 ;;
  *"list-panes -s -t =gamma"*) echo 300 ;;
  *"list-panes -s -t =lead"*) echo 900 ;;
esac'
stub ps "$LSTATE"'
printf "100 1\n101 100\n102 101\n110 1\n200 1\n300 1\n301 300\n900 1\n901 900\n555 1\n"'
stub busctl 'echo "busctl $*" >> "'"$LOG"'"; [ ! -e "'"$T"'/busctl-fails" ]'
stub systemd-run 'echo "systemd-run $*" >> "'"$LOG"'"; touch "'"$T"'/scope-up"
for a in "$@"; do case "$a" in --unit=*) mkdir -p "'"$T"'/up"; touch "'"$T"'/up/${a#--unit=}.scope" ;; esac; done
for a in "$@"; do case "$a" in --description=*) if [ -e "'"$T"'/desc-foreign" ]; then echo "someone else" > "'"$T"'/desc"; else printf "%s\n" "${a#--description=}" > "'"$T"'/desc"; fi ;; esac; done'
# the unit names: <prefix>-<safe name>-<8 hex of sha256 of the raw name>.scope
h8() { printf '%s' "$1" | sha256sum | cut -c1-8; }
UA="lane-alpha-$(h8 alpha).scope"; UB="lane-beta-$(h8 beta).scope"; UG="lane-gamma-$(h8 gamma).scope"; UL="lane-lead-$(h8 lead).scope"
UO="lane-oldsession-$(h8 oldsession).scope"; OL="out-lead-$(h8 lead).scope"; OA="out-alpha-$(h8 alpha).scope"
ST="$T/state"; INV0=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
own() { mkdir -p -m 700 "$ST"; local u; for u in "$@"; do echo "$INV0" > "$ST/scope.$u"; done; }      # as if this tool had created these scopes
disown_() { local u; for u in "$@"; do rm -f "$ST/scope.$u"; done; }
pcg() { mkdir -p "$P/$1"; echo "0::/user.slice/user-1000.slice/user@1000.service/$2" > "$P/$1/cgroup"; }
for p in 100 101 102 110 900 901 555; do pcg $p "app.slice/tmux-spawn-x.scope"; done
pcg 200 "lanes.slice/$UB"; pcg 300 "lanes.slice/$UG"; pcg 301 "app.slice/dreamteam-proj.scope"

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
ok "attach: alpha's panes AND their descendants go in one call (4 pids: 100 101 102 110)" 'grep -q "AttachProcessesToUnit ssau $UA / 4 100 101 102 110$" "$LOG"'
ok "attach: the scope is created inside lanes.slice, delegated" 'grep -q "systemd-run --user --quiet --scope --unit=${UA%.scope} --slice=lanes.slice -p Delegate=yes" "$LOG"'
ok "attach: the excluded session (the lead) is never moved" '! grep -q "lane-lead\|[ /]900\b\|[ /]901\b" "$LOG"'
ok "attach: a process already in the slice is not moved again" '! grep -q "lane-beta" "$LOG"'
ok "attach: a process in a dreamteam-*.scope stays there" '! grep "AttachProcessesToUnit" "$LOG" | grep -q " 301"'
ok "attach: an unrelated process of the user is never moved" '! grep "AttachProcessesToUnit" "$LOG" | grep -q " 555"'
touch "$T/busctl-fails"; run_ls attach; rc=$?; rm -f "$T/busctl-fails"
ok "attach: a move the manager refuses is exit 1 and says which session" '[ "$rc" -eq 1 ] && grep -q "could not move session alpha" "$T/err"'
printf '%s loaded active running x\n' "$UA" "$UO" > "$T/lane-units"; echo 1 > "$T/tasks"; own "$UO"; : > "$LOG"; run_ls attach
ok "attach: a lane scope whose session is gone and that holds only its anchor is stopped, by name" 'grep -qxF "systemctl --user stop $UO" "$LOG" && ! grep -q "stop $UA" "$LOG"'
echo 3 > "$T/tasks"; : > "$LOG"; own "$UO"; run_ls attach      # ours again (the run above stopped it and dropped its record)
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
pcg 900 "lanes.slice/$UL"; pcg 901 "lanes.slice/$UL"
cfg '{"lanes":{"enabled":true,"exclude":[],"lead":["lead"]}}'; : > "$LOG"; rm -f "$T/scope-up"; run_ls status
ok "status: a lead session found inside the slice is said so" 'grep -qx "session lead: NOT a lane, but 2 of 2 processes are in lanes.slice (the next attach moves them out)" "$T/out"'
run_ls attach; rc=$?
ok "attach: a .lanes.lead session's processes inside the slice are moved OUT, into a scope outside it" '[ "$rc" -eq 0 ] && grep -q "AttachProcessesToUnit ssau $OL / 2 900 901$" "$LOG" && grep -q "systemd-run --user --quiet --scope --unit=${OL%.scope} -p Delegate=yes" "$LOG" && ! grep -q -- "--unit=${OL%.scope} --slice" "$LOG"'
ok "…and it is never placed in a lane scope" '! grep -q "$UL / " "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; : > "$LOG"; run_ls attach
ok "the same for a session named only in .lanes.exclude" 'grep -q "AttachProcessesToUnit ssau $OL / 2 900 901$" "$LOG"'
touch "$T/busctl-fails"; run_ls attach; rc=$?; rm -f "$T/busctl-fails"
ok "a move OUT that fails is exit 1 and names the session" '[ "$rc" -eq 1 ] && grep -q "session lead is not a lane but its processes could not be moved out" "$T/err"'
pcg 900 "app.slice/tmux-spawn-lead.scope"; pcg 901 "app.slice/tmux-spawn-lead.scope"; : > "$LOG"; run_ls attach; run_ls status
ok "a lead that is outside the slice is left exactly where it is" '! grep -q "out-lead\| 900\| 901" "$LOG" && grep -qx "session lead: not a lane, outside the slice (2 processes)" "$T/out"'
ok "lane-slice marks and protects nothing (that is the watchdog's scope and the root helper)" '! grep -q "oomd_avoid\|setxattr\|oom_score" "$LS"'

# each lane's OWN budget, on its own scope, also for a lane that is already placed
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"perLane":{"memoryHigh":"5G","memorySwapMax":"1G"}}}'; : > "$LOG"; touch "$T/scope-up"; own "$UB" "$UG"; run_ls attach
ok "per-lane budget: set on the lane's own scope" 'grep -qxF "systemctl --user set-property --runtime $UA MemoryHigh=5G MemorySwapMax=1G" "$LOG"'
ok "…and on a lane that was placed earlier (a changed config reaches a running lane)" 'grep -qxF "systemctl --user set-property --runtime $UB MemoryHigh=5G MemorySwapMax=1G" "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"]}}'; : > "$LOG"; run_ls attach
ok "no perLane: no budget is set" '! grep -q "set-property --runtime lane-" "$LOG"'
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"perLane":{"memoryHigh":"5G; rm"}}}'; run_ls attach
ok "a bad per-lane value is refused" '[ "$?" -eq 2 ]'
rm -f "$T/scope-up"

# a fleet scope holding a lane's processes is not moved; it gets the lanes' weights
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"cpuWeight":40,"ioWeight":20}}'; : > "$LOG"; run_ls attach
ok "a dreamteam-*.scope with a lane's processes gets the slice's CPUWeight and IOWeight" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight=40 IOWeight=20" "$LOG"'
# ── xreview #288 r1 / Sen 09:46: what is NEVER moved or weighted, and the name that reaches systemctl ──────────
raw() { mkdir -p "$P/$1"; echo "0::$2" > "$P/$1/cgroup"; }      # a cgroup path given whole
restore() { for p in 100 101 102 110 900 901 555; do pcg $p "app.slice/tmux-spawn-x.scope"; done; pcg 200 "lanes.slice/$UB"; pcg 300 "lanes.slice/$UG"; pcg 301 "app.slice/dreamteam-proj.scope"; }
raw 301 "/system.slice/dreamteam-proj.scope"; : > "$LOG"; run_ls attach
ok "a lane's process under /system.slice, in a unit NAMED like a fleet scope: never weighted (no set-property for it), never moved, and said" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG" && ! grep "AttachProcessesToUnit" "$LOG" | grep -q " 301" && grep -q "pid 301 of session gamma is under system.slice" "$T/out"'
raw 110 "/system.slice/some.service"; : > "$LOG"; run_ls attach
ok "a lane's pane process that sits in a system service: NOT moved into the slice" '! grep "AttachProcessesToUnit" "$LOG" | grep -qw 110 && grep -q "pid 110 of session alpha is under system.slice" "$T/out" && grep "AttachProcessesToUnit" "$LOG" | grep -qw 100'
restore; pcg 102 "app.slice/lead-spire.scope"; : > "$LOG"; run_ls attach
ok "a lane's process found in the lead's scope (lead-spire.scope): never moved out of it" '! grep "AttachProcessesToUnit" "$LOG" | grep -qw 102 && grep -q "pid 102 of session alpha is in a lead scope" "$T/out"'
restore; raw 301 "/user.slice/user-1001.slice/user@1001.service/app.slice/dreamteam-proj.scope"; : > "$LOG"; run_ls attach
ok "a dreamteam-*.scope in ANOTHER user's manager: its name never reaches systemctl" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG" && grep -q "not a fleet scope of this user" "$T/out"'
for badname in 'dreamteam-a b.scope' 'dreamteam-x;id.scope' 'dreamteam-$(id).scope' 'dreamteam-.scope' "dreamteam-$(printf 'x%.0s' $(seq 1 90)).scope"; do
  restore; raw 301 "/user.slice/user-1000.slice/user@1000.service/app.slice/$badname"; : > "$LOG"; run_ls attach
  if ! grep "set-property" "$LOG" | grep -q "dreamteam-"; then pass "a cgroup path whose unit name is not a plain fleet-scope name (${badname:0:24}…): nothing is handed to set-property"; else fail "unvalidated unit name reached systemctl: $(grep set-property "$LOG")"; fi
done
restore; pcg 901 "app.slice/dreamteam-proj.scope"; : > "$LOG"; run_ls attach
ok "a fleet scope that ALSO holds the lead's processes (the lead is excluded): NOT given the lanes' weights, and said" '! grep -q "set-property --runtime dreamteam-proj.scope CPUWeight=40" "$LOG" && grep -q "fleet scope dreamteam-proj.scope also holds the lead" "$T/out"'
restore; : > "$LOG"; run_ls attach
ok "(control: with the fixture restored the fleet scope gets its weights again)" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight=40 IOWeight=20" "$LOG"'
# ONE lock over discovery and mutation
( exec 7>"$T/lane.lock"; flock 7; sleep 9 ) & lh=$!; sleep 0.4; : > "$LOG"      # held through all five calls below (each waits 1 s at most)
LANE_SLICE_LOCK_WAIT=1 run_ls attach; rc=$?
ok "attach while another run holds the lock past its wait: exit 75 and NOTHING was looked at or changed" '[ "$rc" -eq 75 ] && [ ! -s "$LOG" ] && grep -q "another lane-slice run holds" "$T/err"'
LANE_SLICE_LOCK_WAIT=1 run_ls install; rc=$?; ok "install while the lock is held: exit 75, nothing done" '[ "$rc" -eq 75 ] && [ ! -s "$LOG" ]'
LANE_SLICE_LOCK_WAIT=1 run_ls uninstall; rc=$?; ok "uninstall while the lock is held: exit 75, nothing done" '[ "$rc" -eq 75 ] && [ ! -s "$LOG" ]'
LANE_SLICE_LOCK_WAIT=1 run_ls status; rc=$?; ok "status takes no lock: it answers while the lock is held" '[ "$rc" -eq 0 ] && grep -q "^slice lanes.slice" "$T/out"'
: > "$LOG"; LANE_SLICE_LOCK_WAIT=1 run_ls attach --hook; rc=$?; ok "the hook form while the lock is held: still 0, still silent, nothing done" '[ "$rc" -eq 0 ] && [ ! -s "$T/out" ] && [ ! -s "$LOG" ]'
wait "$lh" 2>/dev/null; : > "$LOG"; run_ls attach; rc=$?
ok "once the lock is free attach works again" '[ "$rc" -eq 0 ] && grep -q "set-property --runtime dreamteam-proj.scope" "$LOG"'
ok "the lock is taken with flock -o, so nothing the script starts inherits it, and it covers install, attach and uninstall" 'grep -q "LANE_SLICE_LOCKED=1 flock -o -E 75 -w" "$LS" && grep -q "if \[ \"\$MODE\" != status \] && \[ -z \"\${LANE_SLICE_LOCKED:-}\" \]; then" "$LS"'
run_ls status
ok "status counts a lane's processes that sit in a fleet scope" 'grep -q "^session gamma: 1 of 2 processes in lanes.slice, 1 in a fleet scope (weights only)$" "$T/out"'

# the SessionStart form: silent, exit 0 whatever happens
touch "$T/busctl-fails"; : > "$LOG"; out=$(LANE_SLICE_STATE="$T/state" LANE_SLICE_LOCK="$T/lane.lock" DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" PATH="$B:$PATH" bash "$LS" attach --hook 2>&1); rc=$?; rm -f "$T/busctl-fails"
ok "attach --hook: silent and exit 0 even when a move fails, and it did try (through its own time-box)" '[ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q "AttachProcessesToUnit ssau $UA" "$LOG"'
# a tmux that never answers cannot hold a session start: the hook form is killed at its bound and still exits 0
mkdir -p "$T/slow"; printf '#!/bin/sh\nsleep 30\n' > "$T/slow/tmux"; chmod +x "$T/slow/tmux"
t0=$(date +%s); LANE_SLICE_STATE="$T/state" LANE_SLICE_LOCK="$T/lane.lock" DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_HOST=test-nooverlay XDG_CONFIG_HOME="$X" DREAMTEAM_PROC="$P" DREAMTEAM_CGROUP_ROOT="$T/cg" LANE_SLICE_HOOK_SECS=2 PATH="$T/slow:$B:$PATH" bash "$LS" attach --hook; rc=$?; t1=$(date +%s)
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
LC="$T/cg/$UM/lanes.slice/$UA"; mkdir -p "$LC"; printf '100\n101\n777\n' > "$LC/cgroup.procs"; echo "/$UM/lanes.slice/$UA" > "$T/controlgroup"
mkdir -p "$P/777"; echo sleep > "$P/777/comm"; printf 'sleep\0infinity\0' > "$P/777/cmdline"; for p in 100 101; do echo claude > "$P/$p/comm"; printf 'claude\0' > "$P/$p/cmdline"; done
printf '%s loaded active running x\n' "$UA" > "$T/lane-units"; printf 'dreamteam-proj.scope loaded active running x\ndreamteam-leadonly.scope loaded active running x\ndreamteam-other.scope loaded active running x\n' > "$T/fleet-units"
mkdir -p "$T/cgof"; echo "/user.slice/user-1000.slice/user@1000.service/app.slice/dreamteam-proj.scope" > "$T/cgof/dreamteam-proj.scope"
echo '{ this is not json' > "$T/config.json"; : > "$LOG"; rm -f "$T/scope-up"; run_ls uninstall; rc=$?
ok "uninstall with an unreadable config still runs (exit 0)" '[ "$rc" -eq 0 ]'
ok "uninstall: the attach timer is disabled" 'grep -qxF "systemctl --user disable --now dreamteam-lane-slice.timer" "$LOG"'
ok "uninstall: each lane's processes are moved out of the slice (the anchor is not)" 'grep -q "AttachProcessesToUnit ssau $OA / 2 100 101$" "$LOG" && ! grep "AttachProcessesToUnit" "$LOG" | grep -q " 777"'
ok "uninstall: the lane scope is stopped, by name" 'grep -qxF "systemctl --user stop $UA" "$LOG"'
ok "uninstall: the weights THIS TOOL set on a fleet scope are reset (it holds the record of that start of it)" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight= IOWeight=" "$LOG" && [ ! -e "$ST/weight.dreamteam-proj.scope" ]'
ok "uninstall: a lead-only fleet scope and an unrelated one, both running, are NOT touched: nothing is listed from the manager, nothing set on them" '! grep -q "dreamteam-leadonly\|dreamteam-other" "$LOG" && ! grep -q "list-units dreamteam-" "$LOG"'
ok "uninstall: the slice file and drop-ins are gone" '[ ! -e "$U/lanes.slice" ] && [ ! -e "$U/a-gate.service.d/20-lanes-slice.conf" ]'
touch "$T/busctl-fails"; own "$UA"; cfg '{"lanes":{"enabled":true,"exclude":[]}}'; run_ls install; echo '{ broken' > "$T/config.json"; : > "$LOG"; run_ls uninstall; rc=$?; rm -f "$T/busctl-fails"
ok "uninstall: a lane that cannot be moved out is NOT stopped (its processes would be ended), exit 1" '[ "$rc" -eq 1 ] && ! grep -q "stop $UA" "$LOG"'
rm -f "$T/lane-units" "$T/fleet-units" "$T/controlgroup"; rm -rf "$T/cg/$UM/lanes.slice"

echo "── ownership is a record, never a name (xreview #288 r2; lead 17:02 Tue) ─────────────────"
# strict: a unit is active only when it was started (by the systemd-run stub) or marked up by name, never "all of them"
fresh() { rm -rf "$ST" "$T/inv" "$T/cgof" "$T/desc" "$T/desc-foreign" "$T/sessions" "$T/lane-units" "$T/fleet-units" "$T/controlgroup" "$T/up"; rm -f "$T/scope-up"; restore; mkdir -p "$T/inv" "$T/cgof" "$T/up"; touch "$T/strict"; : > "$LOG"; }
up() { local u; for u in "$@"; do touch "$T/up/$u"; done; }
FC="/user.slice/user-1000.slice/user@1000.service/app.slice"
cfg '{"lanes":{"enabled":true,"exclude":["lead"],"cpuWeight":40,"ioWeight":20,"perLane":{"memoryHigh":"5G"}}}'
# (1) the rollback and the fleet scopes
fresh; run_ls attach
ok "attach records the fleet scope it weights: the InvocationID of that start, written before the weights" '[ "$(cat "$ST/weight.dreamteam-proj.scope")" = "$INV0" ] && grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight=40 IOWeight=20" "$LOG"'
ok "attach records each scope it creates" '[ "$(cat "$ST/scope.$UA")" = "$INV0" ]'
echo "$FC/dreamteam-proj.scope" > "$T/cgof/dreamteam-proj.scope"; echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$T/inv/dreamteam-proj.scope"; : > "$LOG"; run_ls uninstall
ok "rollback: a fleet scope that was STARTED AGAIN since we weighted it (another InvocationID) is not reset; the stale record goes" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG" && [ ! -e "$ST/weight.dreamteam-proj.scope" ] && grep -q "not the scope this tool weighted any more" "$T/out"'
fresh; run_ls attach; echo "/system.slice/dreamteam-proj.scope" > "$T/cgof/dreamteam-proj.scope"; : > "$LOG"; run_ls uninstall
ok "rollback: a recorded fleet scope whose cgroup is under /system.slice is not set" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG" && grep -q "not inside this user.s manager" "$T/out"'
fresh; run_ls attach; echo "/user.slice/user-1001.slice/user@1001.service/app.slice/dreamteam-proj.scope" > "$T/cgof/dreamteam-proj.scope"; : > "$LOG"; run_ls uninstall
ok "rollback: …nor one in another user's manager" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG"'
fresh; mkdir -p -m 700 "$ST"; for bad in 'dreamteam-x;id.scope' 'dreamteam-a b.scope' 'lead-spire.scope' 'octoprint.service'; do echo "$INV0" > "$ST/weight.$bad"; done; echo "$FC/any.scope" > "$T/controlgroup"; : > "$LOG"; run_ls uninstall
ok "rollback: a weight record whose NAME is not a plain fleet-scope name (also lead-spire.scope, a service) hands nothing to set-property" '! grep -q "set-property" "$LOG"'
fresh; mkdir -p -m 700 "$ST"; echo "$FC/dreamteam-lead.scope" > "$T/cgof/dreamteam-lead.scope"; echo "$INV0" > "$T/planted"; ln -s "$T/planted" "$ST/weight.dreamteam-lead.scope"; : > "$LOG"; run_ls uninstall
ok "rollback: a weight record that is a symlink is not believed" '! grep -q "set-property" "$LOG"'
fresh; mkdir -p "$T/elsewhere"; echo "$INV0" > "$T/elsewhere/weight.dreamteam-lead.scope"; echo "$FC/dreamteam-lead.scope" > "$T/cgof/dreamteam-lead.scope"; ln -s "$T/elsewhere" "$ST"; : > "$LOG"; run_ls uninstall; rm -f "$ST"
ok "rollback: a state directory that is a symlink is not believed" '! grep -q "set-property" "$LOG"'
# the lead comes to live in a fleet scope we had weighted: our weights are taken back, and only ours
fresh; run_ls attach; echo "$FC/dreamteam-proj.scope" > "$T/cgof/dreamteam-proj.scope"; pcg 901 "app.slice/dreamteam-proj.scope"; : > "$LOG"; run_ls attach
ok "a fleet scope WE weighted that now also holds the lead: the weights are taken back and the record dropped" 'grep -qxF "systemctl --user set-property --runtime dreamteam-proj.scope CPUWeight= IOWeight=" "$LOG" && [ ! -e "$ST/weight.dreamteam-proj.scope" ]'
: > "$LOG"; run_ls attach
ok "…and a lead-shared fleet scope we hold NO record for is not written at all (not weighted, not reset)" '! grep -q "set-property --runtime dreamteam-proj.scope" "$LOG"'
# (2) a lane scope is ours only by record
fresh; up "$UA"; run_ls attach; rc=$?
ok "a RUNNING $UA that this tool did not create: REFUSED (exit 1, said), no process moved into it, none started, no budget set on it" '[ "$rc" -eq 1 ] && grep -q "$UA is running and was NOT created by this tool" "$T/err" && ! grep -q "AttachProcessesToUnit ssau $UA" "$LOG" && ! grep -q "systemd-run" "$LOG" && ! grep -q "set-property --runtime $UA" "$LOG"'
fresh; up "$UA"; own "$UA"; echo cccccccccccccccccccccccccccccccc > "$T/inv/$UA"; run_ls attach; rc=$?
ok "…the same when our record is of an EARLIER start of that name (another InvocationID)" '[ "$rc" -eq 1 ] && ! grep -q "AttachProcessesToUnit ssau $UA" "$LOG" && ! grep -q "set-property --runtime $UA" "$LOG"'
fresh; up "$UA"; own "$UA"; run_ls attach; rc=$?
ok "(control: with a record of this start it is used: moved into, budget set)" '[ "$rc" -eq 0 ] && grep -q "AttachProcessesToUnit ssau $UA / 4 100 101 102 110$" "$LOG" && grep -qxF "systemctl --user set-property --runtime $UA MemoryHigh=5G" "$LOG"'
# a running, unowned unit of the lane's name whose processes are ALREADY in it (nothing to move): still no budget on it
fresh; up "$UA"; for q in 100 101 102 110; do pcg $q "lanes.slice/$UA"; done; run_ls attach
ok "a running $UA we did not create, holding the lane's processes already: no budget is set on it" '! grep -q "set-property --runtime $UA" "$LOG"'
fresh; touch "$T/desc-foreign"; run_ls attach; rc=$?
ok "a unit of that name that came up WITHOUT this run's token (started by someone else in the same moment): refused, not recorded, nothing moved in" '[ "$rc" -eq 1 ] && [ ! -e "$ST/scope.$UA" ] && ! grep -q "AttachProcessesToUnit ssau $UA" "$LOG" && grep -q "did not come up as the scope this run started" "$T/err"'
fresh; run_ls attach
ok "the scope this tool starts carries a random token in its Description" 'grep -Eq "systemd-run --user --quiet --scope --unit=${UA%.scope} --slice=lanes.slice -p Delegate=yes --description=dreamteam lane-slice [0-9a-f]{16} sleep infinity" "$LOG"'
# a foreign lane-*.scope and the rollback, and the orphan sweep
fresh; up "$UA" lane-foreign-12345678.scope "$UO"; own "$UA"; printf '%s loaded active running x\n' "$UA" "lane-foreign-12345678.scope" "$UO" > "$T/lane-units"; echo 1 > "$T/tasks"
LCF="$T/cg/$UM/lanes.slice/x"; mkdir -p "$LCF"; printf '100\n101\n' > "$LCF/cgroup.procs"; echo "/$UM/lanes.slice/x" > "$T/controlgroup"; for q in 100 101; do echo claude > "$P/$q/comm"; printf 'claude\0' > "$P/$q/cmdline"; done
: > "$LOG"; run_ls attach
ok "attach's orphan sweep: a lane-*.scope this tool did not create is never stopped, though its session is gone and it holds one task" '! grep -q "stop lane-foreign-12345678.scope" "$LOG" && ! grep -q "stop $UO" "$LOG"'
: > "$LOG"; run_ls uninstall
ok "rollback: a FOREIGN lane-*.scope is left alone: nothing moved out of it, not stopped, and said" '! grep -q "lane-foreign-12345678\|out-foreign" "$LOG" && ! grep -q "stop $UO" "$LOG" && grep -q "lane-foreign-12345678.scope was not created by this tool" "$T/out"'
ok "…while the lane scope that IS ours is emptied and stopped in the same run" 'grep -q "AttachProcessesToUnit ssau $OA / 2 100 101$" "$LOG" && grep -qxF "systemctl --user stop $UA" "$LOG" && [ ! -e "$ST/scope.$UA" ]'
rm -rf "$T/cg/$UM/lanes.slice"
# two session names that safe() folds to the same text get two units
fresh; printf 'a.b\na_b\n' > "$T/sessions"; pcg 400 "app.slice/tmux-spawn-x.scope"; pcg 410 "app.slice/tmux-spawn-x.scope"; run_ls attach
ok "sessions a.b and a_b: two different units (the hash is of the RAW name), one process each" '[ "$(grep -o "AttachProcessesToUnit ssau lane-a_b-[0-9a-f]\{8\}.scope / 1 4[01]0" "$LOG" | sort -u | wc -l)" -eq 2 ] && [ "$(grep -o "ssau lane-a_b-[0-9a-f]\{8\}.scope" "$LOG" | sort -u | wc -l)" -eq 2 ]'
rm -rf "$P/400" "$P/410"
# (3) discovery happens INSIDE the lock: the tmux and ps stubs noted the lock's state each time they were called
fresh; : > "$T/lockstate"; run_ls attach
ok "attach: every tmux and ps call found the lock HELD ($(wc -l < "$T/lockstate") calls)" '[ "$(wc -l < "$T/lockstate")" -ge 3 ] && ! grep -qv "^held$" "$T/lockstate"'
: > "$T/lockstate"; run_ls status
ok "(control: status takes no lock, and the same stubs say so)" '[ -s "$T/lockstate" ] && ! grep -qv "^free$" "$T/lockstate"'
fresh; rm -f "$T/strict"

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
ok "the probe's unit is at normal priority and outside the lanes slice" '! grep -qE "^(Nice|IOSchedulingClass|Slice)=" "$ROOT/systemd/dreamteam-host-io.service"'
ok "each timer has its service and a CHECKS.md row" 'for u in dreamteam-host-io dreamteam-lane-slice; do [ -f "$ROOT/systemd/$u.service" ] && [ -f "$ROOT/systemd/$u.timer" ] || exit 1; done; grep -q "dreamteam-host-io.timer" "$ROOT/docs/CHECKS.md" && grep -q "dreamteam-lane-slice.timer" "$ROOT/docs/CHECKS.md"'
ok "NO root helper ships with this change: no scripts/host/io-shield*, no io-shield system unit, no user@ drop-in" '[ -z "$(ls "$ROOT"/scripts/host/io-shield* "$ROOT"/systemd/system/dreamteam-io-shield.* "$ROOT"/systemd/system/user@.service.d/* 2>/dev/null)" ]'
ok "…and neither script calls sudo, writes under /etc or /sys, or sets a SYSTEM unit's property" '! grep -nE "(^|[^[:alnum:]_])sudo |> */etc/|> */sys/|systemctl set-property|systemctl +(start|enable|daemon-reload)" "$LS" "$HC" | grep -v "^[^:]*:[0-9]*:[[:space:]]*#"'
if command -v systemd-analyze > /dev/null 2>&1; then
  V="$T/v"; mkdir -p "$V"
  for f in "$ROOT"/systemd/dreamteam-host-io.* "$ROOT"/systemd/dreamteam-lane-slice.*; do sed -E 's|^ExecStart=.*|ExecStart=/bin/true|; s|^WorkingDirectory=.*||' "$f" > "$V/$(basename "$f")"; done
  if systemd-analyze --user verify "$V"/dreamteam-host-io.timer "$V"/dreamteam-lane-slice.timer > "$T/v.out" 2>&1; then pass "systemd-analyze accepts the four user unit files"
  else fail "unit files rejected: $(grep -v '^$' "$T/v.out" | head -3)"; fi
fi

echo ""
echo "lane-slice: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
