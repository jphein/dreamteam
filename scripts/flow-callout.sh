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
# Seams (tests/test-flow-callout.sh): ASK_URL · ASK_KEY or DREAMTEAM_ASK_KEY_FILE · ASK_WHO · DREAMTEAM_AGENT_ID ·
# DREAMTEAM_CONFIG · DREAMTEAM_FLOW_LOG · DREAMTEAM_FLOW_BUDGET · DREAMTEAM_FLOW_MAX_LOGS · curl and tmux from PATH.
set -uo pipefail
T0=$(( $(date +%s%N) / 1000000 ))   # ms; the deadline clock starts before ANY external command (xreview #237 r2: the tmux fallback counts)
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
LOG="${DREAMTEAM_FLOW_LOG:-$HOME/.claude/state/dreamteam/flow-callout.log}"
. "$ROOT/scripts/lib/agent-id.sh"

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
MAX_LOGS="${DREAMTEAM_FLOW_MAX_LOGS:-8}"; case "$MAX_LOGS" in ''|*[!0-9]*) MAX_LOGS=8 ;; esac
INPUT="$(cat 2>/dev/null || true)"
ACTIVE="$(printf '%s' "$INPUT" | jq -r 'if type == "object" then (.stop_hook_active // false | tostring) else error("x") end' 2>/dev/null)" || exit 0
[ "$ACTIVE" = "true" ] && exit 0

# ── (b) master switch. `== false`, not `// true` (jq's // treats false as empty: the reuse-gate bug). A missing
#        config still enforces.
ENFORCE=$(jq -r 'if .flow.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# ── (c) who am I: the names this lane goes by, lowercase, deduped, the ledger's name alphabet only. The identity is
#        $ASK_WHO and a teammate's --agent-id (the dt_agent_id walk); the tmux session is ONLY the fallback when there
#        is neither (xreview #237 r1: a teammate is never its hosting session), and only inside tmux (outside it,
#        display-message names the host's most recent session: familiar 2026-11-17 20:09, "spire").
names=()
add() { local n; n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_.-')"; [ -n "$n" ] || return 0
        local x; for x in "${names[@]-}"; do [ "$x" = "$n" ] && return 0; done; names+=("$n"); }
mapfile -t leads < <(jq -r '(.flow.leads // ["sen","jp-2f"])[]' "$CFG" 2>/dev/null || printf 'sen\njp-2f\n')
[ "${#leads[@]}" -gt 0 ] || leads=(sen jp-2f)
is_lead() { local l; for l in "${leads[@]}"; do [ "$1" = "$l" ] && return 0; done; return 1; }
add "${ASK_WHO:-}"
AID="$(dt_agent_id)"; add "${AID%%@*}"
if [ "${#names[@]}" -eq 0 ] && [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  # ms, the same clock as the requests; the TERM grace (-k 1) is paid from the budget, so a tmux that ignores TERM
  # is still killed inside it (xreview #237 r3)
  tl=$(( BUDGET * 1000 - ($(( $(date +%s%N) / 1000000 )) - T0) - 1000 )); [ "$tl" -gt 3000 ] && tl=3000
  [ "$tl" -ge 200 ] && add "$(timeout -k 1 "$(( tl / 1000 )).$(printf '%03d' $(( tl % 1000 )))" tmux display-message -p '#S' 2>/dev/null || true)"
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
  # a regular file only (a FIFO or a device at the key path never reaches the read: that is the one hang guard, r4;
  # a mutation showed a timeout around the read was never exercised, so there is none), at most 200 bytes of it
  KEY=""
  if [ -f "$KF" ] && [ ! -L "$KF" ]; then
    KEY="$(head -c 200 -- "$KF" 2>/dev/null | tr -d '[:space:]')" || KEY=""
  fi
fi
if [ -z "$KEY" ]; then
  note "no ask key (ASK_KEY or ${DREAMTEAM_ASK_KEY_FILE:-~/Projects/plan.realm.watch/data/ask.key}): open rows of ${names[*]} not checked"
  exit 0
fi

URL="${ASK_URL:-http://127.0.0.1:7810}"; URL="${URL%/}"

# ── (f) ONE budget for the whole stop (xreview #237 r1): every request's timeout is cut to what is left of it, and
#        when it is spent the remaining rows are reported as unchecked, never silently skipped. Default 9 s inside the
#        hook's 12 s; seconds. MAX_LOGS bounds the row logs read, newest rows first, and is reported the same way.
left() { echo $(( BUDGET * 1000 - ($(( $(date +%s%N) / 1000000 )) - T0) )); }   # ms left of the budget
secs() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }                     # ms → "s.mmm" for curl -m / timeout
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
