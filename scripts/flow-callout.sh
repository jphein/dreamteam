#!/usr/bin/env bash
# dreamteam — FLOW CALLOUT  (Stop hook)
#
# A lane cannot end a turn while it holds an open Flow row it has not spoken on since that row's last order.
# docs/MANAGEMENT.md practice 3 (closed-loop callouts) and §5 item 1; Flow row 76b3ff47 (JP 2026-11-17 08:09 via
# Sen: "Make your system more robust and part of the plan project"). Replaces the reply-ACK convention.
#
# WHAT IT READS. The Flow ledger (plan.realm.watch, FOR-AGENTS rule 27) over HTTP: GET $ASK_URL/api/flow?open=1&mine=…
# for this lane's open rows, then GET /api/flow/<id> for the log of each row that is not plainly silent. A row is
# SILENT when it is open (ordered · in-progress · blocked · needs-jp) and its log holds no event by this lane after
# its `ordered` event. A row still in state `ordered` is silent by construction (every verb a lane has moves it), so
# it costs no second request. "This lane" is every name the lane goes by: $ASK_WHO, the tmux session, and a
# teammate's --agent-id (name before the @); another session of the same lane (wifey ↔ wifey-8f) counts, as the
# ledger itself counts it; and a lead's note written on the lane's behalf counts when it starts with "<lane>:"
# (the --who workaround, TOOLING-FRICTION 2026-11-17 18:58).
#
# WHAT IT DOES. Exit 2 with one line per silent row naming the id and the three verbs that end the silence
# (checkpoint · block · done --evidence). The harness shows that to the lane instead of letting it stop; the lane
# says where the row stands and stops on its next turn (stop_hook_active is then true, and this hook steps aside:
# never a loop).
#
# WHO IT APPLIES TO. Every session that can be named as a lane. The lead's names (config flow.leads, default sen and
# jp-2f) are never blocked: rows ordered for lanes off familiar carry the lead's name today (TOOLING-FRICTION
# 2026-11-17 18:58), and the lead's stop is the fleet's.
#
# SAFETY POSTURE — FAIL OPEN, WITH ONE LOGGED LINE. No identity, the lead, stop_hook_active, the kill switch
# (config flow.enforce=false), malformed stdin → exit 0 silently. No ask key, the plan server unreachable, an HTTP
# error, an answer that is not the ledger's JSON, a row log that cannot be read → exit 0 and ONE line in
# $DREAMTEAM_FLOW_LOG (default ~/.claude/state/dreamteam/flow-callout.log) saying what was not checked. A plan
# outage must never wedge a lane; the lead's sweep reads `flow stuck` anyway.
#
# BUDGET. One budget for the whole stop, DREAMTEAM_FLOW_BUDGET (default 9 s, inside hooks.json's 12 s): each request's
# timeout is cut to what is left (the list at most 4 s, a row log at most 3 s), and rows left when it is spent are
# reported as unchecked in the log line, never silently skipped. At most DREAMTEAM_FLOW_MAX_LOGS row logs (default 8,
# newest rows first; a lane holding more is a ledger to tidy), reported the same way. TIMEOUTS ARE IN SECONDS.
#
# KNOWN LIMIT (xreview #237 r6, lead ruling 2026-11-18): the file reads are bounded (min 1 s, what is left of the
# budget) and a FIFO at any path is refused before it is opened, but the stat-class calls (-f, -e, -L) and the
# logger's mkdir + printf run outside any timeout, so a STALLED NETWORK MOUNT at one of these paths would hold the
# hook until the harness's own Stop-hook timeout (hooks.json, 12 s) ends it: that timeout is the outer bound. It is
# not a round because every path here lives on local disk: the plugin tree, ~/.claude/state/dreamteam, the config,
# the key file. Never point DREAMTEAM_CONFIG, DREAMTEAM_FLOW_LOG or DREAMTEAM_ASK_KEY_FILE at a network mount.
#
# Seams (tests/test-flow-callout.sh): ASK_URL · ASK_KEY or DREAMTEAM_ASK_KEY_FILE · ASK_WHO · DREAMTEAM_AGENT_ID ·
# DREAMTEAM_CONFIG · DREAMTEAM_FLOW_LOG · DREAMTEAM_FLOW_BUDGET · DREAMTEAM_FLOW_MAX_LOGS · curl and tmux from PATH.
set -uo pipefail
T0=$(( $(date +%s%N) / 1000000 ))   # ms; the deadline clock starts before ANY external command (xreview #237 r2: the tmux fallback counts)
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
LOG="${DREAMTEAM_FLOW_LOG:-$HOME/.claude/state/dreamteam/flow-callout.log}"
. "$ROOT/scripts/lib/agent-id.sh"

# ident_of <pid> → "<start time> <session id>" (fields 22 and 6 of /proc/<pid>/stat), or nothing for a process that
# is gone or a zombie (a zombie holds nothing and cannot be signalled: it is not "left behind")
ident_of() { local st f; st=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; st=${st##*) }; read -r -a f <<< "$st"
             [ "${f[0]:-Z}" = Z ] || printf '%s %s' "${f[19]:-}" "${f[3]:-}"; }
start_of() { local i; i=$(ident_of "$1"); printf '%s' "${i%% *}"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# A clean-up that FAILED (or could not be checked) makes the hook exit 1 instead of 0: a non-blocking hook error the
# harness shows, with the reason in the log. A block (exit 2) stays a block. Set by reap_session and its caller.
REAPFAIL=0
trap 'rc=$?; if [ "$rc" -eq 0 ] && [ "$REAPFAIL" = 1 ]; then echo "flow-callout: the tmux fallback could not be cleaned up or checked (see $LOG)" >&2; exit 1; fi; exit "$rc"' EXIT
# reap_session <session id> <start time of its leader> <1 when the answer arrived>
#   The session is one this hook created (setsid), so "everything still in it" is exactly what the tmux call left
#   behind: the client, a wrapper, a wrapper's children. EXACTLY ONE logged line says the outcome, on every path.
#   IDENTITY, twice:
#     - the session: its id cannot be given to anything else while one member lives; when a process with that id
#       exists, its start time must be the one read when the id arrived. If it differs, ours has ended and the id
#       belongs to someone else now: nothing is signalled (said);
#     - each process: members are listed as pid + start time, and IMMEDIATELY before each signal the pid must
#       still have that start time and still be in this session, else it is skipped (a pid reused in between is
#       never signalled). What remains is the instant between that read and the kill.
#   TERM to each member, a grace of at most 1 s paid ONLY from what is left of the budget (none left: no grace),
#   KILL to what remains, then a confirmation paid from the budget too. Not gone, or not checkable: REAPFAIL.
reap_session() {
  local sid=$1 st=$2 got=$3 cur g dl r n sent="TERM" m p
  command -v pgrep >/dev/null 2>&1 || { REAPFAIL=1; note "tmux fallback: no pgrep here; what the call left behind (session $sid) was NOT CHECKED"; return 1; }
  members() { local q i; for q in $(pgrep -s "$sid" 2>/dev/null); do i=$(ident_of "$q"); [ "${i#* }" = "$sid" ] && printf '%s:%s ' "$q" "${i%% *}"; done; }
  sig() { local sg=$1; shift; for m in "$@"; do p=${m%%:*}; [ "$(ident_of "$p")" = "${m#*:} $sid" ] && kill "-$sg" "$p" 2>/dev/null; done; true; }
  # wait_gone <ms>: poll until the session is empty or <ms> have passed; the last listing is in $cur
  wait_gone() { dl=$(( $(now_ms) + $1 )); while cur=$(members); [ -n "$cur" ] && r=$(( dl - $(now_ms) )) && [ "$r" -gt 0 ]; do [ "$r" -gt 30 ] && r=30; sleep "$(secs "$r")"; done; }
  budget() { local l; l=$(left); [ "$l" -gt "$1" ] && l=$1; [ "$l" -lt 0 ] && l=0; echo "$l"; }      # min(<cap>, what is left), never below 0
  cur=$(members)
  [ -n "$cur" ] && [ "$got" = 1 ] && wait_gone "$(budget 150)"     # it answered: a client that is just exiting gets a moment, from the budget
  if [ -z "$cur" ]; then note "tmux fallback: nothing left in its session $sid: nothing signalled"; return 0; fi
  if [ -e "/proc/$sid" ] && { [ -z "$st" ] || [ "$(start_of "$sid")" != "$st" ]; }; then
    note "tmux fallback: session id $sid now belongs to another process (its leader's start time differs), so ours has ended: nothing signalled"; return 0
  fi
  n=$(wc -w <<< "$cur")
  # shellcheck disable=SC2086
  sig TERM $cur
  g=$(budget 1000); wait_gone "$g"
  if [ -n "$cur" ]; then
    sent="TERM, then KILL after ${g} ms"
    # shellcheck disable=SC2086
    sig KILL $cur
    wait_gone "$(budget 200)"
  fi
  if [ -n "$cur" ]; then REAPFAIL=1; note "tmux fallback overran its bound: $n process(es) of its session $sid signalled ($sent); STILL ALIVE: ${cur% }"; return 1; fi
  note "tmux fallback overran its bound: $n process(es) of its session $sid signalled ($sent); none left"
}

# note — the one logged line of a fail-open path; never fails the hook
note() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # only a regular file (or none yet) takes the line: a FIFO or a device there would hang the hook (xreview #237 r4)
  if [ ! -e "$LOG" ] || { [ -f "$LOG" ] && [ ! -L "$LOG" ]; }; then
    printf '%s flow-callout: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG" 2>/dev/null || true
  fi
}

# ── (a) stdin: a Stop payload. stop_hook_active = the harness already continued once for a stop hook → never loop.
BUDGET="${DREAMTEAM_FLOW_BUDGET:-9}"; case "$BUDGET" in ''|*[!0-9]*) BUDGET=9 ;; esac     # seconds, the whole hook
left() { echo $(( BUDGET * 1000 - ($(( $(date +%s%N) / 1000000 )) - T0) )); }   # ms left of the budget
secs() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }                     # ms → "s.mmm" for curl -m / timeout
# the two file reads below (config, key) are bounded by min(1 s, what is left of the budget), floored at 0.1 s so a
# spent budget still cuts the read rather than running it unbounded (xreview #237 r6 item 3)
readcap() { local l; l=$(left); [ "$l" -gt 1000 ] && l=1000; [ "$l" -lt 100 ] && l=100; secs "$l"; }
MAX_LOGS="${DREAMTEAM_FLOW_MAX_LOGS:-8}"; case "$MAX_LOGS" in ''|*[!0-9]*) MAX_LOGS=8 ;; esac
INPUT="$(cat 2>/dev/null || true)"
ACTIVE="$(printf '%s' "$INPUT" | jq -r 'if type == "object" then (.stop_hook_active // false | tostring) else error("x") end' 2>/dev/null)" || exit 0
[ "$ACTIVE" = "true" ] && exit 0

# ── (b) the config: read ONCE, a regular file only, the read bounded to 1 s (xreview #237 r5: a FIFO or a stalled
#        mount at DREAMTEAM_CONFIG hung the hook); both jq reads below run on the string, which cannot hang. Not a
#        regular file, or a read that times out: said, and the hook steps aside (fail open). A MISSING config still
#        enforces with the default leads. The master switch is `== false`, not `// true` (jq's // treats false as
#        empty: the reuse-gate bug).
CFGTXT=""
if [ -e "$CFG" ]; then
  if [ ! -f "$CFG" ] || [ -L "$CFG" ]; then note "config $CFG is not a regular file: open rows not checked"; exit 0; fi
  CFGTXT=$(timeout -k 1 "$(readcap)" head -c 1048576 -- "$CFG" 2>/dev/null); cfgrc=$?
  if [ "$cfgrc" -ne 0 ]; then note "config $CFG read timed out or failed (rc $cfgrc): open rows not checked"; exit 0; fi
fi
ENFORCE=$(jq -r 'if .flow.enforce == false then "false" else "true" end' <<<"$CFGTXT" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# ── (c) who am I: the names this lane goes by, lowercase, deduped, the ledger's name alphabet only. The identity is
#        $ASK_WHO and a teammate's --agent-id (the dt_agent_id walk); the tmux session is ONLY the fallback when there
#        is neither (xreview #237 r1: a teammate is never its hosting session), and only inside tmux (outside it,
#        display-message names the host's most recent session: familiar 2026-11-17 20:09, "spire").
names=()
add() { local n; n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_.-')"; [ -n "$n" ] || return 0
        local x; for x in "${names[@]-}"; do [ "$x" = "$n" ] && return 0; done; names+=("$n"); }
mapfile -t leads < <(jq -r '(.flow.leads // ["sen","jp-2f"])[]' <<<"$CFGTXT" 2>/dev/null || printf 'sen\njp-2f\n')
[ "${#leads[@]}" -gt 0 ] || leads=(sen jp-2f)
is_lead() { local l; for l in "${leads[@]}"; do [ "$1" = "$l" ] && return 0; done; return 1; }
add "${ASK_WHO:-}"
AID="$(dt_agent_id)"; add "${AID%%@*}"
if [ "${#names[@]}" -eq 0 ] && [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  # ms, the same clock as the requests; one second is kept back for the clean-up's grace, so a tmux that ignores
  # TERM is still killed inside the budget (xreview #237 r3)
  tl=$(( BUDGET * 1000 - ($(( $(date +%s%N) / 1000000 )) - T0) - 1000 )); [ "$tl" -gt 3000 ] && tl=3000
  # THE CALL IS BOUNDED AND CLEANED UP BY THIS HOOK, not by `timeout` (xreview #292 r1). What `timeout` kills
  # differs by implementation: GNU signals the process group, uutils 0.10.0 (Ubuntu 26.04) only its direct child,
  # and with $( ) a wrapper's forked child then held the pipe for its whole life (familiar 2026-11-22: 20 s under
  # a 2 s budget). So:
  #   • tmux runs in a SESSION OF ITS OWN (setsid) and prints that session's id first;
  #   • both lines are read with `read -t` from a process substitution: read gives up at the bound by itself,
  #     whoever still holds the pipe. A name that did not arrive whole is no identity;
  #   • then reap_session: whatever is still in that session gets TERM, a grace paid from the budget, then KILL,
  #     and ONE logged line says the outcome on every path (nothing left included). A clean-up that failed or
  #     could not be checked makes the hook exit 1 (REAPFAIL);
  #   • a session id that never arrived: the process this hook started ($!, identity by start time) is killed,
  #     what it may have started cannot be known, and that is said and is a failure too.
  if [ "$tl" -ge 200 ]; then
    tdl=$(( $(date +%s%N) / 1000000 + tl )); tname=""; tsid=""; tstart=""; tgot=0; tpid=""; tpst=""
    rem() { local r=$(( tdl - $(date +%s%N) / 1000000 )); [ "$r" -lt 10 ] && r=10; secs "$r"; }
    if exec {tfd}< <(setsid bash -c 'echo "$$"; exec tmux display-message -p "#S"' 2>/dev/null); then
      tpid=$!; tpst=$(start_of "$tpid")
      if IFS= read -r -t "$(rem)" -u "$tfd" tsid && [[ "$tsid" =~ ^[0-9]{1,9}$ ]]; then
        tstart=$(start_of "$tsid")
        if IFS= read -r -t "$(rem)" -u "$tfd" tname; then add "$tname"; tgot=1; fi
      else tsid=""; fi
      exec {tfd}<&-
      if [ -n "$tsid" ]; then reap_session "$tsid" "$tstart" "$tgot" || true
      else
        REAPFAIL=1; tk="already gone"
        if [ -n "$tpst" ] && [ "$(start_of "$tpid")" = "$tpst" ]; then kill -KILL "$tpid" 2>/dev/null && tk="killed"; fi
        note "tmux fallback: its session id did not arrive within the bound; the process this hook started ($tpid) $tk, anything it started was NOT CHECKED"
      fi
    else note "tmux fallback: the call could not be started: nothing to clean up, no identity from it"
    fi
  fi
fi
[ "${#names[@]}" -gt 0 ] || exit 0

# ── (d) the lead is never blocked. A tmux fallback equal to a lead name lands here too: such a session is not the
#        lead, but it is no lane either (nothing of its own to answer for), so the outcome is the same: no check.
for n in "${names[@]}"; do is_lead "$n" && exit 0; done
WHO="${names[0]}"

# ── (e) the key: $ASK_KEY, else the plan's key file. Without one nothing can be read: say so once, let the stop go.
KEY="${ASK_KEY:-}"
if [ -z "$KEY" ]; then
  KF="${DREAMTEAM_ASK_KEY_FILE:-$HOME/Projects/plan.realm.watch/data/ask.key}"
  # a regular file only (a FIFO or a device at the key path never reaches the read, r4), the read bounded to 1 s (a
  # stalled mount blocks head on a regular file too, r5), at most 200 bytes of it
  KEY=""
  if [ -f "$KF" ] && [ ! -L "$KF" ]; then
    KEY="$(timeout -k 1 "$(readcap)" head -c 200 -- "$KF" 2>/dev/null | tr -d '[:space:]')" || KEY=""
  fi
fi
if [ -z "$KEY" ]; then
  note "no ask key (ASK_KEY or ${DREAMTEAM_ASK_KEY_FILE:-~/Projects/plan.realm.watch/data/ask.key}): open rows of ${names[*]} not checked"
  exit 0
fi

# The plan's address (its host move, 2026-11-27, plan-62 row d18b3d4a: nothing answers on familiar's 127.0.0.1:7810
# since): ASK_URL, else the one https line in ~/.config/plan-realm-watch/plan-url that the move writes (its rollback
# removes it; the plan's own ask/flow CLIs read the same file), else loopback. Anything but https://host[:port] in the
# file is ignored, so the key only ever goes to loopback or that one origin (curl runs without -L: no redirects).
plan_url_file() {
  local f="${PLAN_URL_FILE:-$HOME/.config/plan-realm-watch/plan-url}" u port
  [ -f "$f" ] || return 0
  u="$(timeout -k 1 2 head -c 301 -- "$f" 2>/dev/null)" || return 0
  [ "${#u}" -le 300 ] || return 0
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  [[ "$u" =~ ^https://[A-Za-z0-9.-]+(:([0-9]{1,5}))?$ ]] || return 0
  port="${BASH_REMATCH[2]}"
  if [ -n "$port" ] && { [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; }; then return 0; fi
  printf '%s' "$u"
}
URL="${ASK_URL:-$(plan_url_file)}"; URL="${URL:-http://127.0.0.1:7810}"; URL="${URL%/}"

# ── (f) ONE budget for the whole stop (xreview #237 r1): every request's timeout is cut to what is left of it, and
#        when it is spent the remaining rows are reported as unchecked, never silently skipped. Default 9 s inside the
#        hook's 12 s; seconds. MAX_LOGS bounds the row logs read, newest rows first, and is reported the same way.
# (left and secs are defined beside BUDGET above: the config and key reads use them first)
# the key reaches curl on stdin (-H @-), never in argv: /proc/<pid>/cmdline is readable by every process of this uid
get() { # get <url> <max-ms>; a reply over 1 MiB is refused (the ledger's list is kilobytes)
  local m="$2" l; l=$(left); [ "$l" -ge 200 ] || return 28; [ "$m" -le "$l" ] || m="$l"
  printf 'X-Ask-Key: %s\n' "$KEY" | curl -fsS -m "$(secs "$m")" --max-filesize 1048576 -H @- -H "X-Ask-Who: $WHO" -H "Accept: application/json" "$1"
}
MAX_ROWS="${DREAMTEAM_FLOW_MAX_ROWS:-200}"; case "$MAX_ROWS" in ''|*[!0-9]*) MAX_ROWS=200 ;; esac

# ── (g) my open rows. Any failure here is an outage: one line, exit 0.
MINE="$(IFS=,; echo "${names[*]}")"
LIST="$(get "$URL/api/flow?open=1&mine=$MINE" 4000 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then
  note "plan unreachable or refused at $URL (curl rc $rc): open rows of $MINE not checked"
  exit 0
fi
# the ledger's row list, or nothing: EXACTLY ONE object (a stream of two is not a reply, xreview #237 r3) whose rows
# are objects with a string id and state (r2: a malformed list allows with the log line, like a malformed detail)
if ! printf '%s' "$LIST" | jq -se 'length == 1 and (.[0] | type == "object" and (.rows | type == "array") and all(.rows[]; type == "object" and (.id | type) == "string" and (.state | type) == "string"))' >/dev/null 2>&1; then
  note "the ledger at $URL answered something that is not its row list: open rows of $MINE not checked"
  exit 0
fi
# ONE pass over the rows (r3: no per-row commands before the bounds): newest first, the four open states, at most
# MAX_ROWS of them; one TSV line each (id, state, what without tabs or newlines, cut to 70). The total says how many
# the cap left out.
# only rows this lane owns (r4: the ledger's answer is not trusted for ownership): the row's lane is one of my names,
# or the same lane under another session suffix, the ledger's own family rule
NAMES_JSON="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)"
ROWS="$(printf '%s' "$LIST" | jq -rs --argjson max "$MAX_ROWS" --argjson names "$NAMES_JSON" '
  def fam: sub("-[0-9a-f]{2,3}$"; "");
  .[0].rows | map(select(.state as $s | ["ordered","in-progress","blocked","needs-jp"] | index($s)))
  | map(select((.lane | type) == "string" and ((.lane | fam) as $l | $names | map(fam) | index($l)) != null))
  | sort_by(-(.ordered_at // 0)) as $all
  | ($all | length | tostring), ($all[:$max][] | [.id, .state, ((.what // "") | tostring | gsub("[\t\r\n]"; " ") | .[0:70])] | @tsv)' 2>/dev/null)" || ROWS=""
TOTAL="${ROWS%%$'\n'*}"; case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
ROWS="${ROWS#*$'\n'}"; [ "$ROWS" = "$TOTAL" ] && ROWS=""
[ "$TOTAL" -gt 0 ] || exit 0
rowcapped=0; [ "$TOTAL" -gt "$MAX_ROWS" ] && rowcapped=$(( TOTAL - MAX_ROWS ))

# ── (h) which of them are silent. `ordered` = silent by construction. Otherwise the row's log decides: an event by
#        one of my names (or my lane family), or a note prefixed "<name>:", after the last `ordered` event. A detail
#        that is not this row's log (HTML, broken JSON, {}, a log that is not an array, another row) proves nothing:
#        that row is UNCHECKED, never silent (xreview #237 r1).
verdict() { # verdict <id> <show-json> → prints spoken | silent | unreadable; the reply must be EXACTLY ONE object whose
            # log is an array of entries shaped {ts: number, who: string, event: string} (r4), else unreadable
  printf '%s' "$2" | jq -rs --arg id "$1" --argjson names "$NAMES_JSON" '
    def fam: sub("-[0-9a-f]{2,3}$"; "");
    if length != 1 or (.[0] | type) != "object" or .[0].id != $id or (.[0].log | type) != "array"
       or ((.[0].log | all(type == "object" and (.ts | type) == "number" and (.who | type) == "string" and (.event | type) == "string")) | not)
    then "unreadable"
    else .[0].log as $log
      | ([$log[] | select(type == "object" and .event == "ordered") | .ts] | max // 0) as $since
      | ([$log[] | select(type == "object" and .event != "ordered" and ((.ts // 0) >= $since))
                 | select((((.who // "") | tostring | fam) as $w | ($names | map(fam) | index($w)) != null)
                          or (((.note // "") | tostring) as $n | $names | any(. as $x | $n | startswith($x + ":"))))]
         | length) as $n
      | if $n > 0 then "spoken" else "silent" end
    end' 2>/dev/null || echo unreadable
}
silent=(); checked=0; unread=0; capped=0; budgeted=0
while IFS=$'\t' read -r id state what; do
  [ -n "$id" ] || continue
  # the deadline first, before any row's work, ordered rows included (r3); a row past it is reported, not judged
  if [ "$(left)" -lt 200 ]; then budgeted=$((budgeted + 1)); continue; fi
  case "$id" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) continue ;; esac
  if [ "$state" = "ordered" ]; then silent+=("$id	$what"); continue; fi
  if [ "$checked" -ge "$MAX_LOGS" ]; then capped=$((capped + 1)); continue; fi
  checked=$((checked + 1))
  SHOW="$(get "$URL/api/flow/$id" 3000 2>/dev/null)" || { unread=$((unread + 1)); continue; }
  case "$(verdict "$id" "$SHOW")" in
    spoken) ;;
    silent) silent+=("$id	$what") ;;
    *) unread=$((unread + 1)) ;;
  esac
done <<< "$ROWS"
why=""
[ "$unread" -gt 0 ] && why="$why; $unread with an unreadable row log"
[ "$capped" -gt 0 ] && why="$why; $capped past the cap of $MAX_LOGS newest"
[ "$budgeted" -gt 0 ] && why="$why; $budgeted past the ${BUDGET}s budget"
[ "$rowcapped" -gt 0 ] && why="$why; $rowcapped past the row cap of $MAX_ROWS newest"
[ -n "$why" ] && note "rows of $MINE not checked at $URL${why}"

[ "${#silent[@]}" -gt 0 ] || exit 0
{
  echo "FLOW CALLOUT — say where your open order(s) stand before you stop (docs/MANAGEMENT.md practice 3, FOR-AGENTS rule 27): a lane ends no turn holding a row with no word since its last order."
  for s in "${silent[@]}"; do
    id="${s%%	*}"; what="${s#*	}"
    echo "  $id  ($what)"
    echo "    flow checkpoint $id \"<what moved>\"  ·  flow block $id \"<reason>\"  ·  flow done $id --evidence \"<PR, sha, card or log line>\""
  done
  echo "Off familiar: ASK_URL=https://plan.realm.watch and ASK_WHO=<your lane>. Then stop again."
} >&2
exit 2
