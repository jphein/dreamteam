#!/usr/bin/env bash
# dreamteam tests — spawn-standards.sh (naming + typed-persona gate).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SS="$ROOT/scripts/spawn-standards.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# run <json>  → uses repo config (enforce defaults on)
run() { printf '%s' "$1" | DREAMTEAM_CONFIG="${2:-$ROOT/config.json}" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err"; }

bash -n "$SS" && ok "bash -n spawn-standards.sh" || bad "bash -n"

# ALLOW: proper name + matching typed persona
run '{"tool_name":"Agent","tool_input":{"name":"lucid-262-cache","subagent_type":"dreamteam:lucid","prompt":"x"}}' \
  && ok "allow: lucid-262-cache + dreamteam:lucid" || bad "proper spawn blocked: $(cat "$TMP/err")"

# ALLOW: untyped dreamname with slug as general-purpose
run '{"tool_name":"Agent","tool_input":{"name":"vesper-1403-appid","subagent_type":"general-purpose","prompt":"x"}}' \
  && ok "allow: untyped persona (vesper) as general-purpose" || bad "vesper blocked: $(cat "$TMP/err")"

# BLOCK: non-roster name
run '{"tool_name":"Agent","tool_input":{"name":"bg-agent-research","prompt":"x"}}' \
  && bad "non-roster name allowed" || { grep -q "not a dream-roster name" "$TMP/err" && ok "block: non-roster name (bg-agent-research)" || bad "wrong message: $(cat "$TMP/err")"; }

# BLOCK: bare dreamname (no slug)
run '{"tool_name":"Agent","tool_input":{"name":"lucid","subagent_type":"dreamteam:lucid","prompt":"x"}}' \
  && bad "bare dreamname allowed" || { grep -q "missing its task slug" "$TMP/err" && ok "block: bare dreamname (needs slug)" || bad "wrong message: $(cat "$TMP/err")"; }

# BLOCK: typed persona spawned without its type
run '{"tool_name":"Agent","tool_input":{"name":"morpheus-1400-routing","subagent_type":"general-purpose","prompt":"x"}}' \
  && bad "typed persona w/o type allowed" || { grep -q 'dreamteam:morpheus' "$TMP/err" && ok "block: morpheus-* must use dreamteam:morpheus" || bad "wrong message: $(cat "$TMP/err")"; }

# BLOCK: unnamed TEAMMATE (team_name present)
run '{"tool_name":"Agent","tool_input":{"team_name":"t1","prompt":"x"}}' \
  && bad "unnamed teammate allowed" || { grep -q "without a name" "$TMP/err" && ok "block: unnamed teammate" || bad "wrong message: $(cat "$TMP/err")"; }

# ALLOW: unnamed utility spawn (no team)
run '{"tool_name":"Agent","tool_input":{"prompt":"quick lookup"}}' \
  && ok "allow: anonymous utility spawn (no team)" || bad "utility spawn blocked: $(cat "$TMP/err")"

# ALLOW: escape hatch
run '{"tool_name":"Agent","tool_input":{"name":"totally-custom","prompt":"STANDARDS-EXEMPT: JP asked for this name"}}' \
  && ok "allow: STANDARDS-EXEMPT escape" || bad "exempt blocked: $(cat "$TMP/err")"

# ALLOW: enforce=false disables the gate entirely (explicit ==false check)
echo '{"spawn":{"enforceStandards":false}}' > "$TMP/off.json"
run '{"tool_name":"Agent","tool_input":{"name":"whatever-x","prompt":"x"}}' "$TMP/off.json" \
  && ok "allow: enforceStandards=false is honored" || bad "disable switch broken: $(cat "$TMP/err")"

# ALLOW: non-Agent tools pass through
run '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  && ok "allow: non-Agent tool passthrough" || bad "non-Agent blocked"

# Teaching message carries the persona map
run '{"tool_name":"Agent","tool_input":{"name":"nope","prompt":"x"}}' || true
grep -q "morpheus=architecture" "$TMP/err" && ok "block message teaches the persona map" || bad "teaching message missing"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
