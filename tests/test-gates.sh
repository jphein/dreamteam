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
  rm -rf "$TMP/resv-default"          # each run starts without the previous admit's reservation in the seam dir
  printf '%s' "$2" | bash "$1" >"$TMP/gate.out" 2>"$TMP/err" || GRC=$?
}

echo "── mem-gate.sh (memory safety gate) ─────────────────────────────"

# 1) BLOCK when available RAM is below the floor. avail=2000 < minAvailable=8000.
export PATH="$BIN:$PATH" CLAUDE_PLUGIN_ROOT="$EMPTY_ROOT" DREAMTEAM_CONFIG="$CONFIG"
export DREAMTEAM_RESERVATIONS="$TMP/resv-default" DREAMTEAM_HOST_LOCK="$TMP/host.lock"   # never the runner's real state (#256 r3)
FAKE_AVAIL=2000 FAKE_SWAP_USED=500 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'MEMORY GATE' "$TMP/err"; then
  pass "mem-gate BLOCKS (exit 2 + gate message) when avail 2000MiB < 8000MiB floor"
else
  fail "mem-gate should block on low avail — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 1b) the HOST LOCK (dreamteam #256 r1 item 3): the gate's measurement and a GPU claim's probe-to-record window share
#     one lock on the host (~/.local/state/dreamteam/host.lock; seams DREAMTEAM_HOST_LOCK, DREAMTEAM_HOST_LOCK_WAIT).
#     Held elsewhere → the gate BLOCKS after its wait (fail closed); free → taken, and the usual decision follows.
HLOCK="$TMP/host.lock"
flock "$HLOCK" sleep 30 & HOLDER=$!
sleep 0.3
FAKE_AVAIL=2000 FAKE_SWAP_USED=500 DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'host lock' "$TMP/err"; then
  pass "mem-gate BLOCKS on a held host lock (a claim's probe-to-record window), fail closed after 1 s"
else
  fail "host lock held: exit $GRC; stderr: $(head -1 "$TMP/err")"
fi
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null   # flock AND the sleep it forked hold the fd
FAKE_AVAIL=2000 FAKE_SWAP_USED=500 DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'MEMORY GATE' "$TMP/err" && ! grep -qi 'host lock' "$TMP/err"; then
  pass "mem-gate takes a free host lock and goes on to its own decision (control: the floor block, not the lock)"
else
  fail "host lock free: exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 2) ALLOW when RAM is plentiful and agent count is under the cap.
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 0 ]; then
  pass "mem-gate ALLOWS (exit 0) when avail 60000MiB and 1 agent live (< cap 30)"
else
  fail "mem-gate should allow with plenty of RAM — got exit $GRC; stderr: $(head -1 "$TMP/err")"
fi

# 2b) the RESERVATION (dreamteam #256 r2): the gate's lock is released when it exits, BEFORE the caller starts the
#     lane, so an ADMITTED spawn, still under the lock, writes $DREAMTEAM_RESERVATIONS/<gate pid>-<ts> holding
#     "<perAgentMB> <now+90>" for the GPU sampler; the lane's SessionStart consumes it. A blocked spawn writes none.
RESV="$TMP/resv"; rm -rf "$RESV"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
rf=$(ls "$RESV" 2>/dev/null | head -1); nowg=$(date +%s); rmb=""; rexp=0
[ -n "$rf" ] && read -r rmb rexp _rest < "$RESV/$rf"
if [ "$GRC" -eq 0 ] && [ -n "$rf" ] && [ "${rmb:-0}" -gt 0 ] && [ "$rexp" -ge $((nowg + 85)) ] && [ "$rexp" -le $((nowg + 95)) ]; then
  pass "an admitted spawn leaves a reservation (${rmb} MB, expires in ~90 s) for the GPU sampler"
else
  fail "reservation after admit: rc=$GRC file=[$rf] content=[$(cat "$RESV/$rf" 2>/dev/null)]"
fi
rm -rf "$RESV"
FAKE_AVAIL=2000 FAKE_SWAP_USED=500 DREAMTEAM_RESERVATIONS="$RESV" \
  run_gate "$MEM_GATE" '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
if [ "$GRC" -eq 2 ] && [ -z "$(ls "$RESV" 2>/dev/null)" ]; then
  pass "a blocked spawn reserves nothing"
else
  fail "reservation after block: rc=$GRC files=[$(ls "$RESV" 2>/dev/null | tr '\n' ' ')]"
fi

# 2c) xreview #256 r3 item 1: the gate SUBTRACTS outstanding reservations from its own budget, under the lock. With the
#     real config (perAgent 300, hostReserve 6000, balloon 4000, floor 8000, cap 36), avail 10400 leaves headroom 400
#     = one agent: gate A admits and reserves 300; gate B, before A's lane exists, sees 10400 - 300 reserved =
#     headroom 100 → blocked, naming the reservation. Reserved agents count toward the cap too: 35 live + 1 reserved
#     = 36 → blocked.
rm -rf "$RESV"
FAKE_AVAIL=10400 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
[ "$GRC" -eq 0 ] && pass "over-admit (r3 item 1): gate A admits with headroom for exactly one agent" || fail "gate A: rc=$GRC $(head -1 "$TMP/err")"
FAKE_AVAIL=10400 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'reserved' "$TMP/err"; then
  pass "over-admit (r3 item 1): gate B is BLOCKED by A's outstanding reservation, named in the message"
else
  fail "gate B should block on the reservation: rc=$GRC $(head -1 "$TMP/err")"
fi
[ "$(ls "$RESV" | wc -l)" -eq 1 ] && pass "a blocked gate B reserved nothing more (one file)" || fail "reservations after B: $(ls "$RESV" | tr '\n' ' ')"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=35 DREAMTEAM_RESERVATIONS="$RESV" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
if [ "$GRC" -eq 2 ] && grep -qi 'reserved' "$TMP/err" && grep -qi 'cap' "$TMP/err"; then
  pass "the agent cap counts reserved agents (35 live + 1 reserved = cap 36)"
else
  fail "cap with a reservation: rc=$GRC $(head -1 "$TMP/err")"
fi

# 2d) xreview #256 r3 items 2–4: the reservation carries a TOKEN (session + subagent type) and `start` runs under the
#     host lock. start marks the oldest unexpired, unstarted reservation of that session and type (the lane's own);
#     another session's or type's cannot be taken (exit 3, nothing changed); the lock held → exit 4, nothing changed;
#     an expired match is pruned, logged as a late start and exit 5 (item 4: a SubagentStart hook cannot cancel a
#     start, so the late start is on record). A started reservation counts until SubagentStop releases it (never by time), so the
#     live sampler never undercounts the handoff (item 2).
RS="$ROOT/scripts/reservation.sh"; rm -rf "$RESV"
tok=$(DREAMTEAM_RESERVATIONS="$RESV" bash "$RS" add 400 90 s-a morpheus)
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-b morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ] && [ "$(awk '{print $5}' "$tok")" = 0 ] && pass "start: another session's token is not taken (exit 3, unstarted)" || fail "start other session: rc=$r $(cat "$tok")"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a luna >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ] && pass "start: another type's token is not taken (exit 3)" || fail "start other type: rc=$r"
flock "$HLOCK" sleep 30 & HOLDER=$!; sleep 0.3
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 4 ] && [ "$(awk '{print $5}' "$tok")" = 0 ] && pass "start under a held host lock: exit 4 after 1 s, nothing changed (item 2)" || fail "start with lock held: rc=$r $(cat "$tok")"
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 0 ] && [ "$(awk '{print $5}' "$tok")" != 0 ] && pass "start: the lane's own token is marked started (lock free)" || fail "start own: rc=$r $(cat "$tok")"
[ "$(DREAMTEAM_RESERVATIONS="$RESV" bash "$RS" live)" -eq 400 ] && pass "a started reservation counts until SubagentStop releases it, never by time (no deletion: no undercount window)" || fail "live after start: $(DREAMTEAM_RESERVATIONS="$RESV" bash "$RS" live)"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ] && pass "start twice: the started token is not taken again (exit 3)" || fail "start twice: rc=$r"
printf '400 %s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/9-9-9"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 5 ] && [ ! -e "$RESV/9-9-9" ] && grep -q "s-a morpheus" "$RESV/../late-starts.log" 2>/dev/null && pass "start on an expired token: pruned, logged as a late start, exit 5 (item 4)" || fail "late start: rc=$r exists=$([ -e "$RESV/9-9-9" ] && echo y || echo n) log=[$(cat "$RESV/../late-starts.log" 2>/dev/null)]"
# #280 r1 (and #256 r5 item 4b): the tombstone is deleted only AFTER its late-start line appended; an append that
# cannot succeed (the log path is a directory) keeps the tombstone and is exit 1, not 5
printf '400 %s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/8-8-8"
DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" live >/dev/null 2>&1   # tombstoned by the scan
rm -f "$RESV/../late-starts.log"; mkdir -p "$RESV/../late-starts.log"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 1 ] && [ -e "$RESV/8-8-8.expired" ] && pass "a late start whose log append fails keeps the tombstone (exit 1, not 5)" || fail "append failure: rc=$r tomb=$([ -e "$RESV/8-8-8.expired" ] && echo y || echo n) files=[$(ls "$RESV" | tr '\n' ' ')]"
rm -rf "$RESV/../late-starts.log"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 5 ] && [ ! -e "$RESV/8-8-8.expired" ] && grep -q "s-a morpheus" "$RESV/../late-starts.log" && pass "with the append possible the late start is logged, then the tombstone deleted (exit 5)" || fail "late start after repair: rc=$r"
# #280 r1 item 3: a digit string with a leading zero is octal to shell arithmetic ("0400" = 256): malformed, exit 1
rm -rf "$RESV"; mkdir -p "$RESV"; printf '0400 %s s-a morpheus 0\n' "$(( $(date +%s) + 60 ))" > "$RESV/7-7-7"
out=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" outstanding 2>&1); r=$?
[ "$r" -ne 0 ] && [ -e "$RESV/7-7-7" ] && pass "a leading-zero MB is malformed (exit $r), never read as octal, the file kept" || fail "leading zero: rc=$r out=[$out]"
# #280 r1 item 7: a scan is all-or-nothing: with one malformed file, an expired unstarted record beside it is NOT
# tombstoned (nothing renamed or deleted before the error)
rm -rf "$RESV"; mkdir -p "$RESV"; printf '300 %s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/6-6-6"; echo garbage > "$RESV/6-6-7"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" live >/dev/null 2>&1; echo $?)
[ "$r" -ne 0 ] && [ -e "$RESV/6-6-6" ] && [ ! -e "$RESV/6-6-6.expired" ] && pass "a scan that meets an error renames and deletes nothing (the expired record is still a plain file)" || fail "all-or-nothing: rc=$r files=[$(ls "$RESV" | tr '\n' ' ')]"
# #280 r2 item 3: every numeric read goes through parse(): a tombstone with a leading-zero expiry is malformed, so a
# start that meets it is an error (exit 1) and the tombstone is kept, never arithmetic on "0795…"
rm -rf "$RESV"; mkdir -p "$RESV"; printf '300 0%s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/4-4-4.expired"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 1 ] && [ -e "$RESV/4-4-4.expired" ] && pass "a malformed tombstone (leading-zero expiry) is an error for start (exit 1), kept, no octal arithmetic" || fail "unparsed tombstone: rc=$r kept=$([ -e "$RESV/4-4-4.expired" ] && echo y || echo n)"
# #280 r3 ruling (2): start validates the tombstones BEFORE any prune: a malformed tombstone beside a valid live record
# is exit 1 and leaves both exactly as they were (the live record is not tombstoned, the tombstone is kept)
rm -rf "$RESV"; mkdir -p "$RESV"; echo garbage > "$RESV/2-2-2.expired"; printf '300 %s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/2-2-3"
r=$(DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 1 ] && [ -f "$RESV/2-2-2.expired" ] && [ -f "$RESV/2-2-3" ] && [ ! -e "$RESV/2-2-3.expired" ] && pass "start validates tombstones before any prune: a malformed tombstone beside a valid expired record leaves both untouched (exit 1)" || fail "tombstones before prune: rc=$r files=[$(ls "$RESV" | tr '\n' ' ')]"
# #280 r2 items 1+2: the prune step is the only writer and runs only after a clean scan: with a malformed file present,
# live is exit 1 and an expired record beside it stays a plain file; once the malformed file is gone, live prunes it
rm -rf "$RESV"; mkdir -p "$RESV"; printf '300 %s s-a morpheus 0\n' "$(( $(date +%s) - 1 ))" > "$RESV/3-3-3"; echo garbage > "$RESV/3-3-4"
DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" live >/dev/null 2>&1
[ -f "$RESV/3-3-3" ] && rm -f "$RESV/3-3-4" && DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HLOCK" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" live >/dev/null 2>&1 && [ -e "$RESV/3-3-3.expired" ] && pass "prune runs only after a clean scan: untouched beside a malformed file, tombstoned once the scan is clean" || fail "prune order: files=[$(ls "$RESV" | tr '\n' ' ')]"

# 2h) PR B of the #256 split (Sen 2026-11-21 23:07), one red case per item:
#   B1 per-spawn id end to end: the gate mints it, writes it into the reservation (field 6) and prefixes the Agent prompt
#      with "[dreamteam reservation <id>]" through PreToolUse updatedInput, WITHOUT a permissionDecision (the security
#      review on 10d4aa7a: the gate must not auto-approve). The hooks reference (read 2026-11-21) gives SubagentStart
#      only session_id, agent_id and agent_type (no env, no prompt) and SubagentStop agent_id + agent_transcript_path,
#      so start binds the class match to agent_id (field 7) and stop releases by the id read from the subagent
#      transcript (exact), else by agent_id (exact), else by class.
#   B2 start reads its token's tombstones BEFORE any scan or prune, so a tombstone prune would remove (older than a
#      day) is still a late start, not "no reservation".
#   B3 a reservations path that cannot be reached for a reason other than ENOENT (EACCES on a parent) is an error.
fresh_resv() { rm -rf "$RESV" "$(dirname "$RESV")/released-ids" "$(dirname "$RESV")/sessions"; }   # a seen-set outlives a record: every case starts clean
RESV="$TMP/resvB"; HL="$TMP/hostB.lock"; fresh_resv
RB() { DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" "$@"; }
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"do the thing","subagent_type":"morpheus"}}'
rid=$(awk '{print $6}' "$RESV"/* 2>/dev/null | head -1); gout=$(cat "$TMP/gate.out" 2>/dev/null)
if [ "$GRC" -eq 0 ] && [ -n "$rid" ] && [ "$rid" != - ] && printf '%s' "$gout" | jq -e --arg id "$rid" '.hookSpecificOutput.updatedInput.prompt | startswith("[dreamteam reservation " + $id + "]")' >/dev/null 2>&1 \
   && ! printf '%s' "$gout" | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
  pass "B1: the gate mints a per-spawn id, writes it into the reservation and prefixes the prompt (updatedInput), with no permissionDecision"
else
  fail "B1 mint: rc=$GRC id=[$rid] stdout=[$(printf '%s' "$gout" | head -c 200)]"
fi
fresh_resv; a=$(RB add 300 90 s-a morpheus --id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa); b=$(RB add 300 90 s-a morpheus --id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
RB start s-a morpheus --agent ag-1 >/dev/null 2>&1; RB start s-a morpheus --agent ag-2 >/dev/null 2>&1
r=$(RB stop s-a morpheus --id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >/dev/null 2>&1; echo $?)
[ "$r" -eq 0 ] && [ ! -e "$b" ] && [ -e "$a" ] && pass "B1: stop --id releases exactly that reservation, the other of the class stays" || fail "stop --id: rc=$r A=$([ -e "$a" ] && echo y || echo n) B=$([ -e "$b" ] && echo y || echo n)"
r=$(RB stop s-a morpheus --agent ag-1 >/dev/null 2>&1; echo $?)
[ "$r" -eq 0 ] && [ ! -e "$a" ] && pass "B1: stop --agent releases the reservation start bound to that agent_id" || fail "stop --agent: rc=$r A=$([ -e "$a" ] && echo y || echo n)"
# (the transcript read itself is pinned in 2i: the session's own path is read, a symlink and an outside path are not)
fresh_resv; mkdir -p "$RESV"; printf '300 %s s-a morpheus 0 - -\n' "$(( $(date +%s) - 200000 ))" > "$RESV/5-5-5.expired"; touch -d '2 days ago' "$RESV/5-5-5.expired"
r=$(RB start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 5 ] && grep -q "s-a morpheus" "$RESV/../late-starts.log" 2>/dev/null && pass "B2: a tombstone prune would remove (older than a day) is read by start first: a late start (exit 5), logged" || fail "tombstone before scan: rc=$r log=[$(tail -1 "$RESV/../late-starts.log" 2>/dev/null)]"
mkdir -p "$TMP/noaccessB/resv"; printf '300 %s s-a morpheus 0 - -\n' "$(( $(date +%s) + 60 ))" > "$TMP/noaccessB/resv/1-1-1"; chmod 000 "$TMP/noaccessB"
out=$(DREAMTEAM_RESERVATIONS="$TMP/noaccessB/resv" DREAMTEAM_HOST_LOCK="$HL" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" outstanding 2>&1); r=$?; chmod 700 "$TMP/noaccessB"
[ "$r" -ne 0 ] && pass "B3: a reservations directory behind an unreadable parent (EACCES, not ENOENT) is an error (exit $r), never 0 0" || fail "EACCES parent: rc=$r out=[$out]"

# 2i) #289 round 1 (Sen 2026-11-24 07:23, comment 7135798440), one red case per finding:
#   1  the per-spawn id is a random 128-bit token (32 hex) the gate mints, and the ledger refuses a repeat
#   2  the stop hook reads only the session's own subagent transcript: <dir of transcript_path>/<session_id>/subagents/
#      agent-<agent_id>.jsonl, a regular file, never a symlink, one bounded field; anything else → release by agent_id
#   3  one validation pass over every record and tombstone before every scan or prune, in every verb
#   4  nothing fails open: an unreadable record, a dir that cannot be made, a dir_ok error in stop, a failed rm
#   5  parse and the probe validate the same seven fields (the shared loop in test-gpu.sh feeds both id/agent shapes)
fresh_resv
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
rid=$(awk '{print $6}' "$RESV"/* 2>/dev/null | head -1)
case "$rid" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass "r1 (1): the gate mints a 128-bit random id (32 hex)" ;; *) fail "r1 (1): id=[$rid]" ;; esac
fresh_resv; RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef >/dev/null
r=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef >/dev/null 2>&1; echo $?)
[ "$r" -ne 0 ] && [ "$(ls "$RESV" | wc -l)" -eq 1 ] && pass "r1 (1): the ledger refuses a repeated id (exit $r), one file" || fail "repeat id: rc=$r files=$(ls "$RESV" | wc -l)"
r=$(RB add 300 90 s-a morpheus --id short >/dev/null 2>&1; echo $?)
[ "$r" -ne 0 ] && pass "r1 (1): an id that is not 32 hex is refused" || fail "short id accepted"
# (2) the transcript reader
sdir="$TMP/sess"; mkdir -p "$sdir/s-a/subagents"; tr_ok="$sdir/s-a/subagents/agent-ag-9.jsonl"
printf '{"type":"user","message":{"content":"[dreamteam reservation 0123456789abcdef0123456789abcdef]\\nx"}}\n' > "$tr_ok"
hook_in() { printf '{"hook_event_name":"SubagentStop","session_id":"s-a","transcript_path":"%s/s-a.jsonl","agent_id":"ag-9","agent_type":"morpheus","agent_transcript_path":"%s"}' "$sdir" "$1"; }
fresh_resv; a=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef); b=$(RB add 300 90 s-a morpheus --id fedcba9876543210fedcba9876543210)
RB start s-a morpheus --agent ag-9 >/dev/null 2>&1   # binds the OLDEST unstarted (a) to ag-9
hook_in "$tr_ok" | RB stop-hook >/dev/null 2>&1
[ ! -e "$a" ] && [ -e "$b" ] && pass "r1 (2): the session's own subagent transcript is read and its id releases exactly that file" || fail "own transcript: a=$([ -e "$a" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
fresh_resv; a=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef); b=$(RB add 300 90 s-a morpheus --id fedcba9876543210fedcba9876543210)
RB start s-a morpheus --agent ag-9 >/dev/null 2>&1; RB start s-a morpheus --agent ag-8 >/dev/null 2>&1   # a→ag-9, b→ag-8
ln -sf "$tr_ok" "$sdir/s-a/subagents/agent-ag-8.jsonl"
printf '{"hook_event_name":"SubagentStop","session_id":"s-a","transcript_path":"%s/s-a.jsonl","agent_id":"ag-8","agent_type":"morpheus","agent_transcript_path":"%s/s-a/subagents/agent-ag-8.jsonl"}' "$sdir" "$sdir" | RB stop-hook >/dev/null 2>&1
[ -e "$a" ] && [ ! -e "$b" ] && pass "r1 (2): a symlinked transcript is not read: the release falls back to agent_id (b, bound to ag-8), a stays" || fail "symlink transcript: a=$([ -e "$a" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
rm -f "$sdir/s-a/subagents/agent-ag-8.jsonl"
fresh_resv; a=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef); b=$(RB add 300 90 s-a morpheus --id fedcba9876543210fedcba9876543210)
RB start s-a morpheus --agent ag-9 >/dev/null 2>&1; RB start s-a morpheus --agent ag-8 >/dev/null 2>&1
cp "$tr_ok" "$TMP/elsewhere.jsonl"
printf '{"hook_event_name":"SubagentStop","session_id":"s-a","transcript_path":"%s/s-a.jsonl","agent_id":"ag-8","agent_type":"morpheus","agent_transcript_path":"%s/elsewhere.jsonl"}' "$sdir" "$TMP" | RB stop-hook >/dev/null 2>&1
[ -e "$a" ] && [ ! -e "$b" ] && pass "r1 (2): a transcript path outside the session's subagents dir is not read: release by agent_id" || fail "outside transcript: a=$([ -e "$a" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
printf '{"type":"user","message":{"content":"[dreamteam reservation 0123456789abcdef0123456789abcdefZZZZ]\\nx"}}\n' > "$tr_ok"
fresh_resv; a=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef); RB start s-a morpheus --agent ag-9 >/dev/null 2>&1
hook_in "$tr_ok" | RB stop-hook >/dev/null 2>&1
[ ! -e "$a" ] && pass "r1 (2): a marker whose id is not exactly 32 hex is not an id: release by agent_id (a, bound to ag-9)" || fail "bad marker: a still there"
# (3) validation before every scan or prune, in every verb
fresh_resv; mkdir -p "$RESV"; echo garbage > "$RESV/1-1-1.expired"; printf '300 %s s-a morpheus 0 - -\n' "$(( $(date +%s) + 60 ))" > "$RESV/1-1-2"
r=$(RB live >/dev/null 2>&1; echo $?); [ "$r" -eq 1 ] && pass "r1 (3): a malformed tombstone is an error for live (exit 1): one validation pass before any scan" || fail "live with a malformed tombstone: rc=$r"
r=$(RB stop s-a morpheus >/dev/null 2>&1; echo $?); [ "$r" -eq 1 ] && pass "r1 (3): a malformed tombstone is an error for stop too" || fail "stop with a malformed tombstone: rc=$r"
# (4) fail closed everywhere
ro="$TMP/ro"; mkdir -p "$ro"; chmod 555 "$ro"
r=$(DREAMTEAM_RESERVATIONS="$ro/resv" DREAMTEAM_HOST_LOCK="$HL" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 1 ] && pass "r1 (4): a reservations dir that cannot be created is an error for start (exit 1), not silence" || fail "mkdir fails: rc=$r"
chmod 755 "$ro"; fresh_resv; mkdir -p "$RESV"; chmod 000 "$RESV"
r=$(RB stop s-a morpheus >/dev/null 2>&1; echo $?); chmod 700 "$RESV"
[ "$r" -eq 1 ] && pass "r1 (4): a dir_ok error is an error for stop (exit 1), not 'no started reservation'" || fail "stop on an unreadable dir: rc=$r"
fresh_resv; a=$(RB add 300 90 s-a morpheus --id 0123456789abcdef0123456789abcdef); RB start s-a morpheus --agent ag-9 >/dev/null 2>&1; chmod 555 "$RESV"
r=$(RB stop s-a morpheus --agent ag-9 >/dev/null 2>&1; echo $?); chmod 755 "$RESV"
[ "$r" -eq 1 ] && [ -e "$a" ] && pass "r1 (4): a release whose rm fails is an error (exit 1), the file still there, never a silent exit 0" || fail "rm fails: rc=$r file=$([ -e "$a" ] && echo y || echo n)"
fresh_resv; mkdir -p "$RESV"; printf '300 %s s-a morpheus 0 - -\n' "$(( $(date +%s) + 60 ))" > "$RESV/2-2-2"; chmod 000 "$RESV/2-2-2"
r=$(RB live >/dev/null 2>&1; echo $?); chmod 600 "$RESV/2-2-2"
[ "$r" -eq 1 ] && pass "r1 (4): an unreadable record is an error for live (exit 1), never skipped" || fail "unreadable record: rc=$r"

# 2j) #289 round 2 (Sen 2026-11-24 09:52, comment 7139819797), one red case per residual, named against its guard:
#   r2-1 replay: a released id stays in a seen-set (<dir>/../released-ids, 7 days); add refuses it and stop --id
#        refuses it (never falls back to the class)                        guard: seen_has / seen_add in reservation.sh
#   r2-2 transcript: the root is the session dir the GATE recorded at spawn (<dir>/../sessions/<session_id>), both
#        sides realpath'ed, prefix required; one bounded field from one line  guard: the Python reader in stop-hook
#   r2-3 enumeration: entries is collected with its status checked; a failed enumeration fails the verb with
#        "cannot stat", before any parse message                             guard: entries + ENT in reservation.sh
#   r2-4 entropy and writes: od's own status (pipefail), 32 hex, mkdir and the appends checked  guard: mem-gate RID
#   r2-5 one validity rule: tombstones validated by the probe too, 12-digit epochs, 128-char tokens  (test-gpu.sh loop)
RESV="$TMP/resvC"; fresh_resv; HL="$TMP/hostC.lock"
RC() { DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" "$@"; }
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
a=$(RC add 300 90 s-a morpheus --id $A); RC start s-a morpheus --agent ag-1 >/dev/null 2>&1; RC stop s-a morpheus --id $A >/dev/null 2>&1
r=$(RC add 300 90 s-a morpheus --id $A >/dev/null 2>&1; echo $?)
[ "$r" -eq 2 ] && [ -z "$(ls "$RESV" 2>/dev/null)" ] && pass "r2-1: a released id is refused on add (exit 2): the seen-set outlives the record" || fail "r2-1 add after release: rc=$r files=[$(ls "$RESV" | tr '\n' ' ')]"
b=$(RC add 300 90 s-a morpheus --id $B); RC start s-a morpheus --agent ag-2 >/dev/null 2>&1
r=$(RC stop s-a morpheus --id $A >/dev/null 2>&1; echo $?)
[ "$r" -eq 2 ] && [ -e "$b" ] && pass "r2-1: a replayed stop --id is refused (exit 2) and never falls back to the class: the other started reservation stays" || fail "r2-1 replayed stop: rc=$r b=$([ -e "$b" ] && echo y || echo n)"
# r2-2
sdir="$TMP/sessC"; mkdir -p "$sdir/s-c/subagents"; fresh_resv
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" "$(printf '{"session_id":"s-c","transcript_path":"%s/s-c.jsonl","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}' "$sdir")"
rid=$(awk '{print $6}' "$RESV"/* 2>/dev/null | head -1); [ -f "$RESV/../sessions/s-c" ] && [ "$(cat "$RESV/../sessions/s-c")" = "$(realpath "$sdir")" ] && pass "r2-2: the gate records the session's transcript dir at spawn (realpath)" || fail "r2-2 session dir not recorded: [$(cat "$RESV/../sessions/s-c" 2>/dev/null)]"
# In each r2-2 case the id names the GATE's file (afile, bound to ag-z) and agent ag-c is bound to a second file (b):
# a read marker releases afile; a refused read releases b by agent_id. The two outcomes differ.
r2_2_setup() { # r2_2_setup: the gate's file started as ag-z, b added and started as ag-c; sets afile b rid
  afile=$(ls "$RESV"/* | head -1); rid=$(awk '{print $6}' "$afile")
  RC start s-c morpheus --agent ag-z >/dev/null 2>&1
  b=$(RC add 300 90 s-c morpheus --id $B); RC start s-c morpheus --agent ag-c >/dev/null 2>&1
}
r2_2_setup
mkdir -p "$TMP/elsewhereC/s-c/subagents"; printf '{"type":"user","message":{"content":"[dreamteam reservation %s]\\nx"}}\n' "$rid" > "$TMP/elsewhereC/s-c/subagents/agent-ag-c.jsonl"
printf '{"hook_event_name":"SubagentStop","session_id":"s-c","transcript_path":"%s/elsewhereC/s-c.jsonl","agent_id":"ag-c","agent_type":"morpheus","agent_transcript_path":"%s/elsewhereC/s-c/subagents/agent-ag-c.jsonl"}' "$TMP" "$TMP" | RC stop-hook >/dev/null 2>&1
[ -e "$afile" ] && [ ! -e "$b" ] && pass "r2-2: a transcript root taken from the hook input, not the recorded session dir, is not read: the release went by agent_id (b), the id's file stays" || fail "r2-2 root from hook input: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
fresh_resv; rm -rf "$sdir"; mkdir -p "$sdir/s-c"; ln -s "$TMP/elsewhereC/s-c/subagents" "$sdir/s-c/subagents"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" "$(printf '{"session_id":"s-c","transcript_path":"%s/s-c.jsonl","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}' "$sdir")"
r2_2_setup
printf '{"type":"user","message":{"content":"[dreamteam reservation %s]\\nx"}}\n' "$rid" > "$TMP/elsewhereC/s-c/subagents/agent-ag-c.jsonl"
printf '{"hook_event_name":"SubagentStop","session_id":"s-c","transcript_path":"%s/s-c.jsonl","agent_id":"ag-c","agent_type":"morpheus","agent_transcript_path":"%s/s-c/subagents/agent-ag-c.jsonl"}' "$sdir" "$sdir" | RC stop-hook >/dev/null 2>&1
[ -e "$afile" ] && [ ! -e "$b" ] && pass "r2-2: a symlinked PARENT dir (subagents → elsewhere) is not followed (realpath prefix): release by agent_id (b), the id's file stays" || fail "r2-2 symlinked parent: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
fresh_resv; rm -rf "$sdir"; mkdir -p "$sdir/s-c/subagents"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" "$(printf '{"session_id":"s-c","transcript_path":"%s/s-c.jsonl","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}' "$sdir")"
r2_2_setup
pre=$(printf '{"type":"user","message":{"role":"user","content":"[dreamteam reservation %s]\\n' "$rid"); post='"}}'
pad=$(( 65537 - 1 - ${#pre} - ${#post} ))   # a VALID user line of exactly 65537 bytes: one past the bound, so only the bound refuses it
{ printf '%s' "$pre"; head -c "$pad" /dev/zero | tr '\0' 'x'; printf '%s\n' "$post"; } > "$sdir/s-c/subagents/agent-ag-c.jsonl"
[ "$(wc -c < "$sdir/s-c/subagents/agent-ag-c.jsonl")" -eq 65537 ] || fail "line-bound fixture is not 65537 bytes"
printf '{"hook_event_name":"SubagentStop","session_id":"s-c","transcript_path":"%s/s-c.jsonl","agent_id":"ag-c","agent_type":"morpheus","agent_transcript_path":"%s/s-c/subagents/agent-ag-c.jsonl"}' "$sdir" "$sdir" | RC stop-hook >/dev/null 2>&1
[ -e "$afile" ] && [ ! -e "$b" ] && pass "r2-2: the field is parsed from one bounded line: a marker past the 64 KiB line bound is not read (release by agent_id, b)" || fail "r2-2 bounded line: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
fresh_resv; rm -rf "$sdir"; mkdir -p "$sdir/s-c/subagents"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" "$(printf '{"session_id":"s-c","transcript_path":"%s/s-c.jsonl","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}' "$sdir")"
r2_2_setup
printf '{"type":"user","message":{"content":"[dreamteam reservation %s]\\nx"}}\n' "$rid" > "$sdir/s-c/subagents/agent-ag-c.jsonl"
printf '{"hook_event_name":"SubagentStop","session_id":"s-c","transcript_path":"%s/s-c.jsonl","agent_id":"ag-c","agent_type":"morpheus","agent_transcript_path":"%s/s-c/subagents/agent-ag-c.jsonl"}' "$sdir" "$sdir" | RC stop-hook >/dev/null 2>&1
[ ! -e "$afile" ] && [ -e "$b" ] && pass "r2-2: the recorded session dir, a real file, one bounded line: the id is read and its file released, b stays (control)" || fail "r2-2 control: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
# r2-3
fresh_resv; mkdir -p "$RESV"; printf '300 %s s-a morpheus 0 - -\n' "$(( $(date +%s) + 60 ))" > "$RESV/1-1-1"; ln -s /nonexistent/never "$RESV/9-9-9.expired"
err=$(RC live 2>&1 >/dev/null); r=$?
[ "$r" -eq 1 ] && printf '%s' "$err" | grep -q "cannot stat" && pass "r2-3: an entry the enumeration cannot stat fails the verb with 'cannot stat' (exit 1), before any parse" || fail "r2-3 enumeration: rc=$r err=[$(printf '%s' "$err" | head -c 120)]"
# r2-4
mkdir -p "$TMP/badod"; printf '#!/usr/bin/env bash\nprintf " 00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff\\n"; exit 1\n' > "$TMP/badod/od"; chmod +x "$TMP/badod/od"
fresh_resv
PATH="$TMP/badod:$PATH" FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
[ "$GRC" -eq 2 ] && grep -qi "reservation id" "$TMP/err" && pass "r2-4: an od that fails behind a 32-char output is caught (pipefail): the gate blocks" || fail "r2-4 entropy: rc=$GRC $(head -1 "$TMP/err")"
mkdir -p "$TMP/shortod"; printf '#!/usr/bin/env bash\nprintf " 00 11 22 33 44\\n"\n' > "$TMP/shortod/od"; chmod +x "$TMP/shortod/od"
rm -rf "$RESV"
PATH="$TMP/shortod:$PATH" FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
[ "$GRC" -eq 2 ] && grep -qi "not 32 hex" "$TMP/err" && pass "r2-4: an od that succeeds with too few bytes is caught by the length check: the gate blocks" || fail "r2-4 short id: rc=$GRC $(head -1 "$TMP/err")"
fresh_resv; mkdir -p "$TMP/roC"; chmod 555 "$TMP/roC"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$TMP/roC/resv" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
chmod 755 "$TMP/roC"
[ "$GRC" -eq 2 ] && pass "r2-4: a reservations dir the gate cannot create is a block, never a silent admit" || fail "r2-4 mkdir: rc=$GRC $(head -1 "$TMP/err")"

# 2k) #289 round 3 ruling (Sen 2026-11-24 11:15, comments 7141808028 + 7141844194), one red case per item, named
#     against its guard:
#   r3-1 no fallback from an explicit --id or --agent: a stop that names an id or an agent releases that one or
#        nothing (exit 3); only a stop with neither falls to the class                guard: stop's pick/byclass gate
#   r3-2 the id is remembered BEFORE the rm: a release whose rm fails has already put the id in the seen-set
#        guard: seen_add before rm in stop
#   r3-4 the marker is read from ONE structured JSON field (the first user message's content prefix), never a byte
#        search: a marker in another field, or past the prefix, is not an id        guard: the Python reader
#   r3-7 transcript tests that cannot pass without reading: the control reads, the negatives refuse (2j, 2k)
C=cccccccccccccccccccccccccccccccc; D=dddddddddddddddddddddddddddddddd
fresh_resv; a=$(RC add 300 90 s-a morpheus --id $C); RC start s-a morpheus --agent ag-1 >/dev/null 2>&1
r=$(RC stop s-a morpheus --id $D >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ] && [ -e "$a" ] && pass "r3-1: stop --id of an id not on the ledger releases nothing (exit 3): no fallback to the class" || fail "r3-1 --id fallback: rc=$r a=$([ -e "$a" ] && echo y || echo n)"
r=$(RC stop s-a morpheus --agent ag-9 >/dev/null 2>&1; echo $?)
[ "$r" -eq 3 ] && [ -e "$a" ] && pass "r3-1: stop --agent of an agent bound to nothing releases nothing (exit 3): no fallback to the class" || fail "r3-1 --agent fallback: rc=$r a=$([ -e "$a" ] && echo y || echo n)"
r=$(RC stop s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 0 ] && [ ! -e "$a" ] && pass "r3-1: a stop with neither id nor agent releases one started reservation of the class (control)" || fail "r3-1 class stop: rc=$r"
fresh_resv; a=$(RC add 300 90 s-a morpheus --id $C); RC start s-a morpheus --agent ag-1 >/dev/null 2>&1; chmod 555 "$RESV"
r=$(RC stop s-a morpheus --id $C >/dev/null 2>&1; echo $?); chmod 755 "$RESV"
[ "$r" -eq 1 ] && [ -e "$a" ] && grep -q "^$C " "$(dirname "$RESV")/released-ids" && pass "r3-2: a release whose rm fails has already remembered the id (seen-set written before the rm), file kept, exit 1" || fail "r3-2 id before rm: rc=$r seen=$(grep -c "^$C " "$(dirname "$RESV")/released-ids" 2>/dev/null)"
# r3-4: the structured read
sdir="$TMP/sessK"; fresh_resv; mkdir -p "$sdir/s-k/subagents"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" "$(printf '{"session_id":"s-k","transcript_path":"%s/s-k.jsonl","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}' "$sdir")"
afile=$(ls "$RESV"/* | head -1); rid=$(awk '{print $6}' "$afile"); RC start s-k morpheus --agent ag-z >/dev/null 2>&1
b=$(RC add 300 90 s-k morpheus --id eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee); RC start s-k morpheus --agent ag-k >/dev/null 2>&1
tr_k="$sdir/s-k/subagents/agent-ag-k.jsonl"
printf '{"type":"user","message":{"role":"user","content":"hello"},"note":"[dreamteam reservation %s]"}\n' "$rid" > "$tr_k"   # the marker in ANOTHER field
printf '{"hook_event_name":"SubagentStop","session_id":"s-k","transcript_path":"%s/s-k.jsonl","agent_id":"ag-k","agent_type":"morpheus","agent_transcript_path":"%s"}' "$sdir" "$tr_k" | RC stop-hook >/dev/null 2>&1
[ -e "$afile" ] && [ ! -e "$b" ] && pass "r3-4: a marker in another JSON field is not an id (release by agent_id, b): the read is structured, not a byte search" || fail "r3-4 other field: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
b=$(RC add 300 90 s-k morpheus --id dddddddddddddddddddddddddddddddd); RC start s-k morpheus --agent ag-k >/dev/null 2>&1
printf '{"type":"user","message":{"role":"user","content":"hello [dreamteam reservation %s]"}}\n' "$rid" > "$tr_k"   # the marker not at the prefix
printf '{"hook_event_name":"SubagentStop","session_id":"s-k","transcript_path":"%s/s-k.jsonl","agent_id":"ag-k","agent_type":"morpheus","agent_transcript_path":"%s"}' "$sdir" "$tr_k" | RC stop-hook >/dev/null 2>&1
[ -e "$afile" ] && [ ! -e "$b" ] && pass "r3-4: a marker that is not the content's prefix is not an id (release by agent_id)" || fail "r3-4 not prefix: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"
b=$(RC add 300 90 s-k morpheus --id ffffffffffffffffffffffffffffffff); RC start s-k morpheus --agent ag-k >/dev/null 2>&1
printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[dreamteam reservation %s]\\nx"}]}}\n' "$rid" > "$tr_k"   # content as blocks
printf '{"hook_event_name":"SubagentStop","session_id":"s-k","transcript_path":"%s/s-k.jsonl","agent_id":"ag-k","agent_type":"morpheus","agent_transcript_path":"%s"}' "$sdir" "$tr_k" | RC stop-hook >/dev/null 2>&1
[ ! -e "$afile" ] && [ -e "$b" ] && pass "r3-4 + r3-7: the marker as the prefix of the first user message's content (block form) is read: the id's file released, b stays" || fail "r3-4 blocks: afile=$([ -e "$afile" ] && echo y || echo n) b=$([ -e "$b" ] && echo y || echo n)"

# 2e) xreview #256 r4 (Sen 2026-11-18 20:58), one red case per item:
#   1  scan errors are nonzero and delete nothing: an unreadable directory, a malformed file (evidence kept); a
#      missing directory is "0 0" (never reserved), an unreadable one is an error the gate turns into a block
#   2  a STARTED reservation never expires on its own (SubagentStart is not proof the RSS is there yet): it is
#      released by the lane's SubagentStop (stop <session> <type>); an unstarted one past expiry is tombstoned
#   3  one token class per reservation, not one token: parallel same-type spawns in one session hold equal-size
#      reservations, so start/stop count per class; a third start with none unstarted is exit 3, said
#   4  the tombstone (<file>.expired) survives a scan, so a late start is still recognised after live/outstanding
#      pruned the live file; a start-hook without ids logs that too
#   7  every helper read runs under the host lock (--locked = the caller already holds it, the gate), writes are
#      tmp + rename; live under a held lock is exit 4
RESV="$TMP/resv4"; fresh_resv; HL="$TMP/host4.lock"
R4() { DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" DREAMTEAM_HOST_LOCK_WAIT=1 bash "$RS" "$@"; }
out=$(R4 outstanding 2>&1); r=$?; [ "$r" -eq 0 ] && [ "$out" = "0 0" ] && pass "r4 item 1: a directory that never existed is 0 0, exit 0" || fail "missing dir: rc=$r out=[$out]"
R4 add 300 90 s-a morpheus >/dev/null; printf '400\n' > "$RESV/bad-1-1"
out=$(R4 outstanding 2>&1); r=$?; [ "$r" -ne 0 ] && [ -e "$RESV/bad-1-1" ] && pass "r4 item 1: a malformed file is a scan ERROR (exit $r), the file kept as evidence" || fail "malformed: rc=$r out=[$out] kept=$([ -e "$RESV/bad-1-1" ] && echo y || echo n)"
rm -f "$RESV/bad-1-1"; chmod 000 "$RESV"
out=$(R4 outstanding 2>&1); r=$?; chmod 700 "$RESV"
[ "$r" -ne 0 ] && pass "r4 item 1: an unreadable directory is a scan ERROR (exit $r), not 0 0" || fail "unreadable dir: rc=$r out=[$out]"
chmod 000 "$RESV"
FAKE_AVAIL=60000 FAKE_SWAP_USED=0 FAKE_PGREP_COUNT=1 DREAMTEAM_RESERVATIONS="$RESV" DREAMTEAM_HOST_LOCK="$HL" \
  run_gate "$MEM_GATE" '{"session_id":"s-a","tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"morpheus"}}'
chmod 700 "$RESV"
[ "$GRC" -eq 2 ] && grep -qi 'reservation' "$TMP/err" && pass "r4 item 1: the gate BLOCKS when the reservations cannot be read" || fail "gate on unreadable reservations: rc=$GRC $(head -1 "$TMP/err")"
fresh_resv; R4 add 300 90 s-a morpheus >/dev/null; f=$(ls "$RESV"/* | head -1)
R4 start s-a morpheus >/dev/null 2>&1; sed -i "s/^300 [0-9]*/300 $(( $(date +%s) - 1 ))/" "$f"
[ "$(R4 live)" = 300 ] && [ -e "$f" ] && pass "r4 item 2: a STARTED reservation past its expiry still counts (released by stop, not by time)" || fail "started past expiry: live=$(R4 live) exists=$([ -e "$f" ] && echo y || echo n)"
r=$(R4 stop s-a morpheus >/dev/null 2>&1; echo $?); [ "$r" -eq 0 ] && [ "$(R4 live)" = 0 ] && pass "r4 item 2: SubagentStop releases the started reservation (stop <session> <type>)" || fail "stop: rc=$r live=$(R4 live)"
r=$(R4 stop s-a morpheus >/dev/null 2>&1; echo $?); [ "$r" -eq 3 ] && pass "r4 item 2: a second stop finds nothing (exit 3)" || fail "second stop: rc=$r"
fresh_resv; R4 add 300 90 s-a morpheus >/dev/null; R4 add 300 90 s-a morpheus >/dev/null
r1=$(R4 start s-a morpheus >/dev/null 2>&1; echo $?); r2=$(R4 start s-a morpheus >/dev/null 2>&1; echo $?); r3=$(R4 start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r1$r2$r3" = "003" ] && [ "$(R4 live)" = 600 ] && pass "r4 item 3: two parallel same-type spawns: two starts mark two reservations, a third is exit 3; both still count (equal sizes per class, said in the script)" || fail "same-type pair: rc=$r1,$r2,$r3 live=$(R4 live)"
fresh_resv; R4 add 300 90 s-a morpheus >/dev/null; f=$(ls "$RESV"/* | head -1); sed -i "s/^300 [0-9]*/300 $(( $(date +%s) - 1 ))/" "$f"
[ "$(R4 live)" = 0 ] && [ ! -e "$f" ] && [ -e "$f.expired" ] && pass "r4 item 4: live prunes an expired UNSTARTED reservation to a tombstone (<file>.expired), not to nothing" || fail "tombstone: live=$(R4 live) file=$([ -e "$f" ] && echo y || echo n) tomb=$([ -e "$f.expired" ] && echo y || echo n)"
r=$(R4 start s-a morpheus >/dev/null 2>&1; echo $?)
[ "$r" -eq 5 ] && grep -q "s-a morpheus" "$RESV/../late-starts.log" && [ ! -e "$f.expired" ] && pass "r4 item 4: a late start is still recognised from the tombstone after the scan (exit 5, logged, tombstone consumed)" || fail "late start via tombstone: rc=$r tomb=$([ -e "$f.expired" ] && echo y || echo n) log=[$(tail -1 "$RESV/../late-starts.log" 2>/dev/null)]"
printf '{"hook_event_name":"SubagentStart"}' | R4 start-hook >/dev/null 2>&1
grep -q "no session_id or agent_type" "$RESV/../start-hook.log" 2>/dev/null && pass "r4 item 4: a start-hook without ids is logged, not silently skipped" || fail "start-hook without ids: log=[$(cat "$RESV/../start-hook.log" 2>/dev/null | tail -1)]"
fresh_resv; R4 add 300 90 s-a morpheus >/dev/null
[ -z "$(ls "$RESV" | grep '\.tmp$')" ] && [ "$(ls "$RESV" | wc -l)" -eq 1 ] && pass "r4 item 7: add leaves one complete file and no .tmp (tmp + rename)" || fail "add files: $(ls "$RESV" | tr '\n' ' ')"
flock "$HL" sleep 30 & HOLDER=$!; sleep 0.3
r=$(R4 live >/dev/null 2>&1; echo $?); [ "$r" -eq 4 ] && pass "r4 item 7: live under a held host lock is exit 4 (every read is serialized)" || fail "live with lock held: rc=$r"
out=$(R4 live --locked 2>&1); r=$?; [ "$r" -eq 0 ] && [ "$out" = 300 ] && pass "r4 item 7: live --locked (the caller holds the lock, as the gate does) reads without taking it again" || fail "live --locked: rc=$r out=[$out]"
pkill -P "$HOLDER" 2>/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
# 2f) security review on 445fbf1e: a token field with a space (an Agent call's name as the type) would write a record
#     no scan can parse, and under item 1 that one file blocks the gate until an operator moves it. The token fields
#     are sanitised at add, start and stop alike ([A-Za-z0-9._:-], at most 128, else _), so the hook-side raw values
#     still match and a scan never meets a self-inflicted malformed record. Mutant: san returns its input (red here).
fresh_resv; f=$(R4 add 300 90 "s a/b" "my type!" 2>/dev/null)
out=$(R4 outstanding 2>&1); r=$?
[ "$r" -eq 0 ] && [ "$out" = "300 1" ] && grep -q "s_a_b my_type_ 0 " "$f" && pass "a token with spaces and punctuation is sanitised at add: the record parses (300 1)" || fail "sanitised add: rc=$r out=[$out] rec=[$(cat "$f" 2>/dev/null)]"
r=$(R4 start "s a/b" "my type!" >/dev/null 2>&1; echo $?); [ "$r" -eq 0 ] && pass "start with the same raw token matches the sanitised record" || fail "sanitised start: rc=$r"
r=$(R4 stop "s a/b" "my type!" >/dev/null 2>&1; echo $?); [ "$r" -eq 0 ] && [ "$(R4 live)" = 0 ] && pass "stop with the same raw token releases it" || fail "sanitised stop: rc=$r live=$(R4 live)"

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
[ "$GRC" -eq 2 ] && grep -q "config.broken.json exists but is not one readable JSON object" "$TMP/err" && pass "overlay: an unreadable overlay BLOCKS (its floors may be the only ones), never a fall-back or a half-read" || fail "broken overlay: exit $GRC $(head -1 "$TMP/err")"

# xreview #230 r1: what the gate must never admit on
g(){ GRC=0; printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' | env "$@" FAKE_PGREP_COUNT=1 bash "$MEM_GATE" 2>"$TMP/err" || GRC=$?; }
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=fami_liar FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q '< 8000MiB floor' "$TMP/err" && pass "host: 'fami_liar' is invalid and never cleaned into 'familiar' (base floor applies)" || fail "host normalize: exit $GRC $(head -1 "$TMP/err")"
printf '%s\n%s\n' '{"memory":{"minAvailableMB":100}}' '{"memory":{"minAvailableMB":100}}' > "$OV/config.twodoc.json"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=twodoc FAKE_AVAIL=7000 FAKE_SWAP_FREE=8700
[ "$GRC" -eq 2 ] && grep -q "config.twodoc.json exists but is not one readable JSON object" "$TMP/err" && pass "overlay: a file with two JSON documents is not one object → blocks" || fail "two docs: exit $GRC $(head -1 "$TMP/err")"
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
printf '{"lane":' > "$OV/config.trunc.json"
o=$(DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=trunc FAKE_AVAIL=1000 FAKE_SWAP_FREE=0 bash "$ROOT/scripts/lane-check.sh"); rc=$?
[ $rc = 1 ] && [[ "$o" == *"overlay exists but is not one readable"* ]] && pass "lane-check: a truncated overlay holds (never the base's 'no floor')" || fail "lane-check trunc: $rc '$o'"
g DREAMTEAM_CONFIG="$OV/config.json" DREAMTEAM_HOST=trunc FAKE_AVAIL=30000 FAKE_SWAP_FREE=0
[ "$GRC" -eq 2 ] && pass "gate: a truncated overlay with plenty of RAM and no swap still blocks (its swap floor is unknowable)" || fail "gate trunc: exit $GRC"
# familiar's overlay is host data (untracked; it lives in the synced tree): when present here it carries the accepted
# numbers (balloon stays the base's); a clean clone has none, and the check says so
if [ -f "$ROOT/config.familiar.json" ]; then
  jq -e '.memory == {"minAvailableMB":3000,"minSwapFreeMB":2048,"perAgentMB":750,"hostReserveMB":2048} and .lane == {"minAvailableMB":6800,"minSwapFreeMB":4096}
         and .overnight == {"min_available_mb":5500,"min_swap_free_mb":4096} and (.memory | has("balloonReserveMB") | not)' "$ROOT/config.familiar.json" >/dev/null \
    && pass "config.familiar.json (synced tree): the accepted floors, balloonReserveMB left to the base" || fail "config.familiar.json content"
else
  pass "config.familiar.json is not in this tree (host data, untracked): nothing to check"
fi

grep -q 'DREAMTEAM_HOST=dreamteam-test' "$ROOT/tests/run.sh" && pass "tests/run.sh pins DREAMTEAM_HOST, so no real host's overlay reaches a suite" || fail "run.sh does not pin DREAMTEAM_HOST"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
