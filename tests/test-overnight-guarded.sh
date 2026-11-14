#!/usr/bin/env bash
# dreamteam — regression tests for the GUARDED nightly sweep (scripts/overnight-guarded.sh,
# systemd/dreamteam-nightly-guarded.{service,timer}). JP 2026-11-14 06:40 "go" on ask 4c77a5b8f3ef:
# "runs 23:30 with the 70 % quota guard, PR-only in production repos, oracle review before any merge".
#
# HERMETIC — nothing real is started, spent or mutated:
#   • curl is PATH-stubbed: serves $FAKE_QUOTA (JSON) or fails when FAKE_QUOTA_DOWN=1 (proxy down).
#   • gh is PATH-stubbed: `gh api repos/<r>/issues…` serves $FAKE_GH_<name> or [] ; logs argv.
#   • git is PATH-stubbed: `git clone` just makes the directory; logs argv.
#   • claude is a recorder (DREAMTEAM_CLAUDE_BIN): writes its argv + cwd + proxy env, prints {}.
#   • systemd-run / tmux are never reached: DREAMTEAM_INLINE=1 runs the runner in-process, and
#     the scope+tmux launch line is asserted from DRY_RUN=1 output instead.
#   • DREAMTEAM_TEST=1 silences voice; state, queue, config and clone dirs are all under $TMP.
#
# Run standalone:  bash tests/test-overnight-guarded.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/scripts/overnight-guarded.sh"
SD="$ROOT/systemd"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

cat > "$BIN/curl" <<'S'
#!/bin/bash
echo probe >> "${SEQ_LOG:-/dev/null}"
[ "${FAKE_QUOTA_DOWN:-0}" = "1" ] && exit 7
echo "${FAKE_QUOTA:-}"
S
cat > "$BIN/gh" <<'S'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
for a in "$@"; do
  case "$a" in
    repos/*/issues/*/comments*) [ "${FAKE_COMMENTS_FAIL:-0}" = 1 ] && exit 1; echo "${FAKE_COMMENTS:-[]}"; exit 0;;
    repos/*/issues/*/events*) def='[{"event":"labeled","label":{"name":"dream"},"actor":{"login":"jphein"}}]'
      [ "${FAKE_EVENTS_FAIL:-0}" = 1 ] && exit 1
      echo "${FAKE_EVENTS:-$def}"; [ -n "${FAKE_EVENTS_P2:-}" ] && case " $* " in *" --paginate "*) echo "$FAKE_EVENTS_P2";; esac; exit 0;;
    repos/*/collaborators/*/permission) l="${a#*/collaborators/}"; l="${l%%/permission}"; v="FAKE_PERM_${l//[^A-Za-z0-9]/_}"
      d=read; [ "$l" = jphein ] && d=admin; echo "{\"permission\":\"${!v:-$d}\"}"; exit 0;;
    repos/*/issues*) r="${a#repos/}"; r="${r%%/issues*}"; n="${r#*/}"; v="FAKE_GH_${n//[^A-Za-z0-9]/_}"; echo "${!v:-[]}"; exit 0;;
  esac
done
echo '[]'
S
cat > "$BIN/git" <<'S'
#!/bin/bash
echo "git $*" >> "$GIT_LOG"
if [ "${1:-}" = "clone" ]; then for d in "$@"; do :; done; mkdir -p "$d"; echo clone >> "${SEQ_LOG:-/dev/null}"; fi
exit 0
S
cat > "$BIN/claude-rec" <<'S'
#!/bin/bash
echo claude >> "${SEQ_LOG:-/dev/null}"
{ echo "CWD=$PWD"; echo "HTTPS_PROXY=${HTTPS_PROXY:-}"; echo "NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-}";
  echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-unset}"; echo "SCOPE=${DREAMTEAM_SCOPE_NAME:-unset}"; echo "DIRECT=${TEAMCLAUDE_ALLOW_DIRECT:-unset}${TEAMCLAUDE_BYPASS:-}"; echo "PATH1=${PATH%%:*}"
  printf 'ARG=%s\n' "$@"; echo "---"; } >> "$CLAUDE_LOG"
if [ -n "${FAKE_CLAUDE_SLEEP:-}" ]; then sleep "$FAKE_CLAUDE_SLEEP"; echo "END-NOT-KILLED" >> "$CLAUDE_LOG"; fi
echo '{"type":"result","result":"done\nSWEEP-RESULT {\"fixed\":[{\"repo\":\"jphein/realmwatch\",\"number\":7,\"pr\":12,\"sha\":\"\"}],\"reviewed_not_merged\":[],\"too_large\":[]}"}'
S
chmod +x "$BIN"/*

Q_OK='{"aggregate":{"fiveHour":{"remaining":0.92},"sevenDay":null,"weeklyShared":{"remaining":0.61}}}'
Q_LOW5='{"aggregate":{"fiveHour":{"remaining":0.69},"weeklyShared":{"remaining":0.9}}}'
Q_LOW7='{"aggregate":{"fiveHour":{"remaining":0.95},"sevenDay":{"remaining":0.29}}}'
Q_NO7='{"aggregate":{"fiveHour":{"remaining":0.95},"sevenDay":null}}'
I2='[{"number":7,"title":"fix seven","user":{"login":"jphein"},"labels":[{"name":"dream"}]},{"number":9,"title":"fix nine","user":{"login":"jphein"},"labels":[{"name":"dream"}]}]'

mkcfg(){ cat > "$TMP/config.json" <<'J'
{"scope":{"memoryHigh":"20G","memoryMax":"24G","memorySwapMax":"8G"},
 "overnight":{"five_hour_min":0.70,"seven_day_min":0.30,"continue_five_hour_min":0.40,
   "max_repos_per_night":3,"max_issues_per_repo":5,"stop_at":"06:30",
   "production_repos":["realmwatch","dreamteam"],"merge_repos":["starcharts"],"never_sweep":["plan.realm.watch"]}}
J
}
mkqueue(){ # $@ = repo:dream pairs
  local rows="" sep=""
  for p in "$@"; do rows="$rows$sep{\"repo\":\"${p%%:*}\",\"dream\":${p##*:},\"open\":${p##*:}}"; sep=","; done
  echo "{\"generated\":\"2026-11-14T21:50:00-08:00\",\"repos\":[$rows]}" > "$TMP/state/issues-queue.json"
}
reset(){ rm -rf "$TMP/state" "$TMP/wt" "$TMP/plan-data" "$TMP"/*.log; mkdir -p "$TMP/state"; mkcfg; }
run_g(){ # env passthrough via caller prefix assignments; extra args to the script
  TEAMCLAUDE_ALLOW_DIRECT=1 TEAMCLAUDE_BYPASS=1 DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_CONFIG="$TMP/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" \
  DREAMTEAM_WT_BASE="$TMP/wt" DREAMTEAM_CLAUDE_BIN="$BIN/claude-rec" DREAMTEAM_PLAN_DATA="$TMP/plan-data" \
  DREAMTEAM_DEADLINE_EPOCH="${DEADLINE:-$(( $(date +%s) + 6*3600 ))}" \
  GH_LOG="$TMP/gh.log" GIT_LOG="$TMP/git.log" CLAUDE_LOG="$TMP/claude.log" \
  PATH="$BIN:$PATH" bash "$G" "$@"
}
gj(){ jq -r "$1" "$TMP/state/overnight-guard.json" 2>/dev/null; }

echo "── syntax + units ───────────────────────────────────────────────"
bash -n "$G" 2>/dev/null && pass "overnight-guarded.sh passes bash -n" || fail "overnight-guarded.sh missing or syntax error"
T="$SD/dreamteam-nightly-guarded.timer"; S="$SD/dreamteam-nightly-guarded.service"
grep -q '^OnCalendar=\*-\*-\* 23:30:00' "$T" 2>/dev/null && pass "guarded timer fires 23:30 daily" || fail "guarded timer OnCalendar not 23:30"
grep -q '^Persistent=false' "$T" 2>/dev/null && pass "guarded timer Persistent=false (a missed night is missed)" || fail "guarded timer not Persistent=false"
grep -q '^AccuracySec=2min' "$T" 2>/dev/null && pass "guarded timer AccuracySec=2min" || fail "guarded timer AccuracySec"
! grep -q '^RandomizedDelaySec' "$T" 2>/dev/null && pass "guarded timer has no random delay" || fail "guarded timer randomizes its start"
grep -q '^Type=oneshot' "$S" 2>/dev/null && grep -q 'overnight-guarded.sh' "$S" && grep -q '^Environment=CLAUDE_PLUGIN_ROOT=' "$S" \
  && pass "guarded service: oneshot → overnight-guarded.sh with CLAUDE_PLUGIN_ROOT" || fail "guarded service shape"
grep -q 'dreamteam-nightly-guarded.timer' "$ROOT/scripts/timers-ctl.sh" && ! grep -qE '^TIMERS=.*dreamteam-nightly\.timer' "$ROOT/scripts/timers-ctl.sh" \
  && pass "timers-ctl installs the guarded pair and not the 02:11 pilot (one nightly start)" || fail "timers-ctl timer list"
if command -v systemd-analyze >/dev/null 2>&1 && [ -f "$T" ]; then
  # only findings about OUR units count (verify also lints unrelated system units it loads)
  out=$(systemd-analyze --user verify "$T" "$S" 2>&1 | grep 'dreamteam-nightly-guarded'); [ -z "$out" ] \
    && pass "systemd-analyze --user verify: guarded timer+service" || fail "systemd-analyze: $out"
fi

echo "── (a) quota guard ──────────────────────────────────────────────"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_LOW5" run_g >/dev/null; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -q '0.69' && [ ! -s "$TMP/claude.log" ]; } \
  && pass "fiveHour 0.69 < 0.70 → no start, reason names the number" || fail "low 5h (rc=$rc decision=$(gj .decision) reason=$(gj .reason))"
[ "$(gj .quota_remaining.five_hour)" = "0.69" ] && pass "guard record carries quota_remaining" || fail "quota_remaining missing"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_LOW7" run_g >/dev/null
{ [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -qi '7-day\|seven'; } && pass "sevenDay 0.29 < 0.30 → no start" || fail "low 7d ($(gj .reason))"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_NO7" run_g >/dev/null
[ "$(gj .decision)" = "no-start" ] && pass "7-day pool unreported (sevenDay and weeklyShared null) → fail closed" || fail "null 7d started ($(gj .decision))"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA_DOWN=1 run_g >/dev/null; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -qi 'proxy' && [ ! -s "$TMP/claude.log" ]; } \
  && pass "proxy down → no start (fail closed), unit still exits 0" || fail "proxy down (rc=$rc $(gj .decision) $(gj .reason))"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA='<html>502</html>' run_g >/dev/null
[ "$(gj .decision)" = "no-start" ] && pass "proxy answers garbage → no start" || fail "garbage quota started"
jq -e '.quota_guard.skipped == 2 and (.quota_guard.reason|length>0)' "$TMP/plan-data/sweep-results.json" >/dev/null 2>&1 \
  && pass "skip night → plan sweep-results.json: quota_guard held back 2 fixes + reason" || fail "plan sweep-results on skip: $(cat "$TMP/plan-data/sweep-results.json" 2>/dev/null)"

echo "── (b) work gate ────────────────────────────────────────────────"
reset; mkqueue jphein/starcharts:0
FAKE_QUOTA="$Q_OK" run_g >"$TMP/out"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ "$(gj .decision)" = "no-work" ] && [ ! -f "$TMP/state/overnight-pending.md" ] && [ ! -s "$TMP/claude.log" ]; } \
  && pass "no dream issues → silent exit 0, decision no-work, no pending, no coordinator" || fail "no-work path (rc=$rc decision=$(gj .decision) out=$(cat "$TMP/out"))"
reset; mkqueue jphein/starcharts:2   # queue says 2, live REST says 0 (closed since)
FAKE_GH_starcharts='[]' FAKE_QUOTA="$Q_OK" run_g >/dev/null
[ "$(gj .decision)" = "no-work" ] && pass "queue stale (live REST shows none open) → no-work" || fail "stale queue started ($(gj .decision))"
reset; mkqueue jphein/plan.realm.watch:4
FAKE_GH_plan_realm_watch="$I2" FAKE_QUOTA="$Q_OK" run_g >/dev/null
{ [ "$(gj .decision)" = "no-work" ] && ! grep -q 'plan.realm.watch' "$TMP/gh.log" 2>/dev/null; } \
  && pass "never_sweep repo (plan.realm.watch) is never read or swept" || fail "plan.realm.watch swept"
reset; mkqueue jphein/starcharts:2
FAKE_GH_starcharts='[{"number":5,"title":"a PR","pull_request":{}},{"number":6,"title":"real","user":{"login":"jphein"},"labels":[]}]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ grep -q '"number":6' "$TMP/claude.log" 2>/dev/null && ! grep -q '"number":5' "$TMP/claude.log"; } && pass "pull requests in the issues endpoint are dropped (issue 6 kept, PR 5 not)" || fail "PR/issue filter: $(grep -o '"number":[0-9]*' "$TMP/claude.log" 2>/dev/null | sort -u | tr '\n' ' ')"

echo "── (c) PR-only in production repos ──────────────────────────────"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2 jphein/unknownrepo:2
FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_GH_unknownrepo="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "started" ] && pass "work + quota OK → started" || fail "happy path not started ($(gj .decision) $(gj .reason))"
pj(){ jq -r "$1" "$(ls -d "$TMP"/state/overnight-runs/*/ | head -n1)plan.json" 2>/dev/null; }
[ "$(pj '.repos[]|select(.repo=="jphein/realmwatch")|.pr_only')" = "true" ] && pass "production repo → pr_only true" || fail "realmwatch not pr_only"
[ "$(pj '.repos[]|select(.repo=="techempower-org/starcharts")|.pr_only')" = "false" ] && pass "merge_repos entry (matched by name across owners) → pr_only false" || fail "starcharts pr_only"
[ "$(pj '.repos[]|select(.repo=="jphein/unknownrepo")|.pr_only')" = "true" ] && pass "unclassified repo → PR-only (fail safe)" || fail "unknownrepo not pr_only"
grep -q '"prOnly": *true' "$TMP/claude.log" && pass "PR-only flag reaches the coordinator prompt (args prOnly:true)" || fail "prOnly:true absent from claude argv"
grep -q 'NEVER merge' "$TMP/claude.log" && pass "PR-only prompt forbids merging in words" || fail "no NEVER merge line"
grep -q '"prOnly": *false' "$TMP/claude.log" && grep -q 'oracle' "$TMP/claude.log" && grep -q 'pr-gate.sh' "$TMP/claude.log" \
  && pass "merge repo prompt: merge only after oracle approve + pr-gate green" || fail "merge-mode prompt rules"

echo "── (d)+(e) happy path: coordinator, cap, proxy env, records ─────"
grep -q 'ARG=-p' "$TMP/claude.log" && pass "coordinator runs headless (claude -p)" || fail "no -p in claude argv"
grep -q 'use a workflow' "$TMP/claude.log" && grep -q 'workflows/overnight.js' "$TMP/claude.log" \
  && pass "prompt opts into the overnight workflow by path" || fail "workflow opt-in/path missing"
grep -q "HTTPS_PROXY=http://127.0.0.1:3456" "$TMP/claude.log" && grep -q 'NODE_EXTRA_CA_CERTS=.*teamclaude-ca.pem' "$TMP/claude.log" \
  && grep -q 'ANTHROPIC_BASE_URL=unset' "$TMP/claude.log" && grep -q '^DIRECT=unset$' "$TMP/claude.log" \
  && pass "coordinator gets the teamclaude proxy env, no base URL override, no direct-seat opt-in" || fail "proxy env not passed / direct opt-in leaked"
grep -q "CWD=$TMP/wt/" "$TMP/claude.log" && ! grep -q "CWD=$HOME/Projects" "$TMP/claude.log" \
  && pass "each coordinator runs in a fresh clone outside the synced tree" || fail "coordinator cwd: $(grep CWD "$TMP/claude.log" | head -2)"
grep -q 'Stop by' "$TMP/claude.log" && pass "prompt carries the wall-clock cap" || fail "no stop-by line in prompt"
[ "$(grep -c '^---$' "$TMP/claude.log")" -eq 3 ] && pass "three repos → three coordinator runs (one at a time)" || fail "coordinator runs: $(grep -c '^---$' "$TMP/claude.log")"
RID=$(gj .run_id)
{ [ -n "$RID" ] && grep -q "STARTED $RID at" "$TMP/state/overnight-pending.md"; } && pass "pending.md says STARTED <run_id> at <time>" || fail "pending.md STARTED line"
grep -q "FINISHED $RID" "$TMP/state/overnight-pending.md" && pass "runner appends FINISHED to pending.md" || fail "no FINISHED line"
grep -q "overnight-guarded: .*started $RID" "$TMP/state/dreamteam.log" && pass "every step logs to state/dreamteam.log" || fail "log line missing"
jq -e '.repos|length==3' "$TMP/state/overnight-guard.json" >/dev/null && jq -e '.issues==6' "$TMP/state/overnight-guard.json" >/dev/null \
  && pass "guard record lists repos + issue count" || fail "guard record repos/issues: $(cat "$TMP/state/overnight-guard.json")"
jq -e '.mode=="active" and .night and (.quota_guard.skipped==0)' "$TMP/plan-data/sweep-results.json" >/dev/null 2>&1 \
  && pass "started night → plan sweep-results.json (mode active, guard held nothing back)" || fail "plan sweep-results on start"
jq -e '.["jphein/realmwatch"]' "$TMP/state/overnight-rotation.json" >/dev/null 2>&1 && pass "rotation records last-swept per repo" || fail "rotation file"

echo "── runner stops on the cap and on the continuation floor ────────"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2
DEADLINE=$(( $(date +%s) + 20*60 )) FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -qi 'cap\|06:30\|stop'; } && pass "under an hour to the 06:30 cap → no start" || fail "near-cap started ($(gj .reason))"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2
FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 DREAMTEAM_QUOTA_SEQ="0.92 0.92 0.35" run_g >/dev/null
[ "$(grep -c '^---$' "$TMP/claude.log" 2>/dev/null)" -eq 1 ] && grep -q 'floor' "$TMP/state/dreamteam.log" \
  && pass "quota below the 0.40 continuation floor before repo 2 → runner stops after 1" || fail "floor stop (runs=$(grep -c '^---$' "$TMP/claude.log" 2>/dev/null))"

reset; mkqueue jphein/realmwatch:2; jq '.overnight.max_hours=0.5' "$TMP/config.json" > "$TMP/c2" && mv "$TMP/c2" "$TMP/config.json"
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -q 'night window'; } && pass "start more than max_hours before 06:30 → refused as a daytime start (xreview #4)" || fail "daytime start allowed ($(gj .decision) $(gj .reason))"

echo "── DRY_RUN prints the contained launch, starts nothing ──────────"
reset; mkqueue jphein/realmwatch:2
out=$(FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DRY_RUN=1 run_g 2>&1)
{ echo "$out" | grep -q 'systemd-run --user --scope' && echo "$out" | grep -q 'MemoryMax=24G' && echo "$out" | grep -q 'MemoryHigh=20G' \
  && echo "$out" | grep -q 'RuntimeMaxSec=' && echo "$out" | grep -q 'tmux -L dreamteam-nightly new-session -d' && [ ! -s "$TMP/claude.log" ]; } \
  && pass "DRY_RUN: scope with MemoryHigh/Max + RuntimeMaxSec cap + own tmux server, nothing started" || fail "dry run output: $out"
[ "$(gj .decision)" = "dry-run" ] && pass "DRY_RUN decision recorded as dry-run" || fail "dry-run decision $(gj .decision)"

reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_LOW5" DRY_RUN=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-start" ] && [ ! -e "$TMP/plan-data/sweep-results.json" ]; } \
  && pass "DRY_RUN never publishes sweep-results.json to the plan, even on a held night" || fail "dry run published to plan data"

echo "── one nightly start: a live previous run blocks a second ───────"
reset; mkqueue jphein/realmwatch:2
echo '{"decision":"started","run_id":"nightly-earlier"}' > "$TMP/state/overnight-guard.json"
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_PREV_LIVE=1 run_g >/dev/null
{ [ "$(gj .run_id)" = "nightly-earlier" ] && grep -q 'duplicate start refused: a previous nightly run is still live' "$TMP/state/dreamteam.log" && [ ! -s "$TMP/claude.log" ]; } \
  && pass "previous run still live → no second start, and the live run's record is left alone" || fail "prev-live: $(gj .run_id) $(tail -1 "$TMP/state/dreamteam.log")"

echo "── xreview 2026-11-14 hardening ─────────────────────────────────"
# #2 the night's first coordinator needs the full 0.70 guard, not the 0.40 floor
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 DREAMTEAM_QUOTA_SEQ="0.92 0.55" run_g >/dev/null
{ [ ! -s "$TMP/claude.log" ] && grep -q 'stop before realmwatch .*below the 0.7' "$TMP/state/dreamteam.log"; } \
  && pass "first coordinator re-checks the full 0.70 guard (0.55 at runner start → nothing runs)" || fail "first repo used the floor: $(grep runner "$TMP/state/dreamteam.log" | tail -2)"
# #2 watchdog: the pool drops under the floor mid-run → the coordinator is stopped
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 DREAMTEAM_QUOTA_SEQ="0.92 0.92 0.30" DREAMTEAM_WATCH_SEC=1 FAKE_CLAUDE_SLEEP=8 run_g >/dev/null
{ grep -q 'stopping realmwatch mid-run' "$TMP/state/dreamteam.log" && ! grep -q 'END-NOT-KILLED' "$TMP/claude.log"; } \
  && pass "watchdog stops a running coordinator when the pool falls under 0.40" || fail "watchdog: $(grep -c END-NOT-KILLED "$TMP/claude.log") $(tail -2 "$TMP/state/dreamteam.log")"
# #3 one start per night (marker), and a held lock exits without a second start
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "started" ] && grep -q 'duplicate start refused: already started for the night' "$TMP/state/dreamteam.log" \
   && [ "$(grep -c '^---$' "$TMP/claude.log")" -eq 1 ] && jq -e '.fleet==1' "$TMP/plan-data/sweep-results.json" >/dev/null; } \
  && pass "second start the same night → refused, the first run's record + sweep-results kept (xreview r2)" || fail "double start: $(gj .decision) runs=$(grep -c '^---$' "$TMP/claude.log") $(cat "$TMP/plan-data/sweep-results.json" 2>/dev/null)"
reset; mkqueue jphein/realmwatch:2
( exec 9>"$TMP/state/overnight-guarded.lock"; flock 9; FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null 9>&- )
{ [ ! -s "$TMP/claude.log" ] && grep -q 'holds .*overnight-guarded.lock' "$TMP/state/dreamteam.log"; } \
  && pass "a held guard lock → exit without starting" || fail "lock ignored"
# #1 PR-only guardrails: gh shim + pre-push hook
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
SHIM=$(grep -m1 '^PATH1=' "$TMP/claude.log" | cut -d= -f2)/gh
if [ -x "$SHIM" ]; then
  GH_LOG="$TMP/gh.log" "$SHIM" pr merge 12 --squash >/dev/null 2>&1; r1=$?
  GH_LOG="$TMP/gh.log" "$SHIM" api -X PUT repos/jphein/realmwatch/pulls/12/merge >/dev/null 2>&1; r2=$?
  GH_LOG="$TMP/gh.log" "$SHIM" api graphql -f query='mutation{mergePullRequest(input:{})}' >/dev/null 2>&1; r3=$?
  GH_LOG="$TMP/gh.log" "$SHIM" pr create --fill >/dev/null 2>&1; r4=$?
  { [ $r1 -eq 77 ] && [ $r2 -eq 77 ] && [ $r3 -eq 77 ] && [ $r4 -eq 0 ] && grep -q 'gh pr create --fill' "$TMP/gh.log"; } \
    && pass "PR-only gh shim refuses pr merge / REST merge / GraphQL merge, passes pr create to the real gh" || fail "shim rc: $r1 $r2 $r3 $r4"
else fail "PR-only coordinator has no gh shim first on PATH (PATH1=$(grep -m1 '^PATH1=' "$TMP/claude.log"))"; fi
HOOK=$(ls "$TMP"/wt/*/realmwatch/.git/hooks/pre-push 2>/dev/null | head -n1)
if [ -x "$HOOK" ]; then
  echo "refs/heads/fix/x abc refs/heads/main def" | "$HOOK" >/dev/null 2>&1; h1=$?
  echo "refs/heads/fix/x abc refs/heads/fix/x def" | "$HOOK" >/dev/null 2>&1; h2=$?
  { [ $h1 -ne 0 ] && [ $h2 -eq 0 ]; } && pass "PR-only pre-push hook refuses main, allows a branch" || fail "hook rc $h1 $h2"
else fail "no pre-push hook in the PR-only clone"; fi
reset; mkqueue techempower-org/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
! grep -q '^PATH1=.*/bin-starcharts' "$TMP/claude.log" && [ ! -e "$(ls -d "$TMP"/wt/*/starcharts 2>/dev/null | head -n1)/.git/hooks/pre-push" ] \
  && pass "merge repo gets no PR-only shim or hook (control: the guardrails are per-repo)" || fail "merge repo was shimmed"
# #5 spawned teammates pinned to the nightly scope; scope delegates
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
grep -q "^SCOPE=dreamteam-$(gj .run_id)$" "$TMP/claude.log" && pass "coordinator env pins scope-attach to the nightly scope (DREAMTEAM_SCOPE_NAME)" || fail "scope pin: $(grep '^SCOPE=' "$TMP/claude.log")"
jq -e '.fixed[0].number==7 and .fixed[0].pr==12' "$TMP/plan-data/sweep-results.json" >/dev/null 2>&1 \
  && pass "coordinator's SWEEP-RESULT line lands in the plan's sweep-results.json" || fail "sweep result fold: $(cat "$TMP/plan-data/sweep-results.json" 2>/dev/null)"
# #7 the tmux runner command survives a quote in a path: run the DRY_RUN's exact command string
reset; Q="$TMP/st'ate \$(touch $TMP/PWNED)"; mkdir -p "$Q"; cp "$TMP/config.json" "$Q/c.json"
mkqueue jphein/realmwatch:2; cp "$TMP/state/issues-queue.json" "$Q/"
out=$(FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DRY_RUN=1 DREAMTEAM_TEST=1 DREAMTEAM_STATE="$Q" DREAMTEAM_CONFIG="$Q/c.json" CLAUDE_PLUGIN_ROOT="$ROOT" \
  DREAMTEAM_WT_BASE="$TMP/wt" DREAMTEAM_CLAUDE_BIN="$BIN/claude-rec" DREAMTEAM_PLAN_DATA="$TMP/plan-data" DREAMTEAM_DEADLINE_EPOCH=$(( $(date +%s) + 6*3600 )) \
  GH_LOG="$TMP/gh.log" GIT_LOG="$TMP/git.log" CLAUDE_LOG="$TMP/claude.log" PATH="$BIN:$PATH" bash "$G" 2>&1)
echo "$out" | grep -q 'Delegate=yes' && pass "the scope is launched with Delegate=yes" || fail "no Delegate=yes"
AV=$(echo "$out" | sed -n 's/^DRY_RUN runner argv: //p'); RA=(); [ -f "$AV" ] && mapfile -d '' -t RA < "$AV"
echo "$out" | grep -q 'tmux -L dreamteam-nightly new-session -d -s [^ ]* -c [^ ]* env CLAUDE_PLUGIN_ROOT=' \
  && pass "tmux gets the runner as separate argv words (exec'd directly, no shell)" || fail "launch argv: $(echo "$out" | grep systemd-run)"
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_TEST=1 DREAMTEAM_QUOTA_SEQ="0.92" GH_LOG="$TMP/gh.log" GIT_LOG="$TMP/git.log" CLAUDE_LOG="$TMP/claude.log" PATH="$BIN:$PATH" \
  "${RA[@]}" >/dev/null 2>&1
{ [ "${#RA[@]}" -ge 6 ] && [ ! -e "$TMP/PWNED" ] && grep -q '^ARG=-p' "$TMP/claude.log" 2>/dev/null; } \
  && pass "the exact runner argv runs from a state path with a quote and \$( ) — no injection" || fail "argv run: n=${#RA[@]} pwned=$([ -e "$TMP/PWNED" ] && echo yes || echo no)"

# r2: the quota is probed AFTER the clone, right before the coordinator spends
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 SEQ_LOG="$TMP/seq.log" run_g >/dev/null
[ "$(tr '\n' ' ' < "$TMP/seq.log")" = "probe clone probe claude " ] && pass "runner order: guard probe → clone → probe → coordinator (xreview r2)" || fail "order: $(tr '\n' ' ' < "$TMP/seq.log")"
# r2: GraphQL from a file cannot be inspected → refused in a PR-only repo
SHIM=$(grep -m1 '^PATH1=' "$TMP/claude.log" | cut -d= -f2)/gh
GH_LOG="$TMP/gh.log" "$SHIM" api graphql -F query=@q.graphql >/dev/null 2>&1; [ $? -eq 77 ] && pass "PR-only shim refuses a GraphQL query read from a file" || fail "graphql @file passed"
# r3: shim parses per argument — query strings, trailing slashes, unreadable GraphQL bodies, split pr/merge
sh_rc(){ GH_LOG="$TMP/gh.log" "$SHIM" "$@" >/dev/null 2>&1; echo $?; }
R=$(printf '%s,' "$(sh_rc api --method PUT 'repos/o/r/pulls/1/merge?audit=nightly')" "$(sh_rc api -X PUT repos/o/r/pulls/1/merge/)" \
    "$(sh_rc api graphql --input req.json)" "$(sh_rc api graphql --input=req.json)" "$(sh_rc pr -R o/r merge 5)" "$(sh_rc alias set m 'pr merge')" \
    "$(sh_rc api -X PUT 'repos/o/r/pulls/1/merge#x')" "$(sh_rc api repos/o/r/merges -f base=main -f head=x)" \
    "$(sh_rc api https://api.github.com/graphql -X POST --input req.json)" "$(sh_rc api 'https://api.github.com/graphql?x=1' --input -)" \
    "$(sh_rc api -X PATCH repos/o/r/pulls/1 --input body.json)" "$(sh_rc api graphql -f 'query={viewer{login}}')" "$(sh_rc pr close 5)" \
    "$(sh_rc pr edit 5 --base main)" "$(sh_rc api repos/o/r/issues/5/comments -f body=x)" "$(sh_rc workflow run deploy)" "$(sh_rc secret list)" \
    "$(sh_rc pr -R o/r diff 5)" "$(sh_rc pr --repo o/r merge 5)" "$(sh_rc api -XPOST repos/o/r/pulls/1/merge)" "$(sh_rc api --method=POST repos/o/r/x)" \
    "$(sh_rc api -iX POST repos/o/r/x)" "$(sh_rc api -X GET repos/o/r/issues/7/comments)" "$(sh_rc api -X GET repos/o/r/issues/7/timeline)" \
    "$(sh_rc issue view 7 --comments)" "$(sh_rc issue comment 7 --body hi)" "$(sh_rc api -X GET repos/o/r/x -f q=@f)" \
    "$(sh_rc issue view 7 --json comments)" "$(sh_rc issue view 7 --comments=true)" "$(sh_rc pr view 5 --json title,comments)" \
    "$(sh_rc pr view 5 --json reviews)" "$(sh_rc pr view 5 -c)" "$(sh_rc pr list --json latestReviews)" \
    "$(sh_rc issue view 7 -wc)" "$(sh_rc api repos/o/r/issues/7/c%6fmments)" "$(sh_rc api repos/o/r//issues/7/comments)" \
    "$(sh_rc api repos/o/r/issues/7/../7/comments)" "$(sh_rc api user)" "$(sh_rc api https://evil.example/x)" "$(sh_rc api REPOS/o/r/issues/7/COMMENTS)" \
    "$(sh_rc api repos/o/r/contents/../issues/7/comments)" "$(sh_rc api repos/o/r/contents/a//b)" "$(sh_rc api repos/o/r/contents/%2e%2e/x)")
[ "$R" = "77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77," ] && pass "allowlist shim refuses merge in every spelling, any graphql, non-GET or bodied api, pr close/edit, workflow, secret, alias" || fail "shim refusals: $R"
R=$(printf '%s,' "$(sh_rc pr create --title 'merge two lists' --fill)" "$(sh_rc api repos/o/r/pulls/1)" "$(sh_rc api -X GET repos/o/r/issues -f state=open)" "$(sh_rc pr view 5 --json state)" \
    "$(sh_rc pr diff 5 -R o/r)" "$(sh_rc issue view 7 --repo o/r --json title,body)" "$(sh_rc pr comment 5 --body 'merge later')" "$(sh_rc api --paginate -H 'Accept: x' --jq .x repos/o/r/pulls)" \
    "$(sh_rc api https://api.github.com/repos/o/r/commits/abc123/check-runs)" "$(sh_rc api /repos/o/r/pulls/5/files)" "$(sh_rc api repos/o/r/contents/src/a.py?ref=x)")
[ "$R" = "0,0,0,0,0,0,0,0,0,0,0," ] && grep -q '^gh api --paginate -H Accept: x --jq .x repos/o/r/pulls$' "$TMP/gh.log" && pass "allowlist passes reads, explicit-GET api with fields, pr create/diff/comment, and hands the real gh the exact argv" || fail "shim false refusals: $R"
# r3: duplicate detection precedes every record — a held-quota or no-work restart leaves the started run's record
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null; RID1=$(gj .run_id); SW1=$(cat "$TMP/plan-data/sweep-results.json")
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_LOW5" DREAMTEAM_INLINE=1 run_g >/dev/null
FAKE_GH_realmwatch='[]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .run_id)" = "$RID1" ] && [ "$(gj .decision)" = "started" ] && [ "$(cat "$TMP/plan-data/sweep-results.json")" = "$SW1" ]; } \
  && pass "restarts that night under a low quota or an empty queue leave the started run's record + results untouched (xreview r3)" || fail "dup ordering: $(gj .decision) $(gj .run_id) vs $RID1"

# security review: provenance — only issues whose author AND dream labeller hold write access are worked
reset; mkqueue jphein/realmwatch:3
FAKE_GH_realmwatch='[{"number":7,"title":"mine","user":{"login":"jphein"}},{"number":8,"title":"outsider","user":{"login":"stranger"}}]' \
  FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ grep -q '"number":7' "$TMP/claude.log" && ! grep -q '"number":8' "$TMP/claude.log" && grep -q "realmwatch#8 skipped — author 'stranger'" "$TMP/state/dreamteam.log"; } \
  && pass "an outsider-authored dream issue is skipped as untrusted input (a maintainer's is worked)" || fail "author provenance: $(grep -o '"number":[0-9]*' "$TMP/claude.log" | tr '\n' ' ')"
reset; mkqueue jphein/realmwatch:2
FAKE_EVENTS='[{"event":"labeled","label":{"name":"dream"},"actor":{"login":"jphein"}},{"event":"labeled","label":{"name":"dream"},"actor":{"login":"helper"}}]' \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-work" ] && grep -q "labeller 'helper' lacks write" "$TMP/state/dreamteam.log"; } \
  && pass "a dream label last added by a read-only account → not worked" || fail "labeller provenance: $(gj .decision)"
reset; mkqueue jphein/realmwatch:2
FAKE_EVENTS_P2='[{"event":"unlabeled","label":{"name":"dream"},"actor":{"login":"helper"}},{"event":"labeled","label":{"name":"dream"},"actor":{"login":"helper"}}]' \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "no-work" ] && pass "a read-only relabel on the SECOND events page is seen (paginated) → not worked" || fail "page-2 relabel missed: $(gj .decision)"
reset; mkqueue jphein/realmwatch:2
FAKE_EVENTS_FAIL=1 FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "no-work" ] && pass "an unreadable label history → untrusted (fail closed)" || fail "events failure trusted: $(gj .decision)"
reset; mkqueue jphein/realmwatch:2
FAKE_PERM_helper=write FAKE_EVENTS='[{"event":"labeled","label":{"name":"dream"},"actor":{"login":"helper"}}]' \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "started" ] && pass "a labeller with write access is trusted (control)" || fail "write labeller rejected: $(gj .reason)"
# comments are input too: an untrusted commenter (or an unreadable comment list) → issue skipped
reset; mkqueue jphein/realmwatch:2
FAKE_COMMENTS='[{"user":{"login":"jphein"}},{"user":{"login":"stranger"}}]' \
  FAKE_GH_realmwatch='[{"number":7,"title":"mine","user":{"login":"jphein"},"comments":2}]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-work" ] && grep -q "commenter 'stranger' lacks write" "$TMP/state/dreamteam.log"; } \
  && pass "an issue with a comment from a non-writer is skipped" || fail "comment provenance: $(gj .decision)"
reset; mkqueue jphein/realmwatch:2
FAKE_COMMENTS_FAIL=1 FAKE_GH_realmwatch='[{"number":7,"title":"mine","user":{"login":"jphein"},"comments":1}]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "no-work" ] && pass "an unreadable comment list → untrusted" || fail "comment read failure trusted"
reset; mkqueue jphein/realmwatch:2
FAKE_COMMENTS='[{"user":{"login":"jphein"}}]' FAKE_GH_realmwatch='[{"number":7,"title":"mine","user":{"login":"jphein"},"comments":1}]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "started" ] && pass "comments only from writers → worked (control)" || fail "writer comments rejected: $(gj .reason)"
# hook honours the clone's real default branch (origin/HEAD → develop), not only main/master
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
HOOK=$(ls "$TMP"/wt/*/realmwatch/.git/hooks/pre-push 2>/dev/null | head -n1); HR="$TMP/hookrepo"
/usr/bin/git init -q "$HR" && /usr/bin/git -C "$HR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
( cd "$HR" && echo "refs/heads/x a refs/heads/develop b" | PATH="/usr/bin:/bin" "$HOOK" >/dev/null 2>&1 ); h1=$?
( cd "$HR" && echo "refs/heads/x a refs/heads/fix/y b" | PATH="/usr/bin:/bin" "$HOOK" >/dev/null 2>&1 ); h2=$?
{ [ -x "$HOOK" ] && [ $h1 -ne 0 ] && [ $h2 -eq 0 ]; } && pass "pre-push hook refuses the clone's real default branch (develop via origin/HEAD)" || fail "default-branch hook rc $h1 $h2"

# r2: a failed contained launch does not consume the night
reset; mkqueue jphein/realmwatch:2; mkdir -p "$TMP/failbin"; printf '#!/bin/bash\nexit 1\n' > "$TMP/failbin/systemd-run"; chmod +x "$TMP/failbin/systemd-run"
DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" DREAMTEAM_CONFIG="$TMP/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_WT_BASE="$TMP/wt" \
  DREAMTEAM_CLAUDE_BIN="$BIN/claude-rec" DREAMTEAM_PLAN_DATA="$TMP/plan-data" DREAMTEAM_DEADLINE_EPOCH=$(( $(date +%s) + 6*3600 )) DREAMTEAM_PREV_LIVE=0 \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" GH_LOG="$TMP/gh.log" PATH="$TMP/failbin:$BIN:$PATH" bash "$G" >/dev/null 2>&1
{ [ ! -e "$TMP/state/overnight-night" ] && [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -q 'launch failed' && grep -q '^LAUNCH FAILED' "$TMP/state/overnight-pending.md"; } \
  && pass "a failed launch is recorded and does NOT mark the night (a retry can still start)" || fail "failed launch: marker=$([ -e "$TMP/state/overnight-night" ] && echo yes || echo no) $(gj .reason)"

echo "── 07:03 morning briefing reports the night ─────────────────────"
printf '#!/bin/bash\nexit 0\n' > "$BIN/journalctl"; chmod +x "$BIN/journalctl"
brief(){ DREAMTEAM_STATE="$TMP/state" CLAUDE_PLUGIN_ROOT="$ROOT" GH_LOG="$TMP/gh.log" PATH="$BIN:$PATH" \
         bash "$ROOT/scripts/morning-briefing.sh" --quiet --repo "$TMP" >/dev/null 2>&1; cat "$TMP/state/briefing-$(date +%F).md" 2>/dev/null; }
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null; RID=$(gj .run_id)
b=$(brief); echo "$b" | grep -q "PRs\*\*" && echo "$b" | grep -q "Nightly sweep\*\*: started $RID: 2 dream issue(s) in realmwatch; FINISHED $RID at" \
  && pass "briefing: a started run is overnight activity and names run_id + FINISHED" || fail "briefing on start: $b"
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_LOW5" run_g >/dev/null
b=$(brief); echo "$b" | grep -q 'Nightly sweep\*\*: no-start: 5-hour pool at 0.69' \
  && pass "briefing: a held night says why" || fail "briefing on hold: $b"

echo "── issues-queue.py next_sweep: guarded timer → mode guarded ─────"
mkdir -p "$TMP/sysd"
cat > "$TMP/sysd/systemctl" <<'S'
#!/bin/bash
case "$*" in
  *is-active*dreamteam-nightly-guarded.timer*) [ "${FAKE_GUARDED:-0}" = 1 ] && { echo active; exit 0; }; echo inactive; exit 3;;
  *NextElapseUSecRealtime*dreamteam-nightly-guarded.timer*) echo "Sat 2026-11-14 23:30:00 PST";;
  *NextElapseUSecRealtime*) echo "n/a";;
  *cat*) exit 1;;
esac
S
chmod +x "$TMP/sysd/systemctl"
ns(){ PATH="$TMP/sysd:$PATH" FAKE_GUARDED="$1" python3 -c "
import importlib.util, datetime, sys
sp = importlib.util.spec_from_file_location('iq', '$ROOT/scripts/issues-queue.py'); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
mode, at = m.next_sweep(datetime.datetime.now().astimezone()); print(mode, at.strftime('%H:%M'))"; }
[ "$(ns 1)" = "guarded 23:30" ] && pass "guarded timer active → next_sweep mode guarded at its elapse" || fail "next_sweep guarded: $(ns 1)"
[ "$(ns 0 | cut -d' ' -f1)" = "pilot" ] && pass "guarded timer inactive → pilot (unchanged fallback)" || fail "next_sweep fallback: $(ns 0)"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
