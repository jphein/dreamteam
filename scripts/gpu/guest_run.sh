#!/usr/bin/env bash
# dreamteam GPU fleet: the guest launch form, for desktop hosts (spec 2026-09-29-gpu-fleet-design.md §4).
# PROMOTED 2026-09-29 by cirrus-scry from money/scratch/contests/gems/tools/guest_run.sh, logic unchanged.
# `dreamteam gpu run` passes the host's budget from gpu/fleet.json in env; without it, the original
# katana/game table below applies, so a direct call behaves exactly like the GEMS copy. Env (optional):
#   GUEST_MAX_MEM_MB  GUEST_MAX_GPU_MIB  GUEST_HEADROOM_MB  (all three, or none)
#
# guest_run.sh: the guarded launcher for GEMS jobs on the SHARED DESKTOP hosts (morpheus-gems,
# 2026-09-28, derived from tools/safe_run.sh; caps from the lead, 23:2x):
#   katana: JP's workstation. RTX 2080 Ti 11 GB, which also drives the desktop; 31 GB RAM.
#   game:   GTX 1650 4 GB, 15 GB RAM, root disk 96% full, with an active graphical session.
# Guards, all enforced here:
#   - scope MemoryMax=CAP, MemorySwapMax=0, nice 19, ionice idle. The host BUDGET (katana 12G RAM /
#     9 GB GPU, game 8G / 3.5 GB) bounds the SUM of the caps of all running guest scopes, not just
#     one job: reverie stacked 6G + 8G + 4G on katana at 23:53 (2026-09-28), each admitted alone.
#   - admission: MemAvailable >= CAP + desktop headroom (katana 4 GB, game 2 GB); free GPU memory
#     >= GPU cap + 1 GB; game root free >= 8 GB + --disk-need; and no ~/.gems-pause.
#     Refusal exits 75: retry later, never bypass.
#   - GPU cap: --gpu-mem GB (<= katana 9, game 3.5), default min(host max, free - 1 GB), and
#     --gpu-mem 0 for a CPU-only job. The watchdog TERMs (then KILLs after 30 s) a job whose
#     processes hold more. The cap is also exported as GEMS_GPU_CAP_MB for jobs that self-limit.
#   - desktop first: the scope is FROZEN (cgroup freezer; no work is lost) while
#       * the DESKTOP's own cgroup (user@UID.service/session.slice, where the GNOME session lives)
#         shows CPU PSI some avg10 > 10 or memory PSI some avg10 > 5. The job's scope sits in
#         app.slice, so its own starved threads never count; or
#       * ~/.gems-pause exists (any agent may touch it on JP's word; freezes within POLL s); or
#       * (game) root free < 8 GB.
#     It is thawed after CALM_S s with every signal under half its threshold (hysteresis).
#     System-wide IO PSI is deliberately NOT used: on 2026-09-28 katana read io some ~90% / full
#     ~48% at ~2 MB/s, i.e. device stalls (a wedged USB hub), not load.
#   - katana CALL GUARD (lead 2026-09-29): OBS keeps the virtual camera (/dev/video9) open all day,
#     so a live call shows up as a SECOND process opening it. While a non-OBS process holds it,
#     GPU jobs (GPU cap > 0) are refused at admission and frozen while running; CPU-only jobs are
#     unaffected. It thaws after CALM_S s with no call.
#   - NOT detected: other GPU-side stutter (CUDA vs the compositor on katana's shared 2080 Ti).
#     The remedy is ~/.gems-pause on JP's word.
# Every guard action is a timed line in $GUEST_LOG (default ~/.gems-guest.log) and on stderr.
# Usage: guest_run.sh [--mem CAP] [--gpu-mem GB] [--disk-need GB] [--] CMD...
# Exit: 75 admission refused, 2 usage, 143/137 terminated by the GPU guard, else the job's code.
set -u
H=$(hostname -s)
if [ -n "${GUEST_MAX_MEM_MB:-}" ] && [ -n "${GUEST_MAX_GPU_MIB:-}" ] && [ -n "${GUEST_HEADROOM_MB:-}" ]; then
  MAXMEM_MB=$GUEST_MAX_MEM_MB; MAXGPU_MB=$GUEST_MAX_GPU_MIB; HEAD_MB=$GUEST_HEADROOM_MB; MEM=4G   # from gpu/fleet.json
else
  case "$H" in
    katana) MAXMEM_MB=12288; MEM=6G; MAXGPU_MB=9216; HEAD_MB=4096 ;;
    game)   MAXMEM_MB=8192;  MEM=4G; MAXGPU_MB=3584; HEAD_MB=2048 ;;
    *) echo "guest_run.sh: katana and game only (familiar: tools/safe_run.sh; gpu0/gpu1: the queue scripts)" >&2; exit 2 ;;
  esac
fi
GPU_REQ=""; DISK_NEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mem) MEM=$2; shift 2 ;;
    --gpu-mem) GPU_REQ=$2; shift 2 ;;
    --disk-need) DISK_NEED=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "guest_run.sh: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "usage: guest_run.sh [--mem CAP] [--gpu-mem GB] [--disk-need GB] [--] CMD..." >&2; exit 2; }
LOG=${GUEST_LOG:-$HOME/.gems-guest.log}; POLL=${GUEST_POLL_S:-5}; CALM_S=${GUEST_CALM_S:-60}
PAUSE=${GUEST_PAUSE:-$HOME/.gems-pause}   # override only for tests
CPU_T=${GUEST_CPU_PSI:-10}; MEM_T=${GUEST_MEM_PSI:-5}; ROOT_MIN_GB=${GUEST_ROOT_MIN_GB:-8}   # overrides for tests only
CALL_DEV=${GUEST_CALL_DEV:-/dev/video9}   # katana's virtual camera; override only for tests
call_live() {  # prints "pid comm" of the first non-OBS process holding CALL_DEV open; katana only
  # one find over /proc/*/fd (~50 ms for ~9k fds): a readlink per fd spawned ~9k processes a pass
  [ "$H" = katana ] && [ -e "$CALL_DEV" ] || return 1
  local dev d p c
  dev=$(readlink -f "$CALL_DEV")
  for d in $(find /proc/[0-9]*/fd -maxdepth 1 -lname "$dev" -printf '%h\n' 2>/dev/null | sort -u); do
    p=${d#/proc/}; p=${p%%/*}; c=$(cat /proc/$p/comm 2>/dev/null)
    case "$c" in obs*|"") continue ;; esac
    echo "$p $c"; return 0
  done
  return 1
}
say() { local m; m="$(date '+%F %T') [$H guest_run $$] $*"; echo "$m" >&2; echo "$m" >> "$LOG"; }
refuse() { say "ADMISSION REFUSED: $*"; exit 75; }

mem_mb=$(echo "$MEM" | awk '/^[0-9.]+[KMGT]?$/ { n = $0 + 0; u = substr($0, length($0));
  f = (u == "K") ? 1/1024 : (u == "G") ? 1024 : (u == "T") ? 1048576 : 1;
  if (u !~ /[KMGT]/) f = 1/1048576; printf "%d", n * f; exit } END { if (NR == 0) exit 1 }')
[ -n "$mem_mb" ] && [ "$mem_mb" -gt 0 ] || { echo "bad --mem '$MEM' (use e.g. 6G, 2500M)" >&2; exit 2; }
# GUEST_MAXMEM_MB may only LOWER the host budget (for tests), never raise it
if [ -n "${GUEST_MAXMEM_MB:-}" ] && [ "$GUEST_MAXMEM_MB" -lt "$MAXMEM_MB" ]; then MAXMEM_MB=$GUEST_MAXMEM_MB; fi
[ "$mem_mb" -le $MAXMEM_MB ] || refuse "--mem $MEM is above $H's max $((MAXMEM_MB / 1024))G"
[ -e "$PAUSE" ] && refuse "$PAUSE exists (JP asked for a pause); remove it to allow jobs"
avail=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
read -r gtot gused < <(nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits | head -1 | tr -d ',')
gfree=$((gtot - gused))
if [ -n "$GPU_REQ" ]; then
  gcap=$(awk -v g="$GPU_REQ" 'BEGIN { printf "%d", g * 1024 }')
  [ "$gcap" -le $MAXGPU_MB ] || refuse "--gpu-mem $GPU_REQ GB is above $H's max $((MAXGPU_MB / 1024)) GB"
else
  gcap=$(( gfree - 1024 < MAXGPU_MB ? gfree - 1024 : MAXGPU_MB ))
  [ "$gcap" -gt 0 ] || gcap=0
fi
rootfree_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }
budget_used() {  # MB of memory caps and GPU caps held by running guest scopes
  local u mu=0 gu=0 m g pids
  for u in $(systemctl --user list-units --type=scope --no-legend 'gems-guest-*' 2>/dev/null | awk '{print $1}'); do
    m=$(systemctl --user show -p MemoryMax --value "$u" 2>/dev/null); [ "$m" -ge 0 ] 2>/dev/null || m=0
    mu=$((mu + m / 1048576))
    g=$(systemctl --user show -p Description --value "$u" 2>/dev/null | sed -n 's/.* gpu=\([0-9]*\).*/\1/p')
    if [ -z "$g" ]; then     # a scope from before the budget: count its measured GPU use
      pids=" $(tr '\n' ' ' < "/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$u")/cgroup.procs" 2>/dev/null) "
      g=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
          awk -F', *' -v p="$pids" 'index(p, " " $1 " ") { s += $2 } END { print s + 0 }')
    fi
    gu=$((gu + g))
  done
  echo "$mu $gu"
}
read -r bmem bgpu < <(budget_used)
if [ -z "$GPU_REQ" ]; then gcap=$(( gcap < MAXGPU_MB - bgpu ? gcap : MAXGPU_MB - bgpu )); [ "$gcap" -gt 0 ] || gcap=0; fi
say "admission: MemAvailable ${avail} MB (need $((mem_mb + HEAD_MB)) = cap ${MEM} + ${HEAD_MB} headroom), GPU free ${gfree} MiB (cap ${gcap} MiB + 1024 margin), root free $(rootfree_gb) GB, budget in use ${bmem}/${MAXMEM_MB} MB RAM and ${bgpu}/${MAXGPU_MB} MiB GPU"
[ $((bmem + mem_mb)) -le $MAXMEM_MB ] || refuse "host budget: running guest caps ${bmem} MB + this ${mem_mb} MB > ${MAXMEM_MB} MB"
if [ "$gcap" -gt 0 ] && [ $((bgpu + gcap)) -gt $MAXGPU_MB ]; then refuse "host GPU budget: running ${bgpu} MiB + this ${gcap} MiB > ${MAXGPU_MB} MiB"; fi
[ "$avail" -ge $((mem_mb + HEAD_MB)) ] || refuse "MemAvailable ${avail} MB < $((mem_mb + HEAD_MB)) MB"
if [ "$gcap" -gt 0 ] && [ "$gfree" -lt $((gcap + 1024)) ]; then refuse "GPU free ${gfree} MiB < cap ${gcap} + 1024 MiB"; fi
if [ "$gcap" -gt 0 ] && cl=$(call_live); then refuse "a call app is reading the virtual camera ($CALL_DEV: pid/comm $cl); GPU jobs wait until the call ends (CPU-only --gpu-mem 0 is allowed)"; fi
if [ "$H" = game ]; then
  [ "$(rootfree_gb)" -ge $((ROOT_MIN_GB + DISK_NEED)) ] || refuse "root free $(rootfree_gb) GB < ${ROOT_MIN_GB} + --disk-need ${DISK_NEED} GB"
fi

UNIT=gems-guest-$$-$(date +%s)
export GEMS_GPU_CAP_MB=$gcap
systemd-run --user --scope --quiet --unit="$UNIT" --description="gems-guest mem=${mem_mb} gpu=${gcap}" -p MemoryMax="$MEM" -p MemorySwapMax=0 \
    nice -n 39 ionice -c3 "$@" &          # 39 clamps to 19 even from an ssh session at -10
J=$!
frozen=0
thaw_if() { [ $frozen = 1 ] && systemctl --user thaw "$UNIT.scope" 2>/dev/null && frozen=0; return 0; }
trap 'say "launcher got SIGTERM/SIGINT: thawing and forwarding SIGTERM to the job"; thaw_if; systemctl --user kill --signal=TERM "$UNIT.scope" 2>/dev/null' TERM INT
trap 'thaw_if' EXIT                     # never leave a job frozen behind
say "launched $UNIT (pid $J): mem cap $MEM, GPU cap ${gcap} MiB; cmd: $*"

SESS=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/session.slice
[ -r "$SESS/cpu.pressure" ] || say "note: no desktop session cgroup ($SESS), so PSI pausing is off; ~/.gems-pause still works"
psi() { awk '/^some/ { sub("avg10=", "", $2); print $2 + 0 }' "$1" 2>/dev/null || echo 0; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
calm=0
while kill -0 "$J" 2>/dev/null; do
  sleep "$POLL"
  kill -0 "$J" 2>/dev/null || break
  CG=/sys/fs/cgroup$(cut -d: -f3 "/proc/$J/cgroup" 2>/dev/null)
  pids=" $(tr '\n' ' ' < "$CG/cgroup.procs" 2>/dev/null) "
  # GPU cap (a frozen job cannot allocate, so skip while frozen)
  if [ $frozen = 0 ] && [ "$gcap" -gt 0 ]; then
    used=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
           awk -F', *' -v p="$pids" 'index(p, " " $1 " ") { s += $2 } END { print s + 0 }')
    if [ "$used" -gt "$gcap" ]; then
      say "GPU_MEM_CAP: the job holds ${used} MiB > cap ${gcap} MiB; SIGTERM"
      systemctl --user kill --signal=TERM "$UNIT.scope" 2>/dev/null
      for _ in $(seq 30); do kill -0 "$J" 2>/dev/null || break; sleep 1; done
      kill -0 "$J" 2>/dev/null && { say "GPU_MEM_CAP: still alive after 30 s; SIGKILL"; systemctl --user kill --signal=KILL "$UNIT.scope" 2>/dev/null; }
      break
    fi
  fi
  # desktop first
  reason=""; cpu=$(psi "$SESS/cpu.pressure"); memp=$(psi "$SESS/memory.pressure")
  [ -e "$PAUSE" ] && reason="$PAUSE exists"
  if [ "$gcap" -gt 0 ] && cl=$(call_live); then reason="${reason:+$reason; }call app on $CALL_DEV (pid/comm $cl)"; fi
  gt "$cpu" "$CPU_T" && reason="${reason:+$reason; }desktop CPU PSI ${cpu}% > ${CPU_T}"
  gt "$memp" "$MEM_T" && reason="${reason:+$reason; }desktop memory PSI ${memp}% > ${MEM_T}"
  if [ "$H" = game ]; then
    rf=$(rootfree_gb)
    if [ "$rf" -lt $ROOT_MIN_GB ] || { [ $frozen = 1 ] && [ "$rf" -lt $((ROOT_MIN_GB + 1)) ]; }; then
      reason="${reason:+$reason; }root free ${rf} GB < ${ROOT_MIN_GB}"
    fi
  fi
  if [ -n "$reason" ]; then
    calm=0
    if [ $frozen = 0 ]; then systemctl --user freeze "$UNIT.scope" && frozen=1 && say "FROZEN: $reason"; fi
  elif [ $frozen = 1 ]; then
    if gt "$cpu" "$(awk -v t="$CPU_T" 'BEGIN { print t / 2 }')" || gt "$memp" "$(awk -v t="$MEM_T" 'BEGIN { print t / 2 }')"; then
      calm=0
    else
      calm=$((calm + POLL))
      if [ $calm -ge "$CALM_S" ]; then systemctl --user thaw "$UNIT.scope" && frozen=0 && calm=0 && say "THAWED after ${CALM_S} s calm"; fi
    fi
  fi
done
wait "$J"; rc=$?
say "exit $rc ($UNIT)"
exit $rc
