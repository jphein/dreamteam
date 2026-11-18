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
printf 'Swap:          8191        %s        %s\n' "${FAKE_SWAP_USED:-500}" "${FAKE_SWAP_FREE:-7614}"
STUB
chmod +x "$BIN/free"
# fake `systemctl` -- mem-gate scales its balloon reserve by LIVE dreamteam-*.scope
# units over 2 GiB (2026-08-15 lesson). Unstubbed, this host's real scopes doubled
# the balloon inside the fixture and 4b read "need 400+16000MiB" (2026-09-18).
cat > "$BIN/systemctl" <<'STUB'
#!/bin/bash
case "$*" in *show*MemoryCurrent*) echo 0 ;; *) exit 0 ;; esac
STUB
chmod +x "$BIN/systemctl"

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
echo "── per-host overlay (config.<host>.json deep-merged over config.json; Sen 2026-11-17) ──"
# A fixture root: the real config.json plus a familiar overlay with the accepted floors. katana has none.
OV="$TMP/ovroot"; mkdir -p "$OV"; cp "$ROOT/config.json" "$OV/config.json"
cat > "$OV/config.familiar.json" <<'J'
{"memory":{"minAvailableMB":3000,"minSwapFreeMB":2048,"perAgentMB":750,"hostReserveMB":2048}}
J
# 7000 MiB available, 8.7 GB swap free: the base floor (8000) blocks; familiar's overlay admits one (2048 host + 4000
# balloon + 750 = 6798 needed; at its 6700 idle the BUDGET, not the 3000 floor, is what binds)
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 0 ] && pass "overlay: familiar at 7000 MiB is ADMITTED under config.familiar.json" || fail "overlay familiar: exit $GRC $(head -2 "$TMP/err")"
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=katana FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "overlay: katana (no overlay) keeps the base verdict: blocked under the 8000 floor" || fail "no overlay changed katana: exit $GRC $(head -1 "$TMP/err")"
# the swap floor is the overlay's: familiar with RAM to spare but swap nearly gone is blocked; katana (default 0) is not
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=12000 FAKE_SWAP_FREE=900 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 2 ] && grep -q 'swap free' "$TMP/err" && pass "overlay: familiar with 900 MiB swap free is blocked (minSwapFreeMB 2048)" || fail "swap floor: exit $GRC $(head -1 "$TMP/err")"
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=katana FAKE_AVAIL=20000 FAKE_SWAP_FREE=900 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 0 ] && pass "overlay: katana has no swap floor (default 0), so the same swap does not block it" || fail "katana swap: exit $GRC $(head -1 "$TMP/err")"
# a deep merge, not a replacement: the overlay's .memory keeps the base's other keys (balloonReserveMB 4000 stays)
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=6700 FAKE_SWAP_FREE=8700 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 2 ] && grep -q 'no budget for another agent (need 750+4000MiB' "$TMP/err" && pass "overlay: familiar at its 6700 idle is blocked by the BUDGET (2048+4000+750 = 6798), not the 3000 floor" || fail "6700 budget: exit $GRC $(head -1 "$TMP/err")"
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=4000 FAKE_SWAP_FREE=8700 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 2 ] && grep -q 'balloon_reserve=4000' "$TMP/err" && grep -q 'per_agent=750' "$TMP/err" && grep -q 'host_reserve=2048' "$TMP/err" \
  && pass "overlay: deep merge (per_agent 750 and host_reserve 2048 from the overlay, balloon 4000 kept from the base)" || fail "deep merge: $(sed -n 3p "$TMP/err")"
# a broken overlay is ignored for the STRICTER base, never half-read
printf '{"memory":' > "$OV/config.broken.json"
DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=broken FAKE_AVAIL=6700 FAKE_SWAP_FREE=8700 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
[ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "overlay: an unreadable overlay falls back to the base (stricter), never a half-read" || fail "broken overlay: exit $GRC"

# xreview #230 r1: what the gate must never admit on
g(){ GRC=0; printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' | env "$@" FAKE_PGREP_COUNT=1 bash "$MEM_GATE" 2>"$TMP/err" || GRC=$?; }
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=fami_liar FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "host: 'fami_liar' is invalid and never cleaned into 'familiar' (base floor applies)" || fail "host normalize: exit $GRC $(head -1 "$TMP/err")"
printf '%s\n%s\n' '{"memory":{"minAvailableMB":100}}' '{"memory":{"minAvailableMB":100}}' > "$OV/config.twodoc.json"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=twodoc FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "overlay: a file with two JSON documents is not one object → ignored (base)" || fail "two docs: exit $GRC $(head -1 "$TMP/err")"
for c in 'minAvailableMB|"bad"' 'minAvailableMB|-5' 'hostReserveMB|-9000' 'perAgentMB|0' 'minSwapFreeMB|"2e3"' 'minSwapFreeMB|2048.5' 'minAvailableMB|99999999999'; do
  k=${c%%|*}; v=${c#*|}; printf '{"memory":{"%s":%s}}\n' "$k" "$v" > "$OV/config.badnum.json"
  g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=badnum FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700
  [ "$GRC" -eq 2 ] && grep -qi "memory.$k" "$TMP/err" && pass "invalid number blocks (exit 2, names it): $k=$v" || fail "invalid $k=$v: exit $GRC $(head -1 "$TMP/err")"
done
# xreview #230 r2: a present false/null/"" is invalid, never "absent → default 0"; a boolean has its own reader
for v in false null '""' '"3000"'; do
  printf '{"memory":{"minSwapFreeMB":%s}}\n' "$v" > "$OV/config.badnum.json"
  g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=badnum FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700
  [ "$GRC" -eq 2 ] && grep -q "memory.minSwapFreeMB is '$v'" "$TMP/err" && pass "a present $v is invalid (exit 2), not the default 0" || fail "present $v: exit $GRC $(head -1 "$TMP/err")"
done
for v in true false; do
  printf '{"memory":{"scopeToDreamteam":%s}}\n' "$v" > "$OV/config.scope.json"
  g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=scope DREAMTEAM_STATE="$TMP/nostate" FAKE_AVAIL=1000 FAKE_SWAP_FREE=8700
  if [ $v = true ]; then [ "$GRC" -eq 0 ] && [ ! -s "$TMP/err" ] && pass "scopeToDreamteam true with no active team: the gate stands aside (exit 0, no message)" || fail "scope true: exit $GRC $(head -1 "$TMP/err")"
  else [ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "scopeToDreamteam false: the gate judges (blocks at 1000 MiB)" || fail "scope false: exit $GRC $(head -1 "$TMP/err")"; fi
done
printf '{"memory":{"scopeToDreamteam":"yes"}}\n' > "$OV/config.scope.json"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=scope FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q 'not true/false' "$TMP/err" && pass "scopeToDreamteam 'yes' is invalid (exit 2)" || fail "scope yes: exit $GRC"
for v in '"1e4"' 9000.5 -1 99999999999; do
  printf '{"local":{"enabled":true,"reserveMB":%s}}\n' "$v" > "$OV/config.local.json"
  g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=local FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700
  [ "$GRC" -eq 2 ] && grep -q 'local.reserveMB' "$TMP/err" && pass "local.reserveMB $v with the lane armed is invalid (exit 2)" || fail "local reserve $v: exit $GRC $(head -1 "$TMP/err")"
done
printf '{"memory":{"minSwapFreeMB":2048}}\n' > "$OV/config.swapread.json"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=swapread FAKE_AVAIL=30000 FAKE_SWAP_FREE=junk
[ "$GRC" -eq 2 ] && grep -q 'no readable swap free' "$TMP/err" && pass "an unreadable swap measurement under a swap floor blocks" || fail "swap read: exit $GRC $(head -1 "$TMP/err")"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=katana FAKE_AVAIL=junk FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q 'no readable available memory' "$TMP/err" && pass "an unreadable MemAvailable blocks (never a comparison error that falls through)" || fail "avail read: exit $GRC"
mkdir -p "$TMP/nolib/scripts"; cp "$MEM_GATE" "$TMP/nolib/scripts/mem-gate.sh"
GRC=0; printf '%s' '{"tool_name":"Agent"}' | FAKE_AVAIL=30000 bash "$TMP/nolib/scripts/mem-gate.sh" 2>"$TMP/err" || GRC=$?
[ "$GRC" -eq 2 ] && grep -q 'did not load' "$TMP/err" && pass "the overlay helper missing → block (exit 2), not empty settings" || fail "nolib: exit $GRC $(head -1 "$TMP/err")"

# lane-check.sh: the lane-start floor (familiar 6800/4096; no overlay = no floor)
printf '%s\n' '{"lane":{"minAvailableMB":6800,"minSwapFreeMB":4096}}' > "$OV/config.familiar.json"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=6700 FAKE_SWAP_FREE=8700 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == "lane-check held: 6700 MiB available < 6800 (familiar)" ]] && pass "lane-check: familiar at 6700 is held under 6800" || fail "lane-check familiar: $rc '$o'"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=familiar FAKE_AVAIL=9000 FAKE_SWAP_FREE=3000 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == *"3000 MiB swap free < 4096"* ]] && pass "lane-check: familiar with 3000 swap free is held under 4096" || fail "lane-check swap: $rc '$o'"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=katana FAKE_AVAIL=1000 FAKE_SWAP_FREE=0 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 0 ] && pass "lane-check: katana (no overlay) is never held" || fail "lane-check katana: $rc '$o'"
printf '%s\n' '{"lane":{"minAvailableMB":"6800MB"}}' > "$OV/config.badlane.json"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=badlane FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == *"lane.minAvailableMB is '\"6800MB\"', not an integer"* ]] && pass "lane-check: an invalid floor is held, never 'no floor'" || fail "lane-check badlane: $rc '$o'"
printf '%s\n' '{"lane":{"minSwapFreeMB":false}}' > "$OV/config.badlane.json"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=badlane FAKE_AVAIL=30000 FAKE_SWAP_FREE=8700 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == *"lane.minSwapFreeMB is 'false'"* ]] && pass "lane-check: a present false is held, not 'no floor'" || fail "lane-check false: $rc '$o'"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=katana FAKE_AVAIL=junk FAKE_SWAP_FREE=8700 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == *"no readable available memory"* ]] && pass "lane-check: an unreadable MemAvailable is held" || fail "lane-check junk: $rc '$o'"
# the repo's own config.familiar.json parses and carries the accepted numbers (balloon stays the base's)
jq -e '.memory == {"minAvailableMB":3000,"minSwapFreeMB":2048,"perAgentMB":750,"hostReserveMB":2048} and .lane == {"minAvailableMB":6800,"minSwapFreeMB":4096}
       and .overnight == {"min_available_mb":5500,"min_swap_free_mb":4096} and (.memory | has("balloonReserveMB") | not)' "$ROOT/config.familiar.json" >/dev/null \
  && pass "config.familiar.json: the accepted floors, balloonReserveMB left to the base" || fail "config.familiar.json content"

grep -q 'DREAMTEAM_HOST=dreamteam-test' "$ROOT/tests/run.sh" && pass "tests/run.sh pins DREAMTEAM_HOST, so no real host's overlay reaches a suite" || fail "run.sh does not pin DREAMTEAM_HOST"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
