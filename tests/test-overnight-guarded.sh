#!/usr/bin/env bash
# dreamteam — regression tests for the GUARDED nightly sweep (scripts/overnight-guarded.sh,
# systemd/dreamteam-nightly-guarded.{service,timer}). JP 2026-11-14 06:40 "go" on ask 4c77a5b8f3ef:
# "runs 23:30 with the 70 % quota guard, PR-only in production repos, oracle review before any merge".
#
# HERMETIC — nothing real is started, spent or mutated:
#   • curl is PATH-stubbed: serves $FAKE_QUOTA (JSON) or fails when FAKE_QUOTA_DOWN=1 (proxy down); the
#     /teamclaude/status pre-flight answers HTTP $FAKE_STATUS_CODE (200), logged as "status" in $STATUS_LOG.
#   • gh is PATH-stubbed: `gh api repos/<r>/issues…` serves $FAKE_GH_<name> or [] ; logs argv.
#   • git is PATH-stubbed: `git clone` just makes the directory; logs argv.
#   • claude is a recorder (DREAMTEAM_CLAUDE_BIN): writes its argv + cwd + proxy env, prints {}.
#   • systemd-run / tmux are never reached: DREAMTEAM_INLINE=1 runs the runner in-process, and
#     the scope+tmux launch line is asserted from DRY_RUN=1 output instead. Both are ALSO PATH-stubbed, so a
#     test that forgets DRY_RUN/INLINE cannot reach the real ones (2026-11-15: a red-phase test did, twice):
#     `tmux … ls` answers "no server"; any launch is logged to $TMP/launch-attempts.txt (outside reset's *.log sweep) and exits 97; the suite's
#     last check requires that log to be empty.
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
export DREAMTEAM_CHECKS_DIR="$TMP/checks" DREAMTEAM_CHECK_HOST=familiar   # never a real check line
BIN="$TMP/bin"; mkdir -p "$BIN"

cat > "$BIN/curl" <<'S'
#!/bin/bash
for a in "$@"; do
  case "$a" in */teamclaude/status)
    echo status >> "${STATUS_LOG:-/dev/null}"; echo status >> "${SEQ_LOG:-/dev/null}"
    [ "${FAKE_QUOTA_DOWN:-0}" = "1" ] && { printf 000; exit 7; }
    printf '%s' "${FAKE_STATUS_CODE:-200}"; exit "${FAKE_STATUS_RC:-0}" ;;
  esac
done
echo probe >> "${SEQ_LOG:-/dev/null}"
[ "${FAKE_QUOTA_DOWN:-0}" = "1" ] && exit 7
echo "${FAKE_QUOTA:-}"
S
cat > "$BIN/systemd-run" <<S
#!/bin/bash
echo "systemd-run \$*" >> "$TMP/launch-attempts.txt"; exit 97
S
cat > "$BIN/tmux" <<S
#!/bin/bash
for a in "\$@"; do [ "\$a" = ls ] && exit 1; done   # no live nightly server, whatever the real host runs
echo "tmux \$*" >> "$TMP/launch-attempts.txt"; exit 97
S
cat > "$BIN/gh" <<'S'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
if [ "${1:-} ${2:-}" = "pr create" ]; then
  case "${FAKE_CREATE:-ok}" in
    ok) echo "https://github.com/jphein/realmwatch/pull/12"; exit 0;;
    exists) echo "a pull request for branch x already exists: https://github.com/jphein/realmwatch/pull/55" >&2; echo "https://github.com/jphein/realmwatch/pull/55"; exit 1;;
    body) echo "Creating pull request"; echo "see https://github.com/jphein/realmwatch/pull/56 for context"; echo "https://github.com/outsider/x/pull/57"; exit 0;;
  esac
fi
for a in "$@"; do
  case "$a" in
    repos/*/pulls/[0-9]*) echo "${FAKE_HEAD_REPO:-jphein/realmwatch}"; exit 0;;
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
echo claude >> "${SEQ_LOG:-/dev/null}"; echo $$ > "${CLAUDE_LOG%.log}.pid"
{ echo "CWD=$PWD"; echo "HTTPS_PROXY=${HTTPS_PROXY:-}"; echo "NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-}";
  echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-unset}"; echo "SCOPE=${DREAMTEAM_SCOPE_NAME:-unset}"; echo "OWNED=${DREAMTEAM_SCOPE_OWNED:-unset}"; echo "BGWAIT=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}"; echo "DIRECT=${TEAMCLAUDE_ALLOW_DIRECT:-unset}${TEAMCLAUDE_BYPASS:-}"; echo "PATH1=${PATH%%:*}"
  printf 'ARG=%s\n' "$@"; echo "---"; } >> "$CLAUDE_LOG"
# FAKE_TERM_DELAY: the coordinator takes that long to exit on TERM (so a signal can land while the runner waits)
[ -n "${FAKE_TERM_DELAY:-}" ] && trap 'sleep "$FAKE_TERM_DELAY"; exit 143' TERM
if [ -n "${FAKE_STUBBORN:-}" ]; then ( trap '' TERM; exec sleep 300 ) & echo $! > "${CLAUDE_LOG%.log}.stubborn"; fi
if [ -n "${FAKE_CLAUDE_SLEEP:-}" ]; then sleep "$FAKE_CLAUDE_SLEEP" & wait $!; echo "END-NOT-KILLED" >> "$CLAUDE_LOG"; fi
# like a real fixer: open a PR through whatever gh is first on PATH (the shim in a PR-only repo)
gh pr create --fill --head fix/x >/dev/null 2>&1 || true
if [ -n "${FAKE_CLAUDE_RC:-}" ]; then echo "[claude] teamclaude proxy :3456 down" >&2; exit "$FAKE_CLAUDE_RC"; fi
echo '{"type":"result","result":"done\nSWEEP-RESULT {\"fixed\":[{\"repo\":\"jphein/realmwatch\",\"number\":7,\"pr\":12,\"sha\":\"\"}],\"reviewed_not_merged\":[{\"repo\":\"jphein/realmwatch\",\"pr\":42}],\"too_large\":[]}"}'
S
cat > "$BIN/tmux-probe" <<'S'
#!/bin/bash
# list-panes -F '#{pane_dead}' on the runner's session: FAKE_SESSION alive (default) | gone | noserver | deadpane |
# denied | weird. The error texts are tmux 3.6's own words (checked against real tmux, 2026-11-17).
echo "probe $*" >> "${PROBE_LOG:-/dev/null}"
case "${FAKE_SESSION:-alive}" in
  alive) echo 0; exit 0;;
  deadpane) echo 1; exit 0;;
  gone) echo "can't find session: nightly-t" >&2; exit 1;;
  noserver) echo "error connecting to /tmp/tmux-1000/dreamteam-nightly (No such file or directory)" >&2; exit 1;;
  denied) echo "error connecting to /tmp/tmux-1000/dreamteam-nightly (Permission denied)" >&2; exit 1;;
  *) echo "lost server" >&2; exit 1;;
esac
S
cat > "$BIN/notify-rec" <<'S'
#!/bin/bash
[ -n "${FAKE_NOTIFY_SLEEP:-}" ] && sleep "$FAKE_NOTIFY_SLEEP"
printf '%s\n' "$*" >> "$NOTIFY_LOG"
exit "${FAKE_NOTIFY_RC:-0}"
S
chmod +x "$BIN"/*

Q_OK='{"aggregate":{"fiveHour":{"remaining":0.92},"sevenDay":null,"weeklyShared":{"remaining":0.61}}}'
Q_LOW5='{"aggregate":{"fiveHour":{"remaining":0.69},"weeklyShared":{"remaining":0.9}}}'
Q_LOW7='{"aggregate":{"fiveHour":{"remaining":0.95},"sevenDay":{"remaining":0.29}}}'
Q_NO7='{"aggregate":{"fiveHour":{"remaining":0.95},"sevenDay":null}}'
I2='[{"number":7,"title":"fix seven","body":"BODY-SEVEN steps","user":{"login":"jphein"},"labels":[{"name":"dream"}]},{"number":9,"title":"fix nine","user":{"login":"jphein"},"labels":[{"name":"dream"}]}]'

mkcfg(){ cat > "$TMP/config.json" <<'J'
{"scope":{"memoryHigh":"20G","memoryMax":"24G","memorySwapMax":"8G"},
 "overnight":{"five_hour_min":0.70,"seven_day_min":0.30,"continue_five_hour_min":0.40,
   "max_repos":3,"max_issues_per_repo":5,"stop_at":"06:30",
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
  DREAMTEAM_TMUX_PROBE="$BIN/tmux-probe" DREAMTEAM_NOTIFY_CMD="$BIN/notify-rec" NOTIFY_LOG="$TMP/notify.txt" PROBE_LOG="$TMP/probe.txt" \
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

# the watch pair (2026-11-17): every 5 min through the night, installed by timers-ctl
WT="$ROOT/systemd/dreamteam-nightly-watch.timer"; WS="$ROOT/systemd/dreamteam-nightly-watch.service"
grep -q -- '--watch' "$WS" 2>/dev/null && grep -q '^Type=oneshot' "$WS" && grep -q 'dreamteam-nightly-watch.timer' "$ROOT/scripts/timers-ctl.sh" \
  && [ "$(grep '^OnCalendar=' "$WT" | cut -d= -f2- | tr '\n' '|')" = '*-*-* 23:35/5:00|*-*-* 00..06:00/5:00|*-*-* 07:00:00|' ] \
  && systemd-analyze calendar '*-*-* 23:35/5:00' '*-*-* 00..06:00/5:00' '*-*-* 07:00:00' >/dev/null 2>&1 \
  && pass "watch pair: oneshot --watch, a 5-min calendar, installed by timers-ctl" || fail "watch pair shape"
if command -v systemd-analyze >/dev/null 2>&1; then
  out=$(systemd-analyze --user verify "$WT" "$WS" 2>&1 | grep 'dreamteam-nightly-watch'); [ -z "$out" ] && pass "systemd-analyze --user verify: watch timer+service" || fail "systemd-analyze watch: $out"
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
# the pre-flight (Sen 2026-11-15): /teamclaude/status must answer 200 before the quota is even read
reset; mkqueue jphein/starcharts:2
: > "$TMP/status.log"; : > "$TMP/seq.log"
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" FAKE_STATUS_CODE=503 STATUS_LOG="$TMP/status.log" SEQ_LOG="$TMP/seq.log" run_g >/dev/null; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -q '503' && gj .reason | grep -q 'teamclaude/status' \
  && [ -s "$TMP/status.log" ] && ! grep -q probe "$TMP/seq.log" && [ ! -s "$TMP/claude.log" ]; } \
  && pass "status pre-flight 503 with a healthy quota → no start, the quota is never read" || fail "status 503 (rc=$rc $(gj .decision) $(gj .reason))"
reset; mkqueue jphein/starcharts:2
: > "$TMP/status.log"
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" STATUS_LOG="$TMP/status.log" DRY_RUN=1 run_g >/dev/null
{ [ "$(gj .decision)" = "dry-run" ] && [ "$(grep -c status "$TMP/status.log")" = 1 ]; } \
  && pass "status 200 → the guard goes on to the quota (one pre-flight probe)" || fail "status 200 path ($(gj .decision) $(grep -c status "$TMP/status.log"))"
reset; mkqueue jphein/starcharts:2; : > "$TMP/seq.log"
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" SEQ_LOG="$TMP/seq.log" DRY_RUN=1 run_g >/dev/null
[ "$(head -2 "$TMP/seq.log" | tr '\n' ' ')" = "status probe " ] \
  && pass "the pre-flight runs before the quota probe (status, then probe)" || fail "order: $(tr '\n' ' ' < "$TMP/seq.log")"
reset; mkqueue jphein/starcharts:2; : > "$TMP/seq.log"
FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" FAKE_STATUS_RC=28 SEQ_LOG="$TMP/seq.log" run_g >/dev/null
{ [ "$(gj .decision)" = "no-start" ] && gj .reason | grep -q 'rc 28' && ! grep -q probe "$TMP/seq.log"; } \
  && pass "a 200 whose transfer failed (curl rc 28) → no start" || fail "200 + curl failure ($(gj .decision) $(gj .reason))"
# the header tells the truth about the wrapper since teamclaude #66 (exit 69, not a silent fallback)
! grep -q 'silently falls back' "$G" "$ROOT/docs/OVERNIGHT-GUARDED.md" && grep -q 'exits 69' "$G" \
  && pass "header and contract doc: the wrapper exits 69 when the proxy is down (no stale fallback claim)" || fail "stale 'silently falls back' text"
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
[ "$(tr '\n' ' ' < "$TMP/seq.log")" = "status probe clone probe claude " ] && pass "runner order: status pre-flight → guard probe → clone → probe → coordinator (xreview r2)" || fail "order: $(tr '\n' ' ' < "$TMP/seq.log")"
# r2: GraphQL from a file cannot be inspected → refused in a PR-only repo
SHIM=$(grep -m1 '^PATH1=' "$TMP/claude.log" | cut -d= -f2)/gh
GH_LOG="$TMP/gh.log" "$SHIM" api graphql -F query=@q.graphql >/dev/null 2>&1; [ $? -eq 77 ] && pass "PR-only shim refuses a GraphQL query read from a file" || fail "graphql @file passed"
# shim: allowlist bound to known numbers — vetted issues 7 and 9, and PRs this shim created
sh_rc(){ GH_LOG="$TMP/gh.log" "$SHIM" "$@" >/dev/null 2>&1; echo $?; }
: > "$(dirname "$SHIM")/prs"
R=$(printf '%s,' "$(sh_rc pr diff 12)" "$(sh_rc api repos/jphein/realmwatch/pulls/12/files)")
[ "$R" = "77,77," ] && pass "before this run opens PR 12, its diff and files are refused" || fail "unbound PR read: $R"
R=$(printf '%s,' "$(sh_rc pr create --title 'merge two lists' --fill --head fix/two-lists)")
{ [ "$R" = "0," ] && grep -qx 12 "$(dirname "$SHIM")/prs"; } && pass "pr create runs and the shim records the PR it opened (#12)" || fail "pr create: $R $(cat "$(dirname "$SHIM")/prs")"
R=$(printf '%s,' "$(sh_rc pr diff 12)" "$(sh_rc pr checks 12)" "$(sh_rc pr comment 12 --body 'merge later')" "$(sh_rc label list)" \
    "$(sh_rc api repos/jphein/realmwatch/branches/main)" "$(sh_rc api /repos/jphein/realmwatch/pulls/12/files)" "$(sh_rc api https://api.github.com/repos/jphein/realmwatch/labels)" \
    "$(sh_rc api repos/jphein/realmwatch/contents/src/a.py)" "$(sh_rc api --paginate -H 'Accept: x' --jq .x repos/jphein/realmwatch/branches)" "$(sh_rc api -X GET repos/jphein/realmwatch)")
[ "$R" = "0,0,0,0,0,0,0,0,0,0," ] && grep -q '^gh api --paginate -H Accept: x --jq .x repos/jphein/realmwatch/branches --hostname github.com$' "$TMP/gh.log" && grep -q '^gh pr diff 12 --repo github.com/jphein/realmwatch$' "$TMP/gh.log" \
  && pass "allowed: own-PR diff/checks/comment, label list, bound api reads; the real gh gets the exact argv" || fail "false refusals: $R"
R=$(printf '%s,' "$(sh_rc pr view 12)" "$(sh_rc pr list)" "$(sh_rc pr status)" "$(sh_rc issue list)" "$(sh_rc issue view 99)" "$(sh_rc pr diff 99)" \
    "$(sh_rc pr comment 99 --body x)" "$(sh_rc api repos/jphein/realmwatch/pulls)" "$(sh_rc api repos/jphein/realmwatch/pulls/12)" "$(sh_rc api repos/jphein/realmwatch/issues)" \
    "$(sh_rc api repos/jphein/realmwatch/issues/99)" "$(sh_rc api repos/jphein/realmwatch/pulls/99/files)" "$(sh_rc api -X PUT 'repos/jphein/realmwatch/pulls/12/merge?audit=nightly')" \
    "$(sh_rc api graphql --input req.json)" "$(sh_rc api https://api.github.com/graphql -X POST --input req.json)" "$(sh_rc pr -R jphein/realmwatch merge 12)" \
    "$(sh_rc pr merge 12)" "$(sh_rc alias set m 'pr merge')" "$(sh_rc api repos/jphein/realmwatch/merges -f base=main -f head=x)" "$(sh_rc api -XPOST repos/jphein/realmwatch/labels)" \
    "$(sh_rc api --method=POST repos/jphein/realmwatch/labels)" "$(sh_rc api -iX POST repos/jphein/realmwatch/labels)" "$(sh_rc api repos/jphein/realmwatch/labels -f name=x)" \
    "$(sh_rc issue view 7 --comments)" "$(sh_rc issue view 7 --json comments)" "$(sh_rc issue view 7 --comments=true)" "$(sh_rc issue view 7 -wc)" \
    "$(sh_rc pr checks 12 --json comments)" "$(sh_rc issue comment 7 --body hi)" "$(sh_rc api repos/jphein/realmwatch/issues/7/comments)" "$(sh_rc api repos/jphein/realmwatch/issues/7/timeline)" \
    "$(sh_rc api repos/jphein/realmwatch/contents/../issues/7/comments)" "$(sh_rc api repos/jphein/realmwatch/contents/a//b)" "$(sh_rc api repos/jphein/realmwatch/contents/%2e%2e/x)" \
    "$(sh_rc api user)" "$(sh_rc api https://evil.example/x)" "$(sh_rc workflow run deploy)" "$(sh_rc secret list)" "$(sh_rc pr edit 12 --base main)" "$(sh_rc pr close 12)")
[ "$R" = "$(printf '77,%.0s' $(seq 40))" ] && pass "refused: listings, pr view, unvetted issues, other PRs, every merge spelling, mutations, comments/reviews, traversal, other hosts" || fail "refusals: $R"
# PR ledger is not poisonable: a failed create, a URL in other output, another repo's URL, --dry-run/--web
FAKE_CREATE=exists sh_rc pr create --fill >/dev/null; FAKE_CREATE=body sh_rc pr create --fill >/dev/null
R=$(printf '%s,' "$(sh_rc pr create --fill --dry-run)" "$(sh_rc pr create --web)" "$(sh_rc pr diff 55)" "$(sh_rc pr diff 56)" "$(sh_rc pr diff 57)" \
    "$(sh_rc pr create --head outsider:payload --base main --title t --body b)" "$(sh_rc pr create -H outsider:payload --fill)" "$(sh_rc pr create --head=outsider:payload --fill)" \
    "$(sh_rc pr create -Houtsider:payload --fill)")
{ [ "$R" = "77,77,77,77,77,77,77,77,77," ] && [ "$(sort -u "$(dirname "$SHIM")/prs" | tr '\n' ' ')" = "12 " ]; } \
  && pass "PR ledger records only a successful create's exact own-repo URL (no dry-run/web/fork head, no error or body URLs)" || fail "ledger: $R [$(tr '\n' ' ' < "$(dirname "$SHIM")/prs")]"
# writer-controlled data only (xreview r11): run logs, run titles, commit messages, check-run summaries and
# fork-ref contents can all carry a non-writer's text
R=$(printf '%s,' "$(sh_rc run view 123 --log --repo jphein/realmwatch)" "$(sh_rc run list)" "$(sh_rc api repos/jphein/realmwatch/actions/runs)" \
    "$(sh_rc api repos/jphein/realmwatch/actions/jobs/5/logs)" "$(sh_rc api repos/jphein/realmwatch/commits/abc123)" "$(sh_rc api repos/jphein/realmwatch/commits/abc123/check-runs)" \
    "$(sh_rc api 'repos/jphein/realmwatch/contents/a.py?ref=refs/pull/9/head')" "$(sh_rc api -X GET repos/jphein/realmwatch/contents/a.py -f ref=refs/pull/9/head)" \
    "$(sh_rc api repos/jphein/realmwatch/check-runs/5)")
[ "$R" = "$(printf '77,%.0s' $(seq 9))" ] && pass "refused: run logs/lists, actions, commits, check-runs, fork-ref contents (query or field)" || fail "writer-only data: $R"
# xreview r15: no live issue reads — the frozen snapshot is the only issue text an agent sees
R=$(printf '%s,' "$(sh_rc issue view 7)" "$(sh_rc issue view 7 --json title,body)" "$(sh_rc api repos/jphein/realmwatch/issues/7)" "$(sh_rc issue list)")
[ "$R" = "77,77,77,77," ] && pass "no live issue reads in a PR-only repo (vetted or not)" || fail "live issue read: $R"
grep -q 'BODY-SEVEN steps' "$TMP/claude.log" && grep -q 'do not fetch them again' "$TMP/claude.log" \
  && pass "the coordinator gets the vetted issue body as a planning-time snapshot" || fail "snapshot missing from the prompt"
# xreview r13: gh may infer a FORK head from the clone's remotes; the ledger checks the PR's real head repo
: > "$(dirname "$SHIM")/prs"
FAKE_HEAD_REPO=outsider/realmwatch sh_rc pr create --base release --title t --body b >/dev/null
R=$(sh_rc pr diff 12)
{ [ "$R" = "77" ] && [ ! -s "$(dirname "$SHIM")/prs" ] && grep -q 'gh api --hostname github.com repos/jphein/realmwatch/pulls/12' "$TMP/gh.log"; } \
  && pass "a created PR whose head repo is a fork never enters the ledger (head.repo verified)" || fail "fork-head ledger: diff=$R ledger=[$(cat "$(dirname "$SHIM")/prs")]"
sh_rc pr create --fill --head fix/x >/dev/null; [ "$(cat "$(dirname "$SHIM")/prs")" = "12" ] && pass "control: an own-repo head is recorded" || fail "own head not recorded"
R=$(printf '%s,' "$(GH_CONFIG_DIR=/tmp/evil sh_rc issue view 7)" "$(XDG_CONFIG_HOME=/tmp/evil sh_rc issue view 7)" "$(sh_rc api --hostname ghe.evil repos/jphein/realmwatch)")
[ "$R" = "77,77,77," ] && pass "gh config dir pinned; api --hostname is the shim's alone" || fail "config pin: $R"
# repo binding (xreview r10): a vetted NUMBER in another repo is not vetted
R=$(printf '%s,' "$(sh_rc issue view 7 --repo outsider/x)" "$(sh_rc issue view 7 -R outsider/x)" "$(sh_rc issue view 7 --repo=outsider/x)" \
    "$(sh_rc api repos/outsider/x/issues/7)" "$(sh_rc api https://api.github.com/repos/outsider/x/issues/7)" "$(sh_rc repo view outsider/x)" \
    "$(GH_REPO=outsider/x sh_rc issue view 7)" "$(sh_rc pr diff 12 --repo outsider/x)" "$(sh_rc label list -R outsider/x)" \
    "$(sh_rc pr comment 12 -Routsider/x --body hi)" "$(sh_rc label list -Routsider/x)" "$(sh_rc repo view --web outsider/x)" "$(sh_rc repo view -- outsider/x)" "$(sh_rc repo view jphein/realmwatch)" \
    "$(sh_rc repo clone jphein/realmwatch)" "$(GH_HOST=ghe.evil.example sh_rc issue view 7)" "$(sh_rc issue view 7 --repo ghe.evil.example/jphein/realmwatch)" \
    "$(sh_rc issue view 7 -- --repo outsider/x)")
[ "$R" = "$(printf '77,%.0s' $(seq 18))" ] && pass "bound to this repo on github.com: --repo/-R/-Rx/--repo=/GH_REPO/GH_HOST/other host/api owner/repo view args/-- refused" || fail "repo binding: $R"
R=$(printf '%s,' "$(sh_rc pr diff 12 --repo JPhein/RealmWatch)" "$(sh_rc repo view)" "$(sh_rc pr checks 12 --repo https://github.com/jphein/realmwatch)")
{ [ "$R" = "0,0,0," ] && [ "$(grep -c '^gh pr diff 12 --repo github.com/jphein/realmwatch$' "$TMP/gh.log")" -ge 2 ] && grep -q '^gh repo view github.com/jphein/realmwatch$' "$TMP/gh.log"; } && pass "same repo in any spelling passes, normalised to one --repo github.com/REPO" || fail "same-repo: $R"
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
{ grep -q '"number":7' "$TMP/claude.log" && ! grep -q '"number":8' "$TMP/claude.log" && grep -q "realmwatch#8 skipped — author 'stranger' lacks write access" "$TMP/state/dreamteam.log" && ! grep -q "labeller 'jphein'" "$TMP/state/dreamteam.log"; } \
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
# xreview r14: a title renamed by a non-writer (triage role) → issue skipped; a writer's rename is fine
reset; mkqueue jphein/realmwatch:2
FAKE_EVENTS='[{"event":"labeled","label":{"name":"dream"},"actor":{"login":"jphein"}},{"event":"renamed","actor":{"login":"triager"},"rename":{"from":"a","to":"b"}}]' \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-work" ] && grep -q "renamed by triager' lacks write" "$TMP/state/dreamteam.log"; } \
  && pass "an issue retitled by a non-writer is skipped" || fail "rename provenance: $(gj .decision) $(grep -c renamed "$TMP/state/dreamteam.log")"
reset; mkqueue jphein/realmwatch:2
FAKE_EVENTS='[{"event":"labeled","label":{"name":"dream"},"actor":{"login":"jphein"}},{"event":"renamed","actor":{"login":"jphein"},"rename":{"from":"a","to":"b"}}]' \
  FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[ "$(gj .decision)" = "started" ] && pass "control: a writer's rename keeps the issue" || fail "writer rename rejected: $(gj .reason)"
# comments are input too: an untrusted commenter (or an unreadable comment list) → issue skipped
reset; mkqueue jphein/realmwatch:2
FAKE_COMMENTS='[{"user":{"login":"jphein"}},{"user":{"login":"stranger"}}]' \
  FAKE_GH_realmwatch='[{"number":7,"title":"mine","user":{"login":"jphein"},"comments":2}]' FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(gj .decision)" = "no-work" ] && grep -q "'commenter stranger' lacks write" "$TMP/state/dreamteam.log"; } \
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

echo "── per-repo records in the guard JSON (Sen's note 2) ────────────"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2 jphein/unknownrepo:2
FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_GH_unknownrepo="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 DREAMTEAM_QUOTA_SEQ="0.92 0.92 0.92 0.35" run_g >/dev/null
RID=$(gj .run_id)
jq -e --arg rid "$RID" '(.runs|length)==3 and ([.runs[].run_id] | all(startswith($rid + "/")))' "$TMP/state/overnight-guard.json" >/dev/null 2>&1 \
  && pass "every planned repo has its own run_id line under .runs" || fail "runs: $(jq -c .runs "$TMP/state/overnight-guard.json" 2>/dev/null)"
jq -e '[.runs[] | select(.status=="finished")] | length == 2 and all(.started_at and .finished_at and (.prs_opened|type=="array") and (.merged|type=="array"))' "$TMP/state/overnight-guard.json" >/dev/null 2>&1 \
  && pass "finished repos carry started/finished times, prs_opened and merged" || fail "finished rows: $(jq -c '[.runs[]|select(.status=="finished")]' "$TMP/state/overnight-guard.json" 2>/dev/null)"
jq -e '[.runs[] | select(.status=="skipped")] | length == 1 and (.[0].reason | test("floor"))' "$TMP/state/overnight-guard.json" >/dev/null 2>&1 \
  && pass "the repo the floor stopped is a skipped line with its reason" || fail "skipped row: $(jq -c '[.runs[]|select(.status=="skipped")]' "$TMP/state/overnight-guard.json" 2>/dev/null)"
jq -e '[.runs[] | select(.repo=="jphein/realmwatch")][0] | .prs_opened == [12] and .prs_reviewed == [42]' "$TMP/state/overnight-guard.json" >/dev/null 2>&1 \
  && pass "PR-only: prs_opened is the shim's verified ledger (#12); a reviewed PR (#42) is not counted as opened" || fail "prs_opened: $(jq -c '.runs' "$TMP/state/overnight-guard.json" 2>/dev/null)"
jq -e '[.runs[] | select(.repo=="techempower-org/starcharts")][0].prs_opened == []' "$TMP/state/overnight-guard.json" >/dev/null 2>&1 \
  && pass "merge repo: no 'opened' list from the coordinator → no PRs counted as opened (fixed/reviewed are not creation evidence)" || fail "merge-repo prs_opened: $(jq -c '.runs' "$TMP/state/overnight-guard.json")"
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
b=$(brief); echo "$b" | grep -q 'realmwatch finished (PRs 1, merged 0)' && pass "the 07:03 briefing lists each repo's outcome" || fail "briefing per-repo: $b"

echo "── exit 69 (wrapper: proxy down) stops the night, no retry ──────"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2
FAKE_CLAUDE_RC=69 FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
{ [ "$(grep -c '^---$' "$TMP/claude.log")" -eq 1 ] \
  && jq -e '[.runs[] | select(.status=="stopped")] | length==1 and (.[0].reason|test("proxy-down"))' "$TMP/state/overnight-guard.json" >/dev/null \
  && jq -e '[.runs[] | select(.status=="skipped")] | length==1 and (.[0].reason|test("proxy-down"))' "$TMP/state/overnight-guard.json" >/dev/null \
  && grep -q 'FINISHED .*proxy-down' "$TMP/state/overnight-pending.md"; } \
  && pass "claude exit 69 → that repo stopped, the rest skipped (proxy-down), one coordinator only" || fail "exit 69: runs=$(grep -c '^---$' "$TMP/claude.log") $(jq -c .runs "$TMP/state/overnight-guard.json" 2>/dev/null)"
[ ! -f "$TMP/state/overnight-rotation.json" ] || ! jq -e '.["jphein/realmwatch"]' "$TMP/state/overnight-rotation.json" >/dev/null 2>&1 \
  && pass "an aborted repo is not marked swept (it goes first next night)" || fail "rotation advanced on exit 69"

echo "── max_repos (Sen's key) caps the night ─────────────────────────"
reset; mkqueue jphein/realmwatch:2 techempower-org/starcharts:2 jphein/unknownrepo:2; jq '.overnight.max_repos=2' "$TMP/config.json" > "$TMP/c2" && mv "$TMP/c2" "$TMP/config.json"
FAKE_GH_realmwatch="$I2" FAKE_GH_starcharts="$I2" FAKE_GH_unknownrepo="$I2" FAKE_QUOTA="$Q_OK" DRY_RUN=1 run_g >/dev/null
[ "$(gj '.repos|length')" = "2" ] && pass "overnight.max_repos=2 → two repos planned" || fail "max_repos: $(gj .repos)"

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

# hermetic: no test reached the (stubbed) real systemd-run / tmux launch
echo "── the CHECK line (nightly-guarded; one derivation from the guard record) ──"
cl(){ cat "$TMP/checks/nightly-guarded.line" 2>/dev/null; }
NSHAPE='^CHECK nightly-guarded (ok|warn|fail) · [^·]+ · next 23:30, owner Sen$'
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:0
FAKE_QUOTA="$Q_OK" run_g >/dev/null
[[ "$(cl)" =~ $NSHAPE ]] && [[ "$(cl)" == "CHECK nightly-guarded ok · night "*": nothing queued (no open dream issues) · "* ]] && pass "line: no-work → ok, nothing queued" || fail "line no-work: '$(cl)'"
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:2
FAKE_GH_starcharts="$I2" FAKE_QUOTA='{"aggregate":{"fiveHour":{"utilization":0.31},"sevenDay":{"utilization":0.2}}}' run_g >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded warn · night "*": held, "* ]] && pass "line: quota-held night → warn, held + reason" || fail "line held: '$(cl)' decision=$(gj .decision)"
reset; rm -rf "$TMP/checks"; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded ok · night "*"finished 1, stopped 0, skipped 0"* ]] && pass "line: INLINE run finished → ok after the runner's finish" || fail "line finished: '$(cl)'"
# crafted records through --check-line (nothing run)
rec(){ # rec <decision> <at> <reason> <runs-json> <deadline-epoch or "">
  reset; rm -rf "$TMP/checks"
  jq -n --arg d "$1" --arg at "$2" --arg r "$3" --argjson runs "$4" \
    '{at:$at, decision:$d, reason:$r, issues:15, repos:["a/x","a/y","a/z"], run_id:"nightly-t", runs:$runs}' > "$TMP/state/overnight-guard.json"
  if [ -n "$5" ]; then mkdir -p "$TMP/state/overnight-runs/nightly-t"; jq -n --argjson dl "$5" '{deadline_epoch:$dl, repos:[{repo:"a/x"},{repo:"a/y"},{repo:"a/z"}]}' > "$TMP/state/overnight-runs/nightly-t/plan.json"; fi
  run_g --check-line >/dev/null
}
NOWE=$(date +%s); RECENT=$(date -Iseconds -d '-8 hours')
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE - 3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"finished 0, stopped 0, skipped 0"*"cap passed with 3 repo(s) never finished (runner gone)"* ]] \
  && pass "line: started, cap passed, repos unfinished → FAIL (the 11-16 dead runner)" || fail "line dead runner: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded ok · "*"running until "* ]] && pass "line: started, before its cap → ok, running" || fail "line running: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"stopped"},{"repo":"a/y","status":"started"}]' "$(( NOWE + 3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"stopped 1"*"running until "* ]] && pass "line: before the cap with a repo already stopped → warn" || fail "line running+stopped: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"skipped"},{"repo":"a/y","status":"finished"}]' "$(( NOWE + 3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"skipped 1"*"running until "* ]] && pass "line: before the cap with a repo skipped → warn" || fail "line running+skipped: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished","prs_opened":[1,2],"merged":[1]},{"repo":"a/y","status":"stopped"},{"repo":"a/z","status":"skipped"}]' "$(( NOWE - 60 ))"
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"finished 1, stopped 1, skipped 1; PRs opened 2, merged 1"* ]] && pass "line: all repos ended, one stopped/skipped → warn with PR counts" || fail "line stopped: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished"}]' ""
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"no readable plan.json"* ]] && pass "line: started with no plan.json → fail (cap unknown)" || fail "line noplan: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished"},{"repo":"a/y","status":"finished"},{"repo":"a/z","status":"finished"}]' ""
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"no readable plan.json"* ]] && pass "line: every repo finished but no plan.json → still fail (plan validated first)" || fail "line allfin-noplan: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished"},{"repo":"a/x","status":"finished"},{"repo":"a/x","status":"finished"}]' "$(( NOWE - 60 ))"
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"finished 1, stopped 0, skipped 0"*"2 repo(s) never finished"* ]] \
  && pass "line: three results for ONE repo don't stand for three planned repos → fail" || fail "line dup: '$(cl)'"
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"stopped"},{"repo":"a/x","status":"finished"},{"repo":"a/y","status":"finished"},{"repo":"a/z","status":"finished"}]' "$(( NOWE - 60 ))"
[[ "$(cl)" == "CHECK nightly-guarded ok · "*"finished 3, stopped 0"* ]] && pass "line: a repo's LAST result counts (stopped then finished → finished)" || fail "line last: '$(cl)'"
rec no-start "$RECENT" "the contained launch failed (systemd-run/tmux)" '[]' ""
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"held, the contained launch failed"* ]] && pass "line: launch failed → fail" || fail "line launch: '$(cl)'"
rec no-work "$(date -Iseconds -d '-50 hours')" "" '[]' ""
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"record is 50 h old"* ]] && pass "line: a 50 h old record → warn (the timer has not decided since)" || fail "line old: '$(cl)'"
rec mystery "$RECENT" "" '[]' ""
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"unknown decision 'mystery'"* ]] && pass "line: unknown decision → fail" || fail "line unknown: '$(cl)'"
reset; rm -rf "$TMP/checks"; run_g --check-line >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded fail · no readable guard record"* ]] && pass "line: no guard record → fail" || fail "line norecord: '$(cl)'"
# a guard record that cannot be written never re-publishes the previous decision as fresh
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:0
jq -n --arg at "$(date -Iseconds)" '{at:$at, decision:"no-work", reason:"", issues:0, repos:[]}' > "$TMP/state/overnight-guard.json"
mkdir -p "$TMP/state/overnight-guard.json.d"; rm -f "$TMP/state/overnight-guard.json"; mv "$TMP/state/overnight-guard.json.d" "$TMP/state/overnight-guard.json"; : > "$TMP/state/overnight-guard.json/keep"
FAKE_QUOTA="$Q_OK" run_g >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded fail · could not write the guard record for decision no-work"* ]] && [ -z "$(ls "$TMP/state/overnight-guard.json" | grep -v keep)" ] \
  && pass "line: guard record unwritable (a directory) → fail, nothing moved into it" || fail "line recwrite: '$(cl)' $(ls "$TMP/state/overnight-guard.json")"
rm -rf "$TMP/state/overnight-guard.json"
# a plan must be an object with a positive numeric deadline and a non-empty list of unique owner/name repo strings
badplan() {  # badplan <label> <plan json>
  rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished"}]' "$(( NOWE - 60 ))"
  printf '%s' "$2" > "$TMP/state/overnight-runs/nightly-t/plan.json"; rm -rf "$TMP/checks"; run_g --check-line >/dev/null
  [[ "$(cl)" == "CHECK nightly-guarded fail · "*"no readable plan.json"* ]] && pass "line: plan $1 → fail" || fail "line plan $1: '$(cl)'"
}
badplan "not an object" '[{"repo":"a/x"}]'
badplan "with no repos" '{"deadline_epoch":1,"repos":[]}'
badplan "repo 'a b/x' (not owner/name)" "{\"deadline_epoch\":$(( NOWE - 60 )),\"repos\":[{\"repo\":\"a b/x\"}]}"
badplan "repo 'ax' (no owner)" "{\"deadline_epoch\":$(( NOWE - 60 )),\"repos\":[{\"repo\":\"ax\"}]}"
badplan "deadline 0" '{"deadline_epoch":0,"repos":[{"repo":"a/x"}]}'
badplan "deadline -5" '{"deadline_epoch":-5,"repos":[{"repo":"a/x"}]}'
badplan "deadline 'x'" '{"deadline_epoch":"x","repos":[{"repo":"a/x"}]}'
badplan "deadline 1e20 (exponent form)" '{"deadline_epoch":1e20,"repos":[{"repo":"a/x"}]}'
badplan "deadline 5000000000 (past 2100)" '{"deadline_epoch":5000000000,"repos":[{"repo":"a/x"}]}'
badplan "deadline 1.5" '{"deadline_epoch":1.5,"repos":[{"repo":"a/x"}]}'
# deadlines inside [1e9, 4102444800) are accepted whatever their JSON form (floored); the upper bound is excluded
goodplan() {  # goodplan <label> <deadline json>  → accepted: the cap (in the past) passed with repos unfinished
  rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE - 60 ))"
  printf '{"deadline_epoch":%s,"repos":[{"repo":"a/x"}]}' "$2" > "$TMP/state/overnight-runs/nightly-t/plan.json"; rm -rf "$TMP/checks"; run_g --check-line >/dev/null
  [[ "$(cl)" == "CHECK nightly-guarded fail · "*"never finished (runner gone)"* ]] && pass "line: deadline $1 accepted (judged against its cap)" || fail "line goodplan $1: '$(cl)'"
}
goodplan "1000000019.5 (fraction)" 1000000019.5
[[ "$(cl)" == *"the $(date -d @1000000019 +%H:%M) cap passed"* ]] && [ "$(date -d @1000000019 +%H:%M)" != "$(date -d @1000000020 +%H:%M)" ] \
  && pass "line: a fractional deadline is FLOORED (1000000019.5 → :19's minute, not the next one)" || fail "line floor: '$(cl)'"
goodplan "1e9 (exponent form, in range)" 1e9
badplan "deadline 4102444800 (the excluded upper bound)" '{"deadline_epoch":4102444800,"repos":[{"repo":"a/x"}]}'
# the record's timestamp must be a real ISO time (GNU date reads "" as today's midnight)
badat() {  # badat <label> <at json fragment>
  reset; rm -rf "$TMP/checks"
  printf '{%s"decision":"no-work","reason":"","issues":0,"repos":[]}' "$2" > "$TMP/state/overnight-guard.json"; run_g --check-line >/dev/null
  [[ "$(cl)" == "CHECK nightly-guarded fail · guard record has no valid timestamp (decision no-work)"* ]] && pass "line: record $1 → fail, never an invented fresh night" || fail "line badat $1: '$(cl)'"
}
badat "with no at" ''
badat "with at null" '"at":null,'
badat "with at 'garbage'" '"at":"garbage",'
badat "with at 7" '"at":7,'
badat "with at 'ISO +1 day' (a relative suffix)" '"at":"2026-11-17T00:00:00-08:00 +1 day",'
badat "with at '2026-11-17' (date only)" '"at":"2026-11-17",'
# a plan whose repos are not usable owner/name strings is no plan: [{}] + an anonymous finished run must not read ok
rec started "$RECENT" "guard passed" '[{"status":"finished"}]' "$(( NOWE - 60 ))"
jq -n --argjson dl "$(( NOWE - 60 ))" '{deadline_epoch:$dl, repos:[{}]}' > "$TMP/state/overnight-runs/nightly-t/plan.json"; rm -rf "$TMP/checks"; run_g --check-line >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"no readable plan.json"* ]] && pass "line: plan repos [{}] → fail, never matched against anonymous results" || fail "line badplan: '$(cl)'"
jq -n --argjson dl "$(( NOWE - 60 ))" '{deadline_epoch:$dl, repos:[{repo:"a/x"},{repo:"a/x"}]}' > "$TMP/state/overnight-runs/nightly-t/plan.json"; rm -rf "$TMP/checks"; run_g --check-line >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"no readable plan.json"* ]] && pass "line: duplicate planned repos → fail" || fail "line dupplan: '$(cl)'"
# the lock is required: a caller that cannot take it publishes nothing
rec no-work "$RECENT" "" '[]' ""; rm -rf "$TMP/checks"
rm -f "$TMP/lock-ready"
( exec 8>"$TMP/state/.nightly-line.lock"; flock 8; : > "$TMP/lock-ready"; exec sleep 30 ) & HOLDER=$!   # the holder IS the fd owner
for _ in $(seq 200); do [ -e "$TMP/lock-ready" ] && break; sleep 0.05; done
DREAMTEAM_LOCK_WAIT=1 run_g --check-line >/dev/null; rc=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ "$rc" = 0 ] && [ -z "$(cl)" ] && pass "line: lock held elsewhere → nothing published (rc 0)" || fail "line lock: rc=$rc '$(cl)'"
run_g --check-line >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded ok · "* ]] && pass "line: lock free again → published" || fail "line relock: '$(cl)'"

# --check-line's stdout: exactly the line it published; nothing when the lock was held elsewhere
rec no-work "$RECENT" "" '[]' ""; rm -rf "$TMP/checks"
out=$(run_g --check-line)
[ "$(grep -c '^CHECK ' <<<"$out")" = 1 ] && [ "$out" = "$(cl)" ] && pass "--check-line prints exactly the line it published" || fail "--check-line stdout: '$out'"
rm -f "$TMP/lock-ready"
# Another publisher replaces the line file WHILE this call waits for the lock: the call must print nothing. Sequenced:
# the holder takes the lock; the caller starts and signals; only then (0.5 s later, inside the caller's 3 s wait) does
# the holder replace the file. An implementation that compared the file before and after would print it.
rm -f "$TMP/lock-ready" "$TMP/caller-started"; rec no-work "$RECENT" "" '[]' ""; rm -rf "$TMP/checks"; mkdir -p "$TMP/checks"
( exec 8>"$TMP/state/.nightly-line.lock"; flock 8; : > "$TMP/lock-ready"
  for _ in $(seq 200); do [ -e "$TMP/caller-started" ] && break; sleep 0.05; done; sleep 0.5
  echo "CHECK nightly-guarded ok · OTHER publisher · next 23:30, owner Sen" > "$TMP/checks/nightly-guarded.line.new"
  mv -T "$TMP/checks/nightly-guarded.line.new" "$TMP/checks/nightly-guarded.line"; exec sleep 30 ) & HOLDER=$!
for _ in $(seq 200); do [ -e "$TMP/lock-ready" ] && break; sleep 0.05; done
out=$( : > "$TMP/caller-started"; DREAMTEAM_LOCK_WAIT=3 run_g --check-line ); kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ -z "$out" ] && [[ "$(cl)" == *"OTHER publisher"* ]] && pass "--check-line prints nothing when another publisher replaced the file while it waited" || fail "--check-line printed: '$out' line='$(cl)'"
# a record-write failure is published only under the lock too
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:0; mkdir -p "$TMP/state/overnight-guard.json/x"; rm -f "$TMP/lock-ready"
( exec 8>"$TMP/state/.nightly-line.lock"; flock 8; : > "$TMP/lock-ready"; exec sleep 30 ) & HOLDER=$!
for _ in $(seq 200); do [ -e "$TMP/lock-ready" ] && break; sleep 0.05; done
DREAMTEAM_LOCK_WAIT=1 FAKE_QUOTA="$Q_OK" run_g >/dev/null; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ -z "$(cl)" ] && pass "record-write failure while the lock is held elsewhere → no line (never published around the lock)" || fail "recfail around lock: '$(cl)'"
rm -rf "$TMP/state/overnight-guard.json"
# a no-work guard run stays silent on stdout (its line goes only to the file)
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:0; out=$(FAKE_QUOTA="$Q_OK" run_g)
[ -z "$out" ] && [ -n "$(cl)" ] && pass "a no-work run prints nothing; its line is in the file" || fail "no-work stdout: '$out'"
# the guard record's temp file is exclusive: a planted symlink at the old predictable name is never followed
reset; rm -rf "$TMP/checks"; mkqueue jphein/starcharts:0; echo SENTINEL > "$TMP/gsent"
ln -s "$TMP/gsent" "$TMP/state/overnight-guard.json.tmp"; ln -s "$TMP/gsent" "$TMP/state/.overnight-guard.json.tmp"
FAKE_QUOTA="$Q_OK" run_g >/dev/null
[ "$(cat "$TMP/gsent")" = SENTINEL ] && [ "$(gj .decision)" = no-work ] && pass "guard record: planted symlinks at predictable temp names untouched" || fail "guard temp followed: $(cat "$TMP/gsent")"

# white box: the line comes from ONE read of the record (a replacement mid-read can't mix two runs)
gl=$(sed -n '/^guard_line() {/,/^}/p' "$G"); nl=$(sed -n '/^nightly_lock() {/,/^}/p' "$G")
[ "$(grep -c 'cat "$g"' <<<"$gl")" = 1 ] && ! grep -q 'jq[^|]*"\$g"' <<<"$gl" && grep -q '^  nightly_lock ||' <<<"$gl" && grep -q 'flock -w' <<<"$nl" \
  && pass "guard_line reads the record once (one cat, every jq on the snapshot) under nightly_lock (flock)" || fail "guard_line reads the record more than once, or outside the lock"
[ "$(grep -c 'check_line "$(check_name nightly-guarded)"' "$G")" = 1 ] && sed -n '/^publish_nightly() {/,/^}/p' "$G" | grep -q 'check_line "$(check_name nightly-guarded)"' \
  && pass "every nightly publication goes through publish_nightly (one check_line call site)" || fail "a nightly check_line outside publish_nightly"
[ -z "$(ls "$TMP/state/overnight-runs" 2>/dev/null)" ] && [ ! -s "$TMP/claude.log" ] && pass "--check-line runs nothing (no run dir, no coordinator)" || fail "--check-line ran something"

echo "── 2026-11-16 23:41: the coordinator, a killed runner, the watchdog ──"
# the coordinator waits for its own background Workflow (print mode otherwise kills it 10 min after the turn ends:
# the 11-16 coordinator ended its turn with "the harness will re-invoke me"), and marks the scope as not its own
reset; mkqueue jphein/realmwatch:2
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 run_g >/dev/null
grep -qx 'BGWAIT=0' "$TMP/claude.log" && pass "coordinator: CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (waits for its Workflow; timeout still caps)" || fail "bgwait: $(grep BGWAIT "$TMP/claude.log")"
grep -qx 'OWNED=1' "$TMP/claude.log" && pass "coordinator: DREAMTEAM_SCOPE_OWNED=1 (its SessionEnd never stops the night's scope)" || fail "owned: $(grep OWNED "$TMP/claude.log")"
# a runner killed by SIGHUP (its tmux server stopped) still writes its end: the repo stopped, FINISHED, a FAIL line
reset; rm -rf "$TMP/checks"; mkqueue jphein/realmwatch:2
( FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 FAKE_CLAUDE_SLEEP=30 FAKE_STUBBORN=1 DREAMTEAM_STOP_GRACE=2 run_g >/dev/null ) &
SUB=$!
for _ in $(seq 100); do grep -q '^---$' "$TMP/claude.log" 2>/dev/null && break; sleep 0.1; done
GPID=$(pgrep -f -n "bash $G" 2>/dev/null)
[ -n "$GPID" ] && kill -HUP "$GPID"
for _ in $(seq 100); do kill -0 "$SUB" 2>/dev/null || break; sleep 0.1; done; kill -0 "$SUB" 2>/dev/null && kill "$SUB"
grep -q "^FINISHED nightly-.*Stopped: runner killed (SIGHUP)" "$TMP/state/overnight-pending.md" 2>/dev/null \
  && [ "$(gj '.runs[] | select(.repo=="jphein/realmwatch") | .status')" = stopped ] \
  && [[ "$(cl)" == "CHECK nightly-guarded fail · "*"runner killed (SIGHUP)"* ]] \
  && ! grep -q END-NOT-KILLED "$TMP/claude.log" && ! kill -0 "$(cat "$TMP/claude.pid" 2>/dev/null || echo 999999)" 2>/dev/null \
  && [ -s "$TMP/claude.stubborn" ] && ! kill -0 "$(cat "$TMP/claude.stubborn")" 2>/dev/null \
  && [ -s "$TMP/state/overnight-runs/$(gj .run_id)/killed" ] \
  && pass "SIGHUP mid-coordinator: its whole group gone (a TERM-ignoring descendant KILLed after the grace), repo stopped, FINISHED names the signal, line FAIL" \
  || fail "sighup: runs=$(jq -c .runs "$TMP/state/overnight-guard.json") pid=$GPID pending=$(grep FINISHED "$TMP/state/overnight-pending.md" 2>/dev/null) status=$(gj '.runs[0].status') line='$(cl)'"
# a signal that lands while the runner WAITS (here after a quota stop) still gets the bounded group stop
reset; rm -rf "$TMP/checks"; mkqueue jphein/realmwatch:2; rm -f "$TMP/claude.stubborn"
( FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 DREAMTEAM_QUOTA_SEQ="0.92 0.92 0.30" DREAMTEAM_WATCH_SEC=1 \
  FAKE_CLAUDE_SLEEP=30 FAKE_TERM_DELAY=20 FAKE_STUBBORN=1 DREAMTEAM_STOP_GRACE=2 run_g >/dev/null ) &
SUB=$!
for _ in $(seq 200); do grep -q "stopping realmwatch mid-run" "$TMP/state/dreamteam.log" 2>/dev/null && break; sleep 0.1; done
sleep 0.5; GPID=$(pgrep -f -n "bash $G" 2>/dev/null); T0=$(date +%s); [ -n "$GPID" ] && kill -HUP "$GPID"
for _ in $(seq 300); do kill -0 "$SUB" 2>/dev/null || break; sleep 0.1; done; T1=$(date +%s); kill -0 "$SUB" 2>/dev/null && kill "$SUB"
[ $(( T1 - T0 )) -lt 12 ] && [ -s "$TMP/claude.stubborn" ] && ! kill -0 "$(cat "$TMP/claude.stubborn")" 2>/dev/null \
  && grep -q "Stopped: runner killed (SIGHUP)" "$TMP/state/overnight-pending.md" \
  && pass "SIGHUP during the runner's wait (after a quota stop): bounded by the grace ($(( T1 - T0 ))s, not the coordinator's 20 s), stubborn descendant gone, FINISHED names it" \
  || fail "late signal: took $(( T1 - T0 ))s stubborn=$(cat "$TMP/claude.stubborn" 2>/dev/null) alive=$(kill -0 "$(cat "$TMP/claude.stubborn" 2>/dev/null)" 2>/dev/null && echo yes) pending=$(grep FINISHED "$TMP/state/overnight-pending.md")"
kill "$(cat "$TMP/claude.stubborn" 2>/dev/null)" 2>/dev/null

# a coordinator that finishes normally but leaves a TERM-ignoring member in its group: swept after the leader exits
reset; mkqueue jphein/realmwatch:2; rm -f "$TMP/claude.stubborn"
FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 FAKE_STUBBORN=1 DREAMTEAM_STOP_GRACE=2 run_g >/dev/null
[ -s "$TMP/claude.stubborn" ] && ! kill -0 "$(cat "$TMP/claude.stubborn")" 2>/dev/null && pass "normal finish: a leftover group member is swept (nothing of a finished coordinator keeps running)" \
  || { fail "normal-finish sweep: stubborn $(cat "$TMP/claude.stubborn" 2>/dev/null) still alive"; kill -KILL "$(cat "$TMP/claude.stubborn" 2>/dev/null)" 2>/dev/null; }
# HUP in the hand-off window (leader reaped, CPID cleared, sweep not yet run)
reset; rm -rf "$TMP/checks"; mkqueue jphein/realmwatch:2; rm -f "$TMP/claude.stubborn" "$TMP/tailpause"
( FAKE_GH_realmwatch="$I2" FAKE_QUOTA="$Q_OK" DREAMTEAM_INLINE=1 FAKE_STUBBORN=1 DREAMTEAM_STOP_GRACE=2 DREAMTEAM_TEST_TAIL_PAUSE="$TMP/tailpause" run_g >/dev/null ) &
SUB=$!
for _ in $(seq 200); do [ -e "$TMP/tailpause" ] && break; sleep 0.05; done
GPID=$(pgrep -f -n "bash $G" 2>/dev/null); [ -n "$GPID" ] && kill -HUP "$GPID"
for _ in $(seq 200); do kill -0 "$SUB" 2>/dev/null || break; sleep 0.1; done; kill -0 "$SUB" 2>/dev/null && kill "$SUB"
[ -e "$TMP/tailpause" ] && [ -s "$TMP/claude.stubborn" ] && ! kill -0 "$(cat "$TMP/claude.stubborn")" 2>/dev/null \
  && [[ "$(cl)" == "CHECK nightly-guarded fail · "*"runner killed (SIGHUP)"* ]] \
  && pass "HUP in the hand-off window: the stubborn member is swept, and the night is FAIL (run-level marker)" \
  || { fail "handoff: pause=$([ -e "$TMP/tailpause" ] && echo y) stubborn-alive=$(kill -0 "$(cat "$TMP/claude.stubborn" 2>/dev/null)" 2>/dev/null && echo y) line='$(cl)'"; kill -KILL "$(cat "$TMP/claude.stubborn" 2>/dev/null)" 2>/dev/null; }

# the watchdog: a started night whose runner session is gone before its cap is FAIL at once, not at 06:30
OLD=$(date -Iseconds -d '-10 minutes'); FRESH=$(date -Iseconds -d '-30 seconds')
FAKE_SESSION=gone rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"runner gone before its "*"cap (no live runner pane in tmux session nightly-t)"* ]] && pass "watch: runner session gone before the cap → FAIL now" || fail "watch gone: '$(cl)'"
grep -qF -- "-L dreamteam-nightly list-panes -t =nightly-t -F #{pane_dead}" "$TMP/probe.txt" && pass "watch: the probe asks the night's own tmux server for exactly this run's pane state" || fail "probe argv: $(cat "$TMP/probe.txt")"
FAKE_SESSION=deadpane rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"no live runner pane"* ]] && pass "watch: the session is there but its pane is dead (remain-on-exit) → FAIL" || fail "watch deadpane: '$(cl)'"
FAKE_SESSION=denied rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"runner liveness unmeasured"* ]] && pass "watch: a socket we cannot open (Permission denied) is unmeasured, not dead" || fail "watch denied: '$(cl)'"
FAKE_SESSION=noserver rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"runner gone before its "* ]] && pass "watch: the night's tmux SERVER gone (tmux 3.6: 'Error connecting to …', the 11-16 state) → FAIL" || fail "watch noserver: '$(cl)'"
FAKE_SESSION=alive rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded ok · "*"running until "* ]] && pass "watch: session alive → ok, running (control)" || fail "watch alive: '$(cl)'"
FAKE_SESSION=gone rec started "$FRESH" "guard passed" '[]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded ok · "* ]] && pass "watch: a record under 2 min old is not judged dead (the launch is still starting)" || fail "watch grace: '$(cl)'"
FAKE_SESSION=weird rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"
[[ "$(cl)" == "CHECK nightly-guarded warn · "*"runner liveness unmeasured"* ]] && pass "watch: an answer the probe cannot read → warn, unmeasured (never ok, never a guess)" || fail "watch weird: '$(cl)'"
# the run-level marker alone makes the night FAIL (a signal after the last repo record, or in a one-repo run)
rec started "$RECENT" "guard passed" '[{"repo":"a/x","status":"finished"},{"repo":"a/y","status":"finished"},{"repo":"a/z","status":"finished"}]' "$(( NOWE + 3600 ))"
printf 'SIGTERM 2026-11-17T23:59:00-08:00\n' > "$TMP/state/overnight-runs/nightly-t/killed"; run_g --check-line >/dev/null
[[ "$(cl)" == "CHECK nightly-guarded fail · "*"finished 3"*"runner killed (SIGTERM)"* ]] && pass "line: the run-level killed marker → FAIL even when every repo reads finished" || fail "killed marker: '$(cl)'"
# --watch tells the lead once per dead run, and never when the run is alive
FAKE_SESSION=alive rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"; rm -f "$TMP/notify.txt"
FAKE_SESSION=alive run_g --watch >/dev/null
[ ! -s "$TMP/notify.txt" ] && pass "--watch: alive → the lead is not told" || fail "watch alive notified: $(cat "$TMP/notify.txt")"
FAKE_SESSION=gone run_g --watch >/dev/null; FAKE_SESSION=gone run_g --watch >/dev/null
[ "$(wc -l < "$TMP/notify.txt" 2>/dev/null)" = 1 ] && grep -q "nightly-t" "$TMP/notify.txt" && grep -q "runner gone" "$TMP/notify.txt" \
  && pass "--watch: dead → the lead is told once per run (run id and reason), not every 5 min" || fail "watch notify: $(cat "$TMP/notify.txt" 2>/dev/null)"
# a send that fails writes no stamp, so the next tick tries again
FAKE_SESSION=gone rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"; rm -f "$TMP/notify.txt" "$TMP/state/.watch-told-"*
FAKE_NOTIFY_RC=1 FAKE_SESSION=gone run_g --watch >/dev/null
s1=$(ls "$TMP/state/.watch-told-"* 2>/dev/null | wc -l)
FAKE_SESSION=gone run_g --watch >/dev/null
[ "$s1" = 0 ] && [ "$(wc -l < "$TMP/notify.txt")" = 2 ] && [ -e "$TMP/state/.watch-told-nightly-t" ] \
  && pass "--watch: a failed send leaves no stamp; the next tick sends again and stamps" || fail "watch retry: s1=$s1 sends=$(wc -l < "$TMP/notify.txt")"
# two watches at once send once (check, send and stamp under one lock)
FAKE_SESSION=gone rec started "$OLD" "guard passed" '[{"repo":"a/x","status":"started"}]' "$(( NOWE + 3*3600 ))"; rm -f "$TMP/notify.txt" "$TMP/state/.watch-told-"*
( FAKE_NOTIFY_SLEEP=2 FAKE_SESSION=gone run_g --watch >/dev/null ) & ( FAKE_NOTIFY_SLEEP=2 FAKE_SESSION=gone run_g --watch >/dev/null ) & wait
[ "$(wc -l < "$TMP/notify.txt")" = 1 ] && pass "--watch: two concurrent watches send once" || fail "watch concurrent: $(wc -l < "$TMP/notify.txt") sends"

[ ! -s "$TMP/launch-attempts.txt" ] && pass "no test attempted a real scope/tmux launch" || fail "a test reached the launch: $(head -3 "$TMP/launch-attempts.txt")"
echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
