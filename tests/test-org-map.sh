#!/usr/bin/env bash
# dreamteam tests — the OPTIONAL org map: scripts/lib/org_lookup.py,
# scripts/org-lookup.sh, and the additive fields in roster-live.sh --json /
# idle-agents.sh --json.
#
# Hermetic: the catalog is a $TMP fixture (DREAMTEAM_AGENTS_CATALOG), the
# config is a $TMP plugin root (CLAUDE_PLUGIN_ROOT) when a config value is
# under test, roster-live's status engine is stubbed (DREAMTEAM_AGENT_ACTIVITY)
# and idle-agents reads a fixture team dir (DREAMTEAM_TEAMS_DIR) whose one
# member is a real, short-lived process carrying `agent-id <id>` in its argv.
#
# COVERAGE
#   • resolution order: exact id · exact current_name (≠ id) · lane glob · dream prefix
#   • escalation chain follows agents to the human; channel three-channel vs slack+text
#     (config .org.threeChannelOwners honoured)
#   • no-ops: unknown name · entry without org fields · catalog missing · "off" ·
#     malformed YAML  → no output / null, exit 0
#   • BACKWARD COMPAT: roster-live --json and human output are byte-identical with
#     the lookup off vs. a missing catalog; org keys are ABSENT when unresolved and
#     PRESENT (additive, existing keys unchanged) when resolved
#   • idle-agents --json gains org keys only for resolvable agents
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
FAKE_PID=""; FAKE_PIDS=()
cleanup(){ [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; for p in "${FAKE_PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: PyYAML not installed — org map is a no-op here by design"; echo "== test-org-map: 0 passed, 0 failed (skipped)"; exit 0; }

for f in scripts/org-lookup.sh scripts/roster-live.sh scripts/idle-agents.sh; do
  bash -n "$ROOT/$f" && ok "bash -n $f" || bad "bash -n $f"
done

cat > "$TMP/agents.yaml" <<'EOF'
agents:
  - {id: scout, current_name: scout, role: researcher, voice: emma, description: legacy, status: active}
  - {id: sandman, current_name: sandman, kind: orchestrator, spawnable: false, department: technology, owner: jp, escalates_to: jp}
  - {id: hypnos, current_name: hypnos, kind: manager, department: technology, owner: jp, escalates_to: sandman}
  - {id: morpheus, current_name: morpheus, kind: persona, department: technology, owner: jp, escalates_to: sandman}
  - {id: oneiros, current_name: dreamer, kind: persona, department: development, owner: pat, escalates_to: pat}
  - {id: money-lane, current_name: money-lane, kind: session-lane, match: "money-*", department: finance-compliance, owner: jp, escalates_to: jp}
  - {id: nebula-legal, current_name: nebula-legal, kind: persona, status: proposed, department: legal-compliance, owner: jp, escalates_to: jp}
  - {id: nebula, current_name: nebula, kind: persona, status: active, department: development, owner: jp, escalates_to: sandman}
  - {id: ember, current_name: ember, kind: local-model, status: active, department: technology, owner: jp, escalates_to: sandman}
EOF
export DREAMTEAM_AGENTS_CATALOG="$TMP/agents.yaml"

L() { bash "$ROOT/scripts/org-lookup.sh" "$@"; }
LJ() { L "$1" --json | jq -r --arg n "$1" ".[\$n]${2:+ | $2}"; }

# ── resolution order ─────────────────────────────────────────────────────────────
[ "$(LJ sandman .agent)" = "sandman" ]                  && ok "exact id" || bad "exact id: $(LJ sandman .agent)"
[ "$(LJ dreamer .agent)" = "oneiros" ]                  && ok "exact current_name (differs from id)" || bad "current_name: $(LJ dreamer .agent)"
[ "$(LJ money-e8 .agent)" = "money-lane" ]              && ok "lane glob money-*" || bad "glob: $(LJ money-e8 .agent)"
[ "$(LJ morpheus-org .agent)" = "morpheus" ]            && ok "dream prefix before first hyphen" || bad "prefix: $(LJ morpheus-org .agent)"
[ "$(LJ dreamer-research .agent)" = "oneiros" ]         && ok "prefix matches current_name too" || bad "prefix cn: $(LJ dreamer-research .agent)"
[ "$(LJ hypnos-agent-manager .department)" = "technology" ] && ok "department resolved" || bad "department"

# ── status: proposed ⇒ reported, not spawnable (lexicon does not validate status) ──
[ "$(LJ nebula-legal .agent)" = "nebula-legal" ]      && ok "exact full name beats the dream prefix" || bad "nebula-legal: $(LJ nebula-legal .agent)"
[ "$(LJ nebula-legal .status)" = "proposed" ]         && ok "status reported" || bad "status: $(LJ nebula-legal .status)"
[ "$(LJ nebula-legal .spawnable)" = "false" ]         && ok "proposed ⇒ spawnable false" || bad "spawnable: $(LJ nebula-legal .spawnable)"
[ "$(LJ nebula-research .spawnable)" = "true" ]       && ok "active persona ⇒ spawnable true" || bad "active spawnable"
[ "$(LJ sandman .spawnable)" = "false" ]              && ok "spawnable:false honoured (sandman)" || bad "sandman spawnable"
L nebula-legal | grep -q "\[proposed — not yet spawnable\]" && ok "human line flags a proposed role" || bad "human proposed flag: $(L nebula-legal)"
# Oracle block on #98: kind local-model / orchestrator were ignored by resolve()
[ "$(LJ ember .spawnable)" = "false" ]                && ok "local-model (ember) ⇒ spawnable false" || bad "ember spawnable: $(LJ ember .spawnable)"
[ "$(LJ ember-x .spawnable)" = "false" ]              && ok "ember-* (dream prefix) ⇒ spawnable false" || bad "ember-x spawnable: $(LJ ember-x .spawnable)"
L ember | grep -qF "[local model — never a Claude agent]" && ok "human line flags a local model" || bad "ember flag: $(L ember)"
L sandman-x | grep -qF "[not spawnable: orchestrator]"    && ok "human line flags an orchestrator" || bad "sandman flag: $(L sandman-x)"
L morpheus-org | grep -q "\[" && bad "spawnable role carries no flag: $(L morpheus-org)" || ok "spawnable role carries no flag"
EJ="$(python3 -c "
import sys, json; sys.path.insert(0,'$ROOT/scripts/lib'); import org_lookup as o
print(json.dumps([o.enrich({'name':'ember-x'}).get('spawnable'), 'spawnable' in o.enrich({'name':'morpheus-org'})]))")"
[ "$EJ" = "[false, false]" ] && ok "enrich: spawnable:false added only when false" || bad "enrich spawnable: $EJ"

# ── escalation ───────────────────────────────────────────────────────────────────
[ "$(LJ hypnos-agent-manager '.chain|join(">")')" = "sandman>jp" ] && ok "chain follows agents to the human" || bad "chain: $(LJ hypnos-agent-manager '.chain|join(">")')"
[ "$(LJ hypnos-agent-manager .human)" = "jp" ]           && ok "human = chain terminal" || bad "human"
[ "$(LJ morpheus-org .channel)" = "three-channel" ]      && ok "jp ⇒ three-channel (REACHING JP)" || bad "channel jp: $(LJ morpheus-org .channel)"
[ "$(LJ dreamer .channel)" = "slack+text" ]              && ok "non-listed owner ⇒ slack+text" || bad "channel pat: $(LJ dreamer .channel)"
mkdir -p "$TMP/root"
printf '{"org":{"threeChannelOwners":["pat"]}}\n' > "$TMP/root/config.json"
C="$(CLAUDE_PLUGIN_ROOT="$TMP/root" ORG_X=1 python3 -c "
import sys; sys.path.insert(0,'$ROOT/scripts/lib'); import org_lookup as o
print(o.resolve('dreamer')['channel'], o.resolve('morpheus-x')['channel'])")"
[ "$C" = "three-channel slack+text" ] && ok "config .org.threeChannelOwners honoured" || bad "config owners: $C"
H="$(L hypnos-agent-manager)"
[ "$H" = "hypnos-agent-manager: technology · owner jp · escalate sandman → jp (three-channel)" ] && ok "human one-liner" || bad "human line: $H"

# ── no-ops (never an error) ──────────────────────────────────────────────────────
[ "$(LJ nobody-here)" = "null" ]   && ok "unknown name ⇒ null" || bad "unknown: $(LJ nobody-here)"
[ "$(LJ scout)" = "null" ]         && ok "entry without org fields ⇒ null" || bad "legacy: $(LJ scout)"
[ -z "$(L nobody-here)" ]          && ok "unknown ⇒ no human output" || bad "unknown human output"
OUT="$(DREAMTEAM_AGENTS_CATALOG="$TMP/missing.yaml" L morpheus-org)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ]    && ok "missing catalog ⇒ silent, exit 0" || bad "missing: rc=$RC out=$OUT"
OUT="$(DREAMTEAM_AGENTS_CATALOG=off L morpheus-org --json | jq -r '.["morpheus-org"]')"
[ "$OUT" = "null" ]                && ok "DREAMTEAM_AGENTS_CATALOG=off ⇒ null" || bad "off: $OUT"
printf 'agents: [ {id: broken\n' > "$TMP/bad.yaml"
OUT="$(DREAMTEAM_AGENTS_CATALOG="$TMP/bad.yaml" L morpheus-org)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ]    && ok "malformed YAML ⇒ silent, exit 0" || bad "malformed: rc=$RC out=$OUT"
L >/dev/null 2>&1; [ $? = 22 ]     && ok "no NAME ⇒ exit 22" || bad "usage exit"

# ── roster-live: additive + backward compatible ─────────────────────────────────
cat > "$TMP/act.json" <<'EOF'
[
 {"name":"morpheus-org","team":"t","verdict":"ACTIVE","isActive":true,"pid":1000,"pane":"default@s:1.0","pane_state":"ACTIVE","queued":false},
 {"name":"plain-worker","team":"t","verdict":"IDLE","isActive":false,"pid":1001,"pane":"default@s:1.1","pane_state":"IDLE","queued":false}
]
EOF
printf '#!/usr/bin/env bash\ncat "%s"\n' "$TMP/act.json" > "$TMP/engine.sh"; chmod +x "$TMP/engine.sh"
RL() { DREAMTEAM_AGENT_ACTIVITY="$TMP/engine.sh" DREAMTEAM_PROJECTS_DIR="$TMP/none" \
       CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/roster-live.sh" --team t --no-overlay "$@"; }
OFF_J="$(DREAMTEAM_AGENTS_CATALOG=off RL --json)"
MISS_J="$(DREAMTEAM_AGENTS_CATALOG="$TMP/missing.yaml" RL --json)"
ON_J="$(RL --json)"
[ "$OFF_J" = "$MISS_J" ] && ok "roster-live --json: off ≡ missing catalog (byte-identical)" || bad "off vs missing differ"
OFF_H="$(DREAMTEAM_AGENTS_CATALOG=off RL)"; MISS_H="$(DREAMTEAM_AGENTS_CATALOG="$TMP/missing.yaml" RL)"
[ "$OFF_H" = "$MISS_H" ] && ok "roster-live human: off ≡ missing catalog" || bad "human off vs missing differ"
echo "$OFF_H" | grep -q "ORG" && bad "no ORG column without a catalog" || ok "no ORG column without a catalog"
echo "$OFF_J" | jq -e '[.agents[] | has("department") or has("owner") or has("escalation")] | any | not' >/dev/null \
  && ok "no org keys without a catalog" || bad "org keys leaked without catalog"
jr() { printf '%s' "$ON_J" | jq -r --arg n "$1" ".agents[] | select(.name==\$n) | $2"; }
[ "$(jr morpheus-org .department)" = "technology" ] && ok "roster-live: department added" || bad "rl dept: $(jr morpheus-org .department)"
[ "$(jr morpheus-org .owner)" = "jp" ]              && ok "roster-live: owner added" || bad "rl owner"
[ "$(jr morpheus-org '.escalation.channel')" = "three-channel" ] && ok "roster-live: escalation channel" || bad "rl channel"
[ "$(jr plain-worker 'has("department")')" = "false" ] && ok "roster-live: unresolved row has no org keys" || bad "rl unresolved keys"
# existing keys untouched: strip the added keys and compare with the off run
STRIP='del(.agents[].department, .agents[].owner, .agents[].escalates_to, .agents[].escalation)'
[ "$(printf '%s' "$ON_J" | jq -S "$STRIP")" = "$(printf '%s' "$OFF_J" | jq -S .)" ] \
  && ok "roster-live: every pre-existing field unchanged" || bad "pre-existing fields changed"
ON_H="$(RL)"
echo "$ON_H" | grep -q "ORG (dept · owner → escalation)" && ok "human ORG column when resolved" || bad "no ORG column: $ON_H"
echo "$ON_H" | grep "morpheus-org" | grep -q "technology · jp → sandman → jp" && ok "human ORG cell" || bad "ORG cell: $(echo "$ON_H" | grep morpheus-org)"

# ── idle-agents: additive ────────────────────────────────────────────────────────
FAKE_ID="orgmap-$$-fakeagent@t"
bash -c 'sleep 30; :' "agent-id $FAKE_ID" &
FAKE_PID=$!
mkdir -p "$TMP/teams/t"
cat > "$TMP/teams/t/config.json" <<EOF
{"members":[
 {"name":"team-lead","agentType":"team-lead","agentId":"lead-x","isActive":true},
 {"name":"morpheus-org","agentType":"morpheus","agentId":"$FAKE_ID","isActive":false,"cwd":"/w","prompt":"Task: org map"}
]}
EOF
sleep 0.3 2>/dev/null || true
IA() { DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROOT/scripts/idle-agents.sh" --team t --json; }
IJ="$(IA)"
[ "$(printf '%s' "$IJ" | jq -r '.[0].name')" = "morpheus-org" ] && ok "idle-agents sees the fake live agent" || bad "idle fixture not live: $IJ"
[ "$(printf '%s' "$IJ" | jq -r '.[0].owner')" = "jp" ] && ok "idle-agents: owner added" || bad "idle owner: $IJ"
IJ_OFF="$(DREAMTEAM_AGENTS_CATALOG=off IA)"
[ "$(printf '%s' "$IJ_OFF" | jq -r '.[0] | has("owner")')" = "false" ] && ok "idle-agents: no org keys when off" || bad "idle off leaked: $IJ_OFF"
[ "$(printf '%s' "$IJ" | jq -S 'map(del(.department,.owner,.escalates_to,.escalation))')" = "$(printf '%s' "$IJ_OFF" | jq -S .)" ] \
  && ok "idle-agents: pre-existing fields unchanged" || bad "idle fields changed"

# ── idle-agents: a non-spawnable role is NEVER offered as reusable (Oracle, #98) ──
# ember-x (local model), sandman-x (orchestrator), nebula-legal (proposed) are
# idle and alive; only morpheus-x may appear in --json (what the reuse gate reads).
mkdir -p "$TMP/teams/t2"
MEMBERS='{"name":"team-lead","agentType":"team-lead","agentId":"lead-y","isActive":true}'
for n in ember-x sandman-x nebula-legal morpheus-x; do
  id="orgmap-$$-$n@t2"
  bash -c 'sleep 30; :' "agent-id $id" & FAKE_PIDS+=("$!")
  MEMBERS="$MEMBERS,{\"name\":\"$n\",\"agentType\":\"x\",\"agentId\":\"$id\",\"isActive\":false,\"cwd\":\"/w\",\"prompt\":\"Task: $n\"}"
done
printf '{"members":[%s]}\n' "$MEMBERS" > "$TMP/teams/t2/config.json"
sleep 0.3 2>/dev/null || true
IA2() { DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROOT/scripts/idle-agents.sh" --team t2 "$@"; }
[ "$(IA2 --json | jq -c 'map(.name)')" = '["morpheus-x"]' ] \
  && ok "idle-agents --json: ember-x / sandman-x / proposed lane NOT reusable" || bad "non-spawnable offered: $(IA2 --json | jq -c 'map(.name)')"
[ "$(DREAMTEAM_AGENTS_CATALOG=off IA2 --json | jq 'length')" = "4" ] \
  && ok "idle-agents --json: no catalog ⇒ all four listed (legacy)" || bad "off json: $(DREAMTEAM_AGENTS_CATALOG=off IA2 --json)"
[ "$(DREAMTEAM_AGENTS_CATALOG=off IA2 --json)" = "$(DREAMTEAM_AGENTS_CATALOG="$TMP/missing.yaml" IA2 --json)" ] \
  && [ "$(DREAMTEAM_AGENTS_CATALOG=off IA2)" = "$(DREAMTEAM_AGENTS_CATALOG="$TMP/missing.yaml" IA2)" ] \
  && ok "idle-agents: off ≡ missing catalog (json + human)" || bad "idle off vs missing differ"
DREAMTEAM_AGENTS_CATALOG=off IA2 | grep -q "not reusable" && bad "no held block without a catalog" || ok "no held block without a catalog"
IH="$(IA2)"
REUSE_BLOCK="$(printf '%s\n' "$IH" | sed '/^not reusable/,$d')"
HELD_BLOCK="$(printf '%s\n' "$IH" | sed -n '/^not reusable/,$p')"
printf '%s' "$REUSE_BLOCK" | grep -qE "ember-x|sandman-x|nebula-legal" && bad "human reusable block lists a non-spawnable role: $IH" || ok "human reusable block: only spawnable roles"
printf '%s' "$HELD_BLOCK" | grep "ember-x" | grep -qF "[local model — never a Claude agent]" \
  && printf '%s' "$HELD_BLOCK" | grep "sandman-x" | grep -qF "[not spawnable: orchestrator]" \
  && printf '%s' "$HELD_BLOCK" | grep "nebula-legal" | grep -qF "[proposed — not yet spawnable]" \
  && ok "human: held roles visible in a separate block with their flags" || bad "held block: $IH"
# a team of ONLY non-spawnable idle agents ⇒ [] so the reuse gate allows the spawn
mkdir -p "$TMP/teams/t3"
jq '.members |= map(select(.name != "morpheus-x"))' "$TMP/teams/t2/config.json" > "$TMP/teams/t3/config.json"
[ "$(DREAMTEAM_TEAMS_DIR="$TMP/teams" bash "$ROOT/scripts/idle-agents.sh" --team t3 --json)" = "[]" ] \
  && ok "idle-agents: team of only non-spawnable idle ⇒ [] (reuse gate allows the spawn)" || bad "t3 not empty"

echo "== test-org-map: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
