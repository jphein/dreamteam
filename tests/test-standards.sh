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

# Rule 0 — teammates require tmux (candela 2026-07-01: GUI windows instead of panes)
runenv() { printf '%s' "$2" | env "$1" DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err"; }
runenv "-u" '{"tool_name":"Agent","tool_input":{"name":"lucid-x1","team_name":"t1","subagent_type":"dreamteam:lucid","prompt":"x"}}' 2>/dev/null
printf '%s' '{"tool_name":"Agent","tool_input":{"name":"lucid-x1","team_name":"t1","subagent_type":"dreamteam:lucid","prompt":"x"}}' | env -u TMUX DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err" \
  && bad "teammate outside tmux allowed" || { grep -q "NOT inside tmux" "$TMP/err" && ok "block: teammate spawn outside tmux (pre-flight enforced)" || bad "wrong message: $(cat "$TMP/err")"; }
printf '%s' '{"tool_name":"Agent","tool_input":{"name":"lucid-x1","team_name":"t1","subagent_type":"dreamteam:lucid","prompt":"x"}}' | env TMUX=/tmp/fake,1,1 DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err" \
  && ok "allow: teammate inside tmux" || bad "teammate inside tmux blocked: $(cat "$TMP/err")"
printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"quick lookup no team"}}' | env -u TMUX DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err" \
  && ok "allow: non-team utility spawn outside tmux" || bad "utility outside tmux blocked"

# Rule 0b — the lead's cwd must be a TRUSTED workspace (2026-11-13 10:26–11:06: five fixers
# spawned from an untrusted cwd sat at Claude Code's "Quick safety check" for 40 min).
# Fixture ~/.claude.json via DREAMTEAM_CLAUDE_JSON; real dirs, a real git repo and worktrees.
TR="$TMP/trust"; mkdir -p "$TR/home/trusted/sub/deeper" "$TR/home/plain"
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
G init "$TR/home/trusted/repo" && G -C "$TR/home/trusted/repo" commit --allow-empty -m i
mkdir -p "$TR/home/trusted/repo/src"
G init "$TR/home/okrepo" && G -C "$TR/home/okrepo" commit --allow-empty -m i
G -C "$TR/home/okrepo" worktree add -b wt1 "$TR/home/okrepo-wt"
G -C "$TR/home/trusted/repo" worktree add -b wt2 "$TR/home/trusted/repo-wt"
jq -n --arg t "$TR/home/trusted" --arg ok "$TR/home/okrepo" --arg no "$TR/home/plain" \
  '{projects:{($t):{hasTrustDialogAccepted:true},($ok):{hasTrustDialogAccepted:true},($no):{hasTrustDialogAccepted:false}}}' > "$TR/claude.json"
tspawn() {  # tspawn <cwd> [claude.json]  → a tmux teammate spawn from <cwd>
  printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"name":"lucid-x1","team_name":"t1","subagent_type":"dreamteam:lucid","prompt":"x"}}' "$1" \
    | env TMUX=/tmp/fake,1,1 DREAMTEAM_CLAUDE_JSON="${2:-$TR/claude.json}" DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err"
}
tspawn "$TR/home/plain" && bad "trust: untrusted cwd allowed" || {
  grep -q "not a TRUSTED workspace" "$TMP/err" && grep -qF "$TR/home/plain" "$TMP/err" \
    && grep -q "cd into a trusted project" "$TMP/err" && grep -q "hasTrustDialogAccepted = true" "$TMP/err" \
    && ok "trust: block untrusted cwd; message names the cwd and both fixes" || bad "trust: wrong message: $(cat "$TMP/err")"; }
tspawn "$TR/home/trusted" && ok "trust: allow a trusted cwd (exact key)" || bad "trust: trusted cwd blocked: $(cat "$TMP/err")"
tspawn "$TR/home/trusted/sub/deeper" && ok "trust: allow a non-git dir under a trusted ancestor" || bad "trust: inherited trust blocked: $(cat "$TMP/err")"
tspawn "$TR/home/trusted/repo/src" && bad "trust: git repo under a trusted parent allowed (trust does not cross a repo root)" || {
  grep -qF "projects[\"$TR/home/trusted/repo\"]" "$TMP/err" && ok "trust: block a git repo whose root is untrusted; fix names the REPO ROOT" || bad "trust: wrong key: $(cat "$TMP/err")"; }
tspawn "$TR/home/okrepo" && ok "trust: allow a trusted repo root" || bad "trust: trusted repo blocked: $(cat "$TMP/err")"
tspawn "$TR/home/okrepo-wt" && ok "trust: allow a worktree of a trusted repo" || bad "trust: worktree of trusted repo blocked: $(cat "$TMP/err")"
tspawn "$TR/home/trusted/repo-wt" && bad "trust: worktree of an untrusted repo allowed" || ok "trust: block a worktree of an untrusted repo"
tspawn "$TR/home/plain" "$TR/missing.json" && ok "trust: unreadable ~/.claude.json fails OPEN" || bad "trust: missing config blocked: $(cat "$TMP/err")"
echo 'not json' > "$TR/bad.json"
tspawn "$TR/home/plain" "$TR/bad.json" && ok "trust: corrupt ~/.claude.json fails OPEN" || bad "trust: corrupt config blocked"
printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"prompt":"lookup"}}' "$TR/home/plain" \
  | env TMUX=/tmp/fake,1,1 DREAMTEAM_CLAUDE_JSON="$TR/claude.json" DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err" \
  && ok "trust: non-team subagent from an untrusted cwd passes (no pane, no dialog)" || bad "trust: utility spawn blocked"
printf '{"tool_name":"Agent","cwd":"%s","tool_input":{"name":"lucid-x1","team_name":"t1","subagent_type":"dreamteam:lucid","prompt":"STANDARDS-EXEMPT: test"}}' "$TR/home/plain" \
  | env TMUX=/tmp/fake,1,1 DREAMTEAM_CLAUDE_JSON="$TR/claude.json" DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SS" 2>"$TMP/err" \
  && ok "trust: STANDARDS-EXEMPT passes" || bad "trust: exempt blocked"

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

# ── The roster itself (2026-08-14) ─────────────────────────────────────────
# A 7-agent research wave ran out of distinct names and spawned everyone as
# nebula-*, which defeats the whole point of naming (panes, logs and
# SendMessage addressing all collapse). These pin the pool's shape.
eval "$(grep -m1 '^ROSTER=' "$SS")"   # controlled repo file; gives us $ROSTER
IFS='|' read -r -a ROSTER_WORDS <<< "$ROSTER"

# Depth — the floor that keeps a 2-wave (~20 agent) session in distinct names.
[ "${#ROSTER_WORDS[@]}" -ge 50 ] \
  && ok "roster depth ${#ROSTER_WORDS[@]} >= 50 (wave-exhaustion floor)" \
  || bad "roster only ${#ROSTER_WORDS[@]} names — a big wave will run out"

# No duplicates: a repeated alternative silently shrinks the usable pool.
dupes="$(printf '%s\n' "${ROSTER_WORDS[@]}" | sort | uniq -d | tr '\n' ' ')"
[ -z "$dupes" ] && ok "roster has no duplicate names" || bad "duplicate roster names: $dupes"

# Every roster word must actually clear the gate with a role suffix. Catches a
# stray character in the regex (e.g. a space or an empty alternative) that would
# otherwise only surface as a mystery block mid-wave.
badwords=""
for w in "${ROSTER_WORDS[@]}"; do
  case "$w" in *[!a-z]*|"") badwords="$badwords $w(shape)"; continue ;; esac
  run "{\"tool_name\":\"Agent\",\"tool_input\":{\"name\":\"$w-worker\",\"subagent_type\":\"dreamteam:$w\",\"prompt\":\"x\"}}" \
    || run "{\"tool_name\":\"Agent\",\"tool_input\":{\"name\":\"$w-worker\",\"subagent_type\":\"general-purpose\",\"prompt\":\"x\"}}" \
    || badwords="$badwords $w"
done
[ -z "$badwords" ] && ok "all ${#ROSTER_WORDS[@]} roster names spawn as <name>-worker" \
                   || bad "roster names rejected by the gate:$badwords"

# Disjoint from JP's tmux session names — a pane named for a session is a
# permanent ambiguity. `ember` predates the rule and is grandfathered.
collides=""
for s in hearth crag forge glade grove hollow rune spire vale; do
  printf '%s' "$s" | grep -qxE "$ROSTER" && collides="$collides $s"
done
[ -z "$collides" ] && ok "roster disjoint from tmux session names" \
                   || bad "roster collides with tmux session names:$collides"

# Drift — the regex is a derived copy of lexicon's vocabularies/dreams.yaml.
# Skipped (not failed) when lexicon isn't checked out: the plugin must stay
# usable on a host that has no lexicon clone.
LEXDREAMS="${DREAMTEAM_LEXICON_DIR:-$HOME/Projects/lexicon.realm.watch}/vocabularies/dreams.yaml"
if [ -f "$LEXDREAMS" ] && python3 -c 'import yaml' 2>/dev/null; then
  gen="$(python3 -c "import yaml,sys;print('|'.join(yaml.safe_load(open(sys.argv[1]))['dreams']['roster']['words']))" "$LEXDREAMS")"
  [ "$gen" = "$ROSTER" ] && ok "ROSTER matches lexicon dreams.roster (no drift)" \
    || bad "ROSTER drifted from $LEXDREAMS — regenerate it (see the comment above ROSTER=)"
else
  echo "SKIP: lexicon dreams.yaml not available — drift check skipped"
fi

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
