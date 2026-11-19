#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2, Sen 2026-11-18): the memory a lane admitted by mem-gate
# will take before its process is visible. mem-gate's flock is released when the gate exits, BEFORE the caller starts
# the lane, so a GPU claim could lock, sample the pre-start footprint and admit in that gap. The gate, still holding
# the host lock, writes one reservation; the lane's SessionStart consumes the oldest; a GPU claim's sampler
# (scripts/lib/gpu_fleet.py PROBE, the same logic inline for the ssh round trip) counts the unexpired ones.
#
# Files: <dir>/<gate pid>-<epoch>, one line "<mb> <expires-epoch>". The pid in the name is the ADMITTING GATE's (the
# lane's own pid does not exist at admission), so a reservation is matched to its lane by order, not by pid: each
# admitted spawn writes one, each session start consumes one. Seam: DREAMTEAM_RESERVATIONS (default
# ~/.local/state/dreamteam/reservations, local disk).
#
#   reservation.sh add <mb> [ttl-s]   write one (default 90 s), print its path
#   reservation.sh consume            remove the oldest unexpired one (the lane that just started), print its path
#   reservation.sh live               print the MB sum of the unexpired ones, pruning expired files
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
now=$(date +%s)
valid() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"
    valid "$mb" && valid "$ttl" || { echo "reservation: mb and ttl are integers" >&2; exit 2; }
    mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now"; printf '%s %s\n' "$mb" "$((now + ttl))" > "$f" || exit 2; echo "$f" ;;
  consume)
    oldest=""
    for f in "$DIR"/*; do
      [ -f "$f" ] || continue
      read -r mb exp < "$f" 2>/dev/null || continue
      if ! valid "$mb" || ! valid "$exp" || [ "$exp" -le "$now" ]; then rm -f -- "$f"; continue; fi
      if [ -z "$oldest" ] || [ "$f" -ot "$oldest" ]; then oldest="$f"; fi
    done
    [ -n "$oldest" ] && { echo "$oldest"; rm -f -- "$oldest"; }; exit 0 ;;
  live)
    sum=0
    for f in "$DIR"/*; do
      [ -f "$f" ] || continue
      read -r mb exp < "$f" 2>/dev/null || continue
      if valid "$mb" && valid "$exp" && [ "$exp" -gt "$now" ]; then sum=$((sum + mb)); else rm -f -- "$f"; fi
    done
    echo "$sum" ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] | consume | live" >&2; exit 2 ;;
esac
