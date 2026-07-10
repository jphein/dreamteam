#!/usr/bin/env bash
# dreamteam tests — roster-live.sh (#41): the UNIFIED REALTIME roster =
#   agent-activity.sh (pane-trusted status + pid-ancestry pane) ⟕ roster.md overlay.
#
# Hermetic + self-isolating: the status ENGINE is stubbed (DREAMTEAM_AGENT_ACTIVITY
# → a script that prints canned agent-activity JSON), the overlay is a $TMP fixture
# (DREAMTEAM_ROSTER_MD / DREAMTEAM_PROJECTS_DIR seams). No host pane / process / team
# config is touched, and roster-live.sh never resolves a pane itself (it reads the
# engine's JSON), so this suite is independent of the live tmux/proc surface.
#
# COVERAGE
#   • join: issue/branch/task from the overlay attach to the right live agent
#   • engine passthrough: pane + pane-trusted status flow straight through
#   • status base map: ACTIVE / IDLE / DEAD / no-pane
#   • flags: ⚠ (stale-isActive verdict) · ⌨ (queued)
#   • overlay FORMAT TOLERANCE — two real-world layouts:
#       fmt2 "Agent|Role|Unit|Worktree / Branch|…" (Role holds the DREAM name, Unit=task)
#       fmt1 "Agent ID|Dream Name|Role|Issue/PR|Worktree|…" (Role is a real role → task)
#   • issue #NNN scan of Notes when there is no Issue/PR column
#   • overlay auto-discovery via <projects>/*/scratch/<team>/roster.md
#   • --no-overlay (pane-truth only) · missing overlay (graceful)
#   • bare (no --team): warns on stderr + resolves team from the engine rows
#   • --json contract (team, overlay, counts, agents[*] keys)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="${ROSTER_LIVE_SH:-$ROOT/scripts/roster-live.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$SUT" && ok "bash -n roster-live.sh" || bad "bash -n roster-live.sh"

mkdir -p "$TMP/bin" "$TMP/projects/proj-a/scratch/faketeam"

# ── stub engine: prints canned agent-activity.sh --json (ignores args) ───────────
cat > "$TMP/act.json" <<'EOF'
[
 {"name":"active-spin","team":"faketeam","verdict":"ACTIVE","isActive":true,"pid":1000,"pane":"default@s:1.0","pane_state":"ACTIVE","queued":false},
 {"name":"idle-done","team":"faketeam","verdict":"IDLE","isActive":false,"pid":1001,"pane":"default@s:1.1","pane_state":"IDLE","queued":false},
 {"name":"stale-active","team":"faketeam","verdict":"ACTIVE ⚠stale-isActive(cfg=idle)","isActive":false,"pid":1002,"pane":"default@s:1.2","pane_state":"ACTIVE","queued":false},
 {"name":"queued-idle","team":"faketeam","verdict":"IDLE","isActive":false,"pid":1005,"pane":"default@s:1.5","pane_state":"IDLE","queued":true},
 {"name":"nopane-x","team":"faketeam","verdict":"IDLE?(no-pane)","isActive":false,"pid":1012,"pane":null,"pane_state":null,"queued":false},
 {"name":"dead-one","team":"faketeam","verdict":"DEAD","isActive":false,"pid":null,"pane":null,"pane_state":null,"queued":false}
]
EOF
cat > "$TMP/engine.sh" <<EOF
#!/usr/bin/env bash
cat "$TMP/act.json"
EOF
chmod +x "$TMP/engine.sh"

# ── overlay fixtures ─────────────────────────────────────────────────────────────
# FORMAT 2 (the current live layout): "Role" column holds the DREAM name; "Unit" = task.
cat > "$TMP/roster-fmt2.md" <<'EOF'
# Dream Team Roster — faketeam
Updated: 2026-07-10 ~09:00 PDT (test)
Liveness: roster.sh --team faketeam. Always --team.

| Agent | Role | Unit | Worktree / Branch | Status | Notes |
|-------|------|------|-------------------|--------|-------|
| team-lead | Sandman | orchestrator | main checkout | active | routes reviews |
| active-spin | Spinny | REALTIME ROSTER | echo-wt / feat/roster | dispatched | agent-activity.sh (#41, #38) |
| idle-done | Doney | GATE | morph-wt / feat/gate | idle | spawn-standards (#40) |
| stale-active | Stale | SKILL.md | lucid-wt / feat/skill | dispatched | crash-audit sweep |
| dead-one | Deady | PERSONAS | neb-wt / feat/personas | dead | agents/*.md |
EOF
# also drop it where auto-discovery looks
cp "$TMP/roster-fmt2.md" "$TMP/projects/proj-a/scratch/faketeam/roster.md"

# FORMAT 1: dedicated "Dream Name" column, so "Role" is a real role (→ task), Issue/PR present.
cat > "$TMP/roster-fmt1.md" <<'EOF'
# Dream Team Roster — faketeam
Updated: 2026-06-30 (test-fmt1)

| Agent ID | Dream Name | Role | Issue/PR | Worktree | Status | Notes |
|----------|------------|------|----------|----------|--------|-------|
| active-spin | Spinny | schema/contract | #23 / PR#29 | vesper-wt | merged | contract v1 |
| idle-done | Doney | diagnostics | #22 / PR#32 | lucid-wt | merged | pane-peek |
EOF

run() { DREAMTEAM_AGENT_ACTIVITY="$TMP/engine.sh" DREAMTEAM_PROJECTS_DIR="$TMP/projects" \
        CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SUT" "$@"; }

# ── FORMAT 2 join (explicit --roster-md) ─────────────────────────────────────────
J="$(run --team faketeam --roster-md "$TMP/roster-fmt2.md" --json)"
printf '%s' "$J" | jq -e . >/dev/null 2>&1 && ok "--json valid JSON" || bad "--json invalid: $J"
jf() { printf '%s' "$J" | jq -r --arg n "$1" --arg f "$2" '.agents[] | select(.name==$n) | .[$f] | tostring'; }
top() { printf '%s' "$J" | jq -r "$1"; }

[ "$(top '.team')" = "faketeam" ]           && ok "json .team=faketeam"        || bad "json team=$(top '.team')"
[ "$(top '.agents | length')" = "6" ]       && ok "json all 6 engine rows kept" || bad "json agents=$(top '.agents|length')"
[ "$(top '.overlay')" = "$TMP/roster-fmt2.md" ] && ok "json .overlay = the explicit --roster-md path" || bad "json overlay=$(top '.overlay')"

# engine passthrough (pane + pane-trusted status)
[ "$(jf active-spin pane)" = "default@s:1.0" ] && ok "pane flows through from engine" || bad "active-spin pane=$(jf active-spin pane)"
[ "$(jf active-spin status)" = "ACTIVE" ]      && ok "status ACTIVE (pane-trusted)"  || bad "active-spin status=$(jf active-spin status)"

# fmt2 disambiguation: Unit=task, Role=dream (NOT task)
[ "$(jf active-spin task)" = "REALTIME ROSTER" ] && ok "fmt2: Unit column ⇒ task" || bad "active-spin task=$(jf active-spin task)"
[ "$(jf active-spin dream)" = "Spinny" ]         && ok "fmt2: Role column (no dream col + unit) ⇒ dream name" || bad "active-spin dream=$(jf active-spin dream)"
[ "$(jf active-spin branch)" = "echo-wt / feat/roster" ] && ok "fmt2: Worktree/Branch ⇒ branch" || bad "active-spin branch=$(jf active-spin branch)"

# issue #NNN scanned out of Notes (no Issue/PR column in fmt2)
[ "$(jf active-spin issue)" = "#41,#38" ] && ok "fmt2: issue #NNN scanned from Notes (#41,#38)" || bad "active-spin issue=$(jf active-spin issue)"
[ "$(jf idle-done issue)" = "#40" ]       && ok "fmt2: single issue scanned (#40)"              || bad "idle-done issue=$(jf idle-done issue)"

# status base map + flags
case "$(jf stale-active flags)" in *"⚠"*) ok "flags: ⚠ on stale-isActive verdict";; *) bad "stale-active flags=$(jf stale-active flags)";; esac
[ "$(jf stale-active status)" = "ACTIVE" ] && ok "stale-active status base ACTIVE (pane-trusted)" || bad "stale-active status=$(jf stale-active status)"
case "$(jf queued-idle flags)" in *"⌨"*) ok "flags: ⌨ on queued agent";; *) bad "queued-idle flags=$(jf queued-idle flags)";; esac
[ "$(jf queued-idle issue)" = "" ] && ok "agent absent from overlay ⇒ empty issue/branch/task" || bad "queued-idle issue=$(jf queued-idle issue)"
[ "$(jf nopane-x status)" = "no-pane" ] && ok "no-pane verdict ⇒ status 'no-pane'" || bad "nopane-x status=$(jf nopane-x status)"
[ "$(jf dead-one status)" = "DEAD" ]    && ok "dead member ⇒ status DEAD"          || bad "dead-one status=$(jf dead-one status)"
[ "$(jf dead-one task)" = "PERSONAS" ]  && ok "DEAD member still carries its overlay task" || bad "dead-one task=$(jf dead-one task)"

# counts
[ "$(top '.counts.active')" = "2" ] && ok "counts.active=2" || bad "counts.active=$(top '.counts.active')"
[ "$(top '.counts.dead')" = "1" ]   && ok "counts.dead=1"   || bad "counts.dead=$(top '.counts.dead')"

# ── FORMAT 1 disambiguation (Role is a real role → task; Issue/PR verbatim) ──────
J="$(run --team faketeam --roster-md "$TMP/roster-fmt1.md" --json)"
[ "$(jf active-spin task)" = "schema/contract" ] && ok "fmt1: dedicated Dream col ⇒ Role used as task" || bad "fmt1 active-spin task=$(jf active-spin task)"
[ "$(jf active-spin dream)" = "Spinny" ]         && ok "fmt1: Dream Name column ⇒ dream"                || bad "fmt1 active-spin dream=$(jf active-spin dream)"
[ "$(jf active-spin issue)" = "#23 / PR#29" ]    && ok "fmt1: explicit Issue/PR column kept verbatim"    || bad "fmt1 active-spin issue=$(jf active-spin issue)"
[ "$(jf active-spin branch)" = "vesper-wt" ]     && ok "fmt1: Worktree column ⇒ branch"                  || bad "fmt1 active-spin branch=$(jf active-spin branch)"

# ── overlay AUTO-DISCOVERY (no --roster-md; glob projects/*/scratch/<team>/roster.md) ──
J="$(run --team faketeam --json)"
[ "$(top '.overlay')" = "$TMP/projects/proj-a/scratch/faketeam/roster.md" ] && ok "auto-discovery finds scratch/<team>/roster.md" || bad "auto overlay=$(top '.overlay')"
[ "$(jf active-spin task)" = "REALTIME ROSTER" ] && ok "auto-discovered overlay joins correctly" || bad "auto task=$(jf active-spin task)"

# ── --no-overlay (pane-truth only) ───────────────────────────────────────────────
J="$(run --team faketeam --roster-md "$TMP/roster-fmt2.md" --no-overlay --json)"
[ "$(top '.overlay')" = "null" ] && ok "--no-overlay ⇒ overlay null" || bad "--no-overlay overlay=$(top '.overlay')"
[ "$(jf active-spin task)" = "" ] && ok "--no-overlay ⇒ no assignment fields" || bad "--no-overlay task=$(jf active-spin task)"
[ "$(jf active-spin status)" = "ACTIVE" ] && ok "--no-overlay still shows live status" || bad "--no-overlay status=$(jf active-spin status)"

# ── missing overlay file ⇒ graceful (agents still listed) ────────────────────────
J="$(run --team faketeam --roster-md "$TMP/does-not-exist.md" --json)"
[ "$(top '.overlay')" = "null" ] && ok "missing overlay ⇒ overlay null (graceful)" || bad "missing overlay=$(top '.overlay')"
[ "$(top '.agents | length')" = "6" ] && ok "missing overlay ⇒ agents still listed" || bad "missing overlay agents=$(top '.agents|length')"

# ── bare (no --team): HARD-REQUIRED — fail-closed, non-zero exit, does NOT proceed ──
run --json >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]  && ok "bare: no --team ⇒ non-zero exit (fail-closed, R4)" || bad "bare: expected non-zero exit, got $rc"
[ "$rc" = "22" ] && ok "bare: exit code 22 (client error)"                 || bad "bare: expected exit 22, got $rc"
ERR="$(run --json 2>&1 >/dev/null)"
echo "$ERR" | grep -qi "REQUIRED" && ok "bare: stderr states --team is REQUIRED" || bad "bare: no REQUIRED error ($ERR)"
# fail-closed contract: a --json consumer (guildmaster) gets NOTHING on stdout — never
# wrong-team data. This is the whole point of exiting instead of warn+proceed.
OUT="$(run --json 2>/dev/null)"
[ -z "$OUT" ] && ok "bare: stdout empty (no wrong-team data reaches a JSON consumer)" || bad "bare: stdout not empty ($OUT)"
# a real --team still works (control: the guard isn't vacuously blocking everything)
J="$(run --team faketeam --roster-md "$TMP/roster-fmt2.md" --json 2>/dev/null)"
[ "$(top '.team')" = "faketeam" ] && ok "control: --team faketeam still produces output" || bad "control: --team faketeam broke ($(top '.team'))"

# ── human render ─────────────────────────────────────────────────────────────────
H="$(run --team faketeam --roster-md "$TMP/roster-fmt2.md" 2>/dev/null)"
echo "$H" | grep -q "realtime roster — team 'faketeam'" && ok "human: header names the team" || bad "human: header missing"
echo "$H" | grep -qE "AGENT +STATUS +PANE +ISSUE +BRANCH +TASK" && ok "human: column headers present" || bad "human: columns missing"
echo "$H" | grep -- "active-spin" | grep -q "REALTIME ROSTER" && ok "human: assignment rendered in the row" || bad "human: assignment row missing"
echo "$H" | grep -q "legend:" && ok "human: legend printed when flags exist" || bad "human: legend missing"
echo "$H" | grep -q "trusts the LIVE pane" && ok "human: states pane-trust provenance" || bad "human: provenance missing"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
