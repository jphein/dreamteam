#!/usr/bin/env bash
# dreamteam — self-contained tests for roster.sh, spawn-accounting.sh, and the
# dashboard/mem-budget defaults-agreement invariant.
#
# NO production script is edited. Isolation is achieved entirely through the
# scripts' own env seams — DREAMTEAM_TEAMS_DIR, CLAUDE_PLUGIN_ROOT, DREAMTEAM_STATE
# — plus a PATH-prepended stub `ps` for the spawn-accounting fault-injection case
# (reproducing the restricted-`ps` hook sandbox that caused the line-21 crash).
#
# Contract: PASS:/FAIL: per check, summary line, exit 1 if any FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
# assert_eq DESC EXPECTED ACTUAL
assert_eq(){ if [ "$2" = "$3" ]; then pass "$1 (=$3)"; else fail "$1 (expected '$2', got '$3')"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dreamteam-test.XXXXXX")"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ── prerequisites (can't test without these) ────────────────────────────────
for bin in jq python3 grep bash; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'FAIL: prerequisite missing: %s\n' "$bin"; exit 1; }
done
for f in scripts/roster.sh scripts/spawn-accounting.sh scripts/dashboard-data.sh scripts/mem-budget.sh; do
  [ -f "$ROOT/$f" ] || { printf 'FAIL: production script not found: %s\n' "$f"; exit 1; }
done

jqok(){ printf '%s' "$1" | jq -e . >/dev/null 2>&1; }  # valid JSON?
jqr(){  printf '%s' "$1" | jq -r "$2" 2>/dev/null; }    # raw scalar

# ─────────────────────────────────────────────────────────────────────────────
echo "== roster.sh: fixture team (liveness classification) =="
mkdir -p "$TMP/teams/faketeam"
# agentId that provably matches no running process → must classify `dead`.
# (isActive:true on purpose — proves the ps-liveness check overrides the config flag.)
GHOST_ID="bogus-agentid-$$-does-not-exist-DEADBEEF"
cat > "$TMP/teams/faketeam/config.json" <<JSON
{
  "members": [
    { "name": "faketeam-lead", "agentType": "team-lead", "agentId": "lead-$$-nonexistent", "isActive": true, "cwd": "/tmp/lead" },
    { "name": "ghost-member",  "agentType": "nebula",    "agentId": "$GHOST_ID",           "isActive": true, "cwd": "/tmp/ghost" }
  ]
}
JSON

RJSON="$(DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROOT/scripts/roster.sh" --team faketeam --json 2>/dev/null)"; RRC=$?
assert_eq "roster fixture exits 0" "0" "$RRC"
if jqok "$RJSON"; then
  pass "roster fixture emits valid JSON"
  assert_eq "roster team name is faketeam"    "faketeam" "$(jqr "$RJSON" '.team')"
  assert_eq "bogus-id member classified dead" "dead"     "$(jqr "$RJSON" '.agents[]|select(.name=="ghost-member")|.status')"
  assert_eq "team-lead classified lead"       "lead"     "$(jqr "$RJSON" '.agents[]|select(.agentType=="team-lead")|.status')"
  assert_eq "member count == 2"               "2"        "$(jqr "$RJSON" '.agents|length')"
  assert_eq "counts.lead == 1"                "1"        "$(jqr "$RJSON" '.counts.lead')"
  assert_eq "counts.dead == 1"                "1"        "$(jqr "$RJSON" '.counts.dead')"
  assert_eq "counts sum == member count" \
    "$(jqr "$RJSON" '.agents|length')" \
    "$(jqr "$RJSON" '.counts.lead + .counts.active + .counts.idle + .counts.dead')"
else
  fail "roster fixture emits valid JSON (got: ${RJSON:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== roster.sh: real current team (live integration) =="
# No DREAMTEAM_TEAMS_DIR override → reads the real ~/.claude/teams newest config.
# tests/run.sh gives suites a private HOME; the live team config is read (only read) from the real one.
RREAL="$(DREAMTEAM_TEAMS_DIR="${DREAMTEAM_REAL_HOME:-$HOME}/.claude/teams" bash "$ROOT/scripts/roster.sh" --json 2>/dev/null)"
if jqok "$RREAL"; then
  pass "roster real-team emits valid JSON"
  LEN="$(jqr "$RREAL" '.agents|length')"
  if [ "${LEN:-0}" -ge 1 ] 2>/dev/null; then
    pass "roster real-team has >=1 agent (=$LEN)"
  else
    fail "roster real-team has >=1 agent (got '$LEN' — this check requires an active dreamteam)"
  fi
else
  fail "roster real-team emits valid JSON (got: ${RREAL:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== spawn-accounting.sh: line-21 regression (restricted/failing ps) =="
# The crash: under `set -o pipefail`, a failing `ps` made `ps|awk||echo 0` emit a
# multiline "0\n0" that broke the arithmetic below. Fixed by letting awk own the
# default. Lock it down: with `ps` stubbed to fail, the hook must still exit 0 and
# emit valid JSON carrying a `.systemMessage` string.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$STUB/ps"
if "$STUB/ps" >/dev/null 2>&1; then fail "stub ps must exit non-zero"; else pass "stub ps exits non-zero (fault injected)"; fi

SA_OUT="$(
  export PATH="$STUB:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_STATE="$TMP/sa-state"
  printf '%s' '{"tool_name":"Agent","tool_input":{"name":"t"}}' \
    | bash "$ROOT/scripts/spawn-accounting.sh" 2>/dev/null
)"; SARC=$?
assert_eq "spawn-accounting exits 0 under failing ps" "0" "$SARC"
if jqok "$SA_OUT"; then
  pass "spawn-accounting emits valid JSON under failing ps"
  assert_eq "spawn-accounting .systemMessage is a string" "true" "$(jqr "$SA_OUT" '.systemMessage|type=="string"')"
else
  fail "spawn-accounting emits valid JSON under failing ps (got: ${SA_OUT:0:160})"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== defaults agreement: dashboard-data / mem-budget / mem-gate (+ scope caps) =="
# Guards the 600/4000 drift class. Anchored on the default LITERALS themselves —
#   dashboard-data.sh:  m("KEY", N)
#   mem-budget.sh:      getcfg KEY N
#   mem-gate.sh:        getcfg KEY N   (#55 — the ACTUAL admission gate)
# — so a concurrent edit that moves the roster section doesn't affect this parse.
DASH="$ROOT/scripts/dashboard-data.sh"; BUD="$ROOT/scripts/mem-budget.sh"; GATE="$ROOT/scripts/mem-gate.sh"
extract_dash(){ grep -oE "m\\(\"$1\", *[0-9]+\\)" "$DASH" | head -1 | grep -oE '[0-9]+' | head -1; }
extract_bud(){  grep -oE "getcfg +$1 +[0-9]+"      "$BUD"  | head -1 | grep -oE '[0-9]+' | head -1; }
extract_gate(){ grep -oE "getcfg +$1 +[0-9]+"      "$GATE" | head -1 | grep -oE '[0-9]+' | head -1; }
# All THREE consumers of the .memory defaults must agree. mem-gate.sh is the
# PreToolUse admission gate — if its baked default drifts from mem-budget /
# dashboard, the gate ADMITS on a different budget than /dreamteam-status and the
# dashboard REPORT (#55: same drift class, on the script that decides admission).
for k in perAgentMB hostReserveMB balloonReserveMB minAvailableMB maxAgents; do
  d="$(extract_dash "$k")"; b="$(extract_bud "$k")"; g="$(extract_gate "$k")"
  if   [ -z "$d" ]; then fail "defaults: '$k' default not found in dashboard-data.sh"
  elif [ -z "$b" ]; then fail "defaults: '$k' default not found in mem-budget.sh"
  elif [ -z "$g" ]; then fail "defaults: '$k' default not found in mem-gate.sh"
  elif [ "$d" = "$b" ] && [ "$b" = "$g" ]; then pass "defaults agree: $k = $d (dashboard-data, mem-budget, mem-gate)"
  else fail "defaults DRIFT: $k dashboard-data=$d mem-budget=$b mem-gate=$g"
  fi
done

# Per-host overlay (Sen 2026-11-17): all three readers deep-merge config.<host>.json over config.json the SAME way.
# Behavioural: one fixture overlay; each reader must report its values (perAgent 750, hostReserve 2048) while the base's
# balloonReserve 4000 survives the merge; and a host with no overlay keeps the base values in all three.
OVR="$TMP/ovr"; mkdir -p "$OVR" "$TMP/ovbin"; cp "$ROOT/config.json" "$OVR/config.json"
# free (100 MiB available, so the gate blocks and prints its parameters) and systemctl (no live scopes: the real host's
# dreamteam scopes would multiply the balloon, 2026-09-18) stubbed for these three calls only
printf '#!/bin/sh
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:  64000 2000 1000 0 1000 100"
echo "Swap: 8191 0 8191"
' > "$TMP/ovbin/free"
printf '#!/bin/sh
case "$*" in *show*MemoryCurrent*) echo 0;; esac
exit 0
' > "$TMP/ovbin/systemctl"; chmod +x "$TMP/ovbin/free" "$TMP/ovbin/systemctl"
printf '%s\n' '{"memory":{"perAgentMB":750,"hostReserveMB":2048}}' > "$OVR/config.familiar.json"
for h in familiar katana fami_liar; do
  bud=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=$h CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>/dev/null | grep 'per-agent plan')
  dsh=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=$h CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$DASH" --json 2>/dev/null | jq -c '[.memory.perAgentMb // .perAgentMb, .memory.hostReserveMb // .hostReserveMb, .memory.balloonReserveMb // .balloonReserveMb]' 2>/dev/null)
  gate=$(printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=$h CLAUDE_PLUGIN_ROOT="$ROOT" FAKE_AVAIL=100 PATH="$TMP/ovbin:$PATH" bash "$GATE" 2>&1 | grep -o 'per_agent=[0-9]*  host_reserve=[0-9]*  balloon_reserve=[0-9]*')
  if [ $h = familiar ]; then want_b="per-agent plan: 750 MiB    host reserve: 2048 MiB    balloon reserve: 4000 MiB"; want_d='[750,2048,4000]'; want_g='per_agent=750  host_reserve=2048  balloon_reserve=4000'
  else want_b="per-agent plan: 300 MiB    host reserve: 6000 MiB    balloon reserve: 4000 MiB"; want_d='[300,6000,4000]'; want_g='per_agent=300  host_reserve=6000  balloon_reserve=4000'; fi
  [[ "$bud" == *"$want_b"* ]] && [ "$dsh" = "$want_d" ] && [ "$gate" = "$want_g" ] \
    && pass "overlay agreement ($h): mem-budget, dashboard-data and mem-gate all read the same merged config (an invalid host name takes no overlay)" \
    || fail "overlay drift ($h): mem-budget='$bud' dashboard=$dsh gate='$gate'"
done
# invalid values: the gate blocks, mem-budget says CONFIG INVALID (exit 2), the dashboard carries configError: never a
# budget the gate will not honour (xreview #230 r3)
ln -sfn "$OVR/nowhere.json" "$OVR/config.invdangling.json"
for n in dangling; do
  b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
  d=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$DASH" --json 2>/dev/null | jq -r '.configError // ""')
  printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$GATE" >/dev/null 2>&1; grc=$?
  [ $brc = 2 ] && [ -n "$d" ] && [ $grc = 2 ] && pass "a dangling overlay link: gate blocks, mem-budget CONFIG INVALID, dashboard configError" || fail "dangling: budget=$brc dashboard='$d' gate=$grc"
done
# integral floats are valid in every reader (jq reads 750.0 and 7.5e2 as 750): mem-budget ok, dashboard no configError,
# and the gate's verdict is about memory, never "not an integer"
for c in 'f1|{"memory":{"perAgentMB":750.0}}' 'f2|{"memory":{"perAgentMB":7.5e2}}'; do
  n=${c%%|*}; printf '%s\n' "${c#*|}" > "$OVR/config.ok$n.json"
  b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=ok$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
  d=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=ok$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$DASH" --json 2>/dev/null | jq -r '[.configError, .memory.perAgentMb] | @tsv')
  ge=$(printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=ok$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$GATE" 2>&1)
  [ $brc = 0 ] && [[ "$b" == *"per-agent plan: 750 MiB"* ]] && [ "$d" = $'\t750' ] && [[ "$ge" == *"per_agent=750"* ]] && [[ "$ge" != *"not an integer"* ]] \
    && pass "an integral float ($n) is 750 in all three readers" || fail "float agreement ($n): budget=$brc dashboard='$d' gate='$(head -c 100 <<<"$ge")'"
done
# negative zero is integral and 0 (jq can print -0): valid in all three readers (xreview #230 r6)
for v in -0 -0.0 -0e2; do
  printf '{"memory":{"minSwapFreeMB":%s}}\n' "$v" > "$OVR/config.negzero.json"
  b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=negzero CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
  d=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=negzero CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$DASH" --json 2>/dev/null | jq -r '[.configError, .memory.minSwapFreeMb] | @tsv')
  ge=$(printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=negzero CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$GATE" 2>&1)
  [ $brc = 0 ] && [ "$d" = $'\t0' ] && [[ "$ge" != *"not an integer"* ]] && pass "negative zero ($v) is 0 in all three readers" || fail "negzero $v: budget=$brc dashboard='$d' gate='$(head -c 90 <<<"$ge")'"
done
# a huge exponent, even in a key no reader uses: the file is invalid for every reader, and nothing ever carries Infinity
# or builds a gigantic int (1e400000000 returns at once)
printf '%s\n' '{"memory":{"someUnusedKey":1e400000000}}' > "$OVR/config.bigunused.json"
out=$(DREAMTEAM_HOST=bigunused timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$OVR/config.json"); rc=$?
b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=bigunused CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
[ $rc = 3 ] && [[ "$out" != *Infinity* ]] && jq -e . <<<"$out" >/dev/null && [ $brc = 2 ] && pass "1e400000000 in an unused key: invalid file (rc 3, at once), strict JSON out, mem-budget CONFIG INVALID" || fail "bigunused: rc=$rc brc=$brc out=$(head -c 80 <<<"$out")"
# an integer literal is bounded like any other number (xreview #230 r9): 4000 nines in an unused key, and 10^19 as a
# floor, make the file invalid at once; 10^19 - 1 is the largest accepted
printf '{"memory":{"someUnusedKey":%s}}\n' "$(printf '9%.0s' $(seq 1 4000))" > "$OVR/config.bigint.json"
printf '%s\n' '{"memory":{"minAvailableMB":10000000000000000000}}' > "$OVR/config.int19.json"
printf '%s\n' '{"memory":{"someUnusedKey":9999999999999999999}}' > "$OVR/config.intmax.json"
r1=$(DREAMTEAM_HOST=bigint timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$OVR/config.json" >/dev/null 2>&1; echo $?)
r2=$(DREAMTEAM_HOST=int19 timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$OVR/config.json" >/dev/null 2>&1; echo $?)
r3=$(DREAMTEAM_HOST=intmax timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$OVR/config.json" >/dev/null 2>&1; echo $?)
[ "$r1" = 3 ] && [ "$r2" = 3 ] && [ "$r3" = 0 ] && pass "integer literals are bounded: 4000 digits and 10^19 invalid (rc 3), 10^19-1 accepted" || fail "int bounds: bigint=$r1 int19=$r2 intmax=$r3"
# an overlay that cannot be CHECKED is invalid, never absent (xreview #230 r9): a config directory without search
# permission hides both files; the base reads as {} (documented) but the overlay's existence is unknown → rc 3
if [ "$(id -u)" != 0 ]; then
  NOX="$TMP/nox"; mkdir -p "$NOX"; printf '{}\n' > "$NOX/config.json"; printf '%s\n' '{"lane":{"minAvailableMB":6800}}' > "$NOX/config.nox.json"
  chmod 600 "$NOX"
  r=$(DREAMTEAM_HOST=nox timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$NOX/config.json" >/dev/null 2>&1; echo $?)
  rn=$(DREAMTEAM_HOST=noxabsent timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$NOX/config.json" >/dev/null 2>&1; echo $?)
  chmod 700 "$NOX"
  ra=$(DREAMTEAM_HOST=noxabsent timeout 5 python3 -I "$ROOT/scripts/lib/config_merge.py" "$NOX/config.json" >/dev/null 2>&1; echo $?)
  [ "$r" = 3 ] && [ "$rn" = 3 ] && [ "$ra" = 0 ] && pass "an unsearchable config dir: the overlay is invalid (rc 3), never treated as absent; a truly absent overlay is rc 0" || fail "unsearchable: present=$r unknown=$rn absent=$ra"
fi
# the scope exemption never hides an invalid config: scopeToDreamteam true, no active team, an invalid .local → exit 2
printf '%s\n' '{"memory":{"scopeToDreamteam":true},"local":[]}' > "$OVR/config.scopebad.json"
printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=scopebad DREAMTEAM_STATE="$TMP/no-active" CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$GATE" >/dev/null 2>&1; grc=$?
b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=scopebad CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
[ $grc = 2 ] && [ $brc = 2 ] && pass "scope exemption + invalid .local: the gate blocks (exit 2) as mem-budget reports" || fail "scope+badlocal: gate=$grc budget=$brc"
for c in 'underflow|{"memory":{"minSwapFreeMB":-1e-400}}' 'nearint|{"memory":{"minAvailableMB":3000.0000000000000001}}' 'bigexp|{"memory":{"minAvailableMB":1e400}}' 'leadzero|{"memory":{"minAvailableMB":03000}}' 'nan|{"memory":{"minAvailableMB":NaN}}' 'null|null' 'localfalse|{"local":false}' 'localarr|{"local":[]}' 'memlist|{"memory":[]}' 'peragent0|{"memory":{"perAgentMB":0}}' 'peragent|{"memory":{"perAgentMB":"x"}}' 'memory|{"memory":{"minSwapFreeMB":false}}' 'local|{"local":{"enabled":true,"reserveMB":"1e4"}}' 'enabled|{"local":{"enabled":"yes"}}' 'trunc|{"memory":'; do
  n=${c%%|*}; printf '%s
' "${c#*|}" > "$OVR/config.inv$n.json"
  b=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$BUD" 2>&1); brc=$?
  d=$(DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$DASH" --json 2>/dev/null | jq -r '.configError // ""')
  printf '%s' '{"tool_name":"Agent"}' | DREAMTEAM_CONFIG="$OVR/config.json" DREAMTEAM_HOST=inv$n CLAUDE_PLUGIN_ROOT="$ROOT" PATH="$TMP/ovbin:$PATH" bash "$GATE" >/dev/null 2>&1; grc=$?
  [ $brc = 2 ] && [[ "$b" == *"CONFIG INVALID"* ]] && [ -n "$d" ] && [ $grc = 2 ] \
    && pass "invalid overlay ($n): gate blocks, mem-budget reports CONFIG INVALID, dashboard carries configError" \
    || fail "invalid agreement ($n): budget rc=$brc '$(head -c 120 <<<"$b")' dashboard='$d' gate=$grc"
done

# Local-lane reserve (#37): .local.reserveMB is read in THREE places — dashboard-data
# (ml("reserveMB", N)), mem-budget + mem-gate (getlocal reserveMB N). All must agree,
# or the dashboard shows a budget the gate won't enforce (same drift class, new knob).
# (GATE defined above, with DASH/BUD.)
dl="$(grep -oE 'ml\("reserveMB", *[0-9]+\)' "$DASH" | grep -oE '[0-9]+' | head -1)"
bl="$(grep -oE 'getlocal +reserveMB +[0-9]+'  "$BUD"  | grep -oE '[0-9]+' | head -1)"
gl="$(grep -oE 'getlocal +reserveMB +[0-9]+'  "$GATE" | grep -oE '[0-9]+' | head -1)"
if   [ -z "$dl" ]; then fail "defaults: '.local.reserveMB' default not found in dashboard-data.sh"
elif [ -z "$bl" ]; then fail "defaults: '.local.reserveMB' default not found in mem-budget.sh"
elif [ -z "$gl" ]; then fail "defaults: '.local.reserveMB' default not found in mem-gate.sh"
elif [ "$dl" = "$bl" ] && [ "$bl" = "$gl" ]; then pass "defaults agree: .local.reserveMB = $dl (dashboard-data, mem-budget, mem-gate)"
else fail "defaults DRIFT: reserveMB dashboard-data=$dl mem-budget=$bl mem-gate=$gl"
fi

# ── scope caps agreement (#55) ───────────────────────────────────────────────
# memoryHigh/memoryMax set the cgroup ceiling in BOTH launch-dreamteam.sh (getcfg,
# reads .scope) and scope-attach.sh (getscope), and are REPORTED by mem-budget.sh
# (getscope). memorySwapMax is set by launch + scope-attach only. Drift = the
# whole-session scope and the per-spawn attach cap the team differently — a silent
# containment inconsistency in the config-absent fallback path. Same literal-anchored
# parse as above; values carry a unit (20G/24G/8G).
LAUNCH="$ROOT/scripts/launch-dreamteam.sh"; ATTACH="$ROOT/scripts/scope-attach.sh"
sval(){ grep -oE "$2 +$1 +[0-9]+[A-Za-z]*" "$3" | head -1 | grep -oE '[0-9]+[A-Za-z]*' | head -1; }
for k in memoryHigh memoryMax; do
  l="$(sval "$k" getcfg "$LAUNCH")"; a="$(sval "$k" getscope "$ATTACH")"; m="$(sval "$k" getscope "$BUD")"
  if   [ -z "$l" ]; then fail "scope: '$k' default not found in launch-dreamteam.sh"
  elif [ -z "$a" ]; then fail "scope: '$k' default not found in scope-attach.sh"
  elif [ -z "$m" ]; then fail "scope: '$k' default not found in mem-budget.sh"
  elif [ "$l" = "$a" ] && [ "$a" = "$m" ]; then pass "scope caps agree: $k = $l (launch, scope-attach, mem-budget)"
  else fail "scope caps DRIFT: $k launch=$l scope-attach=$a mem-budget=$m"
  fi
done
# memorySwapMax: launch + scope-attach only (mem-budget doesn't cap swap).
sl="$(sval memorySwapMax getcfg "$LAUNCH")"; sa="$(sval memorySwapMax getscope "$ATTACH")"
if   [ -z "$sl" ]; then fail "scope: 'memorySwapMax' default not found in launch-dreamteam.sh"
elif [ -z "$sa" ]; then fail "scope: 'memorySwapMax' default not found in scope-attach.sh"
elif [ "$sl" = "$sa" ]; then pass "scope caps agree: memorySwapMax = $sl (launch, scope-attach)"
else fail "scope caps DRIFT: memorySwapMax launch=$sl scope-attach=$sa"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────"
printf 'summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
