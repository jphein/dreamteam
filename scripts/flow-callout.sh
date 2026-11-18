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
# BUDGET. curl -m 4 for the list and -m 3 per row log, at most 8 row logs (a lane holds a handful of rows; more is
# a ledger to tidy, not a stop to block). hooks.json gives it 12 s. TIMEOUTS ARE IN SECONDS.
#
# Seams (tests/test-flow-callout.sh): ASK_URL · ASK_KEY or DREAMTEAM_ASK_KEY_FILE · ASK_WHO · DREAMTEAM_AGENT_ID ·
# DREAMTEAM_CONFIG · DREAMTEAM_FLOW_LOG · curl and tmux from PATH.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
LOG="${DREAMTEAM_FLOW_LOG:-$HOME/.claude/state/dreamteam/flow-callout.log}"
. "$ROOT/scripts/lib/agent-id.sh"

# note — the one logged line of a fail-open path; never fails the hook
note() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s flow-callout: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG" 2>/dev/null || true
}

# ── (a) stdin: a Stop payload. stop_hook_active = the harness already continued once for a stop hook → never loop.
INPUT="$(cat 2>/dev/null || true)"
ACTIVE="$(printf '%s' "$INPUT" | jq -r 'if type == "object" then (.stop_hook_active // false | tostring) else error("x") end' 2>/dev/null)" || exit 0
[ "$ACTIVE" = "true" ] && exit 0

# ── (b) master switch. `== false`, not `// true` (jq's // treats false as empty: the reuse-gate bug). A missing
#        config still enforces.
ENFORCE=$(jq -r 'if .flow.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# ── (c) who am I: every name this lane goes by, lowercase, deduped, the ledger's name alphabet only.
names=()
add() { local n; n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_.-')"; [ -n "$n" ] || return 0
        local x; for x in "${names[@]-}"; do [ "$x" = "$n" ] && return 0; done; names+=("$n"); }
add "${ASK_WHO:-}"
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then   # only inside tmux: outside it, display-message names
  add "$(timeout 3 tmux display-message -p '#S' 2>/dev/null || true)"  # the host's most recent session (familiar: "spire")
fi
AID="$(dt_agent_id)"; add "${AID%%@*}"
[ "${#names[@]}" -gt 0 ] || exit 0

# ── (d) the lead is never blocked.
mapfile -t leads < <(jq -r '(.flow.leads // ["sen","jp-2f"])[]' "$CFG" 2>/dev/null || printf 'sen\njp-2f\n')
[ "${#leads[@]}" -gt 0 ] || leads=(sen jp-2f)
for n in "${names[@]}"; do for l in "${leads[@]}"; do [ "$n" = "$l" ] && exit 0; done; done
WHO="${names[0]}"

# ── (e) the key: $ASK_KEY, else the plan's key file. Without one nothing can be read: say so once, let the stop go.
KEY="${ASK_KEY:-}"
if [ -z "$KEY" ]; then
  KF="${DREAMTEAM_ASK_KEY_FILE:-$HOME/Projects/plan.realm.watch/data/ask.key}"
  KEY="$(head -c 200 -- "$KF" 2>/dev/null | tr -d '[:space:]')" || KEY=""
fi
if [ -z "$KEY" ]; then
  note "no ask key (ASK_KEY or ${DREAMTEAM_ASK_KEY_FILE:-~/Projects/plan.realm.watch/data/ask.key}): open rows of ${names[*]} not checked"
  exit 0
fi

URL="${ASK_URL:-http://127.0.0.1:7810}"; URL="${URL%/}"
get() { curl -fsS -m "$2" -H "X-Ask-Key: $KEY" -H "X-Ask-Who: $WHO" -H "Accept: application/json" "$1"; }

# ── (f) my open rows. Any failure here is an outage: one line, exit 0.
MINE="$(IFS=,; echo "${names[*]}")"
LIST="$(get "$URL/api/flow?open=1&mine=$MINE" 4 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ]; then
  note "plan unreachable or refused at $URL (curl rc $rc): open rows of $MINE not checked"
  exit 0
fi
ROWS="$(printf '%s' "$LIST" | jq -c '.rows[] | select(.state as $s | ["ordered","in-progress","blocked","needs-jp"] | index($s)) | {id, state, what}' 2>/dev/null)" || ROWS=""
if [ -z "$ROWS" ] && ! printf '%s' "$LIST" | jq -e 'type == "object" and (.rows | type == "array")' >/dev/null 2>&1; then
  note "the ledger at $URL answered something that is not its row list: open rows of $MINE not checked"
  exit 0
fi
[ -n "$ROWS" ] || exit 0

# ── (g) which of them are silent. `ordered` = silent by construction. Otherwise the log decides: an event by one of my
#        names (or my lane family), or a note prefixed "<name>:", after the last `ordered` event.
NAMES_JSON="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)"
spoken() { # spoken <show-json> → 0 when this lane has spoken since the last order
  printf '%s' "$1" | jq -e --argjson names "$NAMES_JSON" '
    def fam: sub("-[0-9a-f]{2,3}$"; "");
    (.log // []) as $log
    | ([$log[] | select(.event == "ordered") | .ts] | max // 0) as $since
    | [$log[] | select(.event != "ordered" and .ts >= $since)
             | select((.who | fam) as $w | ($names | map(fam) | index($w)) != null
                      or (.note as $n | $names | any(. as $x | $n | startswith($x + ":"))))]
    | length > 0' >/dev/null 2>&1
}
silent=(); checked=0; unread=0
while IFS= read -r r; do
  [ -n "$r" ] || continue
  id="$(printf '%s' "$r" | jq -r .id)"; state="$(printf '%s' "$r" | jq -r .state)"; what="$(printf '%s' "$r" | jq -r '.what // ""' | cut -c1-70)"
  case "$id" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) continue ;; esac
  if [ "$state" = "ordered" ]; then silent+=("$id	$what"); continue; fi
  [ "$checked" -lt 8 ] || continue
  checked=$((checked + 1))
  SHOW="$(get "$URL/api/flow/$id" 3 2>/dev/null)" || { unread=$((unread + 1)); continue; }
  spoken "$SHOW" || silent+=("$id	$what")
done <<< "$ROWS"
[ "$unread" -gt 0 ] && note "$unread row log(s) of $MINE could not be read at $URL: those rows not checked"

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
