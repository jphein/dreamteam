#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r5, Sen 2026-11-18..21): the memory a lane admitted by
# mem-gate will take before its process shows it. mem-gate's flock is released when the gate exits, BEFORE the caller
# starts the lane, so a GPU claim could lock, sample the pre-start footprint and admit in that gap. The gate, still
# holding the host lock, writes one reservation; a GPU claim's sampler (scripts/lib/gpu_fleet.py PROBE, the same rules
# inline for the ssh round trip, run under the claim's lock) and the gate itself (`outstanding`) count them.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line "<mb> <expires> <session> <type> <started-epoch|0> <id> <agent>",
# written tmp + rename. Every read and write runs under the HOST LOCK (DREAMTEAM_HOST_LOCK; --locked = the caller
# already holds it, as the gate does), so no reader can see or delete a half-written file.
#
# IDENTITY (r5 item 3). The gate mints a per-spawn id, writes it here (field 6) and prefixes the Agent prompt with
# "[dreamteam reservation <id>]" through PreToolUse updatedInput: the hooks reference (read 2026-11-21) gives
# SubagentStart only session_id, agent_id and agent_type (no env, no prompt, no tool_use_id), and SubagentStop
# agent_id plus agent_transcript_path, so the prompt is the one channel to the spawn and the subagent's transcript the
# one place the id comes back. `start` matches the class (session + type: equal sizes per class) and binds the file
# to agent_id (field 7); `stop` releases by the id from the transcript (exact), else by agent_id (exact), else by
# class. Attribution between two same-class spawns is exact from stop on, best-effort at start, and said here.
#
# LIFECYCLE. Unstarted: counts until it expires (90 s: the spawn never happened); then it becomes a TOMBSTONE
# (<file>.expired) that no scan counts. A late `start` reads tombstones BEFORE any scan, appends its late-start line
# and deletes the tombstone only after the append succeeded (r5 item 4). A scan logs a tombstone older than a day as
# abandoned and renames it .expired.logged on success; only .expired.logged tombstones older than a day are pruned.
# Started: counts until the lane's SubagentStop releases it, never by time (r4 item 2).
#
# ERRORS (r5 item 1). A directory that never existed (ENOENT) is "0 0": nothing was ever reserved. A directory that
# cannot be reached or read (EACCES, EIO, a parent without x, a file in its place) is exit 1 and deletes nothing: the
# gate turns it into a block, the sampler into RESV,ERR. Any unreadable or malformed file is the same error.
# Seams: DREAMTEAM_RESERVATIONS (default ~/.local/state/dreamteam/reservations, local disk), DREAMTEAM_HOST_LOCK,
# DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] [--locked]   write one (default 90 s), print its path
#   reservation.sh outstanding [--locked]      "<mb-sum> <count>" of the counting ones (exit 1 on a scan error)
#   reservation.sh live [--locked]             the MB sum of the counting ones (exit 1 on a scan error)
#   reservation.sh start <session> <type> [--agent AID]   a late start first (tombstone: logged, deleted, exit 5;
#                                              log failed: kept, exit 1); else mark one unstarted reservation of the
#                                              class started and bound to AID; exit 0 · 3 none · 4 lock not taken
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
valid() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# the token fields as written and as matched (security review on 445fbf1e): [A-Za-z0-9._:-] only, at most 128, other
# bytes become _, empty becomes -; applied everywhere alike so a raw hook value still matches its record
san() { local s; s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-128); printf '%s' "${s:--}"; }
take_lock() {   # the host lock, unless the caller holds it (--locked); exit 4 = not taken, nothing changed
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>>"$LOCK" || { echo "reservation: cannot open the host lock $LOCK" >&2; exit 4; }
  flock -w "$WAIT" 9 || { echo "reservation: host lock $LOCK not taken within ${WAIT}s: nothing changed" >&2; exit 4; }
}
dir_ok() {      # 0 = readable directory · 2 = never existed (ENOENT) · 1 = cannot be used (EACCES, EIO, a file, ...)
  local st
  if st=$(stat -c %F -- "$DIR" 2>&1); then
    [ "$st" = directory ] && [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "reservation: $DIR is not a readable directory" >&2; return 1; }
    return 0
  fi
  case "$st" in *"No such file or directory"*) return 2 ;; esac
  echo "reservation: cannot reach $DIR: $st" >&2; return 1
}
logline() { printf '%s\n' "$2" >> "$1"; }   # an append whose failure the caller sees
# scan <callback>: for every counting reservation call "<callback> <file> <mb> <session> <type> <started> <id> <agent>";
# an expired unstarted one becomes a tombstone; tombstones: logged-and-old → pruned, unlogged-and-old → logged as
# abandoned then renamed .expired.logged; any error is return 1 with nothing deleted
scan() {
  local f fmb fexp fses ftyp fst fid fag age
  for f in "$DIR"/*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.expired.logged) age=$(( now - $(stat -c %Y -- "$f" 2>/dev/null || echo "$now") )); [ "$age" -gt "$TOMB_TTL" ] && rm -f -- "$f"; continue ;;
      *.expired) age=$(( now - $(stat -c %Y -- "$f" 2>/dev/null || echo "$now") ))
                 if [ "$age" -gt "$TOMB_TTL" ]; then
                   read -r fmb fexp fses ftyp fst fid fag < "$f" 2>/dev/null || true
                   logline "$DIR/../late-starts.log" "$(date -Is) abandoned: ${fses:--} ${ftyp:--} id ${fid:--} (expired ${age}s ago, never started)" && mv -f -- "$f" "$f.logged"
                 fi; continue ;;
      *.tmp) continue ;;
    esac
    [ -f "$f" ] && [ -r "$f" ] || { echo "reservation: $f is not a readable file" >&2; return 1; }
    read -r fmb fexp fses ftyp fst fid fag < "$f" 2>/dev/null || { echo "reservation: cannot read $f" >&2; return 1; }
    valid "$fmb" && valid "$fexp" && [ -n "${fses:-}" ] && [ -n "${ftyp:-}" ] && valid "${fst:-}" && [ "$fmb" -le "$MAX_MB" ] \
      || { echo "reservation: malformed $f" >&2; return 1; }
    if [ "$fst" = 0 ] && [ "$fexp" -le "$now" ]; then mv -f -- "$f" "$f.expired" || return 1; continue; fi
    "$1" "$f" "$fmb" "$fses" "$ftyp" "$fst" "${fid:--}" "${fag:--}" || return 1
  done
}
write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses=$(san "${4:-}"); typ=$(san "${5:-}"); id=$(san "$OPT_ID")
    valid "$mb" && valid "$ttl" && [ "$mb" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded integers" >&2; exit 2; }
    take_lock; mkdir -p "$DIR" || exit 2
    f="$DIR/$$-$now-$RANDOM"; write_atomic "$f" "$mb $((now + ttl)) $ses $typ 0 $id -" || exit 2; echo "$f" ;;
  outstanding|live)
    take_lock; sum=0; n=0
    acc() { sum=$((sum + $2)); n=$((n + 1)); [ "$sum" -le "$MAX_MB" ]; }
    dir_ok; st=$?
    if [ "$st" = 0 ]; then scan acc || { echo "reservation: scan failed, nothing counted" >&2; exit 1; }
    elif [ "$st" = 1 ]; then exit 1; fi
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); ag=$(san "$OPT_AGENT"); take_lock; mkdir -p "$DIR" 2>/dev/null
    noop() { return 0; }; scan noop || exit 1     # an expired live file becomes its tombstone now (a scan never prunes an unlogged one)
    for f in "$DIR"/*.expired; do   # tombstones before the pick (r5 item 4): a late start
      [ -f "$f" ] || continue
      read -r fmb fexp fses ftyp fst fid fag < "$f" 2>/dev/null || continue
      if [ "${fses:-}" = "$ses" ] && [ "${ftyp:-}" = "$typ" ]; then
        if logline "$DIR/../late-starts.log" "$(date -Is) late start: $ses $typ id ${fid:--} agent $ag (its reservation expired $(( now - fexp ))s before SubagentStart; nothing covered the start)"; then
          rm -f -- "$f"; echo "reservation: the token $ses $typ had expired: logged as a late start" >&2; exit 5
        fi
        echo "reservation: late start of $ses $typ could not be logged: tombstone kept" >&2; exit 1
      fi
    done
    oldest=""
    pick() { if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick || exit 1
    if [ -n "$oldest" ]; then
      read -r fmb fexp fses ftyp fst fid fag < "$oldest"; write_atomic "$oldest" "$fmb $fexp $fses $ftyp $now ${fid:--} $ag" || exit 1
      echo "$oldest"; exit 0
    fi
    echo "reservation: no unstarted reservation for $ses $typ" >&2; exit 3 ;;
  stop)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); id=$(san "$OPT_ID"); ag=$(san "$OPT_AGENT"); take_lock
    byid=""; byag=""; byclass=""
    pick() {
      [ "$id" != - ] && [ "$6" = "$id" ] && byid="$1"
      [ "$ag" != - ] && [ "$7" = "$ag" ] && [ "$5" != 0 ] && byag="$1"
      if [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" != 0 ]; then if [ -z "$byclass" ] || [ "$1" -ot "$byclass" ]; then byclass="$1"; fi; fi
      return 0
    }
    dir_ok >/dev/null 2>&1 && { scan pick || exit 1; }
    for f in "$byid" "$byag" "$byclass"; do [ -n "$f" ] && { rm -f -- "$f"; echo "$f"; exit 0; }; done
    echo "reservation: no started reservation for $ses $typ (id ${id}, agent ${ag})" >&2; exit 3 ;;
  start-hook|stop-hook)
    verb="${1%-hook}"; j=$(cat 2>/dev/null)
    ses=$(printf '%s' "$j" | jq -r '.session_id // empty' 2>/dev/null); typ=$(printf '%s' "$j" | jq -r '.agent_type // empty' 2>/dev/null)
    aid=$(printf '%s' "$j" | jq -r '.agent_id // empty' 2>/dev/null)
    mkdir -p "$DIR" 2>/dev/null
    if [ -z "$ses" ] || [ -z "$typ" ]; then logline "$DIR/../start-hook.log" "$(date -Is) $verb-hook: no session_id or agent_type in the hook input: nothing marked"; exit 0; fi
    extra=()
    if [ "$verb" = stop ]; then
      tp=$(printf '%s' "$j" | jq -r '.agent_transcript_path // empty' 2>/dev/null); tp="${tp/#\~/$HOME}"
      rid=$([ -n "$tp" ] && [ -f "$tp" ] && head -c 1048576 -- "$tp" 2>/dev/null | grep -o 'dreamteam reservation [A-Za-z0-9._:-]*' | head -1 | awk '{print $3}')
      [ -n "${rid:-}" ] && extra=(--id "$rid")
    fi
    [ -n "$aid" ] && extra+=(--agent "$aid")
    bash "$0" "$verb" "$ses" "$typ" "${extra[@]}" >/dev/null 2>>"$DIR/../start-hook.log"; rc=$?
    [ "$rc" -eq 0 ] || logline "$DIR/../start-hook.log" "$(date -Is) $verb-hook rc $rc for $ses $typ agent ${aid:--}"
    exit 0 ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] | outstanding | live | start <session> <type> [--agent A] | stop <session> <type> [--id ID|--agent A] | start-hook | stop-hook  [--locked]" >&2; exit 2 ;;
esac
