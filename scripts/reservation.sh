#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r5, PR A of the split, Sen 2026-11-21): the memory a lane
# admitted by mem-gate will take before its process shows it. mem-gate's flock is released when the gate exits,
# BEFORE the caller starts the lane, so a GPU claim could lock, sample the pre-start footprint and admit in that gap.
# The gate, still holding the host lock, writes one reservation; a GPU claim's sampler (scripts/lib/gpu_fleet.py
# PROBE, the same READ rules inline for the ssh round trip, run under the claim's lock) and the gate itself
# (`outstanding`) count them.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line "<mb> <expires-epoch> <session> <type> <started-epoch|0>", written
# tmp + rename. Every read and write runs under the HOST LOCK (DREAMTEAM_HOST_LOCK; --locked = the caller already
# holds it, as the gate does), so no reader can see or delete a half-written file.
#
# LIFECYCLE. Unstarted: counts until it expires (90 s: the spawn never happened); then it becomes a TOMBSTONE
# (<file>.expired) that no scan counts and only `start` consumes, deleting it only after its late-start line appended
# (<dir>/../late-starts.log); tombstones older than a day are pruned. Started (`start`, SubagentStart): counts until
# the lane's SubagentStop releases it (`stop`), NEVER by time: SubagentStart is not proof the RSS is there yet.
#
# TOKEN. A reservation carries the admitting session's id and the Agent call's subagent_type, which SubagentStart and
# SubagentStop see again as session_id and agent_type. Parallel same-type spawns in one session hold reservations of
# the SAME size (perAgentMB at that gate), so `start` and `stop` count per token CLASS and the MB total is right
# whichever file is picked; WHICH file belongs to which spawn is not known.
#
# LIMITS AN OPERATOR MUST KNOW (deferred to PR B of the #256 split, Sen 2026-11-21 23:07):
#   1. No per-spawn identity: a late start or a stop is attributed to a class, not to the spawn; two same-type spawns
#      in one session can take each other's record. The MB arithmetic is unaffected; the late-start log names the
#      class.
#   2. `start` consults the tombstones after its scan and prune, and prune removes tombstones older than a day: a
#      start that is more than a day late is reported as "no reservation" (exit 3), not as a late start.
#   3. A reservations path that cannot be reached for a reason other than "does not exist" (EACCES on a parent, EIO)
#      is read as "never existed" (0 0 / RESV,OK,0) by the `-e` test; only an existing path that is not a readable
#      directory is an error.
#
# READS AND WRITES (#280 r2). `scan` is READ-ONLY: it parses every record (parse: a regular readable file, five
# fields, bounded decimals with no leading zero, arithmetic in base 10) and reports each with its state, counting or
# expired; it never renames or deletes, and any bad record is exit 1 before anything else happens. `prune` is the ONE
# housekeeping writer: it runs only after a scan returned clean, tombstones expired unstarted records and removes
# day-old tombstones. The probe reads with the same rules and never writes. add, start and stop write their own
# record only. Seams: DREAMTEAM_RESERVATIONS (default ~/.local/state/dreamteam/reservations, local disk),
# DREAMTEAM_HOST_LOCK, DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type] [--locked]   write one (default 90 s), print its path
#   reservation.sh outstanding [--locked]      "<mb-sum> <count>" of the counting ones (exit 1 on a scan error)
#   reservation.sh live [--locked]             the MB sum of the counting ones (exit 1 on a scan error)
#   reservation.sh start <session> <type>      mark one unstarted reservation of the class started; exit 0 · 3 none ·
#                                              4 lock not taken · 5 a tombstone of the class: a late start, logged then
#                                              deleted (log append failed: kept, exit 1)
#   reservation.sh stop <session> <type>       release one started reservation of the class; exit 0 · 3 none · 4 lock
#   reservation.sh start-hook | stop-hook      SubagentStart / SubagentStop from stdin JSON; always exit 0, rc logged
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
LOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
MAX_MB=1000000; TOMB_TTL=86400
now=$(date +%s)
LOCKED=0; args=(); for a in "$@"; do if [ "$a" = "--locked" ]; then LOCKED=1; else args+=("$a"); fi; done; set -- "${args[@]}"
# a bounded decimal: digits only, at most 12, and no leading zero (a leading zero is octal to the shell's arithmetic:
# "0400" would count as 256, Sen 2026-11-21 23:14 item 3); every arithmetic site still says 10# (r2 item 3)
valid() { case "${1:-}" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# the token fields as written and as matched (security review on 445fbf1e): [A-Za-z0-9._:-] only, at most 128, other
# bytes become _, empty becomes -; applied at add, start and stop alike so a raw hook value still matches its record
san() { local s; s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-128); printf '%s' "${s:--}"; }
take_lock() {   # the host lock, unless the caller holds it (--locked); exit 4 = not taken, nothing changed
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>>"$LOCK" || { echo "reservation: cannot open the host lock $LOCK" >&2; exit 4; }
  flock -w "$WAIT" 9 || { echo "reservation: host lock $LOCK not taken within ${WAIT}s: nothing changed" >&2; exit 4; }
}
dir_ok() {      # 0 = readable directory · 2 = does not exist (limit 3: any other unreachable path reads the same) · 1 = unusable
  [ -e "$DIR" ] || return 2
  [ -d "$DIR" ] && [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "reservation: $DIR is not a readable directory" >&2; return 1; }
}
# parse <file>: sets fmb fexp fses ftyp fst from a regular, readable, well-formed record (a live one or a tombstone);
# else return 1 with the reason. The ONLY way a number leaves a file.
parse() {
  [ -f "$1" ] && [ -r "$1" ] || { echo "reservation: $1 is not a readable file" >&2; return 1; }
  read -r fmb fexp fses ftyp fst < "$1" 2>/dev/null || { echo "reservation: cannot read $1" >&2; return 1; }
  valid "$fmb" && valid "$fexp" && [ -n "${fses:-}" ] && [ -n "${ftyp:-}" ] && valid "${fst:-}" && [ "$((10#$fmb))" -le "$MAX_MB" ] \
    || { echo "reservation: malformed $1" >&2; return 1; }
}
expired() { [ "$fst" = 0 ] && [ "$((10#$fexp))" -le "$now" ]; }
# scan <callback>: READ-ONLY. Every live record is parsed; any bad one is return 1 and nothing else happens. Each good
# one is reported as "<callback> <file> <mb> <session> <type> <started> <counting|expired>".
scan() {
  local f fmb fexp fses ftyp fst state
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.expired|*.tmp) continue ;; esac
    parse "$f" || return 1
    if expired; then state=expired; else state=counting; fi
    "$1" "$f" "$fmb" "$fses" "$ftyp" "$fst" "$state" || return 1
  done
}
# prune: the ONE housekeeping writer, run only after a scan returned clean: expired unstarted records become
# tombstones, tombstones older than a day go
prune() {
  local f fmb fexp fses ftyp fst
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.expired) [ "$(( now - $(stat -c %Y -- "$f" 2>/dev/null || echo "$now") ))" -gt "$TOMB_TTL" ] && rm -f -- "$f"; continue ;;
      *.tmp) continue ;;
    esac
    parse "$f" || return 1
    if expired; then mv -f -- "$f" "$f.expired" || return 1; fi
  done
}
write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses=$(san "${4:-}"); typ=$(san "${5:-}")
    valid "$mb" && valid "$ttl" && [ "$((10#$mb))" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded decimals" >&2; exit 2; }
    take_lock; mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now-$RANDOM"; write_atomic "$f" "$((10#$mb)) $((now + 10#$ttl)) $ses $typ 0" || exit 2; echo "$f" ;;
  outstanding|live)
    take_lock; sum=0; n=0
    acc() { [ "$6" = counting ] || return 0; sum=$((sum + 10#$2)); n=$((n + 1)); [ "$sum" -le "$MAX_MB" ]; }
    dir_ok; st=$?
    if [ "$st" = 0 ]; then scan acc || { echo "reservation: scan failed, nothing counted" >&2; exit 1; }; prune || { echo "reservation: prune failed" >&2; exit 1; }
    elif [ "$st" = 1 ]; then exit 1; fi
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); take_lock; mkdir -p "$DIR" 2>/dev/null
    for f in "$DIR"/*.expired; do [ -e "$f" ] || continue; parse "$f" || exit 1; done   # tombstones validated BEFORE any prune (#280 r3 ruling 2)
    oldest=""
    pick() { if [ "$6" = counting ] && [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick || exit 1
    if [ -n "$oldest" ]; then
      parse "$oldest" || exit 1; write_atomic "$oldest" "$fmb $fexp $fses $ftyp $now" || exit 1
      echo "$oldest"; exit 0
    fi
    prune || exit 1                  # an expired live record of the class becomes its tombstone before the look below
    for f in "$DIR"/*.expired; do   # no live match: a tombstone of the class is a LATE start
      [ -e "$f" ] || continue
      parse "$f" || exit 1            # a tombstone is evidence: an unparsable one is an error, kept for the operator
      if [ "$fses" = "$ses" ] && [ "$ftyp" = "$typ" ]; then
        # the tombstone goes only after its late-start line is on disk
        if printf '%s late start: %s %s (its reservation expired %ss before SubagentStart; nothing covered the start)\n' "$(date -Is)" "$ses" "$typ" "$(( now - 10#$fexp ))" >> "$DIR/../late-starts.log"; then
          rm -f -- "$f"; echo "reservation: the token $ses $typ had expired: logged as a late start" >&2; exit 5
        fi
        echo "reservation: late start of $ses $typ could not be logged: tombstone kept" >&2; exit 1
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
