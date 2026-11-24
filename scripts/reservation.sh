#!/usr/bin/env bash
# dreamteam — lane-start RESERVATIONS (dreamteam #256 r2–r5, PR A #280 and PR B #289, Sen 2026-11-21/24): the memory
# a lane admitted by mem-gate will take before its process shows it. mem-gate's flock is released when the gate
# exits, BEFORE the caller starts the lane, so a GPU claim could lock, sample the pre-start footprint and admit in
# that gap. The gate, still holding the host lock, writes one reservation; a GPU claim's sampler
# (scripts/lib/gpu_fleet.py PROBE, which carries this file's RECORD RULE block verbatim for the ssh round trip, run
# under the claim's lock) and the gate itself (`outstanding`) count them.
#
# Files: <dir>/<gate pid>-<epoch>-<rand>, one line of EXACTLY seven fields "<mb> <expires-epoch> <session> <type>
# <started-epoch|0> <id|-> <agent|->" (a record from PR A has five fields: id and agent read as -), written tmp +
# rename. Every read and write runs under the HOST LOCK (DREAMTEAM_HOST_LOCK; --locked = the caller already holds
# it, as the gate does), so no reader can see or delete a half-written file.
#
# IDENTITY (#289). The gate mints a random 128-bit id (32 hex from /dev/urandom, its pipeline's own status checked),
# writes it here (field 6) and prefixes the Agent prompt with "[dreamteam reservation <id>]" through PreToolUse
# updatedInput, with no permissionDecision: the hooks reference (read 2026-11-21) gives SubagentStart only session_id,
# agent_id and agent_type (no env, no prompt, no tool_use_id) and SubagentStop agent_id plus agent_transcript_path, so
# the prompt is the one channel to the spawn and the subagent's transcript the one place the id comes back. The
# ledger refuses an id it has seen: on a live record, on a tombstone, or in the SEEN-SET (<dir>/../released-ids, one
# "<id> <epoch>" per released id, kept 7 days, written BEFORE the release's rm), on add AND on stop --id, so a
# replayed or forged marker cannot release twice. A stop names at most ONE selector: --id releases that id or
# nothing, --agent releases the file bound to that agent or nothing, and only a stop with neither releases one
# started reservation of the class (session + type). The gate also records the session's transcript directory at
# spawn (<dir>/../sessions/<session_id>, realpath); the stop hook reads ONLY <that dir>/<session_id>/subagents/
# agent-<agent_id>.jsonl, realpath'ed on both sides with the parent required to match, opened with O_NOFOLLOW under
# python3 -I, a regular file, at most 64 lines of at most 64 KiB, each line ONE JSON object: the id is the prefix of
# the first user message's content field ("[dreamteam reservation <32 hex>]"), never a byte search; anything else
# makes the hook release by agent_id. `start` matches the class and binds the file to agent_id (field 7).
#
# LIFECYCLE. Unstarted: counts until it expires (90 s: the spawn never happened); then it becomes a TOMBSTONE
# (<file>.expired) that no scan counts and only `start` consumes, deleting it only after its late-start line appended
# (<dir>/../late-starts.log); tombstones older than a day are pruned, but `start` reads its token's tombstones BEFORE
# any scan or prune, so a start that is more than a day late is still a late start. Started: counts until the
# lane's SubagentStop releases it (`stop`), NEVER by time: SubagentStart is not proof the RSS is there yet.
#
# READS AND WRITES. Every verb first ENUMERATES the directory into an array with the enumeration's own status (an
# entry that cannot be stat'ed, a symlink or a stray .tmp fails the verb with exit 1 before anything else), then
# runs ONE validation pass over every entry, records and tombstones alike, through the RECORD RULE below, which the
# probe runs verbatim. `scan` is READ-ONLY and reports each record with its state, counting or expired. `prune` is
# the ONE housekeeping writer: after validation it tombstones expired unstarted records and removes day-old
# tombstones. add, start and stop write their own record only, and every write (mkdir, mv, rm, append) is checked:
# nothing fails open. A reservations path that does not exist (ENOENT) is "0 0" / RESV,OK,0; one that cannot be
# reached for any other reason (EACCES on a parent, EIO, a file in its place) is exit 1 / RESV,ERR.
# Seams: DREAMTEAM_RESERVATIONS (default ~/.local/state/dreamteam/reservations, local disk), DREAMTEAM_HOST_LOCK,
# DREAMTEAM_HOST_LOCK_WAIT.
#
#   reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] [--locked]   write one (default 90 s), print its path
#   reservation.sh outstanding [--locked]      "<mb-sum> <count>" of the counting ones (exit 1 on any error)
#   reservation.sh live [--locked]             the MB sum of the counting ones (exit 1 on any error)
#   reservation.sh start <session> <type> [--agent AID]   tombstones first: a late start is logged, deleted, exit 5
#                                              (log append failed: kept, exit 1); else mark one unstarted reservation
#                                              of the class started and bound to AID; exit 0 · 3 none · 4 lock
#   reservation.sh stop <session> <type> [--id ID | --agent AID]   one selector at most; exit 0 · 3 none · 2 a seen
#                                              id or two selectors · 4 lock · 1 error
#   reservation.sh record-session <session> <dir>   the gate: the session's transcript dir at spawn (realpath)
#   reservation.sh start-hook | stop-hook      SubagentStart / SubagentStop from stdin JSON; always exit 0, rc logged
set -u
DIR="${DREAMTEAM_RESERVATIONS:-$HOME/.local/state/dreamteam/reservations}"
LOCK="${DREAMTEAM_HOST_LOCK:-$HOME/.local/state/dreamteam/host.lock}"; WAIT="${DREAMTEAM_HOST_LOCK_WAIT:-5}"
TOMB_TTL=86400; SEEN_TTL=604800
SEEN="$DIR/../released-ids"; SESSIONS="$DIR/../sessions"
now=$(date +%s)
LOCKED=0; OPT_ID=""; OPT_AGENT=""; GOT_ID=0; GOT_AGENT=0; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --locked) LOCKED=1 ;;
    --id) OPT_ID="${2:-}"; GOT_ID=1; shift ;;
    --agent) OPT_AGENT="${2:-}"; GOT_AGENT=1; shift ;;
    *) args+=("$1") ;;
  esac; shift
done
set -- "${args[@]}"
# --- record rule begin
# THE ONE RECORD RULE, read by this script and carried verbatim into the GPU probe (scripts/lib/gpu_fleet.py reads this
# block out of this file; tests/test-gpu.sh checks the probe's copy is byte-identical). Pure field checks, no I/O.
MAX_MB=1000000
# a bounded decimal: digits only, at most 12, no leading zero (octal to the shell); every arithmetic site says 10#
valid() { case "${1:-}" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac; [ "${#1}" -le 12 ]; }
# an id: - or exactly 32 hex; a token (session, type, agent): the token alphabet, 1..128
valid_id() { [ "${1:-}" = - ] || { [ "${#1}" -eq 32 ] && case "$1" in *[!0-9a-f]*) false ;; *) true ;; esac; }; }
valid_tok() { [ -n "${1:-}" ] && [ "${#1}" -le 128 ] && case "$1" in *[!A-Za-z0-9._:-]*) false ;; *) true ;; esac; }
# record_ok <mb> <exp> <session> <type> <started> <id> <agent> <extra>: 0 when the seven fields are a record and
# nothing follows them (id and agent may be - ; an absent id or agent is passed as -)
record_ok() {
  valid "$1" && valid "$2" && valid_tok "$3" && valid_tok "$4" && valid "$5" && valid_id "${6:--}" \
    && { [ "${7:--}" = - ] || valid_tok "$7"; } && [ -z "${8:-}" ] && [ "$((10#$1))" -le "$MAX_MB" ]
}
# --- record rule end
# the token fields as written and as matched: [A-Za-z0-9._:-] only, at most 128, other bytes become _, empty becomes -
san() { local s; s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-128); printf '%s' "${s:--}"; }
take_lock() {   # the host lock, unless the caller holds it (--locked); exit 4 = not taken, nothing changed
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCK")" || { echo "reservation: cannot create the lock directory" >&2; exit 4; }
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
# enumerate: ENT[] = every entry of the directory, with the enumeration's own status: a symlink, an entry that cannot
# be stat'ed (EACCES, EIO) or a stray .tmp is exit 1 here, before any parse. Nothing a glob returned is ever skipped;
# an unmatched glob is the empty array.
ENT=()
enumerate() {
  local f
  ENT=()
  for f in "$DIR"/*; do
    [ "$f" = "$DIR/*" ] && return 0
    [ -L "$f" ] && { echo "reservation: cannot stat $f as a record: a symlink is never one; the enumeration failed, nothing counted" >&2; exit 1; }
    stat -c %n -- "$f" >/dev/null 2>&1 || { echo "reservation: cannot stat $f: the enumeration failed, nothing counted" >&2; exit 1; }
    case "$f" in *.tmp) echo "reservation: stray $f: a write that did not finish" >&2; exit 1 ;; esac
    ENT+=("$f")
  done
}
# parse <file>: sets fmb fexp fses ftyp fst fid fag from a regular, readable record (live or tombstone) that passes
# the record rule; else return 1 with the reason. The ONLY way a number leaves a file.
parse() {
  local extra
  [ -f "$1" ] && [ -r "$1" ] || { echo "reservation: $1 is not a readable file" >&2; return 1; }
  read -r fmb fexp fses ftyp fst fid fag extra < "$1" 2>/dev/null || { echo "reservation: cannot read $1" >&2; return 1; }
  fid="${fid:--}"; fag="${fag:--}"
  record_ok "${fmb:-}" "${fexp:-}" "${fses:-}" "${ftyp:-}" "${fst:-}" "$fid" "$fag" "${extra:-}" || { echo "reservation: malformed $1" >&2; return 1; }
}
expired() { [ "$fst" = 0 ] && [ "$((10#$fexp))" -le "$now" ]; }
# validate_all: enumerate, then ONE pass over every entry, records and tombstones alike; exit 1 on the first failure
validate_all() { local f fmb fexp fses ftyp fst fid fag; enumerate; for f in "${ENT[@]}"; do parse "$f" || exit 1; done; }
# scan <callback>: READ-ONLY, after validate_all. Each live record is reported as
# "<callback> <file> <mb> <session> <type> <started> <counting|expired> <id> <agent>".
scan() {
  local f fmb fexp fses ftyp fst fid fag state
  for f in "${ENT[@]}"; do
    case "$f" in *.expired) continue ;; esac
    parse "$f" || exit 1
    if expired; then state=expired; else state=counting; fi
    "$1" "$f" "$fmb" "$fses" "$ftyp" "$fst" "$state" "$fid" "$fag" || exit 1
  done
}
# prune: the ONE housekeeping writer, after validate_all: expired unstarted records become tombstones, day-old
# tombstones go; every write checked; the array is enumerated again afterwards
prune() {
  local f fmb fexp fses ftyp fst fid fag age mt
  for f in "${ENT[@]}"; do
    case "$f" in
      *.expired) mt=$(stat -c %Y -- "$f") || { echo "reservation: cannot stat $f" >&2; exit 1; }; age=$(( now - mt ))
                 [ "$age" -gt "$TOMB_TTL" ] && { rm -f -- "$f" || exit 1; }; continue ;;
    esac
    parse "$f" || exit 1
    if expired; then mv -f -- "$f" "$f.expired" || exit 1; fi
  done
  enumerate
}
# late_start <session> <type> <agent>: the tombstones of the token (validated already); a match is logged and
# deleted only after the append succeeded (exit 5), an unloggable one kept (exit 1); return 0 = none
late_start() {
  local f fmb fexp fses ftyp fst fid fag
  for f in "${ENT[@]}"; do
    case "$f" in *.expired) ;; *) continue ;; esac
    parse "$f" || exit 1
    if [ "$fses" = "$1" ] && [ "$ftyp" = "$2" ]; then
      if printf '%s late start: %s %s id %s agent %s (its reservation expired %ss before SubagentStart; nothing covered the start)\n' "$(date -Is)" "$1" "$2" "$fid" "$3" "$(( now - 10#$fexp ))" >> "$DIR/../late-starts.log"; then
        rm -f -- "$f" || exit 1; echo "reservation: the token $1 $2 had expired: logged as a late start" >&2; exit 5
      fi
      echo "reservation: late start of $1 $2 could not be logged: tombstone kept" >&2; exit 1
    fi
  done
  return 0
}
# the seen-set of released ids: seen_has <id> (0 = seen within SEEN_TTL), seen_add <id> (atomic rewrite, pruned)
seen_has() {
  local i t; [ -f "$SEEN" ] || return 1
  while read -r i t; do valid "${t:-}" && [ "$i" = "$1" ] && [ $(( now - 10#$t )) -le "$SEEN_TTL" ] && return 0; done < "$SEEN"
  return 1
}
seen_add() {
  local i t
  { if [ -f "$SEEN" ]; then while read -r i t; do valid "${t:-}" && [ $(( now - 10#$t )) -le "$SEEN_TTL" ] && printf '%s %s\n' "$i" "$t"; done < "$SEEN"; fi
    printf '%s %s\n' "$1" "$now"; } > "$SEEN.tmp" && mv -f -- "$SEEN.tmp" "$SEEN" || { echo "reservation: cannot record the released id" >&2; exit 1; }
}
write_atomic() { printf '%s\n' "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; }
# open_dir: the directory for a verb that must have one: dir_ok 1 → exit 1; ENOENT → create it (checked)
open_dir() { dir_ok; case $? in 1) exit 1 ;; 2) mkdir -p "$DIR" || { echo "reservation: cannot create $DIR" >&2; exit 1; } ;; esac; }
case "${1:-}" in
  add)
    mb="${2:-}"; ttl="${3:-90}"; ses=$(san "${4:-}"); typ=$(san "${5:-}"); id="${OPT_ID:--}"
    valid "$mb" && valid "$ttl" && [ "$((10#$mb))" -le "$MAX_MB" ] || { echo "reservation: mb and ttl are bounded decimals" >&2; exit 2; }
    valid_id "$id" || { echo "reservation: an id is 32 hex (or absent)" >&2; exit 2; }
    take_lock; open_dir; validate_all
    if [ "$id" != - ]; then   # a repeat is refused: on a record, on a tombstone, or released within 7 days
      seen_has "$id" && { echo "reservation: id $id was released before (seen-set)" >&2; exit 2; }
      for f in "${ENT[@]}"; do parse "$f" || exit 1; [ "$fid" = "$id" ] && { echo "reservation: id $id is already on the ledger" >&2; exit 2; }; done
    fi
    f="$DIR/$$-$now-$RANDOM"; write_atomic "$f" "$((10#$mb)) $((now + 10#$ttl)) $ses $typ 0 $id -" || exit 2; echo "$f" ;;
  outstanding|live)
    take_lock; sum=0; n=0
    acc() { [ "$6" = counting ] || return 0; sum=$((sum + 10#$2)); n=$((n + 1)); [ "$sum" -le "$MAX_MB" ]; }
    dir_ok; st=$?
    if [ "$st" = 0 ]; then validate_all; scan acc; prune
    elif [ "$st" = 1 ]; then exit 1; fi
    if [ "$1" = live ]; then echo "$sum"; else echo "$sum $n"; fi ;;
  start)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); ag=$(san "$OPT_AGENT"); take_lock; open_dir; validate_all
    late_start "$ses" "$typ" "$ag"      # tombstones BEFORE any scan or prune: a day-late start is still a late start
    oldest=""
    pick() { if [ "$6" = counting ] && [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" = 0 ]; then if [ -z "$oldest" ] || [ "$1" -ot "$oldest" ]; then oldest="$1"; fi; fi; }
    scan pick
    if [ -n "$oldest" ]; then
      parse "$oldest" || exit 1; write_atomic "$oldest" "$fmb $fexp $fses $ftyp $now $fid $ag" || exit 1
      echo "$oldest"; exit 0
    fi
    prune                            # an expired live record of the class becomes its tombstone: a late start too
    late_start "$ses" "$typ" "$ag"
    echo "reservation: no unstarted reservation for $ses $typ" >&2; exit 3 ;;
  stop)
    ses=$(san "${2:?session}"); typ=$(san "${3:?type}"); id="${OPT_ID:--}"; ag=$(san "$OPT_AGENT"); take_lock
    [ "$GOT_ID" = 1 ] && [ "$GOT_AGENT" = 1 ] && { echo "reservation: stop takes one selector, --id or --agent" >&2; exit 2; }
    valid_id "$id" || { echo "reservation: an id is 32 hex (or absent)" >&2; exit 2; }
    [ "$GOT_ID" = 1 ] && seen_has "$id" && { echo "reservation: id $id was released before: a replayed stop is refused" >&2; exit 2; }
    dir_ok; case $? in 1) exit 1 ;; 2) echo "reservation: no reservations directory" >&2; exit 3 ;; esac
    validate_all
    target=""; byclass=""
    pick() {
      if [ "$GOT_ID" = 1 ]; then [ "$7" = "$id" ] && target="$1"
      elif [ "$GOT_AGENT" = 1 ]; then [ "$8" = "$ag" ] && [ "$5" != 0 ] && target="$1"
      elif [ "$3" = "$ses" ] && [ "$4" = "$typ" ] && [ "$5" != 0 ]; then if [ -z "$byclass" ] || [ "$1" -ot "$byclass" ]; then byclass="$1"; fi; fi
      return 0
    }
    scan pick
    [ -n "$target" ] || target="$byclass"
    if [ -n "$target" ]; then
      parse "$target" || exit 1
      [ "$fid" != - ] && seen_add "$fid"   # the id is remembered BEFORE the rm: a crash between them cannot lose it
      rm -f -- "$target" || { echo "reservation: cannot release $target" >&2; exit 1; }
      echo "$target"; exit 0
    fi
    echo "reservation: no started reservation for $ses $typ (id $id, agent $ag): nothing released" >&2; exit 3 ;;
  record-session)   # the gate, under the lock: the session's transcript directory as recorded at spawn (realpath)
    ses=$(san "${2:?session}"); d="${3:-}"
    [ -n "$d" ] || { echo "reservation: no transcript directory to record" >&2; exit 2; }
    rp=$(realpath -e -- "$d") || { echo "reservation: the transcript directory does not resolve" >&2; exit 2; }
    mkdir -p "$SESSIONS" || { echo "reservation: cannot create $SESSIONS" >&2; exit 1; }
    write_atomic "$SESSIONS/$ses" "$rp" || { echo "reservation: cannot record the session directory" >&2; exit 1; }; exit 0 ;;
  start-hook|stop-hook)
    verb="${1%-hook}"; j=$(cat 2>/dev/null)
    ses=$(printf '%s' "$j" | jq -r '.session_id // empty' 2>/dev/null); typ=$(printf '%s' "$j" | jq -r '.agent_type // empty' 2>/dev/null)
    aid=$(printf '%s' "$j" | jq -r '.agent_id // empty' 2>/dev/null)
    log="$DIR/../start-hook.log"
    mkdir -p "$DIR" || { echo "reservation: cannot create $DIR" >&2; exit 0; }
    if [ -z "$ses" ] || [ -z "$typ" ]; then printf '%s %s-hook: no session_id or agent_type in the hook input: nothing marked\n' "$(date -Is)" "$verb" >> "$log" || echo "reservation: cannot append to $log" >&2; exit 0; fi
    sel=()
    if [ "$verb" = stop ]; then
      # the id comes back ONLY from the session's own subagent transcript under the directory the GATE recorded at
      # spawn (never from the hook input), realpath'ed on both sides with the prefix required, opened without
      # following symlinks, a regular file, at most 64 lines of at most 64 KiB, each one JSON object; the id is the
      # prefix of the FIRST user message's content field, never a byte search. Exactly one selector goes to stop.
      tp=$(printf '%s' "$j" | jq -r '.agent_transcript_path // empty' 2>/dev/null); tp="${tp/#\~/$HOME}"
      rid=""; sses=$(san "$ses"); root=""
      [ -f "$SESSIONS/$sses" ] && [ ! -L "$SESSIONS/$sses" ] && read -r root < "$SESSIONS/$sses"
      if [ -n "$tp" ] && [ -n "$root" ] && [ -n "$aid" ] && valid_tok "$sses" && valid_tok "$aid"; then
        rid=$(python3 -I - "$tp" "$root" "$sses" "$aid" <<'PY' 2>/dev/null
import json, os, stat, sys
tp, root, ses, aid = sys.argv[1:5]
root = os.path.realpath(root)
expect = os.path.join(root, ses, "subagents", "agent-" + aid + ".jsonl")
if os.path.realpath(tp) != expect or os.path.realpath(os.path.dirname(tp)) != os.path.dirname(expect):
    sys.exit(1)
try:
    fd = os.open(tp, os.O_RDONLY | os.O_NOFOLLOW | os.O_NOCTTY)
except OSError:
    sys.exit(1)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        sys.exit(1)
    f = os.fdopen(fd, "rb")
except OSError:
    os.close(fd); sys.exit(1)
MARK = "[dreamteam reservation "
HEX = set("0123456789abcdef")
with f:
    for _ in range(64):
        line = f.readline(65536 + 1)
        if not line:
            break
        if len(line) > 65536:          # a line past the bound is skipped WHOLE: its remainder is never looked at
            while not line.endswith(b"\n"):
                line = f.readline(65536 + 1)
                if not line:
                    break
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict) or obj.get("type") != "user":
            continue
        msg = obj.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, list):   # block form: the first text block
            content = next((b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"), None)
        if not isinstance(content, str) or not content.startswith(MARK):
            sys.exit(1)                # the first user message decides; no further search
        rid = content[len(MARK):len(MARK) + 32]
        if len(rid) == 32 and set(rid) <= HEX and content[len(MARK) + 32:len(MARK) + 33] == "]":
            sys.stdout.write(rid); sys.exit(0)
        sys.exit(1)
sys.exit(1)
PY
) || rid=""
      fi
      if [ -n "$rid" ]; then sel=(--id "$rid"); elif [ -n "$aid" ]; then sel=(--agent "$aid"); fi
    else
      [ -n "$aid" ] && sel=(--agent "$aid")
    fi
    bash "$0" "$verb" "$ses" "$typ" "${sel[@]}" >/dev/null 2>>"$log"; rc=$?
    [ "$rc" -eq 0 ] || printf '%s %s-hook rc %s for %s %s agent %s\n' "$(date -Is)" "$verb" "$rc" "$ses" "$typ" "${aid:--}" >> "$log" || echo "reservation: cannot append to $log" >&2
    exit 0 ;;
  *) echo "usage: reservation.sh add <mb> [ttl-s] [session] [type] [--id ID] | outstanding | live | start <session> <type> [--agent A] | stop <session> <type> [--id ID|--agent A] | record-session <session> <dir> | start-hook | stop-hook  [--locked]" >&2; exit 2 ;;
esac
