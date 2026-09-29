#!/usr/bin/env bash
# dreamteam GPU fleet: katana's call watcher (spec 2026-09-29-gpu-fleet-design.md §3b).
#
# JP's OBS runs all day in the tray with its virtual camera on (the Kiyo-Call profile), holding the
# v4l2loopback device /dev/video9. So "OBS holds the camera" is NOT a call, and pausing on it would
# keep katana's 2080 Ti off-limits all day (the lead's correction, 2026-09-29; memory
# obs-virtualcam-not-a-call). A live call is a SECOND, non-OBS process reading the device. While one does:
#   - the pause file (~/.gems-pause) is written with a `callwatch` marker. Every guest-form job obeys it:
#     guest_run.sh refuses new GPU jobs and freezes running ones. If a pause file already exists and is not
#     ours (set by hand, on JP's word), it is left exactly as it is.
#   - running containers that hold a GPU (HostConfig.DeviceRequests) get `docker pause`. A container runs
#     outside a user scope, so freezing the launcher's cgroup does not reach it (morpheus-gems).
# After CALM_S seconds (default 60) with no call, ONLY our own pause file is removed and ONLY the
# containers we paused are unpaused. Detection mirrors guest_run.sh's call_live: one pass of
# `find /proc/*/fd -lname <dev>` (~50 ms for ~9k fds) instead of a readlink per fd, skipping comm obs*.
#
# Usage: callwatch.sh [--once]
#   Without --once it loops every POLL_S seconds (default 5); systemd/dreamteam-gpu-callwatch.service runs it.
# Env (tests): CALLWATCH_DEVS (space-separated; default /dev/video9) CALLWATCH_PAUSE CALLWATCH_STATE
#              CALLWATCH_LOG CALLWATCH_POLL_S CALLWATCH_CALM_S CALLWATCH_DOCKER
set -u
DEVS=${CALLWATCH_DEVS:-/dev/video9}
PAUSE=${CALLWATCH_PAUSE:-$HOME/.gems-pause}
STATE=${CALLWATCH_STATE:-$HOME/.claude/state/dreamteam/gpu/callwatch.state}
LOG=${CALLWATCH_LOG:-$HOME/.claude/state/dreamteam/gpu/callwatch.log}
POLL=${CALLWATCH_POLL_S:-5}; CALM=${CALLWATCH_CALM_S:-60}
DOCKER=${CALLWATCH_DOCKER:-docker}
mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"
say() { printf '%s [callwatch %s] %s\n' "$(date '+%F %T')" "$$" "$*" >> "$LOG"; }

holder() {  # "pid comm dev" of the first non-OBS process holding a watched device open
  local d dev fdd p c
  for d in $DEVS; do
    [ -e "$d" ] || continue
    dev=$(readlink -f "$d")
    for fdd in $(find /proc/[0-9]*/fd -maxdepth 1 -lname "$dev" -printf '%h\n' 2>/dev/null | sort -u); do
      p=${fdd#/proc/}; p=${p%%/*}; c=$(cat "/proc/$p/comm" 2>/dev/null)
      case "$c" in obs*|"") continue ;; esac
      echo "$p $c $d"; return 0
    done
  done
  return 1
}

gpu_containers() {  # running containers that request a GPU
  command -v "$DOCKER" >/dev/null 2>&1 || return 0
  "$DOCKER" ps --filter status=running --format '{{.Names}}' 2>/dev/null | while read -r n; do
    [ -n "$n" ] || continue
    dr=$("$DOCKER" inspect -f '{{json .HostConfig.DeviceRequests}}' "$n" 2>/dev/null)
    case "$dr" in ""|null|"[]") ;; *) echo "$n" ;; esac
  done
}

ours() { [ -f "$PAUSE" ] && head -c 9 "$PAUSE" 2>/dev/null | grep -qx callwatch; }

tick() {  # STATE holds "active <since>" or "calm <since>"; STATE.containers lists the containers we paused
  local h st now n
  now=$(date +%s); st=$(cat "$STATE" 2>/dev/null || true)
  if h=$(holder); then
    if [ "${st%% *}" != active ]; then
      say "CALL: pid/comm/device $h holds the camera"
      if [ -e "$PAUSE" ] && ! ours; then
        say "a pause file already exists and is not ours; leaving it: $PAUSE"
      else
        printf 'callwatch %s %s\n' "$now" "$h" > "$PAUSE"; say "PAUSED: wrote $PAUSE"
      fi
      for n in $(gpu_containers); do
        if "$DOCKER" pause "$n" >/dev/null 2>&1; then echo "$n" >> "$STATE.containers"; say "docker paused $n (holds a GPU)"; fi
      done
    fi
    echo "active $now" > "$STATE"
    return 0
  fi
  case "${st%% *}" in
    active) echo "calm $now" > "$STATE"; say "the call ended; clearing after ${CALM}s of calm" ;;
    calm)
      if [ $((now - ${st#calm })) -ge "$CALM" ]; then
        if ours; then rm -f "$PAUSE"; say "RESUMED: removed our $PAUSE"; fi
        if [ -s "$STATE.containers" ]; then
          while read -r n; do "$DOCKER" unpause "$n" >/dev/null 2>&1 && say "docker unpaused $n"; done < "$STATE.containers"
          rm -f "$STATE.containers"
        fi
        rm -f "$STATE"
      fi ;;
  esac
}

if [ "${1:-}" = --once ]; then tick; exit 0; fi
say "watching $DEVS every ${POLL}s (pause file $PAUSE, calm ${CALM}s)"
trap 'say "stopping"; exit 0' TERM INT
while :; do tick; sleep "$POLL"; done
