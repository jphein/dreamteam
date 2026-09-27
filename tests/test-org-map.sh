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
FAKE_PID=""
cleanup(){ [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$TMP"; }
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

echo "== test-org-map: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
