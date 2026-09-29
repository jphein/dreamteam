#!/usr/bin/env bash
# dreamteam GPU fleet: the remote launch form, for gpu0 and gpu1 (spec 2026-09-29-gpu-fleet-design.md §4).
# Generalized 2026-09-29 by cirrus-scry from money/scratch/contests/gems/lanes/drift/gpu1_launch.sh
# (drift-gems). It launches one job on one card, detached and sleep-locked, and runs ON the GPU host:
# `dreamteam gpu run` installs it there, checksum-verified. GEMS specifics (holdouts, g0-/g1- names,
# run_exp.sh, --threads 1) stay in GEMS's own wrapper.
#
# Usage: remote_run.sh --gpu IDX --cap CAP --name NAME --log LOG [--no-cap] -- CMD...
#   The job runs with CUDA_VISIBLE_DEVICES=IDX under `systemd-inhibit --what=sleep`, so a stray
#   `realm wol sleep` is refused while it lives. It is detached (setsid nohup, stdin /dev/null), with
#   stdout and stderr to LOG.
#   CAP: MemoryMax with MemorySwapMax=0. Where the user lingers, a --user scope is used. Otherwise a
#   SYSTEM scope run as you (sudo -n systemd-run --scope --uid --gid). gpu0 and gpu1 do not linger
#   (loginctl Linger=no, 2026-09-29), so a --user scope there would end with the ssh session and kill
#   the job. With neither lingering nor sudo, the job runs uncapped and says so; the claim's pair rule
#   still admitted it. sudo resets the environment, so CUDA_VISIBLE_DEVICES, HOME and PATH are passed
#   through env explicitly.
# Exits: 0 launched · 2 usage · 5 GPU not usable (nvidia-smi failed: the driver lib/module mismatch trap)
#        · 17 a run with this log exists · 75 below the disk floor.
set -euo pipefail
IDX=""; CAP=""; NAME=""; LOG=""; NOCAP=0; FLOOR_GB=${GPU_DISK_FLOOR_GB:-10}
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu) IDX=$2; shift 2 ;;
    --cap) CAP=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --log) LOG=$2; shift 2 ;;
    --no-cap) NOCAP=1; shift ;;
    --) shift; break ;;
    *) echo "remote_run.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ $# -lt 1 ] || ! [[ $IDX =~ ^[0-9]+$ ]] || [ -z "$NAME" ] || [ -z "$LOG" ]; then
  echo "usage: remote_run.sh --gpu IDX --cap CAP --name NAME --log LOG [--no-cap] -- CMD..." >&2; exit 2
fi
H=$(hostname -s)
SMI=${GPU_NVIDIA_SMI:-nvidia-smi}
"$SMI" -i "$IDX" --query-gpu=name --format=csv,noheader >/dev/null 2>&1 \
  || { echo "GPU$IDX not usable on $H: nvidia-smi failed (a driver lib/module mismatch waits for a reboot?)" >&2; exit 5; }
[ ! -e "$LOG" ] || { echo "a run with this log exists on $H: $LOG (pick another --name)" >&2; exit 17; }
dir=$(dirname "$LOG"); mkdir -p "$dir"
free_gb=$(df -BG --output=avail "$dir" | tail -1 | tr -dc 0-9)
[ "${free_gb:-0}" -ge "$FLOOR_GB" ] || { echo "ADMISSION REFUSED: $dir has ${free_gb} GB free < floor ${FLOOR_GB} GB" >&2; exit 75; }
wrap=(); how="uncapped"
if [ $NOCAP -eq 0 ] && [ -n "$CAP" ]; then
  if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
    wrap=(systemd-run --user --scope --quiet -p MemoryMax="$CAP" -p MemorySwapMax=0 --); how="user scope"
  elif sudo -n true 2>/dev/null; then
    wrap=(sudo -n systemd-run --scope --quiet -p MemoryMax="$CAP" -p MemorySwapMax=0 --uid="$(id -u)" --gid="$(id -g)" --)
    how="system scope as $(id -un)"
  else
    echo "note: no lingering and no passwordless sudo on $H: the job runs UNCAPPED (the claim's pair rule admitted it)" >&2
  fi
fi
setsid nohup systemd-inhibit --what=sleep --mode=block --who="dreamteam-gpu:$NAME" --why="$NAME on GPU$IDX" \
  "${wrap[@]}" env CUDA_VISIBLE_DEVICES="$IDX" HOME="$HOME" PATH="$PATH" "$@" > "$LOG" 2>&1 < /dev/null &
pid=$!
echo "launched $NAME on $H GPU$IDX: cap ${CAP:-none} ($how); log $LOG"
echo "$pid"
