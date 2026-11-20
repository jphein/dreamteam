#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r4, Sen 2026-11-18): the memory a lane admitted by mem-gate
# will take before its process shows it. mem-gate's flock is released when the gate exits, BEFORE the caller starts
# the lane, so a GPU claim could lock, sample the pre-start footprint and admit in that gap. The gate, still holding
# the host lock, writes one reservation; a GPU claim's sampler (scripts/lib/gpu_fleet.py PROBE, the same rules inline
# for the ssh round trip, run under the claim's lock) and the gate itself (`outstanding`, r3 item 1) count them.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line "<mb> <expires-epoch> <session> <type> <started-epoch|0>", written
# tmp + rename (r4 item 7). Every read and write runs under the HOST LOCK (DREAMTEAM_HOST_LOCK; --locked = the caller
# already holds it, as the gate does), so no reader can see or delete a half-written file.
#
# LIFECYCLE. Unstarted: counts until it expires (90 s: the spawn never happened); then it becomes a TOMBSTONE
# (<file>.expired, r4 item 4) that a scan never counts and only `start` consumes, so a late start is still recognised
# after any number of scans; tombstones older than a day are removed. Started (`start`, SubagentStart): counts until
# the lane's SubagentStop releases it (`stop`), NEVER by time (r4 item 2: SubagentStart is not proof the RSS is there
# yet), so the handoff from reserved to live RSS over-counts for the lane's lifetime and never under-counts.
#
# TOKEN (r4 item 3, acknowledged ambiguity): a reservation carries the admitting session's id and the Agent call's
# subagent_type, which SubagentStart/SubagentStop see again as session_id and agent_type; no per-invocation id exists
# at both hooks. Parallel same-type spawns in one session hold reservations of the SAME size (perAgentMB at that gate),
# so start and stop count per token CLASS: each start marks one unstarted reservation of the class, each stop releases
# one started one; the sum is exact whichever file is picked. Attribution across the class is not claimed.
#
# A scan ERROR (an unreadable directory, a non-file entry, an unreadable or malformed file, a value past the bound)
# is exit 1 and deletes nothing (r4 item 1): the gate turns it into a block, the sampler into RESV,ERR. A directory
# that never existed is "0 0": nothing was ever reserved. Seams: DREAMTEAM_RESERVATIONS (default
# ~/.local/state/dreamteam/reservations, local disk), DREAMTEAM_HOST_LOCK, DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type] [--locked]   write one (default 90 s), print its path
#   reservation.sh outstanding [--locked]      print "<mb-sum> <count>" of the counting ones (exit 1 on a scan error)
#   reservation.sh live [--locked]             print the MB sum of the counting ones (exit 1 on a scan error)
#   reservation.sh start <session> <type>      mark one unstarted reservation of the token started; exit 0 marked ·
#                                              3 none · 4 lock not taken, nothing changed · 5 a tombstone of the token
#                                              was found instead: a LATE start, logged to <dir>/../late-starts.log
#   reservation.sh stop <session> <type>       release one started reservation of the token; exit 0 · 3 none · 4 lock
#   reservation.sh start-hook | stop-hook      SubagentStart / SubagentStop: session_id + agent_type from stdin JSON;
#                                              always exit 0 (a hook must not fail the lane), rc and missing ids logged
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
LOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
MAX_MB=1000000; TOMB_TTL=86400
now=$(date +%s)
LOCKED=0; args=(); for a in "$@"; do if [ "$a" = "--locked" ]; then LOCKED=1; else args+=("$a"); fi; done; set -- "${args[@]}"
valid() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# the token fields as written and as matched (security review on 445fbf1e): [A-Za-z0-9._:-] only, at most 128, other
# bytes become _, empty becomes -; applied at add, start and stop alike so a raw hook value still matches its record,
# and a scan never meets a record this script wrote that it cannot parse (one unparsable file is a fail-closed block)
san() { local s; s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-128); printf '%s' "${s:--}"; }
take_lock() {   # the host lock, unless the caller holds it (--locked); exit 4 = not taken, nothing changed
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>>"$LOCK" || { echo "reservation: cannot open the host lock $LOCK" >&2; exit 4; }
  flock -w "$WAIT" 9 || { echo "reservation: host lock $LOCK not taken within ${WAIT}s: nothing changed" >&2; exit 4; }
}
dir_ok() {      # 0 = readable directory · 2 = never existed · 1 = exists but unusable (a file, unreadable, unsearchable)
  [ -e "$DIR" ] || return 2
  [ -d "$DIR" ] && [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "reservation: $DIR is not a readable directory" >&2; return 1; }
}
# scan <callback>: for every counting reservation call "<callback> <file> <mb> <session> <type> <started>"; an
# expired unstarted one becomes a tombstone; any error is return 1 with nothing deleted
scan() {
  local f fmb fexp fses ftyp fst
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.expired) [ "$(( now - $(stat -c %Y -- "$f" 2>/dev/null || echo "$now") ))" -gt "$TOMB_TTL" ] && rm -f -- "$f"; continue ;; *.tmp) continue ;; esac
    [ -f "$f" ] && [ -r "$f" ] || { echo "reservation: $f is not a readable file" >&2; return 1; }
    read -r fmb fexp fses ftyp fst < "$f" 2>/dev/null || { echo "reservation: cannot read $f" >&2; return 1; }
    valid "$fmb" && valid "$fexp" && [ -n "${fses:-}" ] && [ -n "${ftyp:-}" ] && valid "${fst:-}" && [ "$fmb" -le "$MAX_MB" ] \
      || { echo "reservation: malformed $f" >&2; return 1; }
    if [ "$fst" = 0 ] && [ "$fexp" -le "$now" ]; then mv -f -- "$f" "$f.expired" || return 1; continue; fi
    "$1" "$f" "$fmb" "$fses" "$ftyp" "$fst" || return 1
  done
}
write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses=$(san "${4:-}"); typ=$(san "${5:-}")
    valid "$mb" && valid "$ttl" && [ "$mb" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded integers" >&2; exit 2; }
    take_lock; mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now-$RANDOM"; write_atomic "$f" "$mb $((now + ttl)) $ses $typ 0" || exit 2; echo "$f" ;;
  outstanding|live)
    take_lock; sum=0; n=0
    acc() { sum=$((sum + $2)); n=$((n + 1)); [ "$sum" -le "$MAX_MB" ]; }
    dir_ok; st=$?
    if [ "$st" = 0 ]; then scan acc || { echo "reservation: scan failed, nothing counted" >&2; exit 1; }
    elif [ "$st" = 1 ]; then exit 1; fi
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); take_lock; mkdir -p "$DIR" 2>/dev/null
    oldest=""
    pick() { if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick || exit 1
    if [ -n "$oldest" ]; then
      read -r fmb fexp fses ftyp fst < "$oldest"; write_atomic "$oldest" "$fmb $fexp $fses $ftyp $now" || exit 1
      echo "$oldest"; exit 0
    fi
    for f in "$DIR"/*.expired; do   # no live match: a tombstone of the token is a LATE start (r4 item 4)
      [ -f "$f" ] || continue
      read -r fmb fexp fses ftyp fst < "$f" 2>/dev/null || continue
      if [ "${fses:-}" = "$ses" ] && [ "${ftyp:-}" = "$typ" ]; then
        printf '%s late start: %s %s (its reservation expired %ss before SubagentStart; nothing covered the start)\n' "$(date -Is)" "$ses" "$typ" "$(( now - fexp ))" >> "$DIR/../late-starts.log"
        rm -f -- "$f"; echo "reservation: the token $ses $typ had expired: logged as a late start" >&2; exit 5
      fi
    done
    echo "reservation: no unstarted reservation for $ses $typ" >&2; exit 3 ;;
  stop)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); take_lock
    oldest=""
    pick() { if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" != 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    dir_ok >/dev/null 2>&1 && { scan pick || exit 1; }
    [ -n "$oldest" ] && { rm -f -- "$oldest"; echo "$oldest"; exit 0; }
    echo "reservation: no started reservation for $ses $typ" >&2; exit 3 ;;
  start-hook|stop-hook)
    verb="${1%-hook}"; j=$(cat 2>/dev/null)
    ses=$(printf '%s' "$j" | jq -r '.session_id // empty' 2>/dev/null); typ=$(printf '%s' "$j" | jq -r '.agent_type // empty' 2>/dev/null)
    mkdir -p "$DIR" 2>/dev/null
    if [ -z "$ses" ] || [ -z "$typ" ]; then printf '%s %s-hook: no session_id or agent_type in the hook input: nothing marked\n' "$(date -Is)" "$verb" >> "$DIR/../start-hook.log"; exit 0; fi
    bash "$0" "$verb" "$ses" "$typ" >/dev/null 2>>"$DIR/../start-hook.log"; rc=$?
    [ "$rc" -eq 0 ] || printf '%s %s-hook rc %s for %s %s\n' "$(date -Is)" "$verb" "$rc" "$ses" "$typ" >> "$DIR/../start-hook.log"
    exit 0 ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] [session] [type] | outstanding | live | start <session> <type> | stop <session> <type> | start-hook | stop-hook  [--locked]" >&2; exit 2 ;;
esac
