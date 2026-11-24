#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r5, PR A #280 and PR B of the split, Sen 2026-11-21): the
# memory a lane admitted by mem-gate will take before its process shows it. mem-gate's flock is released when the
# gate exits, BEFORE the caller starts the lane, so a GPU claim could lock, sample the pre-start footprint and admit
# in that gap. The gate, still holding the host lock, writes one reservation; a GPU claim's sampler
# (scripts/lib/gpu_fleet.py PROBE, the same READ rules inline for the ssh round trip, run under the claim's lock) and
# the gate itself (`outstanding`) count them.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line "<mb> <expires-epoch> <session> <type> <started-epoch|0> <id>
# <agent>" (a record from PR A has five fields: id and agent read as -), written tmp + rename. Every read and write
# runs under the HOST LOCK (DREAMTEAM_HOST_LOCK; --locked = the caller already holds it, as the gate does), so no
# reader can see or delete a half-written file.
#
# IDENTITY (PR B). The gate mints a per-spawn id, writes it here (field 6) and prefixes the Agent prompt with
# "[dreamteam reservation <id>]" through PreToolUse updatedInput, with no permissionDecision: the hooks reference
# (read 2026-11-21) gives SubagentStart only session_id, agent_id and agent_type (no env, no prompt, no tool_use_id),
# and SubagentStop agent_id plus agent_transcript_path, so the prompt is the one channel to the spawn and the
# subagent's transcript the one place the id comes back. `start` matches the class (session + type: equal sizes per
# class) and binds the file to agent_id (field 7); `stop` releases by the id from the transcript (exact), else by
# agent_id (exact), else by class. Attribution is exact from stop on, by class at start.
#
# LIFECYCLE. Unstarted: counts until it expires (90 s: the spawn never happened); then it becomes a TOMBSTONE
# (<file>.expired) that no scan counts and only `start` consumes, deleting it only after its late-start line appended
# (<dir>/../late-starts.log); tombstones older than a day are pruned, but `start` reads its token's tombstones BEFORE
# any scan or prune (PR B), so a start that is more than a day late is still a late start. Started: counts until the
# lane's SubagentStop releases it (`stop`), NEVER by time: SubagentStart is not proof the RSS is there yet.
#
# READS AND WRITES (#280 r2). `scan` is READ-ONLY: it parses every record (parse: a regular readable file, five or
# seven fields, bounded decimals with no leading zero, arithmetic in base 10) and reports each with its state,
# counting or expired; it never renames or deletes, and any bad record is exit 1 before anything else happens.
# `prune` is the ONE housekeeping writer: it runs only after a scan returned clean, tombstones expired unstarted
# records and removes day-old tombstones. The probe reads with the same rules and never writes. add, start and stop
# write their own record only. A reservations path that does not exist (ENOENT) is "0 0" / RESV,OK,0; one that
# cannot be reached for any other reason (EACCES on a parent, EIO, a file in its place) is exit 1 / RESV,ERR (PR B).
# Seams: DREAMTEAM_RESERVATIONS (default ~/.local/state/dreamteam/reservations, local disk), DREAMTEAM_HOST_LOCK,
# DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] [--locked]   write one (default 90 s), print its path
#   reservation.sh outstanding [--locked]      "<mb-sum> <count>" of the counting ones (exit 1 on a scan error)
#   reservation.sh live [--locked]             the MB sum of the counting ones (exit 1 on a scan error)
#   reservation.sh start <session> <type> [--agent AID]   tombstones first: a late start is logged, deleted, exit 5
#                                              (log append failed: kept, exit 1); else mark one unstarted reservation
#                                              of the class started and bound to AID; exit 0 · 3 none · 4 lock
#   reservation.sh stop <session> <type> [--id ID | --agent AID]   release by id, else by agent, else one started of
#                                              the class; exit 0 · 3 none · 4 lock
#   reservation.sh start-hook | stop-hook      SubagentStart / SubagentStop from stdin JSON; stop-hook reads the id
#                                              from agent_transcript_path; always exit 0, rc and missing ids logged
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
LOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
MAX_MB=1000000; TOMB_TTL=86400
now=$(date +%s)
LOCKED=0; OPT_ID=""; OPT_AGENT=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --locked) LOCKED=1 ;;
    --id) OPT_ID="${2:-}"; shift ;;
    --agent) OPT_AGENT="${2:-}"; shift ;;
    *) args+=("$1") ;;
  esac; shift
done
set -- "${args[@]}"
# a bounded decimal: digits only, at most 12, and no leading zero (a leading zero is octal to the shell's arithmetic:
# "0400" would count as 256); every arithmetic site still says 10#
valid() { case "${1:-}" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# the token fields as written and as matched: [A-Za-z0-9._:-] only, at most 128, other bytes become _, empty becomes -
san() { local s; s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-128); printf '%s' "${s:--}"; }
take_lock() {   # the host lock, unless the caller holds it (--locked); exit 4 = not taken, nothing changed
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>>"$LOCK" || { echo "reservation: cannot open the host lock $LOCK" >&2; exit 4; }
  flock -w "$WAIT" 9 || { echo "reservation: host lock $LOCK not taken within ${WAIT}s: nothing changed" >&2; exit 4; }
}
dir_ok() {      # 0 = readable directory · 2 = does not exist (ENOENT) · 1 = cannot be used (EACCES, EIO, a file, ...)
  local st
  if st=$(stat -c %F -- "$DIR" 2>&1); then
    [ "$st" = directory ] && [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "reservation: $DIR is not a readable directory" >&2; return 1; }
    return 0
  fi
  case "$st" in *"No such file or directory"*) return 2 ;; esac
  echo "reservation: cannot reach $DIR: $st" >&2; return 1
}
# parse <file>: sets fmb fexp fses ftyp fst fid fag from a regular, readable, well-formed record (live or tombstone);
# else return 1 with the reason. The ONLY way a number leaves a file.
parse() {
  [ -f "$1" ] && [ -r "$1" ] || { echo "reservation: $1 is not a readable file" >&2; return 1; }
  read -r fmb fexp fses ftyp fst fid fag < "$1" 2>/dev/null || { echo "reservation: cannot read $1" >&2; return 1; }
  fid="${fid:--}"; fag="${fag:--}"
  valid "$fmb" && valid "$fexp" && [ -n "${fses:-}" ] && [ -n "${ftyp:-}" ] && valid "${fst:-}" && [ "$((10#$fmb))" -le "$MAX_MB" ] \
    || { echo "reservation: malformed $1" >&2; return 1; }
}
expired() { [ "$fst" = 0 ] && [ "$((10#$fexp))" -le "$now" ]; }
# scan <callback>: READ-ONLY. Every live record is parsed; any bad one is return 1 and nothing else happens. Each good
# one is reported as "<callback> <file> <mb> <session> <type> <started> <counting|expired> <id> <agent>".
scan() {
  local f fmb fexp fses ftyp fst fid fag state
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in *.expired|*.tmp) continue ;; esac
    parse "$f" || return 1
    if expired; then state=expired; else state=counting; fi
    "$1" "$f" "$fmb" "$fses" "$ftyp" "$fst" "$state" "$fid" "$fag" || return 1
  done
}
# prune: the ONE housekeeping writer, run only after a scan returned clean: expired unstarted records become
# tombstones, tombstones older than a day go
prune() {
  local f fmb fexp fses ftyp fst fid fag
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
# late_start <session> <type> <agent>: the tombstones of the token, validated first; a match is logged and deleted
# only after the append succeeded (exit 5), an unloggable one kept (exit 1); return 0 = none
late_start() {
  local f fmb fexp fses ftyp fst fid fag
  for f in "$DIR"/*.expired; do [ -e "$f" ] || continue; parse "$f" || exit 1; done
  for f in "$DIR"/*.expired; do
    [ -e "$f" ] || continue
    parse "$f" || exit 1
    if [ "$fses" = "$1" ] && [ "$ftyp" = "$2" ]; then
      if printf '%s late start: %s %s id %s agent %s (its reservation expired %ss before SubagentStart; nothing covered the start)\n' "$(date -Is)" "$1" "$2" "$fid" "$3" "$(( now - 10#$fexp ))" >> "$DIR/../late-starts.log"; then
        rm -f -- "$f"; echo "reservation: the token $1 $2 had expired: logged as a late start" >&2; exit 5
      fi
      echo "reservation: late start of $1 $2 could not be logged: tombstone kept" >&2; exit 1
    fi
  done
  return 0
}
write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses=$(san "${4:-}"); typ=$(san "${5:-}"); id=$(san "$OPT_ID")
    valid "$mb" && valid "$ttl" && [ "$((10#$mb))" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded decimals" >&2; exit 2; }
    take_lock; mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now-$RANDOM"; write_atomic "$f" "$((10#$mb)) $((now + 10#$ttl)) $ses $typ 0 $id -" || exit 2; echo "$f" ;;
  outstanding|live)
    take_lock; sum=0; n=0
    acc() { [ "$6" = counting ] || return 0; sum=$((sum + 10#$2)); n=$((n + 1)); [ "$sum" -le "$MAX_MB" ]; }
    dir_ok; st=$?
    if [ "$st" = 0 ]; then scan acc || { echo "reservation: scan failed, nothing counted" >&2; exit 1; }; prune || { echo "reservation: prune failed" >&2; exit 1; }
    elif [ "$st" = 1 ]; then exit 1; fi
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); ag=$(san "$OPT_AGENT"); take_lock; mkdir -p "$DIR" 2>/dev/null
    late_start "$ses" "$typ" "$ag"      # tombstones BEFORE any scan or prune (PR B): a day-late start is still a late start
    oldest=""
    pick() { if [ "$6" = counting ] && [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick || exit 1
    if [ -n "$oldest" ]; then
      parse "$oldest" || exit 1; write_atomic "$oldest" "$fmb $fexp $fses $ftyp $now $fid $ag" || exit 1
      echo "$oldest"; exit 0
    fi
    prune || exit 1                  # an expired live record of the class becomes its tombstone: a late start too
    late_start "$ses" "$typ" "$ag"
    echo "reservation: no unstarted reservation for $ses $typ" >&2; exit 3 ;;
  stop)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); id=$(san "$OPT_ID"); ag=$(san "$OPT_AGENT"); take_lock
    byid=""; byag=""; byclass=""
    pick() {
      [ "$id" != - ] && [ "$7" = "$id" ] && byid="$1"
      [ "$ag" != - ] && [ "$8" = "$ag" ] && [ "$5" != 0 ] && byag="$1"
      if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" != 0 ]; then if [ -z "$byclass" ] || [ "$1" -ot "$byclass" ]; then byclass="$1"; fi; fi
      return 0
    }
    dir_ok >/dev/null 2>&1 && { scan pick || exit 1; }
    for f in "$byid" "$byag" "$byclass"; do [ -n "$f" ] && { rm -f -- "$f"; echo "$f"; exit 0; }; done
    echo "reservation: no started reservation for $ses $typ (id $id, agent $ag)" >&2; exit 3 ;;
  start-hook|stop-hook)
    verb="${1%-hook}"; j=$(cat 2>/dev/null)
    ses=$(printf '%s' "$j" | jq -r '.session_id // empty' 2>/dev/null); typ=$(printf '%s' "$j" | jq -r '.agent_type // empty' 2>/dev/null)
    aid=$(printf '%s' "$j" | jq -r '.agent_id // empty' 2>/dev/null)
    mkdir -p "$DIR" 2>/dev/null
    if [ -z "$ses" ] || [ -z "$typ" ]; then printf '%s %s-hook: no session_id or agent_type in the hook input: nothing marked\n' "$(date -Is)" "$verb" >> "$DIR/../start-hook.log"; exit 0; fi
    extra=()
    if [ "$verb" = stop ]; then
      tp=$(printf '%s' "$j" | jq -r '.agent_transcript_path // empty' 2>/dev/null); tp="${tp/#\~/$HOME}"
      rid=""; [ -n "$tp" ] && [ -f "$tp" ] && rid=$(head -c 1048576 -- "$tp" 2>/dev/null | grep -o 'dreamteam reservation [A-Za-z0-9._:-]*' | head -1 | awk '{print $3}')
      [ -n "$rid" ] && extra=(--id "$rid")
    fi
    [ -n "$aid" ] && extra+=(--agent "$aid")
    bash "$0" "$verb" "$ses" "$typ" "${extra[@]}" >/dev/null 2>>"$DIR/../start-hook.log"; rc=$?
    [ "$rc" -eq 0 ] || printf '%s %s-hook rc %s for %s %s agent %s\n' "$(date -Is)" "$verb" "$rc" "$ses" "$typ" "${aid:--}" >> "$DIR/../start-hook.log"
    exit 0 ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] | outstanding | live | start <session> <type> [--agent A] | stop <session> <type> [--id ID|--agent A] | start-hook | stop-hook  [--locked]" >&2; exit 2 ;;
esac
