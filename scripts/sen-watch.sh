#!/usr/bin/env bash
STATE="${SEN_WATCH_STATE:-$HOME/.local/state/sen-watch}"; mkdir -p "$STATE"
# One combined watch: plan-chat (JP), Squire's dispatch/pane, agent-mail inbox. Lines prefixed by source.
seen=$STATE/squire-seen.txt; touch "$seen"
( ~/.local/bin/plan-chat watch 2>&1 | grep --line-buffered -v '^plan-chat watch: listening' | sed -u 's/^/[plan-chat] /' ) &
( agent-mail watch sen | sed -u 's/^/[agent-mail] /' ) &
( while true; do out=$(ssh -o ConnectTimeout=8 katana 'tail -n 10 ~/Projects/money/scratch/webagent-queue/dispatch.log 2>/dev/null | grep -E "DONE|CLAIM|ASK|FAIL|NEEDS|READY|NOTE|SIGNED-OUT|BLOCKED|ABSENT|CANCEL|BAD|SWEPT|VERDICT"; p=$(tmux capture-pane -pt ember 2>/dev/null); printf "%s\n" "$p" | grep -vE "^\s*$" | tail -3 | grep -E "ASK|JP|needs you|blocked|NEEDS-JP|READY-FOR-JP|VERDICT" | sed "s/^/Squire: /"' 2>/dev/null || echo "squire-watch: ssh katana failed $(date +%H:%M)"); printf '%s\n' "$out" | while IFS= read -r l; do [ -z "$l" ] && continue; if ! grep -qxF -- "$l" "$seen"; then printf '%s\n' "$l" >> "$seen"; printf '[squire] %s\n' "$l"; fi; done; sleep 60; done ) &
# Gmail Sent watcher (JP 2026-11-07 12:29 "you really are stale": his own sends must reach the lead within minutes, not at the hourly pass)
( sentseen="$STATE/sen-watch.sent-seen"; touch "$sentseen"; while true; do ~/.local/bin/gmail-fetch search 'in:sent newer_than:1d' 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
for m in d.get('messages',[]): print(m.get('id'), (m.get('date') or '')[:22], '->', (m.get('to') or '')[:40], '|', (m.get('subject') or '')[:60])" | while IFS= read -r l; do [ -z "$l" ] && continue; id=${l%% *}; if ! grep -qxF -- "$id" "$sentseen"; then printf '%s\n' "$id" >> "$sentseen"; printf '[sent] %s\n' "$l"; fi; done; sleep 120; done ) &
# Dispatcher liveness (2026-11-10, money: "alive" = the wz-dispatch.sh process is running; STATE DOWN [Steward] is the held wakizashi lane, expected while .hold-1 exists; the log is event-only, so its age means nothing overnight): once an hour, 07–22, say so if the process is gone.
( lastwarn=""; while true; do h=$(date +%H); if [ "$h" -ge 7 ] && [ "$h" -le 22 ]; then n=$(ps -C bash -o args= 2>/dev/null | grep -c 'wz-dispatch.sh'); if [ "$n" -eq 0 ] && [ "$lastwarn" != "$h" ]; then lastwarn=$h; printf '[dispatch] DOWN: no wz-dispatch.sh process on familiar (money owns it; tmux wz-dispatch)\n'; fi; fi; sleep 600; done ) &
# sen-sweep (token plan item 1, JP 2026-11-12): the sweep + mail pass as a script, every 15 min, actionable lines only
( sleep 20; while true; do bash ~/.claude/scripts/sen-sweep.sh 2>/dev/null | tee >(sed "s/^/$(date +%H:%M) /" > ~/srv/plan.realm.watch/data/sweep-last.txt) | sed -u 's/^/[sweep] /'; sleep 900; done ) &
wait
