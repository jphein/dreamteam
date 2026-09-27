#!/usr/bin/env bash
# idle-assign.sh: freed agent → systemMessage with held context + ranked backlog; deduped per stretch.
set -u; cd "$(dirname "$0")/.."
S=scripts/idle-assign.sh; export CLAUDE_PROJECT_DIR=$(mktemp -d); mkdir -p "$CLAUDE_PROJECT_DIR/scratch/dreamteam"
CTX="$HOME/.claude/state/agent-context.json"; cp "$CTX" "$CTX.bak-test" 2>/dev/null || true
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }
bash $S backlog add "[lifeline] fetch register items" >/dev/null; bash $S backlog add "[tapstone] rebase vr-m1b-s" >/dev/null
echo '{"tool_name":"Agent","tool_input":{"name":"ia-test","prompt":"IDLE-CHECKED: x\nYou are Lucid, project lifeline."}}' | bash $S context
out=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"ia-test"}' | bash $S idle)
grep -q 'ia-test is free' <<<"$out" && ok "announces the freed agent" || bad "no announcement: $out"
grep -q 'IDLE-CHECKED' <<<"$out" && bad "gate preamble leaked into held context" || ok "held context is the task, not the preamble"
python3 -c "import json,sys; m=json.loads(sys.argv[1])['systemMessage']; l=[x for x in m.splitlines() if x.strip().startswith('1. ')][0]; assert 'lifeline' in l, l" "$out" && ok "lifeline item ranked first for a lifeline agent" || bad "ranking"
out2=$(echo '{"hook_event_name":"SubagentStop","teammate_name":"ia-test"}' | bash $S idle)
[ -z "$out2" ] && ok "second idle in the same stretch is silent" || bad "dedupe: $out2"
echo '{"tool_name":"SendMessage","tool_input":{"to":"ia-test","summary":"tapstone rebase","message":"rebase vr-m1b-s"}}' | bash $S context
out3=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"ia-test"}' | bash $S idle)
python3 -c "import json,sys; m=json.loads(sys.argv[1])['systemMessage']; l=[x for x in m.splitlines() if x.strip().startswith('2. ')][0]; assert 'tapstone' in l, l" "$out3" && ok "re-armed by a new assignment; ranking follows the new context" || bad "re-arm/rank: $out3"
out4=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"team-lead"}' | bash $S idle); [ -z "$out4" ] && ok "team-lead never announced" || bad "lead announced"
# the guard must fail once on purpose: an agent with no backlog still gets announced (message is the mechanism)
: > "$CLAUDE_PROJECT_DIR/scratch/dreamteam/backlog.md"; echo '{"tool_name":"Agent","tool_input":{"name":"ia-empty","prompt":"x"}}' | bash $S context
out5=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"ia-empty"}' | bash $S idle); grep -q 'backlog empty' <<<"$out5" && ok "empty backlog still announces" || bad "empty backlog: $out5"
python3 - <<'PY'
import json,os; p=os.path.expanduser('~/.claude/state/agent-context.json'); d=json.load(open(p)); [d.pop(k,None) for k in ('ia-test','ia-empty')]; json.dump(d,open(p,'w'))
PY
rm -rf "$CLAUDE_PROJECT_DIR" "$CTX.bak-test"; [ $fail = 0 ] && echo "test-idle-assign: PASS" || { echo "test-idle-assign: FAIL"; exit 1; }
