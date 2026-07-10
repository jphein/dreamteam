#!/usr/bin/env bash
# dreamteam — regression tests for the two PreToolUse SAFETY gates.
#
#   • scripts/mem-gate.sh    — blocks agent spawns when RAM headroom is short
#                              (THE 2026-06-30 OOM prevention)
#   • scripts/reuse-gate.sh  — blocks a fresh spawn when an idle teammate can
#                              take the task (reuse = zero new RAM + warm context)
#
# ISOLATION STRATEGY — zero edits to production scripts:
#   Both gates observe the world only through (a) external commands `free` and
#   `pgrep`, and (b) env-overridable paths (DREAMTEAM_CONFIG, DREAMTEAM_TEAMS_DIR,
#   CLAUDE_PLUGIN_ROOT). We shadow `free`/`pgrep` with fakes on a temp PATH and
#   feed fixtures via those env seams. The REAL gate logic runs unmodified.
#
#   Liveness for the reuse block-path is simulated via the SAME pgrep seam that
#   idle-agents.sh uses (`pgrep -f "agent-id <id>"`, checked by return code) —
#   NOT by fabricating a real OS process. Stubbing the liveness oracle is the
#   legitimate, transparent way to drive that path deterministically.
#
# Run standalone:  bash tests/test-gates.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config.json"        # real config → deterministic defaults (400/6000/8000/8000/30)
MEM_GATE="$ROOT/scripts/mem-gate.sh"
REUSE_GATE="$ROOT/scripts/reuse-gate.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── temp sandbox: fake bin dir + fixtures, cleaned on exit ──────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; EMPTY_ROOT="$TMP/emptyroot"
mkdir -p "$BIN" "$EMPTY_ROOT"

# fake `free -m` — Mem: $7 = available, Swap: $3 = used (matches the awk fields
# the gates parse). Values controlled by env at call time.
cat > "$BIN/free" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "              total        used        free      shared  buff/cache   available"
printf 'Mem:          64000        2000        1000           0        1000       %s\n' "${FAKE_AVAIL:-16000}"
printf 'Swap:          8191        %s        7614\n' "${FAKE_SWAP_USED:-500}"
STUB
chmod +x "$BIN/free"

# fake `pgrep` — dual role:
#   count mode  (flag contains 'c', e.g. `pgrep -fc claude/versions`) → echo FAKE_PGREP_COUNT
#   match mode  (`pgrep -f "agent-id <id>"`)                          → exit 0 iff last arg
#                                                                        contains FAKE_ALIVE_MATCH
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == *c* ]]; then
  echo "${FAKE_PGREP_COUNT:-0}"
  exit 0
fi
pat="${@: -1}"
if [ -n "${FAKE_ALIVE_MATCH:-}" ] && [[ "$pat" == *"$FAKE_ALIVE_MATCH"* ]]; then
  echo 4242; exit 0
fi
exit 1
STUB
chmod +x "$BIN/pgrep"

# reuse-gate block-path fixture: one member, alive (via pgrep stub) + isActive:false = reusable
mkdir -p "$TMP/teams/faketeam"
cat > "$TMP/teams/faketeam/config.json" <<'JSON'
{"members":[
  {"name":"warm","agentType":"lucid","isActive":false,"agentId":"fakeagent001",
   "cwd":"/tmp/warmcwd","prompt":"task: earlier dashboard-data work"}
]}
JSON

# run_gate <script> <stdin-json> — env vars (PATH, FAKE_*, DREAMTEAM_*, CLAUDE_PLUGIN_ROOT)
# are set by the caller via a leading `env`. Captures exit code in GRC, stderr in $TMP/err.
GRC=0
run_gate() {
  GRC=0
  printf '%s' "$2" | bash "$1" 2>"$TMP/err" || GRC=$?
}

echo "── mem-gate.sh (memory safety gate) ─────────────────────────────"

# 1) BLOCK when available RAM is below the floor. avail=2000 < minAvailable=8000.
export PATH="$BIN:$PATH" CLAUDE_PLUGIN_ROOT="$EMPTY_ROOT" DREAMTEAM_CONFIG="$CONFIG"
FAKE_AVAIL=2000 FAKE_SWAP_USED=500 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'MEMORY GATE' "$TMP/err"; then
  pass "mem-gate BLOCKS (exit 2 + gate message) when avail 2000MiB < 8000MiB floor"
else
  fail "mem-gate should block on low avail — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 2) ALLOW when RAM is plentiful and agent count is under the cap.
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 0 ]; then
  pass "mem-gate ALLOWS (exit 0) when avail 60000MiB and 1 agent live (< cap 30)"
else
  fail "mem-gate should allow with plenty of RAM — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 3) Non-Agent tools pass through untouched (gate only guards Agent|Task).
FAKE_AVAIL=2000 \
  run_gate "$MEM_GATE" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
if [ "$GRC" -eq 0 ]; then
  pass "mem-gate passes through non-Agent tool (Bash) with exit 0 even at low RAM"
else
  fail "mem-gate should ignore non-Agent tools — got exit $GRC"
fi

# 4) BLOCK on the count cap even when RAM is fine (99 live >= cap 30).
FAKE_AVAIL=60000 FAKE_PGREP_COUNT=99 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'cap' "$TMP/err"; then
  pass "mem-gate BLOCKS (exit 2) on count cap: 99 agents live >= cap 30, RAM fine"
else
  fail "mem-gate should block on count cap — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# ── local-model lane reserve (#37) ───────────────────────────────────────────
# Standalone fixtures (no .memory) → baked defaults (perAgent 400, host 6000,
# balloon 8000, floor 8000). avail=20000 is ABOVE the floor and leaves budget when
# the ollama lane is OFF, but the +9000 armed reserve zeroes it → a matched pair
# where ONLY .local.enabled flips the decision (proves the block isn't vacuous).
LOCAL_OFF="$TMP/local-off.json"; printf '%s' '{"local":{"enabled":false,"reserveMB":9000}}' > "$LOCAL_OFF"
LOCAL_ON="$TMP/local-on.json";   printf '%s' '{"local":{"enabled":true,"reserveMB":9000}}'  > "$LOCAL_ON"

# 4b) lane OFF at avail 20000 → ALLOW (reserve not applied)
DREAMTEAM_CONFIG="$LOCAL_OFF" FAKE_AVAIL=20000 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 0 ]; then
  pass "mem-gate ALLOWS (exit 0) at avail 20000MiB when the ollama lane is OFF (no reserve)"
else
  fail "lane-off control should allow — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 4c) lane ARMED at the SAME 20000 → BLOCK, and the message names local_reserve
DREAMTEAM_CONFIG="$LOCAL_ON" FAKE_AVAIL=20000 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'no budget' "$TMP/err" && grep -qi 'local_reserve' "$TMP/err"; then
  pass "mem-gate BLOCKS (exit 2, msg shows local_reserve) at 20000MiB when the lane is ARMED (#37, non-vacuous vs 4b)"
else
  fail "lane-armed should block w/ local_reserve note — got exit $GRC; stderr: $(head -2 "$TMP/err")"
fi

# 4d) armed is a SUBTRACTION, not a kill-switch — ample RAM (40000) still admits
DREAMTEAM_CONFIG="$LOCAL_ON" FAKE_AVAIL=40000 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 0 ]; then
  pass "mem-gate ALLOWS (exit 0) lane-armed at 40000MiB — reserve subtracts headroom, doesn't hard-block"
else
  fail "lane-armed w/ ample RAM should allow — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi
unset FAKE_AVAIL FAKE_SWAP_USED FAKE_PGREP_COUNT

echo "── reuse-gate.sh (reuse-before-spawn gate) ──────────────────────"

# Point ROOT at the repo so reuse-gate can find scripts/idle-agents.sh; feed the
# fixture team dir. Config (real) has reuse.enforce=true, so the gate is armed.
export CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_TEAMS_DIR="$TMP/teams" DREAMTEAM_CONFIG="$CONFIG"

# 5) ALLOW when the prompt carries the conscious override FRESH-SPAWN (even with a
#    reusable teammate present — override short-circuits before the oracle).
run_gate "$REUSE_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"do work FRESH-SPAWN: independent parallel task","team_name":"faketeam"}}'
if [ "$GRC" -eq 0 ]; then
  pass "reuse-gate ALLOWS (exit 0) on FRESH-SPAWN override"
else
  fail "reuse-gate should allow FRESH-SPAWN — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 6) ALLOW when there is no team_name (nothing to reuse from — SendMessage needs a teammate).
run_gate "$REUSE_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"do work"}}'
if [ "$GRC" -eq 0 ]; then
  pass "reuse-gate ALLOWS (exit 0) when no team_name is present"
else
  fail "reuse-gate should allow with no team — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 7) Non-Agent tools pass through untouched.
run_gate "$REUSE_GATE" '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
if [ "$GRC" -eq 0 ]; then
  pass "reuse-gate passes through non-Agent tool (Bash) with exit 0"
else
  fail "reuse-gate should ignore non-Agent tools — got exit $GRC"
fi

# 8) BLOCK when a reusable idle teammate exists. Liveness of the fixture member is
#    simulated through the pgrep seam (FAKE_ALIVE_MATCH matches its agentId) — the
#    same oracle idle-agents.sh consults; no real process is fabricated.
FAKE_ALIVE_MATCH="fakeagent001" \
  run_gate "$REUSE_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"pick up the dashboard-data work","team_name":"faketeam"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'REUSE GATE' "$TMP/err"; then
  pass "reuse-gate BLOCKS (exit 2 + reuse message) when a live idle teammate can take the task"
else
  fail "reuse-gate should block when a reusable idle agent exists — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
