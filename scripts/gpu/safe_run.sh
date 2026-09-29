#!/bin/bash
# dreamteam GPU fleet: the familiar launch form (spec docs/superpowers/specs/2026-09-29-gpu-fleet-design.md §4).
# PROMOTED 2026-09-29 by cirrus-scry from money/scratch/contests/gems/tools/safe_run.sh, logic unchanged.
# `dreamteam gpu run` calls it on familiar with thresholds from gpu/fleet.json in env; the defaults below
# are the GEMS values, so a direct call behaves exactly like the GEMS copy. Env (all optional):
#   GPU_REGEN_HEADROOM_MB (2048)  GPU_PROT_MIN_AVAIL_MB (6144)  GPU_PROT_MAX_SWAP_PCT (50)
#   GPU_ONE_HEAVY (1 on familiar)  GPU_HEAVY_PATHS ('fwork/gems|/archive/gems/')
#   GPU_MEMINFO (/proc/meminfo; a test seam)
#
# Launch ONE heavy job on familiar per scratch/contests/gems/FAMILIAR-RULES.md (Lucid; rule 1 as
# refined 20:40, rule 3 forms as tested 20:30). Still one job at a time, announced to morpheus-gems.
# PROMOTED to tools/ by morpheus-gems 2026-09-28 20:4x as the one launcher for every lane. Added:
# the rule-2 guard below, which refuses if another GEMS python process (command line under
# /fwork/gems/, RSS > 1 GB) is already resident, so "one heavy job at a time" is enforced in code.
# Supersedes tools/familiar_launch.sh.
#
#   safe_run.sh CAP CMD...              regenerable job (sweeps, table builds, resumable features)
#       admission: MemAvailable >= CAP + 2 GB (zram level is not a criterion for this form)
#       launch:    scope, MemoryMax=CAP, MemorySwapMax=0, oom_score_adj +500 (dies first), nice 19
#
#   safe_run.sh --protected CAP CMD...  training / hours-to-redo job
#       admission: MemAvailable >= 6 GB AND zram (swap) used < 50%   (the strict rule, unchanged)
#       launch:    scope, MemoryMax=CAP, MemorySwapMax=0, then sudo choom -300 on EVERY pid in the
#                  scope's cgroup.procs (twice, to close the fork race); no nice; exit code passed on
#
# CAP uses systemd's units: e.g. 2500M, 3G, 1.5G. Refusal exits 75 (EX_TEMPFAIL): retry later.
# Never add a bypass to this script; test launch paths on a copy with the check removed.
set -u
PROT=0
if [ "${1:-}" = "--protected" ]; then PROT=1; shift; fi
CAP=${1:?usage: safe_run.sh [--protected] CAP CMD...}; shift
[ $# -ge 1 ] || { echo "usage: safe_run.sh [--protected] CAP CMD..." >&2; exit 2; }
cap_mb=$(echo "$CAP" | awk '/^[0-9.]+[KMGT]?$/ { n = $0 + 0; u = substr($0, length($0));
  f = (u == "K") ? 1/1024 : (u == "G") ? 1024 : (u == "T") ? 1048576 : 1;
  if (u !~ /[KMGT]/) f = 1/1048576;             # bare number = bytes, as systemd reads it
  printf "%d", n * f; exit } END { if (NR == 0) exit 1 }')
[ -n "$cap_mb" ] && [ "$cap_mb" -gt 0 ] || { echo "bad CAP '$CAP' (use e.g. 2500M, 3G)" >&2; exit 2; }
MI=${GPU_MEMINFO:-/proc/meminfo}
HEAD_MB=${GPU_REGEN_HEADROOM_MB:-2048}; PMIN_MB=${GPU_PROT_MIN_AVAIL_MB:-6144}; PMAX_SWP=${GPU_PROT_MAX_SWAP_PCT:-50}
avail=$(awk '/MemAvailable/ {print int($2 / 1024)}' "$MI")
swp=$(awk '/SwapTotal/ {t = $2} /SwapFree/ {f = $2} END {print (t > 0) ? int(100 * (t - f) / t) : 0}' "$MI")
if [ $PROT -eq 1 ]; then
  need="MemAvailable >= ${PMIN_MB} MB and swap < ${PMAX_SWP}% (protected form)"
  [ "$avail" -ge "$PMIN_MB" ] && [ "$swp" -lt "$PMAX_SWP" ] && ok=1 || ok=0
else
  need="MemAvailable >= CAP + ${HEAD_MB} = $((cap_mb + HEAD_MB)) MB (regenerable form)"
  [ "$avail" -ge $((cap_mb + HEAD_MB)) ] && ok=1 || ok=0
fi
echo "admission $(date +%H:%M:%S): MemAvailable ${avail} MB, swap used ${swp}%, cap ${CAP} (${cap_mb} MB); need ${need}" >&2
if [ $ok -ne 1 ]; then echo "ADMISSION REFUSED" >&2; exit 75; fi
# rule 2: one heavy GEMS job at a time. Match on the executable (python) plus a GEMS path in the
# command line, so this script's own shell and the caller's ssh command never self-match.
# (familiar only: on gpu0/gpu1 a capped CPU job beside a GPU training run is the intended use)
# A python process over the RSS threshold counts as a GEMS job if "fwork/gems" is in its command
# line OR its working directory: relative launches from the GEMS tree (cd /var/tmp/fwork/gems;
# .venv/bin/python lanes/...) carry no absolute path, and an args-only match missed them (lucid,
# 20:4x: 0 of 1 synthetic relative launches counted). GUARD_MIN_RSS_KB may only LOWER the
# threshold (stricter), for testing without a 1 GB hog.
min_kb=1048576
if [ -n "${GUARD_MIN_RSS_KB:-}" ] && [ "$GUARD_MIN_RSS_KB" -lt "$min_kb" ]; then min_kb=$GUARD_MIN_RSS_KB; fi
heavy=""
ONE=${GPU_ONE_HEAVY:-$([ "$(hostname -s)" = familiar ] && echo 1 || echo 0)}
HPATHS=${GPU_HEAVY_PATHS:-fwork/gems|/archive/gems/}
if [ "$ONE" = 1 ]; then
  for pid in $(ps -eo pid=,rss=,comm= | awk -v m="$min_kb" '$3 ~ /^python/ && $2 > m {print $1}'); do
    where="$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null) $(readlink /proc/$pid/cwd 2>/dev/null)"
    printf '%s\n' "$where" | grep -qE "$HPATHS" && heavy="$heavy $pid"   # + archive tree (morpheus)
  done
fi
if [ -n "$heavy" ]; then
  echo "ADMISSION REFUSED: heavy GEMS job(s) already resident, pid(s)$heavy (rule 2: one at a time)" >&2
  exit 75
fi

if [ $PROT -eq 0 ]; then
  exec systemd-run --user --scope --quiet -p MemoryMax="$CAP" -p MemorySwapMax=0 \
       choom -n 500 -- nice -n 39 "$@"
fi
systemd-run --user --scope --quiet -p MemoryMax="$CAP" -p MemorySwapMax=0 "$@" &
J=$!
for pass in 1 2; do
  sleep 1
  [ -e "/proc/$J/cgroup" ] || break                      # job already finished
  CG=/sys/fs/cgroup$(cut -d: -f3 "/proc/$J/cgroup")
  for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do sudo -n choom -n -300 -p "$p" >/dev/null 2>&1; done
done
[ -e "/proc/$J/oom_score_adj" ] && echo "protected: pid $J oom_score_adj $(cat /proc/$J/oom_score_adj)" >&2
wait "$J"
