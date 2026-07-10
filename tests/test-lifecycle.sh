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
# Stub `notify-send` → record each invocation (args + the DBUS addr it was given, for
# the #51 assertion) to a log instead of hitting the real desktop bus (RED/scope tier
# events call it; tests must not spam JP's desktop).
printf '#!/bin/bash\nprintf "%%s DBUS=%%s\\n" "$*" "${DBUS_SESSION_BUS_ADDRESS:-UNSET}" >> "%s/notify.log"\n' "$TMP" > "$TMP/bin/notify-send"
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
case "$OUT" in *luna*) ok "TeammateIdle names the teammate";; *) bad "TeammateIdle names teammate ($OUT)";; esac
case "$OUT" in *"team-lead(lead)"*) ok "TeammateIdle carries live roster";; *) bad "TeammateIdle roster ($OUT)";; esac
# #21 regression — a turn-boundary message must NOT claim idle/reusable (doing so
# misled the orchestrator into retasking a live, working agent); it must frame the
# event honestly and route reuse through the authoritative live check.
case "$OUT" in *"is IDLE"*|*"reusable via SendMessage"*) bad "#21: TeammateIdle still claims idle/reusable ($OUT)";; *) ok "#21: TeammateIdle no longer claims idle/reusable";; esac
case "$OUT" in *"turn boundary"*) ok "#21: TeammateIdle framed as a turn boundary";; *) bad "#21: turn-boundary framing missing ($OUT)";; esac
case "$OUT" in *"dreamteam-roster"*) ok "#21: TeammateIdle routes reuse to the live check";; *) bad "#21: verify-first directive missing ($OUT)";; esac

# team-events: SubagentStop → systemMessage; SubagentStart → log-only (silent)
OUT=$(echo '{"hook_event_name":"SubagentStop","agent_id":"lucid@s1"}' | run_ev)
case "$OUT" in *lucid@s1*stopped*) ok "SubagentStop emits stop notice";; *) bad "SubagentStop ($OUT)";; esac
OUT=$(echo '{"hook_event_name":"SubagentStart","agent_name":"wisp"}' | run_ev)
[ -z "$OUT" ] && ok "SubagentStart is log-only (no stdout)" || bad "SubagentStart silent ($OUT)"

# team-events: liveness stamps (#20) — the fleet observer's real signal.
# The three events above already fired; assert their stamps landed with the
# right states, project-prefixed keys, and @team stripped from agent ids.
read -r ST _EP < "$TMP/fleet/projx__luna" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "TeammateIdle stamps working, not idle (#21: turn boundary ≠ idle)" || bad "#21 TeammateIdle stamp should be working, got: $ST"
read -r ST _EP < "$TMP/fleet/projx__wisp" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "SubagentStart stamps working" || bad "working stamp: $ST"
read -r ST EPOCH < "$TMP/fleet/projx__lucid" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "#56: SubagentStop stamps working not stopped (per-turn boundary ≠ death; @team stripped lucid@s1→lucid)" || bad "#56 SubagentStop stamp should be working, got: $ST"
case "${EPOCH:-x}" in ''|*[!0-9]*) bad "stamp epoch not numeric (${EPOCH:-empty})";; *) ok "stamp carries numeric epoch";; esac
# #56 regression — SubagentStop must NOT flip a working subagent to "stopped" (it's a
# per-turn response-end, not death; 892 stops vs 105 starts in the wild). wisp was
# stamped working by SubagentStart above; a following SubagentStop must keep it working.
echo '{"hook_event_name":"SubagentStop","agent_id":"wisp"}' | run_ev >/dev/null
read -r ST _EP < "$TMP/fleet/projx__wisp" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "#56: SubagentStop keeps a working subagent working (no false-stopped latch)" || bad "#56: SubagentStop flipped working→'$ST'"

# #21 regression — the liveness stamp must not LATCH a working teammate to "idle".
# TeammateIdle is a turn boundary; the name-keyed stamp had no "working" writer
# after the one-shot spawn, so the first idle stuck forever (a live agent read as
# idle for its whole life). Assert the honest state machine on ONE key:
#   TaskCreated → working ; a following TeammateIdle STAYS working (no latch) ;
#   TaskCompleted → idle (the single true "task done, now reusable" signal).
echo '{"hook_event_name":"TaskCreated","teammate_name":"seq"}'   | run_ev >/dev/null
read -r ST _EP < "$TMP/fleet/projx__seq" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "TaskCreated stamps working (#21 name-keyed work signal)" || bad "TaskCreated stamp: $ST"
echo '{"hook_event_name":"TeammateIdle","teammate_name":"seq"}'  | run_ev >/dev/null
read -r ST _EP < "$TMP/fleet/projx__seq" 2>/dev/null || ST=missing
[ "$ST" = "working" ] && ok "TeammateIdle after work STAYS working — no false-idle latch (#21)" || bad "#21 latch regression: TeammateIdle flipped a working teammate to '$ST'"
echo '{"hook_event_name":"TaskCompleted","teammate_name":"seq"}' | run_ev >/dev/null
read -r ST _EP < "$TMP/fleet/projx__seq" 2>/dev/null || ST=missing
[ "$ST" = "idle" ] && ok "TaskCompleted stamps idle — the honest 'task done' signal (#21)" || bad "TaskCompleted stamp: $ST"

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

# team-events #50: co-firing scope-pressure + RED must collapse to ONE notify_red
# delivery, and it must be the MORE-URGENT RED — not dropped by scope-pressure's
# shared 600s marker touch. Clear marker + log first so the throttle can't hide it.
rm -f "$TMP/state/.last-notify"; : > "$TMP/notify.log"
echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_SCOPE=pressure FAKE_AVAIL=5000 run_ev >/dev/null
NL=$(wc -l < "$TMP/notify.log" 2>/dev/null || echo 0)
[ "$NL" -eq 1 ] && ok "#50: co-firing scope+RED → exactly ONE notify_red (not two)" || bad "#50: expected 1 notify, got $NL ($(cat "$TMP/notify.log" 2>/dev/null))"
grep -q "RED TIER" "$TMP/notify.log" && ok "#50: the single delivery is the more-urgent RED" || bad "#50: RED not delivered ($(cat "$TMP/notify.log"))"
grep -q "SCOPE PRESSURE" "$TMP/notify.log" && bad "#50: scope-pressure consumed the slot, dropping RED (regression)" || ok "#50: scope-pressure did not displace RED"
OUT=$(echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_SCOPE=pressure FAKE_AVAIL=5000 run_ev)
case "$OUT" in *"SCOPE PRESSURE"*"RED TIER"*) ok "#50: in-context systemMessage still shows BOTH tiers (additive)";; *) bad "#50: both tiers should appear in-context ($OUT)";; esac
# negative control — RED alone (no scope) still delivers exactly one RED notify
rm -f "$TMP/state/.last-notify"; : > "$TMP/notify.log"
echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_AVAIL=5000 run_ev >/dev/null
grep -q "RED TIER" "$TMP/notify.log" && ok "#50 control: RED-only still notifies" || bad "#50 control: RED-only notify missing"

# team-events #51: notify-send must carry a session-bus address (DBUS) so the desktop
# toast doesn't silently no-op in the hook/cron context (no inherited DBUS). The stub
# records DBUS=<addr|UNSET>; the fix supplies /run/user/<uid>/bus when none is inherited.
# Unset DBUS in a subshell to mimic a real hook/cron ctx (no inherited bus) — makes
# this NON-VACUOUS: unfixed code → notify-send sees no bus → stub logs UNSET; the fix
# supplies /run/user/<uid>/bus. (Without the unset, a graphical test env would pass hollow.)
rm -f "$TMP/state/.last-notify"; : > "$TMP/notify.log"
( unset DBUS_SESSION_BUS_ADDRESS
  echo '{"hook_event_name":"SubagentStop","agent_id":"x"}' | FAKE_AVAIL=5000 run_ev >/dev/null )
grep -q "DBUS=unix:" "$TMP/notify.log" && ok "#51: notify-send gets a DBUS session-bus addr even when none is inherited" || bad "#51: DBUS unset on notify-send ($(cat "$TMP/notify.log"))"
# #51 covers BOTH notify-send call-sites (team-lead: the whole #51 is mine). No standalone
# harness for morning-briefing.sh (it gathers gh/PR state), so static-guard that its toast
# now supplies a bus address too — it referenced no DBUS at all before the fix.
grep -q 'DBUS_SESSION_BUS_ADDRESS' "$ROOT/scripts/morning-briefing.sh" && ok "#51: morning-briefing.sh notify() also supplies a DBUS bus (both call-sites fixed)" || bad "#51: morning-briefing.sh notify-send has no DBUS bus"

# ── #57: tier→Nyx routing (S7) — durable blackboard + RED poke ─────────────────────
# Fixture: a team WITH a nyx member (roster.sh --team resolves it by agentType/name) + a
# poke stub (records args; the DREAMTEAM_POKE seam lets the RED path fire without typing
# into a real pane). Blackboard is per-project (#69): $TMP/state/tier-status-<project>.
# run_ev pins DREAMTEAM_PROJECT_DIR=$TMP/projx, so writes land at $BB.
BB="$TMP/state/tier-status-projx"
mkdir -p "$TMP/teams/nyxteam"
cat > "$TMP/teams/nyxteam/config.json" <<'EOF'
{"members":[
  {"name":"team-lead","agentType":"team-lead","agentId":"lead-n"},
  {"name":"nyx-resource-manager","agentType":"dreamteam:nyx","agentId":"nyx-n","isActive":true}
]}
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/poke.log"\n' "$TMP" > "$TMP/bin/poke-stub"; chmod +x "$TMP/bin/poke-stub"

# blackboard: RED writes it, atomically, with tier=RED + a ts
rm -f "$BB" "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | FAKE_AVAIL=5000 run_ev >/dev/null
[ -f "$BB" ] && ok "#57: RED writes the durable blackboard" || bad "#57: no blackboard on RED"
grep -q '"tier":"RED"' "$BB" && ok "#57: blackboard records tier=RED" || bad "#57: blackboard tier ($(cat "$BB" 2>/dev/null))"
grep -q '"ts":' "$BB" && ok "#57: blackboard carries ts (for staleness)" || bad "#57: blackboard ts missing"
ls "$TMP/state/"*.tmp >/dev/null 2>&1 && bad "#57: atomic-write temp file leaked" || ok "#57: atomic write leaves no temp file"

# precedence: scope-only → SCOPE; ORANGE → ORANGE; green → NO write (staleness handles clear)
rm -f "$BB" "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | FAKE_SCOPE=pressure run_ev >/dev/null
grep -q '"tier":"SCOPE"' "$BB" && ok "#57: scope-only writes tier=SCOPE" || bad "#57: scope tier ($(cat "$BB" 2>/dev/null))"
rm -f "$BB" "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | FAKE_AVAIL=10000 run_ev >/dev/null
grep -q '"tier":"ORANGE"' "$BB" && ok "#57: ORANGE writes tier=ORANGE" || bad "#57: orange tier ($(cat "$BB" 2>/dev/null))"
rm -f "$BB" "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | run_ev >/dev/null
[ -f "$BB" ] && bad "#57: green should NOT write the blackboard" || ok "#57: green → no blackboard write (resolved tier read as stale by age)"

# RED pokes the nyx member (best-effort low-latency nudge) via the DREAMTEAM_POKE seam
rm -f "$TMP/state/.last-notify"; : > "$TMP/poke.log"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | DREAMTEAM_POKE="$TMP/bin/poke-stub" FAKE_AVAIL=5000 run_ev >/dev/null
grep -q 'nyx-resource-manager' "$TMP/poke.log" && ok "#57: RED pokes the nyx member (low-latency urgency)" || bad "#57: RED did not poke nyx ($(cat "$TMP/poke.log" 2>/dev/null))"
# ORANGE must NOT poke (RED-only)
: > "$TMP/poke.log"; rm -f "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"nyxteam"}' | DREAMTEAM_POKE="$TMP/bin/poke-stub" FAKE_AVAIL=10000 run_ev >/dev/null
[ -s "$TMP/poke.log" ] && bad "#57: ORANGE must not poke (RED-only)" || ok "#57: ORANGE does not poke (RED-only)"
# nyx ABSENT → no poke, but blackboard STILL written (Sandman backstop)
: > "$TMP/poke.log"; rm -f "$BB" "$TMP/state/.last-notify"
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"faketeam"}' | DREAMTEAM_POKE="$TMP/bin/poke-stub" FAKE_AVAIL=5000 run_ev >/dev/null
[ -s "$TMP/poke.log" ] && bad "#57: nyx-absent must not poke" || ok "#57: nyx-absent → no poke"
grep -q '"tier":"RED"' "$BB" && ok "#57: nyx-absent → blackboard STILL written (Sandman backstop)" || bad "#57: nyx-absent blackboard missing"

# tier-status.sh reader — reports the recorded tier + age/staleness; 'none' when absent
run_ts() { DREAMTEAM_STATE="$TMP/state" DREAMTEAM_PROJECT_DIR="$TMP/projx" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/tier-status.sh" "$@"; }
bash -n "$ROOT/scripts/tier-status.sh" && ok "bash -n tier-status.sh" || bad "bash -n tier-status.sh"
run_ts --json | jq -e '.tier=="RED"' >/dev/null 2>&1 && ok "#57: tier-status.sh --json reports the recorded tier" || bad "#57: tier-status --json tier ($(run_ts --json))"
run_ts --json | jq -e '.ageSec >= 0 and .stale==false' >/dev/null 2>&1 && ok "#57: tier-status reports age; fresh tier not stale" || bad "#57: tier-status age/stale ($(run_ts --json))"
printf '{"ts":%s,"tier":"RED","avail":5000,"floor":8000,"scopeCur":null,"scopeHigh":null,"host":"t"}\n' "$(( $(date +%s) - 9999 ))" > "$BB"
run_ts --json | jq -e '.stale==true' >/dev/null 2>&1 && ok "#57: an aged tier reads STALE (pressure likely cleared)" || bad "#57: aged tier not stale"
rm -f "$BB"
run_ts --json | jq -e '.tier=="none"' >/dev/null 2>&1 && ok "#57: tier-status.sh → none when no blackboard" || bad "#57: absent tier-status ($(run_ts --json))"

# ── #69: the blackboard is namespaced by PROJECT — concurrent fleets don't collide ──
# $STATE is shared HOST-WIDE across projects, so a bare tier-status would last-writer-win
# across fleets. Drive two DIFFERENT projects and assert distinct files, no overwrite.
run_ev_proj() { local pd="$1"; DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_TEAMS_DIR="$TMP/teams" DREAMTEAM_PROJECT_DIR="$pd" DREAMTEAM_FLEET_STATE="$TMP/fleet" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/bin:$PATH" bash "$ROOT/scripts/team-events.sh"; }
rm -f "$TMP/state/tier-status-"*
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"faketeam"}' | FAKE_AVAIL=5000  run_ev_proj "$TMP/projA" >/dev/null
echo '{"hook_event_name":"SubagentStop","agent_id":"x","team_name":"faketeam"}' | FAKE_AVAIL=10000 run_ev_proj "$TMP/projB" >/dev/null
{ [ -f "$TMP/state/tier-status-projA" ] && [ -f "$TMP/state/tier-status-projB" ]; } && ok "#69: tier-status namespaced per project (distinct files)" || bad "#69: per-project files missing ($(ls "$TMP"/state/tier-status-* 2>/dev/null))"
{ grep -q '"tier":"RED"' "$TMP/state/tier-status-projA" && grep -q '"tier":"ORANGE"' "$TMP/state/tier-status-projB"; } && ok "#69: projB (ORANGE) did NOT overwrite projA (RED) — no cross-project misattribution" || bad "#69: cross-project collision (A=$(cat "$TMP/state/tier-status-projA" 2>/dev/null) B=$(cat "$TMP/state/tier-status-projB" 2>/dev/null))"

# team-events #52: the RED-tier voice attention call passes a short --timeout (reverie's
# speak.sh contract) so a hung synth can't pin a proc for speak.sh's 180s manual default.
# Voice is DREAMTEAM_TEST-suppressed, so assert on the source call site.
grep -Eq 'speak\.sh.*--voice davis.*--timeout' "$ROOT/scripts/team-events.sh" \
  && ok "#52: attention voice call passes --timeout (short cap)" || bad "#52: --timeout missing on speak.sh attention call"

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

# ── crash-audit.sh: #54 shared-checkout guard + #58 silent-death (SessionStart) ──
bash -n "$ROOT/scripts/crash-audit.sh" && ok "bash -n crash-audit.sh" || bad "bash -n crash-audit.sh"
CA_STATE="$TMP/ca-state"; CA_TEAMS="$TMP/ca-teams"; mkdir -p "$CA_STATE" "$CA_TEAMS/t1"
# crash-audit reads DREAMTEAM_STATE (marker) + DREAMTEAM_TEAMS_DIR (via roster.sh) + DREAMTEAM_CWD (#54).
run_ca() { DREAMTEAM_STATE="$CA_STATE" DREAMTEAM_TEAMS_DIR="$CA_TEAMS" DREAMTEAM_CWD="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/crash-audit.sh" 2>/dev/null; }

# #58: a dead member (bogus agentId → no live pid) triggers the silent-death advisory.
cat > "$CA_TEAMS/t1/config.json" <<'EOF'
{"members":[
  {"name":"team-lead","agentType":"team-lead","agentId":"lead-x","cwd":"/tmp"},
  {"name":"ghost","agentId":"no-such-agent-id-000","isActive":false,"cwd":"/tmp"}
]}
EOF
OUT=$(run_ca "$TMP")   # $TMP isn't a git repo → #54 stays silent, isolating #58
case "$OUT" in *"DREAMTEAM LIVENESS"*) ok "#58: crash-audit flags a silently-dead member";; *) bad "#58: dead-member advisory missing ($OUT)";; esac
# non-vacuous control: an all-live team (lead only) → NO advisory.
rm -rf "${CA_TEAMS:?}"/*; mkdir -p "$CA_TEAMS/t2"
printf '{"members":[{"name":"team-lead","agentType":"team-lead","agentId":"lead-y","cwd":"/tmp"}]}\n' > "$CA_TEAMS/t2/config.json"
OUT=$(run_ca "$TMP")
case "$OUT" in *"DREAMTEAM LIVENESS"*) bad "#58: false silent-death advisory on all-live team ($OUT)";; *) ok "#58: no advisory when nobody is dead (non-vacuous)";; esac

# #54: real temp git repo. On default → silent; off-default → warn; linked worktree → skip.
CA_REPO="$TMP/ca-repo"; mkdir -p "$CA_REPO"
git -C "$CA_REPO" init -q -b main 2>/dev/null
git -C "$CA_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
OUT=$(run_ca "$CA_REPO")   # on 'main' (== default fallback) → silent
case "$OUT" in *"DREAMTEAM CHECKOUT"*) bad "#54: false checkout warn on the default branch ($OUT)";; *) ok "#54: on default branch → silent (non-vacuous)";; esac
git -C "$CA_REPO" checkout -q -b feature/x 2>/dev/null
OUT=$(run_ca "$CA_REPO")   # off default → warn
case "$OUT" in *"DREAMTEAM CHECKOUT"*"feature/x"*) ok "#54: off-default shared checkout → warn";; *) bad "#54: off-default warn missing ($OUT)";; esac
# a LINKED worktree on a feature branch is expected → must NOT warn (exemption non-vacuous).
git -C "$CA_REPO" worktree add -q "$TMP/ca-wt" -b feature/wt >/dev/null 2>&1
OUT=$(run_ca "$TMP/ca-wt")
case "$OUT" in *"DREAMTEAM CHECKOUT"*) bad "#54: warned inside a linked worktree — should skip ($OUT)";; *) ok "#54: linked worktree on a feature branch → skipped";; esac

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
