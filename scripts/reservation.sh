#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r3, Sen 2026-11-18): the memory a lane admitted by mem-gate
# will take before its process shows it. mem-gate's flock is released when the gate exits, BEFORE the caller starts
# the lane, so a GPU claim could lock, sample the pre-start footprint and admit in that gap. The gate, still holding
# the host lock, writes one reservation; a GPU claim's sampler (scripts/lib/gpu_fleet.py PROBE, the same logic inline
# for the ssh round trip) and the gate itself (`outstanding`, r3 item 1) count the unexpired ones.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line "<mb> <expires-epoch> <session> <type> <started-epoch|0>". The
# TOKEN is <session> <type>: the admitting gate's session id and the Agent call's subagent_type (r3 item 3), which
# the lane's SubagentStart hook sees again as session_id and agent_type. `start` marks the lane's own reservation
# started, under the host lock (r3 item 2), and NEVER deletes it: a reservation counts until it expires (90 s), so
# the handoff from reserved to live RSS over-counts for at most 90 s and never under-counts. A start that finds its
# token expired is logged as a late start (r3 item 4: a SubagentStart hook cannot cancel the start; the record is
# the mechanism until one can). Seams: DREAMTEAM_RESERVATIONS (default ~/.local/state/dreamteam/reservations, local
# disk), DREAMTEAM_HOST_LOCK, DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type]   write one (default 90 s), print its path
#   reservation.sh outstanding                          print "<mb-sum> <count>" of the unexpired ones (prunes expired)
#   reservation.sh live                                 print the MB sum of the unexpired ones (prunes expired)
#   reservation.sh start <session> <type>               under the host lock, mark the oldest unexpired unstarted
#                                                       reservation of that token started; exit 0 marked · 3 none
#                                                       matching · 4 lock not taken (nothing changed) · 5 the match had
#                                                       expired (pruned, logged to <dir>/../late-starts.log)
#   reservation.sh start-hook                           SubagentStart: session_id + agent_type from stdin JSON → start;
#                                                       always exit 0 (a hook must not fail the start), rc in the log
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
LOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
MAX_MB=1000000
now=$(date +%s)
valid() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# scan: prune expired, then for each unexpired file call "$1 <file> <mb> <session> <type> <started>"
scan() {   # its locals are prefixed: bash scopes dynamically, and the callback compares against the caller's token vars
  local f fmb fexp fses ftyp fst
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || { rm -f -- "$f"; continue; }
    read -r fmb fexp fses ftyp fst < "$f" 2>/dev/null || { rm -f -- "$f"; continue; }
    if ! valid "$fmb" || ! valid "$fexp" || [ "$fmb" -gt "$MAX_MB" ] || [ "$fexp" -le "$now" ]; then rm -f -- "$f"; continue; fi
    "$1" "$f" "$fmb" "${fses:--}" "${ftyp:--}" "${fst:-0}"
  done
}
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses="${4:--}"; typ="${5:--}"
    valid "$mb" && valid "$ttl" && [ "$mb" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded integers" >&2; exit 2; }
    mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now-$RANDOM"; printf '%s %s %s %s 0\n' "$mb" "$((now + ttl))" "$ses" "$typ" > "$f" || exit 2; echo "$f" ;;
  outstanding|live)
    sum=0; n=0
    acc() { sum=$((sum + $2)); n=$((n + 1)); }
    [ -d "$DIR" ] && scan acc
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses="${2:?session}"; typ="${3:?type}"
    mkdir -p "$(dirname "$LOCK")" "$DIR" 2>/dev/null
    exec 9>>"$LOCK" || exit 4
    flock -w "$WAIT" 9 || { echo "reservation: host lock $LOCK not taken within ${WAIT}s: nothing changed" >&2; exit 4; }
    # the expired match first (r3 item 4): it is gone from scan's view, so look at every file for the token
    late=""
    for f in "$DIR"/*; do
      [ -f "$f" ] || continue
      read -r mb exp fses ftyp st < "$f" 2>/dev/null || continue
      if [ "$fses" = "$ses" ] && [ "$ftyp" = "$typ" ] && valid "$exp" && [ "$exp" -le "$now" ]; then late="$f"; fi
    done
    oldest=""
    pick() { if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick
    if [ -n "$oldest" ]; then
      read -r mb exp fses ftyp st < "$oldest"; printf '%s %s %s %s %s\n' "$mb" "$exp" "$fses" "$ftyp" "$now" > "$oldest"
      echo "$oldest"; exit 0
    fi
    if [ -n "$late" ]; then
      printf '%s late start: %s %s (token expired before SubagentStart; the reservation no longer covered it)\n' "$(date -Is)" "$ses" "$typ" >> "$DIR/../late-starts.log"
      rm -f -- "$late"; echo "reservation: the token $ses $typ had expired: logged as a late start" >&2; exit 5
    fi
    echo "reservation: no unstarted reservation for $ses $typ" >&2; exit 3 ;;
  start-hook)
    j=$(cat 2>/dev/null); ses=$(printf '%s' "$j" | jq -r '.session_id // empty' 2>/dev/null); typ=$(printf '%s' "$j" | jq -r '.agent_type // empty' 2>/dev/null)
    [ -n "$ses" ] && [ -n "$typ" ] || exit 0
    bash "$0" start "$ses" "$typ" >/dev/null 2>>"$DIR/../start-hook.log"; rc=$?
    [ "$rc" -eq 0 ] || printf '%s start-hook rc %s for %s %s\n' "$(date -Is)" "$rc" "$ses" "$typ" >> "$DIR/../start-hook.log"
    exit 0 ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] [session] [type] | outstanding | live | start <session> <type> | start-hook" >&2; exit 2 ;;
esac
