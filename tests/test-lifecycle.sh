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
# Stub `systemctl` so the scope-pressure tier is deterministic. Default: the
# agents scope is INACTIVE (is-active exits 3), so EVERY existing tier test stays
# green (scope check short-circuits). FAKE_SCOPE=pressure flips is-active→active
# and makes `show … MemoryCurrent` report FAKE_SCOPE_CUR (default 18G) — enough to
# cross 85% of the config's 20G MemoryHigh.
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
  *is-active*)          [ "${FAKE_SCOPE:-}" = pressure ] && exit 0 || exit 3 ;;
  *show*MemoryCurrent*) echo "${FAKE_SCOPE_CUR:-19327352832}" ;;
  *)                    exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/systemctl"
# Stub `notify-send` → record each invocation to a log instead of hitting the real
# desktop bus (RED/scope tier events call it; tests must not spam JP's desktop).
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$TMP" > "$TMP/bin/notify-send"
chmod +x "$TMP/bin/notify-send"
# DREAMTEAM_PROJECT_DIR pins the derived project/scope name (hermetic against
# whatever REAL dreamteam-<cwd>.scope is live on the host); DREAMTEAM_FLEET_STATE
# isolates the #20 liveness stamps.
run_ev() { DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" DREAMTEAM_PROJECT_DIR="$TMP/projx" DREAMTEAM_FLEET_STATE="$TMP/fleet" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/team-events.sh"; }
run_cg() { DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/compact-guard.sh"; }

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

# team-events: liveness stamps (#20) — the fleet observer's real signal.
# The three events above already fired; assert their stamps landed with the
# right states, project-prefixed keys, and @team stripped from agent ids.
read -r ST _EP < "$TMP/fleet/projx__luna" 2>/dev/null || ST=missing
[ "$ST" = "idle" ] && ok "TeammateIdle stamps idle (projx__luna)" || bad "idle stamp: $ST"
read -r ST _EP < "$TMP/fleet/projx__wisp" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "SubagentStart stamps working" || bad "working stamp: $ST"
read -r ST EPOCH < "$TMP/fleet/projx__lucid" 2>/dev/null || ST=missing
[ "$ST" = "stopped" ] && ok "SubagentStop stamps stopped, @team stripped (lucid@s1 → lucid)" || bad "stopped stamp: $ST"
case "${EPOCH:-x}" in ''|*[!0-9]*) bad "stamp epoch not numeric (${EPOCH:-empty})";; *) ok "stamp carries numeric epoch";; esac

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

# team-events: scope-pressure tier (#3) — additive to the host tiers, driven by
# the dreamteam-agents.scope cgroup (systemctl stub). Default scope is INACTIVE.
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | run_ev)
case "$OUT" in *"SCOPE PRESSURE"*) bad "scope inactive: no scope-pressure expected ($OUT)";; *) ok "scope inactive → no scope-pressure line";; esac
# Active at 18G current vs 20G MemoryHigh (90% ≥ 85%) → SCOPE PRESSURE fires, even
# though host memory is green — i.e. surfaced independently of the host tier.
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | FAKE_SCOPE=pressure run_ev)
case "$OUT" in *"SCOPE PRESSURE"*"MemoryHigh"*) ok "scope ≥85% of MemoryHigh → SCOPE PRESSURE warning";; *) bad "scope pressure ($OUT)";; esac
# Non-vacuous threshold control: 16G current vs 20G high = 80% < 85% → silent.
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | FAKE_SCOPE=pressure FAKE_SCOPE_CUR=17179869184 run_ev)
case "$OUT" in *"SCOPE PRESSURE"*) bad "scope 80% < 85%: should NOT warn ($OUT)";; *) ok "scope 80% < threshold → silent (threshold non-vacuous)";; esac
# Additive: scope pressure and a RED host tier co-fire in the SAME message.
OUT=$(echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_SCOPE=pressure FAKE_AVAIL=5000 run_ev)
case "$OUT" in *"SCOPE PRESSURE"*"RED TIER"*|*"RED TIER"*"SCOPE PRESSURE"*) ok "scope pressure + RED host tier are additive";; *) bad "additive tiers ($OUT)";; esac

# team-events: RED-tier desktop notification (#3), throttled via state/.last-notify
rm -f "$TMP/state/.last-notify" "$TMP/notify.log"
echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_AVAIL=5000 run_ev >/dev/null
[ -f "$TMP/state/.last-notify" ] && ok "RED tier touches the notify throttle marker" || bad "notify marker not written"
{ [ -f "$TMP/notify.log" ] && [ "$(wc -l < "$TMP/notify.log")" -eq 1 ]; } && ok "RED tier fires notify-send once" || bad "RED notify count ($(cat "$TMP/notify.log" 2>/dev/null))"
# Immediate second RED event → throttled (marker < 600s old): still one invocation.
echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_AVAIL=5000 run_ev >/dev/null
[ "$(wc -l < "$TMP/notify.log")" -eq 1 ] && ok "second RED within 600s is throttled (no re-notify)" || bad "throttle failed ($(cat "$TMP/notify.log"))"
# Green host memory → no notification at all (notify is RED/scope only).
rm -f "$TMP/state/.last-notify" "$TMP/notify.log"
echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | run_ev >/dev/null
[ ! -f "$TMP/notify.log" ] && ok "green tier does not notify" || bad "green notified unexpectedly ($(cat "$TMP/notify.log"))"

# team-events + spawn-accounting + compact-guard: per-session roster threading (#4).
# A DECOY team, made mtime-NEWEST with a DIFFERENT lead name, simulates a
# multi-fleet day. A no-team call must resolve the decoy (proving it IS newest);
# a call carrying team_name must resolve THAT team instead — proving --team is
# threaded past roster.sh's newest-config default.
mkdir -p "$TMP/teams/decoytm"
cat > "$TMP/teams/decoytm/config.json" <<'EOF'
{"members":[
  {"name":"decoy-lead","agentType":"team-lead","agentId":"decoy-x","cwd":"/tmp"}
]}
EOF
touch "$TMP/teams/decoytm/config.json"   # bump mtime → decoy is the newest config
# Control: no team_name → newest (decoy) resolves. Makes the next check non-vacuous.
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna"}' | run_ev)
case "$OUT" in *"decoy-lead(lead)"*) ok "no team_name → mtime-newest (decoy) roster (control)";; *) bad "decoy-newest control ($OUT)";; esac
# The #4 fix (team-events): team_name routes past the newest-fallback to faketeam.
OUT=$(echo '{"hook_event_name":"TeammateIdle","teammate_name":"luna","team_name":"faketeam"}' | run_ev)
case "$OUT" in
  *"team-lead(lead)"*) case "$OUT" in *decoy-lead*) bad "team-events threaded team leaked decoy ($OUT)";; *) ok "team-events: team_name:faketeam → faketeam roster despite newer decoy";; esac ;;
  *) bad "team-events team threading ($OUT)";;
esac
# The #4 fix (spawn-accounting): tool_input.team_name routes past newest-fallback.
OUT=$(echo '{"tool_name":"Agent","tool_input":{"name":"t","team_name":"faketeam"},"cwd":"/tmp/proj"}' | DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/spawn-accounting.sh")
case "$OUT" in
  *"team-lead(lead)"*) case "$OUT" in *decoy-lead*) bad "spawn-accounting leaked decoy ($OUT)";; *) ok "spawn-accounting: tool_input.team_name:faketeam → faketeam roster";; esac ;;
  *) bad "spawn-accounting team threading ($OUT)";;
esac
# The #4 fix (compact-guard): team_name in a PreCompact payload routes the snapshot.
echo '{"hook_event_name":"PreCompact","trigger":"manual","cwd":"'"$ROOT"'","team_name":"faketeam"}' | run_cg >/dev/null
{ grep -q "team-lead" "$TMP/state/HANDOFF-auto.md" && ! grep -q "decoy-lead" "$TMP/state/HANDOFF-auto.md"; } && ok "compact-guard: team_name routes snapshot roster to faketeam" || bad "compact-guard team threading ($(grep -E 'lead' "$TMP/state/HANDOFF-auto.md" 2>/dev/null))"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
