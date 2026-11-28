#!/usr/bin/env bash
# dreamteam — tests for the ROOT helper io-shield and its acceptance script (PR B of the #282 split; lead ruling
# 7128796049 on #282, Flow row f72945bc):
#   • scripts/host/io-shield         io.cost latency targets per device, IOWeight on named units and containers,
#                                    and the OOM score of the lead's own unit, kept in a ledger
#   • scripts/host/io-shield-accept  the supervised acceptance run: fails on an absent named service, a restart,
#                                    any changed score or cgroup, or zero protected leads
#   • the two system unit files and the user@ drop-in
#
# Hermetic: io.cost.qos, /sys/block, /proc, the cgroup tree and the ledger are fixture dirs through the scripts'
# seams; systemctl and docker are PATH stubs that LOG what they were asked to do. Nothing here touches a real unit,
# cgroup, score or process, and nothing here runs as root.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SH="$ROOT/scripts/host/io-shield"
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
  *"show failing.service -p LoadState"*) exit 1 ;;
  *"show nosuch.service -p LoadState"*) printf "LoadState=not-found\nIOWeight=[not set]\n" ;;
  *"-p LoadState"*) printf "LoadState=loaded\nIOWeight=%s\n" "$(cat "'"$T"'/wnow/$2" 2>/dev/null || echo "[not set]")" ;;
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
run_sh() { rm -f "$T/run0/dreamteam-io-shield.off"; IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_RUN_DIR="$T/run0" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" python3 -I "$SH" "$@" > "$T/out" 2> "$T/err"; }

echo "── io-shield ────────────────────────────────────────────────────"
# production apply needs the acceptance flag for THIS helper (its sha256); the tests hold one, and test its absence below
export IO_SHIELD_ACCEPTED="$T/accepted"
accept_flag() { printf 'sha256=%s\n' "$(sha256sum "$SH" | cut -d' ' -f1)" > "$T/accepted"; chmod 600 "$T/accepted"; }
accept_flag
ok "the helper compiles (python3 -I), and is no shell script any more" 'python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SH" && head -n 1 "$SH" | grep -qx "#!/usr/bin/python3 -I"'
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
IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" PATH="$B:$PATH" python3 -I "$SH" apply > /dev/null 2>&1; rc=$?
if [ "$(id -u)" -ne 0 ]; then ok "apply without root is exit 2" '[ "$rc" -eq 2 ]'; fi
IO_SHIELD_CONF="$T/absent" IO_SHIELD_ASSUME_ROOT=1 python3 -I "$SH" apply > /dev/null 2>&1; ok "no config is exit 2" '[ "$?" -eq 2 ]'
python3 -I "$SH" > /dev/null 2>&1; ok "no argument is exit 22" '[ "$?" -eq 22 ]'
python3 -I "$SH" bogus > /dev/null 2>&1; ok "an unknown verb is exit 22" '[ "$?" -eq 22 ]'

UM="user.slice/user-$(id -u).slice/user@$(id -u).service"

echo "── oomprotect: scores only the lead unit, records first, writes back ONLY while still in that unit (PR B) ──"
# THE RULES under test (lead ruling on #282, 2026-11-24):
#   • a negative score this helper did not write is NEVER written to, anywhere;
#   • a process it DID score is written back only by `off`, and only while its cgroup STILL IS the lead unit of its
#     record. A recorded process found anywhere else, /system.slice first of all, is never written: its record is
#     retired to <ledger>/left/;
#   • apply, off and on share one lock.
# "Untouched" is observed, not inferred from the final value: each such fixture file's content, mtime and inode
# are compared before and after (sig), so a write of the very same value would be seen.
LD="$T/cg/$UM/app.slice/lead-spire.scope"; XD="$T/cg/$UM/app.slice/tmux-spawn-x.scope"
mkdir -p "$LD/sub" "$XD" "$T/cg/$UM/app.slice/lead-spire.scope-x" "$T/cg/$UM/lanes.slice/lead-spire.scope" "$T/cg/system.slice/adopted.service" "$T/run"
PR="$T/fproc"; LG="$T/run/dreamteam-io-shield"
fp() {  # fp <pid> <cgroup path as in /proc> <score> [starttime]
  mkdir -p "$PR/$1"; echo "${3:-0}" > "$PR/$1/oom_score_adj"; echo "0::$2" > "$PR/$1/cgroup"
  echo "$1 (fix ture) S 1 $1 $1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 ${4:-5000$1} 0 0" > "$PR/$1/stat"
}
scores() { local p o=""; for p in "$@"; do o="$o$(cat "$PR/$p/oom_score_adj") "; done; printf '%s' "$o"; }
sig() { local p; for p in "$@"; do printf '%s:%s:%s ' "$p" "$(cat "$PR/$p/oom_score_adj")" "$(stat -c '%y %i' "$PR/$p/oom_score_adj")"; done; }
# never to be written: a lane's, lookalike units, a login session with its own negative score, an unrelated
# user-slice process with one, five system services running as the user with their units' own scores (familiar's
# four and serialhub's octoprint), and two INSIDE the lead unit that already had one
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
run_op() { IO_SHIELD_THROWAWAY_CONF="$T/tconf" IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" python3 -I "$SH" "$@" > "$T/out" 2> "$T/err"; }
moved() { echo "0::$2" > "$PR/$1/cgroup"; }   # the process now sits in another cgroup (its score file is not touched)
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"

fixture; before=$(sig $STAY); run_op apply; rc=$?
ok "apply: the unit's processes with a non-negative score get it (sub-cgroup too)" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "-500 -500 -500 " ] && grep -q "3 process(es) scored -500 and recorded" "$T/out"'
ok "apply: a record per scored process: pid, start time, unit, score, the score it had before" 'grep -qx "start=5000900 unit=lead-spire.scope score=-500 prev=0 uid=$(id -u)" "$LG/900" && grep -q "prev=200 " "$LG/901" && [ "$(ls "$LG" | tr "\n" " ")" = "900 901 902 " ]'
ok "apply: NOTHING else is written to: lane, lookalike units, the login session's -700, an unrelated -500 in the user slice, palace-daemon, qwen3-coder, familiar-loadguard, donkey-llm, octoprint (content, mtime, inode)" '[ "$(sig $STAY)" = "$before" ]'
ok "apply: inside the unit, a process that already had a negative score is left as found, unrecorded" '[ "$(scores 903 904)" = "-900 -500 " ] && [ ! -e "$LG/903" ] && [ ! -e "$LG/904" ] && grep -q "2 in the unit left as found" "$T/out"'
all=$(sig 900 901 902 $STAY); run_op apply
ok "a second apply writes to nobody at all" '[ "$(sig 900 901 902 $STAY)" = "$all" ] && grep -q "0 process(es) scored" "$T/out"'

# THE RULING'S TEST: a process WE scored and recorded now sits under /system.slice. It is left alone by apply AND off.
moved 901 /system.slice/adopted.service; printf '900\n903\n904\n' > "$LD/cgroup.procs"; all=$(sig 900 901 902 $STAY); run_op apply; rc=$?
ok "a RECORDED process that now sits in /system.slice: apply does NOT write it (content, mtime, inode), nor anyone else" '[ "$rc" -eq 0 ] && [ "$(sig 900 901 902 $STAY)" = "$all" ] && [ "$(scores 901)" = "-500 " ]'
ok "…its record is RETIRED to left/ (kept for a person, never acted on), and the run says so" '[ ! -e "$LG/901" ] && [ -f "$LG/left/901.5000901" ] && grep -q "1 of ours have LEFT the unit holding our score and were NOT written" "$T/out"'
run_op status
ok "…status names it: the pid, the score it still holds, and where it is" 'grep -q "left the unit holding our score, NOT written:901=-500(adopted.service)" "$T/out"'
all=$(sig 900 901 902 $STAY); cp -r "$LG" "$T/lg.b"; run_op status
ok "…and status itself wrote nothing, not even the ledger" '[ "$(sig 900 901 902 $STAY)" = "$all" ] && diff -r "$LG" "$T/lg.b" > /dev/null'
rm -rf "$T/lg.b"
s901=$(sig 901 $STAY); run_op off; rc=$?
ok "…OFF does not write it either: under /system.slice a score is never written back, recorded or not" '[ "$rc" -eq 0 ] && [ "$(sig 901 $STAY)" = "$s901" ]'
ok "…while off DID put back the two recorded processes still in the unit (0 and 0)" '[ "$(scores 900 902)" = "0 0 " ] && grep -q "2 of OUR recorded score(s), each still in its lead unit, put back" "$T/out"'
# the same for every OTHER place a recorded process can be found: none is written, by apply or by off
for where in "/$UM/app.slice/tmux-spawn-x.scope" "/$UM/app.slice/lead-spire.scope-x" "/$UM/lanes.slice/lead-spire.scope" "/user.slice/user-$(id -u).slice/session-4.scope" "/$UM/app.slice" "/system.slice/lead-spire.scope" "/system.slice"; do
  fixture; run_op apply; moved 900 "$where"; printf '901\n903\n904\n' > "$LD/cgroup.procs"; s=$(sig 900 $STAY)
  run_op apply; a=$(sig 900 $STAY); run_op off
  if [ "$a" = "$s" ] && [ "$(sig 900 $STAY)" = "$s" ] && [ "$(scores 900)" = "-500 " ] && [ ! -e "$LG/900" ]; then pass "a recorded process found in $where: never written, by apply or by off; its record retired"
  else fail "recorded process in $where was written: $(scores 900)"; fi
done
fixture; run_op apply; moved 900 /system.slice/adopted.service; printf '901\n903\n904\n' > "$LD/cgroup.procs"; run_op apply; rm -rf "$PR/900"; run_op apply
ok "a retired record is forgotten once its process has exited" '[ -z "$(ls "$LG/left" 2>/dev/null)" ]'
fixture; run_op apply; moved 900 /system.slice/adopted.service; run_op apply; moved 900 "/$UM/app.slice/lead-spire.scope"; printf '900\n901\n903\n904\n' > "$LD/cgroup.procs"; s=$(sig 900); run_op apply; run_op off
ok "a retired process that comes BACK into the unit is not written either (it holds a negative score we have no live record of)" '[ "$(sig 900)" = "$s" ]'

# records that are no longer about the same thing are dropped without a write
fixture; run_op apply
echo "900 (other) S 1 900 900 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 7777777 0 0" > "$PR/900/stat"; s900=$(sig 900); run_op off
ok "a record whose pid now is ANOTHER process (start time differs): off does not write it, the record goes" '[ "$(sig 900)" = "$s900" ] && [ ! -e "$LG/900" ]'
fixture; run_op apply; echo -300 > "$PR/902/oom_score_adj"; sleep 0.02; s902=$(sig 902); run_op off
ok "a recorded process whose score someone has CHANGED since is not ours any more: off does not write it" '[ "$(sig 902)" = "$s902" ] && [ ! -e "$LG/902" ]'
fixture; run_op apply; rm -rf "$PR/901"; run_op apply; rc=$?
ok "a recorded process that has exited: record dropped, no error" '[ "$rc" -eq 0 ] && [ ! -e "$LG/901" ]'

# off: every record still in its unit is undone, and STILL nothing unrecorded is touched
printf 'device nvme0n1\nunit syncthing@jp.service 20\ndocker mempalace-db 20\noomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
fixture; run_op apply; before=$(sig $STAY); : > "$LOG"; run_op off; rc=$?
ok "off: each score WE recorded, still in the unit, goes back to what it was (0, 200, 0); the ledger is empty; a stamp is written" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "0 200 0 " ] && [ -z "$(ls "$LG" | grep -v "^left$")" ] && [ -e "$T/run/dreamteam-io-shield.off" ]'
ok "off: the login session's -700, the user-slice -500, the five system services and the two unrecorded in-unit scores are NOT written" '[ "$(sig $STAY)" = "$before" ]'
ok "off: io.cost disabled, unit and container weights reset" 'grep -qxF "259:0 enable=0" "$T/qos" && grep -qxF "systemctl set-property --runtime syncthing@jp.service IOWeight=" "$LOG" && grep -qxF "systemctl set-property --runtime docker-'"$ID"'.scope IOWeight=" "$LOG"'
all=$(sig 900 901 902 $STAY); : > "$LOG"; run_op apply; rc=$?
ok "after off, the timer's apply does NOTHING" '[ "$rc" -eq 0 ] && grep -q "nothing applied" "$T/out" && [ "$(sig 900 901 902 $STAY)" = "$all" ] && [ ! -s "$LOG" ]'
run_op status; ok "status says it is off" 'grep -q "^OFF: " "$T/out"'
run_op on; run_op apply
ok "on, then apply: applied again" '[ ! -e "$T/run/dreamteam-io-shield.off" ] && grep -q "^259:0 enable=1" "$T/qos" && [ "$(scores 900)" = "-500 " ]'
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"

echo "── one lock for apply, off and on ───────────────────────────────"
LK="$T/run/dreamteam-io-shield.lock"
fixture; ( exec 7>"$LK"; flock 7; sleep 8 ) & lh=$!; sleep 0.4; all=$(sig 900 901 902 $STAY)      # held through the four calls below (each waits 1 s at most)
IO_SHIELD_LOCK_WAIT=1 run_op apply; rc=$?
ok "apply while another run holds the lock past its wait: exit 75, NOTHING written, no ledger" '[ "$rc" -eq 75 ] && [ "$(sig 900 901 902 $STAY)" = "$all" ] && [ ! -e "$LG" ] && grep -q "another io-shield run holds" "$T/err"'
IO_SHIELD_LOCK_WAIT=1 run_op off; rc=$?
ok "off while the lock is held: exit 75, and NO stamp was written (the stamp is inside the lock)" '[ "$rc" -eq 75 ] && [ ! -e "$T/run/dreamteam-io-shield.off" ]'
touch "$T/run/dreamteam-io-shield.off"; IO_SHIELD_LOCK_WAIT=1 run_op on; rc=$?
ok "on while the lock is held: exit 75, the stamp still there" '[ "$rc" -eq 75 ] && [ -e "$T/run/dreamteam-io-shield.off" ]'
rm -f "$T/run/dreamteam-io-shield.off"
IO_SHIELD_LOCK_WAIT=1 run_op status; rc=$?
ok "status takes no lock: it answers while the lock is held" '[ "$rc" -eq 0 ] && grep -q "oomprotect uid" "$T/out"'
wait "$lh" 2>/dev/null
# a run that WAITS: nothing is written while the lock is held, everything after
fixture; ( exec 7>"$LK"; flock 7; sleep 2 ) & lh=$!; sleep 0.4
( IO_SHIELD_LOCK_WAIT=20 IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" python3 -I "$SH" apply > "$T/out.w" 2>&1 ) & ap=$!
sleep 0.8; mid=$(scores 900 901 902); wait "$lh" 2>/dev/null; wait "$ap"; rc=$?
ok "a run that waits for the lock has written NOTHING while it is held, and applies once it is free" '[ "$mid" = "0 200 0 " ] && [ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "-500 -500 -500 " ]'
# two applies and an off at the same moment: whatever the order, the end state is one of the two serial ones, and
# no score is left behind without a record (the failure the lock exists for)
for round in 1 2 3; do
  fixture
  for v in apply apply off; do ( IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" python3 -I "$SH" "$v" > /dev/null 2>&1 ) & done; wait
  orphan=0; for p in 900 901 902; do if [ "$(cat "$PR/$p/oom_score_adj")" = -500 ] && [ ! -e "$LG/$p" ]; then orphan=$((orphan + 1)); fi; done
  st="$(scores 900 901 902)"
  if [ "$orphan" -eq 0 ] && { [ "$st" = "0 200 0 " ] || [ "$st" = "-500 -500 -500 " ]; }; then pass "overlapping apply, apply and off (round $round): a serial end state ($st), and no score without its record"
  else fail "overlap round $round: scores '$st', $orphan score(s) without a record"; fi
done
ok "the lock's descriptor is close-on-exec: nothing the helper starts holds it" 'grep -q "os.open(LOCKF, os.O_WRONLY | os.O_CREAT | os.O_CLOEXEC" "$SH"'

echo "── the ledger is not something a user can plant ─────────────────"
fixture; mkdir -p -m 700 "$T/elsewhere"; chmod 700 "$T/elsewhere"; rm -rf "$T/elsewhere"/*; ln -s "$T/elsewhere" "$LG"; before=$(sig 900 901 902 $STAY); run_op apply
rc=$?; ok "a ledger path that is a SYMLINK is not trusted: exit 1, nothing is scored, nothing undone" '[ "$rc" -eq 1 ] && [ "$(sig 900 901 902 $STAY)" = "$before" ] && [ -z "$(ls "$T/elsewhere")" ]'
rm -f "$LG"
fixture; mkdir -p "$LG"; chmod 777 "$LG"; before=$(sig 900 901 902 $STAY); run_op apply
rc=$?; ok "a ledger directory that others can write is not trusted: exit 1, nothing is scored, nothing recorded" '[ "$rc" -eq 1 ] && [ "$(sig 900 901 902 $STAY)" = "$before" ] && [ -z "$(ls "$LG")" ]'
fixture; run_op apply; printf 'start=5000100 unit=lead-spire.scope score=0 prev=-999 uid=%s\n' "$(id -u)" > "$T/planted"; ln -s "$T/planted" "$LG/100"; echo garbage > "$LG/101"
printf 'start=5000302 unit=lead-spire.scope score=-500 prev=77 uid=%s\n' "$(( $(id -u) + 1 ))" > "$LG/302"; before=$(sig $STAY); run_op apply; run_op off
ok "a record that is a symlink, one that is garbage, and one for another uid are ignored: those processes are not written" '[ "$(sig $STAY)" = "$before" ]'
# the same two, aimed where a write COULD follow: at processes inside the lead unit holding their own negative score
fixture; run_op apply; printf 'start=5000903 unit=lead-spire.scope score=-900 prev=0 uid=%s\n' "$(id -u)" > "$T/planted"; ln -s "$T/planted" "$LG/903"; before=$(sig $STAY); run_op off
ok "a SYMLINKED record matching a process INSIDE the lead unit (903, its own -900): not read, the process not written" '[ "$(sig $STAY)" = "$before" ]'
fixture; run_op apply; printf 'start=5000904 unit=lead-spire.scope score=-500 prev=77 uid=%s\n' "$(( $(id -u) + 1 ))" > "$LG/904"; before=$(sig $STAY); run_op off
ok "a record carrying ANOTHER uid matching a process inside the lead unit (904, its own -500): not acted on" '[ "$(sig $STAY)" = "$before" ]'
if [ "$(id -u)" -ne 0 ]; then
  fixture; chmod 444 "$PR/901/oom_score_adj"; run_op apply; rc=$?
  ok "a score that cannot be written: exit 1, NO record is left for it (a record without its score is a later false undo), and the run STOPS there (the next process is not scored)" '[ "$rc" -eq 1 ] && [ ! -e "$LG/901" ] && [ "$(scores 900 901 902)" = "-500 200 0 " ] && [ ! -e "$LG/902" ]'
fi
# a PLANTED record that looks right, for a process in a unit that is not a lead unit: off must not write it
fixture; mkdir -p -m 700 "$LG"; printf 'start=5000302 unit=tmux-spawn-x.scope score=-500 prev=0 uid=%s\n' "$(id -u)" > "$LG/302"; before=$(sig $STAY); run_op off
ok "a record naming a unit that is not a lead unit (tmux-spawn-x.scope) writes nobody, though pid, start and score match" '[ "$(sig $STAY)" = "$before" ]'
fixture; mkdir -p -m 700 "$LG"; printf 'start=5000310 unit=lead-spire.scope score=-500 prev=0 uid=%s\n' "$(id -u)" > "$LG/310"; before=$(sig $STAY); run_op off; run_op apply
ok "a record that matches palace-daemon's pid, start and score (-500): NOT written, by off or apply (it is under /system.slice)" '[ "$(sig $STAY)" = "$before" ]'

echo "── who can be scored at all ─────────────────────────────────────"
fixture; run_op apply
ok "a lane's scope, a unit whose name only STARTS like it, the same name under another slice, and the parent slice earn nothing" '[ "$(scores 100 101 200 201 202)" = "0 0 0 0 0 " ]'
if python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.oomd_avoid", b"1")' "$XD" 2>/dev/null; then
  run_op apply; ok "a lane that MARKS its own scope (user.oomd_avoid) earns nothing" '[ "$(scores 100 101)" = "0 0 " ]'
fi
ok "no attribute is read anywhere in the tool, and no blanket reset is left in it" '! grep -q "getxattr\|oomd_avoid" "$SH" && ! grep -q "startswith(mine)\|wr_score(fd, \"0\")" "$SH"'
ok "the helper has exactly ONE place that writes a score back, and it is behind still_in()" '[ "$(grep -c "wr_score(fd, r\[\"prev\"\])" "$SH")" = 1 ] && grep -B4 "wr_score(fd, r\[\"prev\"\])" "$SH" | grep -q "if not still_in(place(fd), r\[\"uid\"\], r\[\"unit\"\]):"'
fixture; mv "$LD" "$LD.away"; ln -s "$LD.away" "$LD"; before=$(sig 900 901 902 $STAY); run_op apply; rm -f "$LD"; mv "$LD.away" "$LD"
ok "the unit path being a symlink (to a directory listing processes whose own cgroup IS the unit): nobody is scored" '[ "$(sig 900 901 902 $STAY)" = "$before" ] && [ ! -e "$LG/900" ]'
fixture; run_op apply; mv "$LD" "$LD.away"; ln -s "$LD.away" "$LD"; s=$(sig 900 901 902 $STAY); run_op off; rm -f "$LD"; mv "$LD.away" "$LD"
ok "off while the unit path is a symlink: no recorded score is written back (the unit cannot be placed), the records retired" '[ "$(sig 900 901 902 $STAY)" = "$s" ] && [ ! -e "$LG/900" ]' 
fixture; printf '900\n901\n903\n904\n200\n201\n' > "$LD/cgroup.procs"; before=$(sig $STAY); run_op apply
ok "listed in the unit but its own cgroup is lead-spire.scope-x, or lanes.slice/lead-spire.scope: not scored, not recorded" '[ "$(sig $STAY)" = "$before" ] && [ ! -e "$LG/200" ] && [ ! -e "$LG/201" ] && [ "$(scores 900)" = "-500 " ]'
fixture; mv "$LD" "$LD.away"; before=$(sig 900 901 902 $STAY); run_op apply; mv "$LD.away" "$LD"
ok "the unit not existing (the lead is down): nobody is scored" '[ "$(sig 900 901 902 $STAY)" = "$before" ]'
fixture; printf 'oomprotect %s lead-spire.scope -500\n' "$(( $(id -u) + 1 ))" > "$T/conf"; before=$(sig 900 901 902 $STAY); run_op apply; run_op off
ok "a line for another uid writes to none of this user's processes (apply and off)" '[ "$(sig 900 901 902 $STAY)" = "$before" ]'
O=$(( $(id -u) + 1 )); OD="$T/cg/user.slice/user-$O.slice/user@$O.service/app.slice/lead-spire.scope"; mkdir -p "$OD"
fixture; fp 950 "/user.slice/user-$O.slice/user@$O.service/app.slice/lead-spire.scope" 0; echo 950 > "$OD/cgroup.procs"; printf 'oomprotect %s lead-spire.scope -500\n' "$O" > "$T/conf"; run_op apply
ok "a process sitting in that uid's lead unit but OWNED by another user is not scored (the owner is read from /proc/<pid> itself)" '[ "$(scores 950)" = "0 " ] && [ ! -e "$LG/950" ]'
rm -rf "$T/cg/user.slice/user-$O.slice"
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"; fixture; run_op apply; run_op status
ok "status: who is in the unit (and which are not ours), the ledger, the left ones" 'grep -q "in:900=-500 901=-500 903=-900(not ours) 904=-500(not ours) 902=-500; recorded:900(lead-spire.scope) 901(lead-spire.scope) 902(lead-spire.scope); left the unit holding our score, NOT written:none" "$T/out"'
ok "owner, start time, cgroup and the write all go through one /proc/<pid> directory descriptor" 'grep -q "os.O_DIRECTORY" "$SH" && grep -q "dir_fd=fd" "$SH" && ! grep -q "stat -c %u" "$SH"'
for bad in "oomprotect $(id -u) -500" "oomprotect $(id -u) tmux-spawn-x.scope -500" "oomprotect $(id -u) app.slice -500" "oomprotect $(id -u) lead-spire.service -500" \
           "oomprotect $(id -u) ../lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope 100" "oomprotect $(id -u) lead-spire.scope -2000" "oomprotect jp lead-spire.scope -500" "oomprotect $(id -u) lead-spire.scope -500 extra"; do
  fixture; printf '%s\n' "$bad" > "$T/conf"; before=$(sig 900 $STAY); run_op apply; rc=$?
  if [ "$rc" -eq 22 ] && [ "$(sig 900 $STAY)" = "$before" ]; then pass "bad oomprotect line refused: $bad"; else fail "bad oomprotect '$bad': rc $rc"; fi
done

echo "── io-shield-accept: fails on an absent service, a restart, a change, or zero leads ──"
AC="$ROOT/scripts/host/io-shield-accept"
printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
run_ac() { local host=$1; shift; IO_SHIELD_ACCEPT_HOST="$host" IO_SHIELD_THROWAWAY_CONF="$T/tconf" IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_BIN="${ACBIN:-$SH}" PATH="$B:$PATH" bash "$AC" "$@" > "$T/out" 2> "$T/err"; }
ok "the list in the script's table is the list in its header (familiar's four and serialhub's three, with their scores)" '[ "$(sed -n "/^  familiar)/s/.*MUST=\"\(.*\)\" ;;/\1/p" "$AC")" = "palace-daemon.service=-500 qwen3-coder.service=-500 familiar-loadguard.service=-800 donkey-llm.service=-100" ] && [ "$(sed -n "/^  serialhub)/s/.*MUST=\"\(.*\)\" ;;/\1/p" "$AC")" = "octoprint.service=-900 ustreamer.service=-900 ustreamer-builtin.service=-900" ] && for u in "palace-daemon.service        -500" "qwen3-coder.service          -500" "familiar-loadguard.service   -800" "donkey-llm.service           -100"; do grep -q "^#  *\(familiar  *\)\?$u" "$AC" || exit 1; done'
fixture; run_ac familiar "$(id -u)" apply; rc=$?
ok "familiar, apply: exit 0, each of its four services reported the same process, cgroup and score" '[ "$rc" -eq 0 ] && for u in "palace-daemon.service pid 310 -500" "qwen3-coder.service pid 311 -500" "familiar-loadguard.service pid 312 -800" "donkey-llm.service pid 313 -100"; do grep -q "^untouched  $u (same process, same cgroup)" "$T/out" || exit 1; done'
ok "…and it counted the leads: 3 processes scored and recorded in lead-spire.scope" 'grep -q "^lead unit  lead-spire.scope: 3 process(es) in it hold -500 with a ledger record of ours" "$T/out" && grep -q "^ACCEPT (apply on familiar): 4 named process(es) of 4 listed unit(s)" "$T/out"'
run_ac familiar "$(id -u)" off; rc=$?
ok "familiar, off: exit 0, the four the same, no recorded score left in the lead unit" '[ "$rc" -eq 0 ] && grep -q "^lead unit  lead-spire.scope: 0 process(es)" "$T/out" && grep -q "^ACCEPT (off on familiar)" "$T/out"'
fixture; rm -rf "$PR/312"; all=$(sig 900 901 902 $STAY 2>/dev/null); run_ac familiar "$(id -u)" apply; rc=$?
ok "a NAMED service is ABSENT (familiar-loadguard): exit 1, REJECT by name, and the helper was NOT run" '[ "$rc" -eq 1 ] && grep -q "^REJECT: familiar-loadguard.service is on this host.s list and has no process" "$T/out" && ! grep -q "== RUN" "$T/out" && [ "$(scores 900)" = "0 " ]'
fixture; echo -100 > "$PR/310/oom_score_adj"; run_ac familiar "$(id -u)" apply; rc=$?
ok "a named service at ANOTHER score before the run (palace-daemon -100, listed -500): exit 1, the helper not run" '[ "$rc" -eq 1 ] && grep -q "^REJECT: palace-daemon.service should hold -500 before the run and holds: 310=-100" "$T/out" && ! grep -q "== RUN" "$T/out"'
fixture; run_ac serialhub "$(id -u)" apply; rc=$?
ok "on serialhub the list is ITS three: ustreamer is absent in this fixture → exit 1 (never an ACCEPT with a named unit missing)" '[ "$rc" -eq 1 ] && grep -q "^REJECT: ustreamer.service is on this host.s list" "$T/out"'
fixture; run_ac katana "$(id -u)" apply; rc=$?
ok "a host with no list: refused (exit 2), nothing run" '[ "$rc" -eq 2 ] && grep -q "has no acceptance list" "$T/err" && [ "$(scores 900)" = "0 " ]'
fixture; IO_SHIELD_MUST_STAY="octoprint.service=-900" run_ac katana "$(id -u)" apply; rc=$?
ok "…with IO_SHIELD_MUST_STAY naming one: accepted against that list" '[ "$rc" -eq 0 ] && grep -q "^untouched  octoprint.service pid 314 -900" "$T/out"'
mkevil() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$T/evil-shield"; chmod +x "$T/evil-shield"; }
mkevil "echo 0 > \"$PR/310/oom_score_adj\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "not vacuous: a helper that RESETS palace-daemon is exit 1 and named" '[ "$rc" -eq 1 ] && grep -q "^REJECT: palace-daemon.service pid 310: score CHANGED -500 → 0" "$T/out"'
mkevil "echo \"310 (new one) S 1 310 310 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 8888888 0 0\" > \"$PR/310/stat\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a named service RESTARTED during the run (same pid number, another start time): exit 1, not 'untouched'" '[ "$rc" -eq 1 ] && grep -q "^REJECT: palace-daemon.service pid 310 is GONE or REPLACED after the run" "$T/out"'
mkevil "echo \"0::/user.slice/moved.scope\" > \"$PR/311/cgroup\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a named service MOVED to another cgroup during the run: exit 1" '[ "$rc" -eq 1 ] && grep -q "^REJECT: qwen3-coder.service pid 311: cgroup CHANGED" "$T/out"'
mkevil "echo 0 > \"$PR/301/oom_score_adj\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a score that is NOT a named unit's (the login session's -700) changed by the helper: exit 1 too" '[ "$rc" -eq 1 ] && grep -q "^REJECT: session-4.scope pid 301 (not a named unit" "$T/out"'
mkevil "true"; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "ZERO protected leads after apply (a helper that scored nobody): exit 1, though every service is untouched" '[ "$rc" -eq 1 ] && grep -q "^REJECT: ZERO protected processes in lead-spire.scope after apply" "$T/out" && grep -q "^untouched  palace-daemon.service" "$T/out"'
mkevil "mkdir -p -m 700 \"$LG\"; echo \"start=5000900 unit=lead-spire.scope score=-500 prev=0 uid=$(id -u)\" > \"$LG/900\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a RECORD without its score (the lead's process still at 0) is not a protected lead: exit 1" '[ "$rc" -eq 1 ] && grep -q "^REJECT: ZERO protected processes" "$T/out"'
mkevil "mkdir -p -m 700 \"$LG\"; echo \"start=5000100 unit=lead-spire.scope score=-500 prev=0 uid=$(id -u)\" > \"$LG/100\"; echo -500 > \"$PR/100/oom_score_adj\""; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a scored and recorded process OUTSIDE the lead unit (a lane's scope) is not a protected lead: exit 1" '[ "$rc" -eq 1 ] && grep -q "^REJECT: ZERO protected processes" "$T/out"' 
fixture; mv "$LD" "$LD.away"; run_ac familiar "$(id -u)" apply; rc=$?; mv "$LD.away" "$LD"
ok "the lead is DOWN (its unit does not exist): the real helper scores nobody → exit 1, zero leads" '[ "$rc" -eq 1 ] && grep -q "ZERO protected processes" "$T/out"'
fixture; printf 'device nvme0n1\n' > "$T/conf"; run_ac familiar "$(id -u)" apply; rc=$?; printf 'oomprotect %s lead-spire.scope -500\n' "$(id -u)" > "$T/conf"
ok "a config with NO oomprotect line for the uid: exit 1 (there is no lead to protect)" '[ "$rc" -eq 1 ] && grep -q "names no oomprotect unit" "$T/out"'
mkevil "exit 0"; fixture; run_op apply; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" off; rc=$?
ok "off that undid nothing (records still live in the unit): exit 1" '[ "$rc" -eq 1 ] && grep -q "still hold our score with a record after off" "$T/out"'
mkevil "exit 3"; fixture; ACBIN="$T/evil-shield" run_ac familiar "$(id -u)" apply; rc=$?
ok "a helper that fails: exit 2, no ACCEPT" '[ "$rc" -eq 2 ] && ! grep -q "^ACCEPT" "$T/out"'
bash "$AC" > /dev/null 2>&1; ok "io-shield-accept without arguments: exit 22" '[ "$?" -eq 22 ]'
bash "$AC" "$(id -u)" status > /dev/null 2>&1; ok "io-shield-accept with another verb: exit 22" '[ "$?" -eq 22 ]'


echo "── xreview #291 r1, finding by finding ──────────────────────────"
ME=$(id -u); OP="oomprotect $ME lead-spire.scope -500"
setconf() { printf '%s\n' "$@" > "$T/conf"; }
mkdir -p "$T/wnow"
# 1. unit weights and io.cost are in the ledger, record first; off undoes ONLY what is recorded
fixture; setconf "device nvme0n1" "unit foreign.service 20" "docker mempalace-db 20" "$OP"; echo "259:0 enable=1 ctrl=user rpct=50.00 rlat=9000 wpct=50.00 wlat=9000 min=10.00 max=100.00" > "$T/qos"; cp "$T/qos" "$T/qos.b"; : > "$LOG"; run_op off; rc=$?
ok "off WITHOUT a prior apply: a configured unit, container and device are NOT written (no set-property, io.cost.qos byte-identical), and it says so" '[ "$rc" -eq 0 ] && ! grep -q "set-property" "$LOG" && cmp -s "$T/qos" "$T/qos.b" && grep -q "foreign.service has no record of ours: not written" "$T/out" && grep -q "was not enabled by this tool (no record): not written" "$T/out"'
run_op on; echo 55 > "$T/wnow/foreign.service"; : > "$LOG"; run_op apply; rc=$?
ok "apply: a record for the unit, the container and the device BEFORE each is set: our weight, what it had before" '[ "$rc" -eq 0 ] && grep -qx "ours=20 prev=55" "$LG/unit.foreign.service" && grep -qx "ours=20 prev=unset" "$LG/unit.docker-$ID.scope" && grep -qx "prev=259:0 enable=1 ctrl=user rpct=50.00 rlat=9000 wpct=50.00 wlat=9000 min=10.00 max=100.00" "$LG/dev.259_0"'
echo "[not set]" > "$T/wnow/foreign.service"; : > "$LOG"; run_op off; rc=$?
ok "off: the recorded unit gets its PREVIOUS weight back (55), not just the default; the records are gone" '[ "$rc" -eq 0 ] && grep -qxF "systemctl set-property --runtime foreign.service IOWeight=" "$LOG" && grep -qxF "systemctl set-property --runtime foreign.service IOWeight=55" "$LOG" && [ ! -e "$LG/unit.foreign.service" ] && [ ! -e "$LG/dev.259_0" ]'
ok "off: the device gets the io.cost.qos line it had BEFORE us, not a blanket enable=0" 'cmp -s "$T/qos" "$T/qos.b"'
rm -f "$T/wnow/foreign.service"; run_op on; : > "$T/qos"; run_op apply; setconf "$OP"; : > "$LOG"; run_op off
ok "off undoes what is RECORDED even when the config no longer names it" 'grep -qxF "systemctl set-property --runtime foreign.service IOWeight=" "$LOG" && grep -qxF "259:0 enable=0" "$T/qos"'
fixture; run_op on; setconf "unit broken.service 20" "unit foreign.service 20"; : > "$LOG"; run_op apply; rc=$?
ok "a set-property that fails: exit 1, NO record of a setting that was not made, and the run stops (the next unit is not set)" '[ "$rc" -eq 1 ] && [ ! -e "$LG/unit.broken.service" ] && ! grep -q "foreign.service" "$LOG"'
# 2. the unit validator refuses the forbidden targets by the shape of the name, before ANY action
for badu in system.slice user.slice lead-spire.scope lane-alpha-12345678.scope dreamteam-proj.scope "user@$ME.service" systemd-journald.service lanes.slice; do
  fixture; run_op on; setconf "device nvme0n1" "unit $badu 20" "$OP"; : > "$T/qos"; : > "$LOG"; before=$(sig 900 901 902 $STAY); run_op apply; a=$?; run_op off; b=$?
  if [ "$a" -eq 22 ] && [ "$b" -eq 22 ] && [ ! -s "$T/qos" ] && ! grep -q "set-property" "$LOG" && [ "$(sig 900 901 902 $STAY)" = "$before" ] && [ ! -e "$LG" ]; then pass "unit $badu: refused (22) by apply AND off, before anything: the earlier device line is not applied, no score, no ledger"
  else fail "unit $badu: apply $a off $b qos [$(cat "$T/qos")] log [$(cat "$LOG")]"; fi
done
# 3. root runs are not steerable; the sudoers grant is in the diff and narrow
ok "as root the helper drops the environment and fixes PATH; the IO_SHIELD_* seams exist only in the not-root branch" 'grep -q "^    os.environ.clear()$" "$SH" && grep -q "/usr/sbin:/usr/bin:/sbin:/bin" "$SH" && [ "$(grep -c "os.environ" "$SH")" -eq 3 ] && grep -A3 "^if ROOT:$" "$SH" | grep -q "E = {}"'
SU="$ROOT/systemd/system/sudoers.d/dreamteam-io-shield.in"; sed 's/@USER@/someone/g' "$SU" > "$T/sudoers"
if command -v visudo > /dev/null 2>&1; then
  if visudo -cf "$T/sudoers" > /dev/null 2>&1; then pass "the sudoers file parses (visudo -cf)"; else fail "visudo rejects the sudoers file"; fi
  printf 'someone ALL=(root) NOPASSWD /bin/true\n' > "$T/sudoers.bad"; if visudo -cf "$T/sudoers.bad" > /dev/null 2>&1; then fail "visudo accepted a broken file: the check is vacuous"; else pass "…and visudo rejects a broken one (the check is not vacuous)"; fi
fi
ok "the grant is exactly the two read-only verbs of this one helper, to one user; apply, off and on are not in it" '[ "$(grep -v "^#" "$T/sudoers" | grep -c "NOPASSWD")" -eq 1 ] && grep -qx "someone ALL=(root) NOPASSWD: DT_IO_SHIELD" "$T/sudoers" && grep -qx "Cmnd_Alias DT_IO_SHIELD = /usr/local/sbin/dreamteam-io-shield status, /usr/local/sbin/dreamteam-io-shield --throwaway status" "$T/sudoers" && ! grep -v "^#" "$T/sudoers" | grep -qw "apply\|off\|on\|ALL$"'
ok "…with the environment reset, no setenv, and a fixed path" 'grep -qx "Defaults!DT_IO_SHIELD env_reset, !setenv, secure_path=\"/usr/sbin:/usr/bin:/sbin:/bin\"" "$T/sudoers"'
# 4. the ledger: durable publication, and a damaged ledger stops the run before anything
setconf "$OP"
damaged() { # damaged <label> <command that damages the ledger after an apply>
  fixture; run_op on; run_op apply; eval "$2"; all=$(sig 900 901 902 $STAY); snap=$(ls -la "$LG" | md5sum); run_op off; a=$?
  if [ "$a" -eq 1 ] && [ "$(sig 900 901 902 $STAY)" = "$all" ] && [ ! -e "$T/run/dreamteam-io-shield.off" ] && [ "$(ls -la "$LG" | md5sum)" = "$snap" ] && grep -q "ledger" "$T/err"; then pass "damaged ledger ($1): off exits 1, writes NO score back (not even the intact records'), no stamp, the ledger untouched"
  else fail "damaged ledger ($1): rc $a scores $(scores 900 901 902) stamp $(ls "$T/run" | tr '\n' ' ') err [$(head -c 150 "$T/err")]"; fi
  run_op apply; a=$?
  if [ "$a" -eq 1 ] && [ "$(sig 900 901 902 $STAY)" = "$all" ]; then pass "damaged ledger ($1): apply exits 1 too, nobody scored"; else fail "damaged ledger ($1): apply rc $a"; fi
}
damaged "a HALF-WRITTEN record" 'printf "start=5000900 unit=lead-spi" > "$LG/900"'
damaged "a record without its newline" 'printf "start=5000900 unit=lead-spire.scope score=-500 prev=0 uid=%s" "$ME" > "$LG/900"'
damaged "a record with a field too many" 'printf "start=5000900 unit=lead-spire.scope score=-500 prev=0 uid=%s extra=1\n" "$ME" > "$LG/900"'
damaged "an empty record" ': > "$LG/901"'
damaged "an entry of an unknown name" 'echo hello > "$LG/notes"'
damaged "a record that is a symlink" 'printf "start=5000903 unit=lead-spire.scope score=-900 prev=0 uid=%s\n" "$ME" > "$T/planted"; ln -s "$T/planted" "$LG/903"'
damaged "a directory where a record should be" 'mkdir "$LG/905"'
damaged "left/ replaced by a file" ': > "$LG/left"'
damaged "a half-written unit record" 'printf "ours=20 pre" > "$LG/unit.foreign.service"'
fixture; run_op on; run_op apply; echo junk > "$LG/.900.tmp"; run_op off; rc=$?
ok "a leftover temp file of an interrupted publish is no record and no damage: off runs" '[ "$rc" -eq 0 ] && [ "$(scores 900 901 902)" = "0 200 0 " ]'
if command -v strace > /dev/null 2>&1 && strace -o /dev/null true 2> /dev/null; then
  fixture; run_op on
  IO_SHIELD_CONF="$T/conf" IO_SHIELD_QOS_FILE="$T/qos" IO_SHIELD_SYSBLOCK="$T/sys" IO_SHIELD_CGROUP_ROOT="$T/cg" IO_SHIELD_PROC="$PR" IO_SHIELD_RUN_DIR="$T/run" IO_SHIELD_ASSUME_ROOT=1 PATH="$B:$PATH" strace -f -o "$T/strace" -e trace=fsync,renameat,rename,renameat2,write python3 -I "$SH" apply > /dev/null 2>&1
  # for each of the three records: the record's bytes written, fsync of the file, the rename, fsync of the directory, and only THEN the score
  seq=$(grep -E 'fsync\(|rename|write\([0-9]+, "(start=|-500)' "$T/strace" | sed -E 's/^[0-9]+ +//; s/\(.*//' | tr '\n' ' ')
  ok "publication is durable, in this order for every record: write, fsync(file), rename, fsync(directory), and only then the score ($(grep -c 'fsync(' "$T/strace") fsyncs for 3 records)" '[ "$(grep -c "fsync(" "$T/strace")" -eq 6 ] && [ "$seq" = "write fsync rename fsync write write fsync rename fsync write write fsync rename fsync write " ]'
fi
# 5. EACCES / EIO are not absence: the record is kept and the run stops before the next change
if [ "$ME" -ne 0 ]; then
  fixture; run_op on; run_op apply; chmod 000 "$PR/901"; run_op off; rc=$?; chmod 755 "$PR/901"
  ok "a recorded process that cannot be LOOKED AT (EACCES): exit 1, its record KEPT (it is not 'gone'), and the run stops: the next record is not undone" '[ "$rc" -eq 1 ] && [ -e "$LG/901" ] && [ "$(scores 900 901 902)" = "0 -500 -500 " ] && [ -e "$LG/902" ] && grep -q "not known to be gone" "$T/err"'
  fixture; run_op on; run_op apply; chmod 000 "$PR/901/oom_score_adj"; run_op off; rc=$?; chmod 644 "$PR/901/oom_score_adj"
  ok "a recorded process whose score cannot be READ: exit 1, record kept, run stopped" '[ "$rc" -eq 1 ] && [ -e "$LG/901" ] && [ -e "$LG/902" ]'
  fixture; run_op on; run_op apply; chmod 500 "$LG"; run_op off; rc=$?; chmod 700 "$LG"
  ok "a record that cannot be DELETED: exit 1 and the run stops at once (no further score is written back)" '[ "$rc" -eq 1 ] && [ "$(scores 901 902)" = "-500 -500 " ] && grep -q "cannot remove the record" "$T/err"'
  fixture; run_op on; chmod 000 "$PR/901"; run_op apply; rc=$?; chmod 755 "$PR/901"
  ok "apply: a process in the unit that cannot be looked at stops the run (exit 1); it is not skipped as absent" '[ "$rc" -eq 1 ] && [ ! -e "$LG/902" ]'
fi
fixture; run_op on; setconf "unit failing.service 20" "unit foreign.service 20"; : > "$LOG"; run_op apply; rc=$?
ok "a systemctl show that FAILS is not 'not loaded': exit 1, nothing set on that unit or on the next" '[ "$rc" -eq 1 ] && ! grep -q "set-property" "$LOG" && ! grep -q "is not loaded now" "$T/out" && grep -q "its state is unknown" "$T/err"'
setconf "$OP"
# 6. the placement is read again immediately before the write (and once after a new score)
seqcg() { rm -f "$PR/$1/cgroup"; mkfifo "$PR/$1/cgroup"; shift; ( for c in "$@"; do echo "0::$c" > "$FIFO_OF"; sleep 0.1; done ) & SEQ=$!; }      # the pause: the reader of one answer has closed before the next is offered (a FIFO with no open end drops what is in it)
IN="/$UM/app.slice/lead-spire.scope"
fixture; run_op on; run_op apply; FIFO_OF="$PR/901/cgroup" seqcg 901 "$IN" "/system.slice/adopted.service"; s=$(sig 901); run_op off; rc=$?; kill "$SEQ" 2>/dev/null; wait "$SEQ" 2>/dev/null
ok "off: a process that is in its lead unit at the first look and under /system.slice at the look just before the write is NOT written; its record is retired" '[ "$rc" -eq 0 ] && [ "$(sig 901)" = "$s" ] && [ -f "$LG/left/901.5000901" ] && [ "$(scores 900 902)" = "0 0 " ]'
fixture; run_op on; FIFO_OF="$PR/901/cgroup" seqcg 901 "$IN" "/$UM/app.slice/tmux-spawn-x.scope"; s=$(sig 901); run_op apply; rc=$?; kill "$SEQ" 2>/dev/null; wait "$SEQ" 2>/dev/null
ok "apply: a process that leaves between the first look and the look just before the write is NOT scored, and no record of it remains" '[ "$rc" -eq 0 ] && [ "$(sig 901)" = "$s" ] && [ ! -e "$LG/901" ] && [ "$(scores 900 902)" = "-500 -500 " ]'
fixture; run_op on; FIFO_OF="$PR/901/cgroup" seqcg 901 "$IN" "$IN" "/system.slice/adopted.service"; run_op apply; rc=$?; kill "$SEQ" 2>/dev/null; wait "$SEQ" 2>/dev/null
ok "apply: a process that leaves DURING the write is found at the look after it: its record is retired at once and the run says so (2 scored, 1 left)" '[ "$rc" -eq 0 ] && [ ! -e "$LG/901" ] && [ -f "$LG/left/901.5000901" ] && grep -q "2 process(es) scored -500 and recorded; 2 in the unit left as found (a negative score we did not write); 1 of ours have LEFT" "$T/out"'
ok "the header does not claim an atomic check-and-write: it states the window" 'grep -q "WHAT THAT IS NOT:" "$SH" && grep -q "an atomic check-and-write" "$SH"'
# 7. first use is a throwaway unit, by construction
fixture; run_op on; rm -f "$T/accepted"; : > "$LOG"; before=$(sig 900 901 902 $STAY); run_op apply; rc=$?
ok "production apply WITHOUT the acceptance flag: exit 3, nothing scored, no ledger, nothing set" '[ "$rc" -eq 3 ] && [ "$(sig 900 901 902 $STAY)" = "$before" ] && [ ! -e "$LG" ] && [ ! -s "$LOG" ] && grep -q "NOT ACCEPTED on this host" "$T/err"'
printf 'sha256=%s\n' "$(printf x | sha256sum | cut -d" " -f1)" > "$T/accepted"; chmod 600 "$T/accepted"; run_op apply; rc=$?
ok "…with a flag for ANOTHER helper (another sha256): exit 3" '[ "$rc" -eq 3 ] && [ ! -e "$LG" ]'
accept_flag; chmod 666 "$T/accepted"; run_op apply; rc=$?; ok "…with a flag others can write: exit 3" '[ "$rc" -eq 3 ] && [ ! -e "$LG" ]'
accept_flag; mv "$T/accepted" "$T/accepted.real"; ln -s "$T/accepted.real" "$T/accepted"; run_op apply; rc=$?; rm -f "$T/accepted" "$T/accepted.real"
ok "…with a flag that is a symlink: exit 3" '[ "$rc" -eq 3 ] && [ ! -e "$LG" ]'
run_op status; rc=$?; ok "status says the host is not accepted; off and on need no flag" '[ "$rc" -eq 0 ] && grep -q "^NOT ACCEPTED on this host" "$T/out"'
TD="$T/cg/$UM/app.slice/lead-throwaway-a1.scope"; mkdir -p "$TD"; TLG="$T/run/dreamteam-io-shield-throwaway"
tfix() { fixture; rm -rf "$TLG" "$T/run/dreamteam-io-shield-throwaway.off"; fp 950 "/$UM/app.slice/lead-throwaway-a1.scope" 0; fp 951 "/$UM/app.slice/lead-throwaway-a1.scope" 0; printf '950\n951\n' > "$TD/cgroup.procs"; printf 'oomprotect %s lead-throwaway-a1.scope -500\n' "$ME" > "$T/tconf"; }
tfix; before=$(sig 900 901 902 $STAY); run_op --throwaway apply; rc=$?
ok "--throwaway apply needs NO flag: it scores the throwaway unit only, in its OWN ledger; the production unit and ledger are untouched" '[ "$rc" -eq 0 ] && [ "$(scores 950 951)" = "-500 -500 " ] && [ -e "$TLG/950" ] && [ ! -e "$LG" ] && [ "$(sig 900 901 902 $STAY)" = "$before" ]'
run_op --throwaway off; rc=$?
ok "--throwaway off undoes it, with its own stamp" '[ "$rc" -eq 0 ] && [ "$(scores 950 951)" = "0 0 " ] && [ -e "$T/run/dreamteam-io-shield-throwaway.off" ] && [ ! -e "$T/run/dreamteam-io-shield.off" ]'
for badt in "oomprotect $ME lead-spire.scope -500" "device nvme0n1" "unit foreign.service 20" "docker mempalace-db 20" "oomprotect $ME lead-throwaway-.scope -500" "oomprotect $ME lead-throwaway-A.scope -500"; do
  tfix; printf '%s\n' "$badt" > "$T/tconf"; : > "$T/qos"; : > "$LOG"; before=$(sig 900 901 902 950 951 $STAY); run_op --throwaway apply; rc=$?
  if [ "$rc" -eq 22 ] && [ "$(sig 900 901 902 950 951 $STAY)" = "$before" ] && [ ! -s "$T/qos" ] && [ ! -s "$LOG" ]; then pass "a throwaway config may hold nothing but lead-throwaway-<name>.scope lines: refused: $badt"; else fail "throwaway config '$badt': rc $rc"; fi
done
tfix; setconf "oomprotect $ME lead-throwaway-a1.scope -500"; accept_flag; run_op apply; rc=$?; setconf "$OP"
ok "a PRODUCTION config may not name a throwaway unit: refused (22)" '[ "$rc" -eq 22 ] && [ "$(scores 950)" = "0 " ]'
# io-shield-accept throwaway: the only writer of the flag
tfix; rm -f "$T/accepted"; run_ac familiar "$ME" throwaway; rc=$?
ok "io-shield-accept throwaway: a whole apply and a whole off on the throwaway unit, the four services untouched in both, exit 0" '[ "$rc" -eq 0 ] && [ "$(grep -c "^untouched  palace-daemon.service pid 310 -500" "$T/out")" -eq 2 ] && grep -q "^lead unit  lead-throwaway-a1.scope: 2 process(es) in it hold -500" "$T/out" && grep -q "^ACCEPT (throwaway on familiar)" "$T/out" && [ "$(scores 950 951)" = "0 0 " ]'
ok "…and ONLY THEN the flag: the sha256 of the helper that was run, 0600" 'grep -qx "sha256=$(sha256sum "$SH" | cut -d" " -f1)" "$T/accepted" && [ "$(stat -c %a "$T/accepted")" = 600 ]'
run_op on; run_op apply; rc=$?; ok "…after which production apply is allowed" '[ "$rc" -eq 0 ] && [ "$(scores 900)" = "-500 " ]'
tfix; rm -rf "$PR/312"; run_ac familiar "$ME" throwaway; rc=$?
ok "accept throwaway with a named service ABSENT: exit 1, the helper not run, NO flag (the earlier flag is removed too)" '[ "$rc" -eq 1 ] && ! grep -q "== RUN" "$T/out" && [ ! -e "$T/accepted" ]'
mkevil 'case "$*" in *apply*) exec python3 -I "'"$SH"'" "$@" ;; *) exit 0 ;; esac'; tfix; ACBIN="$T/evil-shield" run_ac familiar "$ME" throwaway; rc=$?
ok "accept throwaway where the off undoes nothing: exit 1, NO flag" '[ "$rc" -eq 1 ] && grep -q "still hold our score with a record after off" "$T/out" && [ ! -e "$T/accepted" ]'
mkevil 'case "$*" in *apply*) exec python3 -I "'"$SH"'" "$@" ;; *) echo 0 > "'"$PR"'/950/oom_score_adj"; echo 0 > "'"$PR"'/951/oom_score_adj"; exit 0 ;; esac'; tfix; ACBIN="$T/evil-shield" run_ac familiar "$ME" throwaway; rc=$?
ok "accept throwaway where the off resets the scores but leaves its records in the ledger: exit 1, NO flag" '[ "$rc" -eq 1 ] && grep -q "after the throwaway off the ledger still holds" "$T/out" && [ -e "$TLG/950" ] && [ ! -e "$T/accepted" ]'
mkevil 'exit 0'; tfix; ACBIN="$T/evil-shield" run_ac familiar "$ME" throwaway; rc=$?
ok "accept throwaway where nobody was scored: exit 1 (zero leads), NO flag" '[ "$rc" -eq 1 ] && grep -q "ZERO protected processes" "$T/out" && [ ! -e "$T/accepted" ]'
ok "as root the acceptance script drops IO_SHIELD_* and fixes PATH (it then runs the INSTALLED helper only)" 'grep -q "for v in \$(compgen -v | grep .^IO_SHIELD_. || true); do unset \"\$v\"; done" "$AC" && grep -q "PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH" "$AC"'
accept_flag; setconf "$OP"
# the installer: the one way onto a host, and the gate on the timer
IN_="$ROOT/scripts/host/io-shield-install"; IR="$T/iroot"
run_in() { IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_INSTALL_ROOT="$IR" PATH="${INPATH:+$INPATH:}$B:$PATH" bash "$IN_" "$@" > "$T/out" 2> "$T/err"; }
iflag() { mkdir -p "$IR/var/lib/dreamteam"; printf 'sha256=%s\nhost=x\n' "$(sha256sum "${1:-$IR/usr/local/sbin/dreamteam-io-shield}" | cut -d" " -f1)" > "$IR/var/lib/dreamteam/io-shield.accepted"; chmod 600 "$IR/var/lib/dreamteam/io-shield.accepted"; }
if command -v visudo > /dev/null 2>&1; then
  rm -rf "$IR"; : > "$LOG"; run_in someone; rc=$?
  ok "install: the helper, the acceptance script (0755), the two units (0644) and the sudoers file (0440, the user's name in it)" '[ "$rc" -eq 0 ] && cmp -s "$SH" "$IR/usr/local/sbin/dreamteam-io-shield" && [ "$(stat -c %a "$IR/usr/local/sbin/dreamteam-io-shield")" = 755 ] && cmp -s "$AC" "$IR/usr/local/sbin/dreamteam-io-shield-accept" && [ -f "$IR/etc/systemd/system/dreamteam-io-shield.timer" ] && [ "$(stat -c %a "$IR/etc/sudoers.d/dreamteam-io-shield")" = 440 ] && grep -qx "someone ALL=(root) NOPASSWD: DT_IO_SHIELD" "$IR/etc/sudoers.d/dreamteam-io-shield"'
  ok "install WITHOUT an acceptance: the timer is not enabled; it is DISABLED, and the next step is named" '! grep -q "systemctl enable" "$LOG" && grep -qxF "systemctl disable --now dreamteam-io-shield.timer" "$LOG" && grep -q "dreamteam-io-shield-accept <uid> throwaway" "$T/out"'
  : > "$LOG"; run_in someone --enable; rc=$?
  ok "install --enable without the flag: REFUSED (exit 3), no enable" '[ "$rc" -eq 3 ] && ! grep -q "systemctl enable" "$LOG"'
  iflag "$AC"; : > "$LOG"; run_in someone --enable; rc=$?
  ok "install --enable with a flag for ANOTHER helper: refused (3), the timer disabled" '[ "$rc" -eq 3 ] && ! grep -q "systemctl enable" "$LOG" && grep -qxF "systemctl disable --now dreamteam-io-shield.timer" "$LOG"'
  iflag; chmod 666 "$IR/var/lib/dreamteam/io-shield.accepted"; : > "$LOG"; run_in someone --enable; rc=$?
  ok "install --enable with a flag others can write: refused (3)" '[ "$rc" -eq 3 ] && ! grep -q "systemctl enable" "$LOG"'
  iflag; mv "$IR/var/lib/dreamteam/io-shield.accepted" "$T/fl"; ln -s "$T/fl" "$IR/var/lib/dreamteam/io-shield.accepted"; : > "$LOG"; run_in someone --enable; rc=$?; rm -f "$IR/var/lib/dreamteam/io-shield.accepted"
  ok "install --enable with a flag that is a symlink: refused (3)" '[ "$rc" -eq 3 ] && ! grep -q "systemctl enable" "$LOG"'
  iflag; : > "$LOG"; run_in someone; rc=$?
  ok "install with a valid flag but no --enable: the timer is left as it is" '[ "$rc" -eq 0 ] && ! grep -q "systemctl enable\|systemctl disable" "$LOG"'
  : > "$LOG"; run_in someone --enable; rc=$?
  ok "install --enable with the flag for the installed helper: the timer is enabled" '[ "$rc" -eq 0 ] && grep -qxF "systemctl enable --now dreamteam-io-shield.timer" "$LOG"'
  mkdir -p "$T/novisudo"; printf '#!/bin/sh\nexit 1\n' > "$T/novisudo/visudo"; chmod +x "$T/novisudo/visudo"; rm -rf "$IR"; INPATH="$T/novisudo" run_in someone; rc=$?
  ok "a sudoers file visudo does not accept: exit 2 and NOTHING is installed" '[ "$rc" -eq 2 ] && [ ! -e "$IR/usr/local/sbin/dreamteam-io-shield" ] && [ ! -e "$IR/etc/sudoers.d/dreamteam-io-shield" ]'
fi
for badw in "" "Some One" "root;id" "../x"; do IO_SHIELD_ASSUME_ROOT=1 IO_SHIELD_INSTALL_ROOT="$IR" bash "$IN_" $badw > /dev/null 2>&1; [ "$?" -eq 22 ] && pass "installer: bad user name refused: '${badw}'" || fail "installer accepted user '$badw'"; done
if [ "$ME" -ne 0 ]; then bash "$IN_" someone > /dev/null 2>&1; ok "installer without root: exit 2" '[ "$?" -eq 2 ]'; fi
ok "the timer's service needs BOTH the config and the acceptance flag" 'grep -qx "ConditionPathExists=/etc/dreamteam/io-shield.conf" "$ROOT/systemd/system/dreamteam-io-shield.service" && grep -qx "ConditionPathExists=/var/lib/dreamteam/io-shield.accepted" "$ROOT/systemd/system/dreamteam-io-shield.service"'
ok "the installer parses" 'bash -n "$IN_"'

echo "── units ────────────────────────────────────────────────────────"
DD="$ROOT/systemd/system/user@.service.d/20-delegate-io.conf"
ok "the user@ drop-in adds io and keeps the vendor's three controllers" 'grep -qx "Delegate=pids memory cpu io" "$DD" && grep -qx "\[Service\]" "$DD"'
ok "io-shield's service runs apply from /usr/local/sbin and waits for its config" 'grep -qx "ExecStart=/usr/local/sbin/dreamteam-io-shield apply" "$ROOT/systemd/system/dreamteam-io-shield.service" && grep -qx "ConditionPathExists=/etc/dreamteam/io-shield.conf" "$ROOT/systemd/system/dreamteam-io-shield.service"'
ok "the timer has its service and a CHECKS.md row" '[ -f "$ROOT/systemd/system/dreamteam-io-shield.timer" ] && grep -q "dreamteam-io-shield.timer" "$ROOT/docs/CHECKS.md"'
if command -v systemd-analyze > /dev/null 2>&1; then
  V="$T/v"; mkdir -p "$V"
  for f in "$ROOT"/systemd/system/dreamteam-io-shield.*; do sed -E 's|^ExecStart=.*|ExecStart=/bin/true|' "$f" > "$V/$(basename "$f")"; done
  if systemd-analyze verify "$V"/dreamteam-io-shield.timer > "$T/v.out" 2>&1; then pass "systemd-analyze accepts the two system unit files"
  else fail "unit files rejected: $(grep -v '^$' "$T/v.out" | head -3)"; fi
fi
for f in "$AC"; do
  body=$(awk "/python3 -I -c '/{on=1; next} on && /^[^#]*' \"\\$/{on=0} on" "$f")
  if [ -n "$body" ] && ! grep -q "'" <<<"$body"; then pass "no apostrophe inside the python embedded in $(basename "$f") (it would end the shell's quoted block)"; else fail "an apostrophe (or no body found) in the embedded python of $(basename "$f")"; fi
done

echo ""
echo "io-shield: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
