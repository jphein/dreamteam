#!/usr/bin/env bash
# Controls for scripts/gpu/guest_run.sh (promoted from GEMS tools/, 2026-09-29) on the host it runs on (katana or game).
# ON-HOST controls: real scopes, freezes and an NVENC encode, so tests/run.sh does not run them. Run by hand:
#   bash scripts/gpu/test_guest_run.sh Light: bash counters and
# sleeps, plus an ffmpeg NVENC encode for the GPU cap. It uses a private pause file and log (never
# ~/.gems-pause), and keeps its temp dir when anything fails.
set -u
T=$(cd "$(dirname "$0")" && pwd); d=$(mktemp -d "${TMPDIR:-/var/tmp}/guesttest.XXXX")
R=${GUEST_RUN:-$T/guest_run.sh}              # the launcher under test (a .new copy before an atomic swap)
export GUEST_PAUSE=$d/pause GUEST_LOG=$d/log GUEST_POLL_S=1 GUEST_CALM_S=4
pass=0; fail=0
ok() { if [ "$1" = 1 ]; then pass=$((pass + 1)); echo "  PASS $2"; else fail=$((fail + 1)); echo "  FAIL $2"; fi; }
b() { if "$@"; then echo 1; else echo 0; fi; }            # a test as 1/0, never an empty argument
unit_of_last() { grep -o 'gems-guest-[0-9]*-[0-9]*' "$GUEST_LOG" | tail -1; }
fstate() { systemctl --user show -p FreezerState --value "$1.scope" 2>/dev/null; }

# 1. admission refusals, exit-code pass-through
"$R" --mem 40G -- true 2>/dev/null; ok "$(b [ $? -eq 75 ])" "a cap above the host max is refused (75)"
touch "$GUEST_PAUSE"; "$R" --gpu-mem 0 --mem 256M -- true 2>/dev/null
ok "$(b [ $? -eq 75 ])" "the pause file refuses admission (75)"; rm -f "$GUEST_PAUSE"
"$R" --gpu-mem 0 --mem 256M -- bash -c 'exit 0' 2>/dev/null; ok "$(b [ $? -eq 0 ])" "a clean job exits 0"
"$R" --gpu-mem 0 --mem 256M -- bash -c 'exit 7' 2>/dev/null; ok "$(b [ $? -eq 7 ])" "the job's exit code passes through (7)"

# 2. freeze on the pause file, thaw after calm: the counter must stall, then resume
"$R" --gpu-mem 0 --mem 256M -- bash -c "for i in \$(seq 200); do echo \$i > $d/count; sleep 0.25; done" 2>/dev/null &
L=$!; sleep 3; u=$(unit_of_last); touch "$GUEST_PAUSE"
for _ in $(seq 10); do [ "$(fstate "$u")" = frozen ] && break; sleep 1; done
c1=$(cat "$d/count"); sleep 2; c2=$(cat "$d/count")
ok "$([ "$(fstate "$u")" = frozen ] && [ "$c1" = "$c2" ] && echo 1 || echo 0)" "the pause file freezes the scope ($(fstate "$u"), counter $c1 -> $c2)"
rm -f "$GUEST_PAUSE"; t0=$(date +%s)
for _ in $(seq 12); do [ "$(fstate "$u")" = running ] && break; sleep 1; done
tw=$(( $(date +%s) - t0 )); c3=$(cat "$d/count"); sleep 1.5; c4=$(cat "$d/count")
ok "$([ "$(fstate "$u")" = running ] && [ "$c4" != "$c3" ] && echo 1 || echo 0)" "the scope thaws after calm (${tw} s after removal, CALM_S=4; counter $c3 -> $c4)"
kill -TERM $L; wait $L 2>/dev/null

# 3. killing the launcher while frozen thaws the job and TERMs it (never left frozen)
"$R" --gpu-mem 0 --mem 256M -- bash -c "sleep 60" 2>/dev/null &
L=$!; sleep 2; u=$(unit_of_last); touch "$GUEST_PAUSE"
for _ in $(seq 10); do [ "$(fstate "$u")" = frozen ] && break; sleep 1; done
fz=$(fstate "$u"); kill -TERM $L; wait $L 2>/dev/null; sleep 2; rm -f "$GUEST_PAUSE"
act=$(systemctl --user show -p ActiveState --value "$u.scope" 2>/dev/null)
ok "$([ "$fz" = frozen ] && [ "$act" != active ] && echo 1 || echo 0)" "a launcher SIGTERM while frozen thaws and ends the job (was $fz, scope now ${act:-gone})"

# 3b. (game) the disk floor: a floor above the current free space must refuse admission
if [ "$(hostname -s)" = game ]; then
  fr=$(df -BG --output=avail / | tail -1 | tr -dc "0-9")
  GUEST_ROOT_MIN_GB=$((fr + 1)) "$R" --gpu-mem 0 --mem 256M -- true 2>/dev/null
  ok "$([ $? -eq 75 ] && echo 1 || echo 0)" "a root-free floor above the free space (${fr} GB) refuses admission (75)"
fi

# 3c. host budget: the SUM of running guest caps is bounded, not each job alone
if grep -q "^budget_used()" "$R"; then
  eval "$(sed -n "/^budget_used() {/,/^}/p" "$R")"
  export GUEST_MAXMEM_MB=4096; max=4096          # a shrunken budget: the holder fits free RAM on any host
  read -r um _ < <(budget_used); rem=$((max - um))
  if [ $rem -ge 2048 ]; then
    "$R" --gpu-mem 0 --mem $((rem - 1024))M -- sleep 30 2>/dev/null & HOLD=$!; sleep 3
    "$R" --gpu-mem 0 --mem 2048M -- true 2>/dev/null; r1=$?
    "$R" --gpu-mem 0 --mem 512M -- true 2>/dev/null; r2=$?
    kill -TERM $HOLD; wait $HOLD 2>/dev/null
    ok "$([ $r1 -eq 75 ] && [ $r2 -eq 0 ] && echo 1 || echo 0)" "budget: with $((rem - 1024)) MB held (plus ${um} MB already running), 2 GB is refused ($r1) and 512 MB admitted ($r2)"
    unset GUEST_MAXMEM_MB
  else
    echo "  SKIP budget test: only ${rem} MB of budget left"
  fi
fi

# 3d. (katana) the call guard: a SECOND reader of the virtual camera (not OBS) blocks and freezes GPU jobs
if [ "$(hostname -s)" = katana ]; then
  export GUEST_CALL_DEV=$d/video9; : > $GUEST_CALL_DEV
  cp /bin/sleep $d/obs; $d/obs 120 3<$GUEST_CALL_DEV & OBS=$!               # comm "obs": the always-on writer
  sleep 0.5
  "$R" --gpu-mem 0.05 --mem 256M -- true 2>/dev/null
  ok "$([ $? -eq 0 ] && echo 1 || echo 0)" "call guard: OBS alone holding the camera does not block a GPU job"
  sleep 120 3<$GUEST_CALL_DEV & CALL=$!; sleep 0.5                          # a "call app" (comm sleep)
  "$R" --gpu-mem 0.05 --mem 256M -- true 2>/dev/null; g=$?
  "$R" --gpu-mem 0 --mem 256M -- true 2>/dev/null; c=$?
  ok "$([ $g -eq 75 ] && [ $c -eq 0 ] && echo 1 || echo 0)" "call guard: with a second reader a GPU job is refused ($g) and a CPU-only job admitted ($c)"
  kill $CALL; wait $CALL 2>/dev/null
  "$R" --gpu-mem 0.05 --mem 256M -- bash -c "for i in \$(seq 200); do echo \$i > $d/count2; sleep 0.25; done" 2>/dev/null &
  L=$!; sleep 3; u=$(unit_of_last); sleep 60 3<$GUEST_CALL_DEV & CALL=$!
  for _ in $(seq 10); do [ "$(fstate "$u")" = frozen ] && break; sleep 1; done; fz=$(fstate "$u")
  kill $CALL; wait $CALL 2>/dev/null
  for _ in $(seq 12); do [ "$(fstate "$u")" = running ] && break; sleep 1; done; th=$(fstate "$u")
  ok "$([ "$fz" = frozen ] && [ "$th" = running ] && echo 1 || echo 0)" "call guard: a running GPU job freezes when a call starts ($fz) and thaws after it ends ($th)"
  kill -TERM $L; wait $L 2>/dev/null; kill $OBS; wait $OBS 2>/dev/null; unset GUEST_CALL_DEV
fi

# 4. GPU cap: an NVENC encode holds a CUDA context > 50 MiB -> GPU_MEM_CAP -> terminated
if command -v ffmpeg >/dev/null; then
  "$R" --gpu-mem 0.05 --mem 2G -- ffmpeg -hide_banner -loglevel error -f lavfi \
      -i testsrc=size=1280x720:rate=30 -t 60 -c:v h264_nvenc -f null - 2>/dev/null
  rc=$?
  ok "$([ $rc -ne 0 ] && grep -q GPU_MEM_CAP "$GUEST_LOG" && echo 1 || echo 0)" "a job over its GPU cap is terminated (rc $rc, GPU_MEM_CAP logged)"
fi

echo "--- guard log"; cut -c1-170 "$GUEST_LOG" | sed 's/^/  /' | tail -16
echo "GUEST_RUN_TEST $([ $fail -eq 0 ] && echo PASS || echo FAIL) ($pass passed, $fail failed)"
if [ $fail -eq 0 ]; then rm -rf "$d"; else echo "kept $d for inspection"; fi
