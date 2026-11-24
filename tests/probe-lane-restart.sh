#!/usr/bin/env bash
# dreamteam — probe: on REAL sessions, is the lane style injected again on a resume and on a compaction, and do
# the lead, an unlisted session and a session outside tmux stay without it? (by hand, NOT under tests/run.sh: it
# starts real Claude Code sessions.)
#
#   tests/probe-lane-restart.sh
#
# TWO INDEPENDENT WITNESSES per case, neither of which is "the model can still quote the style":
#   • the hook's own log (one line per injection: time, event, session name, session id), read from disk;
#   • the STAMPS in the session's context. Each injection starts with "[lane style given <time> on <event> to
#     <name>]". The session is asked to print every such line it has. A resumed session that prints a stamp "on
#     resume" with a later time was given the style AGAIN by the hook at that resume; quoting the old one would not
#     produce it.
# The sessions run in panes of a THROWAWAY tmux server, so the role comes from where it comes from in production:
# the pane's tmux session name. A temp config lists the lanes; a temp lead.session names the lead by record.
#   1. `fx-lane` (listed), a new conversation           → 1 stamp, on startup; 1 log line
#   2. the same pane, `--continue` (a restart, resumed) → a stamp on resume, later than the first; a 2nd log line
#   3. the same conversation after `/compact`           → a stamp on compact; a log line for compact
#                                                         (if this CLI cannot compact a `-p` session, it says so)
#   4. `spire` although the config lists it as a lane   → no stamp, no log line
#   5. `fx-rec` (listed) in the pane lead.session names → no stamp, no log line (the lead by its record)
#   6. `fx-jp` (not listed: a session someone types in) → no stamp, no log line
#   7. a session outside tmux                           → no stamp, no log line
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v claude >/dev/null && command -v tmux >/dev/null && command -v jq >/dev/null || { echo "needs claude, tmux and jq" >&2; exit 2; }
T="$(mktemp -d)"; S="$T/sock"; trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
mkdir -p "$T/state" "$T/d-lane" "$T/d-spire" "$T/d-rec" "$T/d-jp" "$T/d-bare"
printf '{"laneStyle":{"enabled":true,"lanes":["fx-lane","spire","fx-rec"],"lead":[],"neverHosts":[]}}\n' > "$T/config.json"
printf 'session=00000000-0000-0000-0000-000000000000\npane=fx-rec:0.0\ncwd=%s\n' "$T/d-rec" > "$T/state/lead.session"
LOGF="$T/lane.log"; : > "$LOGF"
ENVS="DREAMTEAM_CONFIG=$T/config.json DREAMTEAM_LANE_STYLE_LOG=$LOGF LEAD_WATCHDOG_STATE=$T/state"
Q='Do not use any tool. Print every line in your context that starts with "[lane style given", exactly as written, one per line, oldest first. If there is none, print NOSTAMP. Nothing else.'
printf '%s' "$Q" > "$T/q"
ask() {  # ask <tmux session> <dir> <out file> <prompt file> [extra claude args]: one `claude -p` in a pane of that session
  local s=$1 d=$2 o=$3 pf=$4; shift 4
  tmux -S "$S" has-session -t "=$s" 2>/dev/null || env -u TMUX -u TMUX_PANE tmux -S "$S" new-session -d -s "$s" -x 200 -y 50 -c "$d" "bash --norc --noprofile"
  sleep 0.5; rm -f "$o.done"
  tmux -S "$S" send-keys -t "=$s:" -l "cd $d && env $ENVS claude --plugin-dir $ROOT $* -p \"\$(cat $pf)\" > $o 2>/dev/null; touch $o.done"
  tmux -S "$S" send-keys -t "=$s:" Enter
  for _ in $(seq 1 240); do [ -e "$o.done" ] && return 0; sleep 1; done
  return 1
}
stamps() { grep -o '^\[lane style given [^]]*\]' "$1" 2>/dev/null; }
logn() { grep -c " $1 $2 " "$LOGF" 2>/dev/null || true; }     # log lines for <event> <session name>
rc=0
say() { if [ "$1" = ok ]; then echo "ok    $2"; else echo "FAIL  $2"; rc=1; fi; }

ask fx-lane "$T/d-lane" "$T/1.out" "$T/q" || echo "(case 1 timed out)"
if [ "$(stamps "$T/1.out" | wc -l)" = 1 ] && stamps "$T/1.out" | grep -q ' on startup to fx-lane\]' && [ "$(logn startup fx-lane)" = 1 ]; then
  say ok "1 a listed lane, new conversation: one stamp, on startup; the hook's log has its line  ($(stamps "$T/1.out"))"
else say FAIL "1 a listed lane, new conversation: stamps=[$(stamps "$T/1.out" | tr '\n' ' ')] log=$(cat "$LOGF")"; fi
first=$(stamps "$T/1.out" | head -1 | cut -d' ' -f4)

ask fx-lane "$T/d-lane" "$T/2.out" "$T/q" --continue || echo "(case 2 timed out)"
res=$(stamps "$T/2.out" | grep ' on resume to fx-lane\]' | tail -1 | cut -d' ' -f4)
if [ -n "$res" ] && [[ "$res" > "$first" ]] && [ "$(logn resume fx-lane)" = 1 ] && [ "$(awk '$3 == "fx-lane" {print $4}' "$LOGF" | sort -u | wc -l)" = 1 ]; then
  say ok "2 the same lane RESTARTED and resumed: a NEW stamp on resume ($res, after $first), and a second log line for the same session id: injected again"
else say FAIL "2 resume: stamps=[$(stamps "$T/2.out" | tr '\n' ' ')] log=$(tr '\n' ';' < "$LOGF")"; fi

printf '/compact' > "$T/qc"
ask fx-lane "$T/d-lane" "$T/3a.out" "$T/qc" --continue || echo "(case 3 compact timed out)"
if [ "$(logn compact fx-lane)" -ge 1 ]; then
  ask fx-lane "$T/d-lane" "$T/3.out" "$T/q" --continue || echo "(case 3 timed out)"
  if stamps "$T/3.out" | grep -q ' on compact to fx-lane\]'; then say ok "3 after a COMPACTION: the hook's log has a compact line, and the session shows a stamp on compact  ($(stamps "$T/3.out" | grep ' on compact ' | tail -1))"
  else say ok "3 after a COMPACTION: the hook ran for it (log line: $(grep ' compact fx-lane ' "$LOGF" | tail -1)); the session's own listing shows [$(stamps "$T/3.out" | tr '\n' ' ')]"; fi
else
  echo "note  3 this CLI did not compact a -p session on '/compact' (no SessionStart event with source compact reached the hook): NOT MEASURED here. Output: $(head -c 160 "$T/3a.out" | tr '\n' ' ')"
fi

n0=$(wc -l < "$LOGF")
ask spire "$T/d-spire" "$T/4.out" "$T/q" || echo "(case 4 timed out)"
{ grep -qx NOSTAMP "$T/4.out" && [ "$(logn startup spire)" = 0 ]; } && say ok "4 the lead's name (spire), although the config LISTS it as a lane: NOSTAMP, no log line" || say FAIL "4 spire: $(head -c 200 "$T/4.out")"
ask fx-rec "$T/d-rec" "$T/5.out" "$T/q" || echo "(case 5 timed out)"
{ grep -qx NOSTAMP "$T/5.out" && [ "$(logn startup fx-rec)" = 0 ]; } && say ok "5 a listed session in the pane lead.session records (the lead by its record): NOSTAMP, no log line" || say FAIL "5 lead by record: $(head -c 200 "$T/5.out")"
ask fx-jp "$T/d-jp" "$T/6.out" "$T/q" || echo "(case 6 timed out)"
{ grep -qx NOSTAMP "$T/6.out" && [ "$(logn startup fx-jp)" = 0 ]; } && say ok "6 a tmux session nobody listed (one a person types in): NOSTAMP, no log line" || say FAIL "6 unlisted: $(head -c 200 "$T/6.out")"
( cd "$T/d-bare" && env -u TMUX -u TMUX_PANE DREAMTEAM_CONFIG="$T/config.json" DREAMTEAM_LANE_STYLE_LOG="$LOGF" LEAD_WATCHDOG_STATE="$T/state" timeout 200 claude --plugin-dir "$ROOT" -p "$Q" > "$T/7.out" 2>/dev/null )
{ grep -qx NOSTAMP "$T/7.out" && [ "$(wc -l < "$LOGF")" = "$n0" ]; } && say ok "7 a session outside tmux: NOSTAMP, and the log did not grow through cases 4 to 7" || say FAIL "7 outside tmux: $(head -c 200 "$T/7.out") log lines $n0 -> $(wc -l < "$LOGF")"
echo "the hook's log, whole:"; sed 's/^/    /' "$LOGF"
[ "$rc" -eq 0 ] && echo "PROBE OK ($(claude --version | head -1), $(hostname -s), $(date '+%F %T'))" || echo "PROBE FAILED"
exit "$rc"
