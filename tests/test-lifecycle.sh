#!/usr/bin/env bash
# dreamteam tests — team-events.sh, compact-guard.sh, subagent-statusline.sh.
# Hermetic: DREAMTEAM_STATE + DREAMTEAM_TEAMS_DIR point at $TMP fixtures, so the
# roster is deterministic and no production state is touched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Fixture team: a lead + one member with a bogus agent-id (classifies dead).
mkdir -p "$TMP/teams/faketeam" "$TMP/state"
cat > "$TMP/teams/faketeam/config.json" <<'EOF'
{"members":[
  {"name":"team-lead","agentType":"team-lead","agentId":"lead-x","cwd":"/tmp"},
  {"name":"ghost","agentId":"no-such-agent-id-000","isActive":false,"cwd":"/tmp","prompt":"task: haunt"}
]}
EOF
# Stub `free` so the memory-tier check is deterministic: default = plenty (20000 MiB)
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho "Mem: 32000 10000 2000 100 3000 ${FAKE_AVAIL:-20000}"\n' > "$TMP/bin/free"
chmod +x "$TMP/bin/free"
run_ev() { DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/team-events.sh"; }
run_cg() { DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/compact-guard.sh"; }

for f in team-events compact-guard subagent-statusline; do
  bash -n "$ROOT/scripts/$f.sh" && ok "bash -n $f.sh" || bad "bash -n $f.sh"
done

# team-events: TeammateIdle → valid systemMessage naming the agent + roster
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | run_ev)
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && ok "TeammateIdle emits valid systemMessage JSON" || bad "TeammateIdle JSON ($OUT)"
case "$OUT" in *luna*IDLE*) ok "TeammateIdle names the idle agent";; *) bad "TeammateIdle names agent ($OUT)";; esac
case "$OUT" in *"team-lead(lead)"*) ok "TeammateIdle carries live roster";; *) bad "TeammateIdle roster ($OUT)";; esac

# team-events: SubagentStop → systemMessage; SubagentStart → log-only (silent)
OUT=$(echo '{"hook_event_name":"SubagentStop","agent_id":"lucid@s1"}' | run_ev)
case "$OUT" in *lucid@s1*stopped*) ok "SubagentStop emits stop notice";; *) bad "SubagentStop ($OUT)";; esac
OUT=$(echo '{"hook_event_name":"SubagentStart","agent_name":"wisp"}' | run_ev)
[ -z "$OUT" ] && ok "SubagentStart is log-only (no stdout)" || bad "SubagentStart silent ($OUT)"

# team-events: worktree audit — off-pattern flagged, canonical path not
echo '{"hook_event_name":"WorktreeCreate","path":"/tmp/rogue"}' | run_ev >/dev/null
echo '{"hook_event_name":"WorktreeCreate","path":"/repo/.claude/worktrees/luna-1"}' | run_ev >/dev/null
grep -q '"path":"/tmp/rogue","offPattern":true' "$TMP/state/events.log" && ok "off-pattern worktree flagged" || bad "off-pattern flag"
grep -q '"path":"/repo/.claude/worktrees/luna-1","offPattern":false' "$TMP/state/events.log" && ok "canonical worktree not flagged" || bad "canonical worktree flag"

# team-events: every event logged with payload keys; empty stdin safe
N=$(wc -l < "$TMP/state/events.log")
[ "$N" -ge 5 ] && ok "events.log has one line per event ($N)" || bad "events.log lines ($N)"
grep -q '"payloadKeys":\["hook_event_name","teammate_name"\]' "$TMP/state/events.log" && ok "payload keys captured for field discovery" || bad "payload keys captured"
printf '' | run_ev; [ $? -eq 0 ] && ok "team-events: empty stdin exits 0" || bad "team-events empty stdin"

# team-events: memory-tier actor (incident-#2 fix) — green is silent, ORANGE and
# RED fire at floor*1.5 and floor (default floor 8000)
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | run_ev)
case "$OUT" in *TIER*) bad "green: no tier warning expected ($OUT)";; *) ok "green avail: no tier warning";; esac
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | FAKE_AVAIL=10000 run_ev)
case "$OUT" in *"ORANGE TIER"*) ok "10000MiB avail → ORANGE (quiesce) warning";; *) bad "ORANGE tier ($OUT)";; esac
OUT=$(echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_AVAIL=5000 run_ev)
case "$OUT" in *"RED TIER"*"shutdown_request"*) ok "5000MiB avail → RED (shed) warning";; *) bad "RED tier ($OUT)";; esac

# spawn-accounting: first spawn writes the crash marker (incident-#2 fix);
# a second spawn must not overwrite it
OUT=$(echo '{"tool_name":"Agent","tool_input":{"name":"t"},"cwd":"/tmp/proj"}' | DREAMTEAM_STATE="$TMP/state" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/spawn-accounting.sh")
[ -f "$TMP/state/active" ] && ok "first spawn writes state/active crash marker" || bad "crash marker not written"
grep -q '"repo":"/tmp/proj"' "$TMP/state/active" && ok "marker records cwd as repo" || bad "marker repo field"
M1=$(cat "$TMP/state/active")
echo '{"tool_name":"Agent","tool_input":{"name":"t2"},"cwd":"/elsewhere"}' | DREAMTEAM_STATE="$TMP/state" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/spawn-accounting.sh" >/dev/null
[ "$(cat "$TMP/state/active")" = "$M1" ] && ok "second spawn does not overwrite marker" || bad "marker overwritten"

# compact-guard: PreCompact writes snapshot + systemMessage
OUT=$(echo '{"hook_event_name":"PreCompact","trigger":"auto","cwd":"'"$ROOT"'"}' | run_cg)
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && ok "PreCompact emits systemMessage" || bad "PreCompact systemMessage ($OUT)"
SNAP="$TMP/state/HANDOFF-auto.md"
[ -f "$SNAP" ] && ok "PreCompact wrote HANDOFF-auto.md" || bad "HANDOFF-auto.md missing"
grep -q "trigger: auto" "$SNAP" && ok "snapshot records trigger" || bad "snapshot trigger"
grep -q "team-lead" "$SNAP" && ok "snapshot contains roster" || bad "snapshot roster"
grep -q "^branch: " "$SNAP" && ok "snapshot contains git branch" || bad "snapshot git branch"
grep -q "Post-compaction first actions" "$SNAP" && ok "snapshot has recovery checklist" || bad "snapshot checklist"

# compact-guard: PostCompact re-arms with roster + snapshot pointer
OUT=$(echo '{"hook_event_name":"PostCompact"}' | run_cg)
case "$OUT" in *COMPACTED*"team-lead(lead)"*HANDOFF-auto.md*) ok "PostCompact re-injects roster + snapshot path";; *) bad "PostCompact re-arm ($OUT)";; esac

# subagent-statusline: rich, partial (single field), empty
OUT=$(echo '{"name":"lucid","status":"active","model":{"display_name":"Opus 4.8"}}' | bash "$ROOT/scripts/subagent-statusline.sh")
case "$OUT" in "🕯 lucid · active · Opus 4.8") ok "subagent line: full payload";; *) bad "subagent full ($OUT)";; esac
OUT=$(echo '{"agent_id":"nebula@s1"}' | bash "$ROOT/scripts/subagent-statusline.sh")
case "$OUT" in "🕯 nebula@s1") ok "subagent line: partial payload (single field)";; *) bad "subagent partial ($OUT)";; esac
OUT=$(printf '' | bash "$ROOT/scripts/subagent-statusline.sh")
case "$OUT" in "🕯 dreaming…") ok "subagent line: empty stdin fallback";; *) bad "subagent empty ($OUT)";; esac

# hooks.json: all new events wired
for ev in TeammateIdle SubagentStart SubagentStop TaskCreated TaskCompleted WorktreeCreate WorktreeRemove PreCompact PostCompact; do
  python3 -c "
import json,sys
h=json.load(open('$ROOT/hooks/hooks.json'))['hooks']
sys.exit(0 if '$ev' in h else 1)" && ok "hooks.json wires $ev" || bad "hooks.json wires $ev"
done

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
