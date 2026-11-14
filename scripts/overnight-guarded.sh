#!/usr/bin/env bash
# dreamteam — GUARDED nightly sweep (JP 2026-11-14 06:40 "go" on ask 4c77a5b8f3ef:
# "Guarded = runs 23:30 with the 70 % quota guard, PR-only in production repos, oracle review
# before any merge"). Timer target of systemd/dreamteam-nightly-guarded.timer. Contract:
# docs/OVERNIGHT-GUARDED.md. Replaces the 02:11 PILOT (overnight-launch.sh), which only surfaced work.
#
#   overnight-guarded.sh                 guard → (start the contained runner | record why not)
#   overnight-guarded.sh --runner DIR    the runner itself (started by the line above, inside the scope)
#
# THE GUARD (every step logged to state/dreamteam.log and recorded in state/overnight-guard.json:
# {at, quota_remaining:{five_hour, seven_day}, decision, reason, issues, repos, run_id}):
#   (a) quota: GET the teamclaude proxy's /teamclaude/quota. START only if aggregate.fiveHour.remaining
#       >= .overnight.five_hour_min (0.70: the sweep never starts into a 5-hour pool below 70 %) and the
#       7-day pool (aggregate.sevenDay.remaining, else aggregate.weeklyShared.remaining: this proxy
#       reports sevenDay as null) >= .overnight.seven_day_min (0.30). A proxy that does not answer, or
#       answers without those numbers, is NO START (fail closed): the ~/.cargo/bin/claude wrapper
#       silently falls back to familiar's own login when the proxy is down, which bills outside the pool.
#   (b) work: repos with dream > 0 in state/issues-queue.json (all owners, not only jphein/dreamteam),
#       minus .overnight.never_sweep, least-recently-swept first (state/overnight-rotation.json), each
#       re-read LIVE over REST (the queue can be hours old). None open → decision no-work, silent, exit 0.
#   (c) PR-only: a repo whose NAME is in .overnight.production_repos opens PRs and NEVER merges; a repo in
#       .overnight.merge_repos merges a PR only after the oracle says approve AND pr-gate.sh is green, one
#       at a time; an unlisted repo is PR-only (fail safe). Matched by name so an owner transfer is moot.
#   (d) start: ONE systemd-run --user --scope (MemoryHigh/Max/SwapMax from config .scope, RuntimeMaxSec =
#       seconds until .overnight.stop_at 06:30, before the 07:03 briefing, and never over max_hours) holding a detached tmux server
#       on its own socket (-L dreamteam-nightly: a shared -L dreamteam server may already live in another
#       team's scope, and a session created there would escape this scope's caps). Inside, the runner
#       clones each repo fresh under ~/srv/wt/overnight/<night>/ (git never touches the synced ~/Projects)
#       and runs one headless `claude -p` per repo with the overnight workflow, one at a time, re-probing
#       the quota (continuation floor .overnight.continue_five_hour_min) and the clock before each.
#   (e) records: run_id in the guard record, state/overnight-pending.md "STARTED <run_id> at <time>"
#       (the 07:03 morning-briefing reports it), sweep-results.json for the plan's /hearth/issues page.
#
# HARDENING (xreview 2026-11-14, gpt-6.1-sol BLOCK → fixed): the FIRST repo needs the full start guard,
#   later ones the continuation floor, and a watchdog re-probes every DREAMTEAM_WATCH_SEC (600) while a
#   coordinator runs and stops it under the floor; flock + a night marker (night = date 12 h ago, so a
#   00:20 restart is the same night) make it one start a night; a start more than max_hours before
#   stop_at is refused (no daytime sweeps); PR-only repos get a `gh` shim (refuses `pr merge` and the
#   REST merge endpoint) and a pre-push hook (refuses the default branch): guardrails, not a security
#   boundary; branch protection is; spawned teammates are pinned to the nightly scope
#   (DREAMTEAM_SCOPE_NAME, Delegate=yes) so scope-attach cannot re-home them out of its caps.
# SEAMS (tests/test-overnight-guarded.sh): DREAMTEAM_STATE, DREAMTEAM_CONFIG, DREAMTEAM_QUEUE,
#   DREAMTEAM_QUOTA_URL, DREAMTEAM_QUOTA_SEQ (space-separated fiveHour overrides, one per probe),
#   DREAMTEAM_WT_BASE, DREAMTEAM_CLAUDE_BIN, DREAMTEAM_PLAN_DATA, DREAMTEAM_DEADLINE_EPOCH,
#   DREAMTEAM_INLINE=1 (run the runner in-process, no scope/tmux), DREAMTEAM_PREV_LIVE (0/1),
#   DRY_RUN=1 (print the launch, start nothing), DREAMTEAM_WATCH_SEC (watchdog period). curl/gh/git/tmux are called by bare name (PATH stubs).
# Always exits 0 on a decision (a timer target records, it does not fail the unit); exit 2 = usage.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$SELF")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
mkdir -p "$STATE"
LOG="$STATE/dreamteam.log"
PROXY="http://127.0.0.1:3456"
QURL="${DREAMTEAM_QUOTA_URL:-$PROXY/teamclaude/quota}"
TMUX_SOCK="dreamteam-nightly"

log() { echo "$(date +%FT%T) overnight-guarded: $*" >> "$LOG" 2>/dev/null || true; }
oc()  { jq -r --arg k "$1" --arg d "$2" '(.overnight[$k] // $d) | tostring' "$CFG" 2>/dev/null || printf '%s' "$2"; }
sc()  { jq -r --arg k "$1" --arg d "$2" '.scope[$k] // $d' "$CFG" 2>/dev/null || printf '%s' "$2"; }
olist() { jq -c --arg k "$1" '.overnight[$k] // []' "$CFG" 2>/dev/null || echo '[]'; }
ge()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) >= (b+0))}'; }
isnum() { [[ "$1" =~ ^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; }

FIVE_MIN=$(oc five_hour_min 0.70); SEVEN_MIN=$(oc seven_day_min 0.30)
CONT_MIN=$(oc continue_five_hour_min 0.40)
MAX_REPOS=$(oc max_repos_per_night 3); MAX_ISSUES=$(oc max_issues_per_repo 5)
STOP_AT=$(oc stop_at 06:30); MAX_HOURS=$(oc max_hours 7.5); MIN_START_MIN=$(oc min_start_minutes 60); MIN_REPO_MIN=$(oc min_repo_minutes 30)

# ── quota probe → FIVE, WEEK (strings; "" = unreported). rc 1 = proxy did not answer ──
quota_probe() {
  FIVE=""; WEEK=""
  local body; body=$(curl -s -m 10 "$QURL" 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  FIVE=$(printf '%s' "$body" | jq -r '.aggregate.fiveHour.remaining // empty' 2>/dev/null) || FIVE=""
  WEEK=$(printf '%s' "$body" | jq -r '(.aggregate.sevenDay.remaining // .aggregate.weeklyShared.remaining) // empty' 2>/dev/null) || WEEK=""
  isnum "$FIVE" || FIVE=""; isnum "$WEEK" || WEEK=""
  if [ -n "${DREAMTEAM_QUOTA_SEQ:-}" ]; then   # test seam: the Nth probe's fiveHour
    local f="$STATE/.quota-seq-idx" i; i=$(cat "$f" 2>/dev/null || echo 0)
    local -a seq; read -r -a seq <<< "$DREAMTEAM_QUOTA_SEQ"
    [ "$i" -lt "${#seq[@]}" ] && FIVE="${seq[$i]}"; echo $((i+1)) > "$f"
  fi
  return 0
}
# quota_ok MIN5 → rc 0 ok; else sets QREASON
quota_ok() {
  if ! quota_probe; then QREASON="the teamclaude proxy did not answer $QURL (fail closed)"; return 1; fi
  if [ -z "$FIVE" ]; then QREASON="the proxy answered without a 5-hour remaining figure (fail closed)"; return 1; fi
  if [ -z "$WEEK" ]; then QREASON="the proxy reports no 7-day pool (sevenDay and weeklyShared both null; fail closed)"; return 1; fi
  if ! ge "$FIVE" "$1"; then QREASON="5-hour pool at $FIVE, below the $1 start guard"; return 1; fi
  if ! ge "$WEEK" "$SEVEN_MIN"; then QREASON="7-day pool at $WEEK, below the $SEVEN_MIN guard"; return 1; fi
  QREASON=""; return 0
}

deadline_epoch() {
  if [ -n "${DREAMTEAM_DEADLINE_EPOCH:-}" ]; then echo "$DREAMTEAM_DEADLINE_EPOCH"; return; fi
  local t; t=$(date -d "today $STOP_AT" +%s)
  [ "$t" -le "$(date +%s)" ] && t=$(date -d "tomorrow $STOP_AT" +%s)
  echo "$t"
}

# sweep-results.json for the plan (contract: plan.realm.watch src/plan_realm_watch/issues.py) + state copy
write_sweep() { # $1 = json doc
  local plan_data="${DREAMTEAM_PLAN_DATA:-$HOME/srv/plan.realm.watch/data}"
  printf '%s\n' "$1" > "$STATE/sweep-results.json.tmp" && mv -f "$STATE/sweep-results.json.tmp" "$STATE/sweep-results.json"
  [ "${DRY_RUN:-0}" = "1" ] && return 0   # a dry run records in state/, never publishes to the plan
  if [ -d "$plan_data" ] || [ -n "${DREAMTEAM_PLAN_DATA:-}" ]; then
    mkdir -p "$plan_data" 2>/dev/null
    printf '%s\n' "$1" > "$plan_data/sweep-results.json.tmp" && mv -f "$plan_data/sweep-results.json.tmp" "$plan_data/sweep-results.json"
  fi
}

# ════════════════════════════════ RUNNER ════════════════════════════════
# PR-only guardrails for one clone: a gh shim dir (prepended to PATH for that coordinator) and a
# pre-push hook. They stop an obedient-but-misled agent (an issue body that says "merge it"); they do not
# stop a hostile one (it could call the real gh by path or --no-verify). The boundary is branch protection.
make_pr_only_guards() { # $1 = shim dir, $2 = clone dir, $3 = real gh path
  mkdir -p "$1"
  { printf '#!/usr/bin/env bash\nREAL_GH=%q\n' "$3"; cat <<'SHIM'; } > "$1/gh"
# overnight-guarded PR-only shim: an ALLOWLIST (security review 2026-11-14: a denylist kept missing merge
# spellings). A PR-only fixer or reviewer needs only these; everything else is refused.
refuse() { echo "overnight-guarded: PR-only repo — 'gh $*' is not on the allowlist (open the PR and stop)" >&2; exit 77; }
sub="${1:-}"; shift || true
act=""; method=GET; explicit=0; body=0; gql=0; skip=0; prev=""
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; case "$prev" in -X|--method) method="$a"; explicit=1;; esac; continue; fi
  prev="$a"
  case "$a" in
    -R|--repo|-X|--method|-H|--header|--jq|-q|--template|-t|--title|-b|--body|-B|--base|--head|-L|--limit|--json|-s|--state|-l|--label|-a|--assignee|-A|--author|-S|--search|-c|--commit|-w|--web) skip=1;;
    -X*|--method=*) method="${a#-X}"; method="${method#--method=}"; explicit=1;;
    --input|--input=*) body=2; [ "$a" = --input ] && skip=1;;
    -f|-F|--field|--raw-field) [ "$body" = 2 ] || body=1; skip=1;;
    -f*|-F*|--field=*|--raw-field=*) [ "$body" = 2 ] || body=1;;
    -*) ;;
    *) if [ -z "$act" ]; then act="$a"; fi
       e="${a%%[?#]*}"; e="${e%/}"; case "$e" in graphql|*/graphql) gql=1;; esac;;
  esac
done
method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
case "$sub" in
  pr)    case "$act" in create|view|list|checks|diff|comment|status) ;; *) refuse "$sub" "$act";; esac;;
  issue) case "$act" in view|list|comment) ;; *) refuse "$sub" "$act";; esac;;
  repo)  case "$act" in view|clone) ;; *) refuse "$sub" "$act";; esac;;
  run)   case "$act" in view|list) ;; *) refuse "$sub" "$act";; esac;;
  auth)  case "$act" in status) ;; *) refuse "$sub" "$act";; esac;;
  label) case "$act" in list) ;; *) refuse "$sub" "$act";; esac;;
  # api: GET only. gh sends fields as a POST unless -X GET is explicit; an --input body is never read here.
  api)   [ "$gql" = 0 ] || refuse "api graphql"; [ "$method" = GET ] || refuse "api -X $method"
         [ "$body" = 2 ] && refuse "api --input"; { [ "$body" = 1 ] && [ "$explicit" = 0 ]; } && refuse "api fields without -X GET (a POST)";;
  --version|version|help|"") ;;
  *) refuse "$sub";;
esac
exec "$REAL_GH" "$sub" "$@"
SHIM
  chmod +x "$1/gh"
  [ -d "$2/.git/hooks" ] || mkdir -p "$2/.git/hooks"
  cat > "$2/.git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
# overnight-guarded PR-only hook: never push to the default branch of a production repo.
def=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); def="refs/heads/${def#refs/remotes/origin/}"
while read -r _lref _lsha rref _rsha; do
  case "$rref" in "$def"|refs/heads/main|refs/heads/master|refs/heads/trunk|refs/heads/production)
    echo "overnight-guarded: PR-only repo — push to $rref refused; push a branch and open a PR" >&2; exit 1;;
  esac
done
exit 0
HOOK
  chmod +x "$2/.git/hooks/pre-push"
}

run_runner() {
  local dir="$1" plan="$1/plan.json"
  [ -f "$plan" ] || { log "runner: no plan at $plan"; return 0; }
  local rid night deadline wt claude_bin n i
  rid=$(jq -r .run_id "$plan"); night=$(jq -r .night "$plan"); deadline=$(jq -r .deadline_epoch "$plan")
  wt=$(jq -r .wt_base "$plan"); claude_bin=$(jq -r .claude_bin "$plan"); n=$(jq '.repos|length' "$plan")
  local stop_words; stop_words=$(date -d "@$deadline" '+%H:%M %Z')
  # The proxy env the ~/.cargo/bin/claude wrapper sets, set here too so the real binary routes through
  # the pool even if the wrapper's own probe races. No key is involved: the proxy presents as API auth.
  export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" https_proxy="$PROXY" http_proxy="$PROXY"
  export NO_PROXY='localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.jphe.in,.realm.watch,.local,familiar,disks,ubox0,nodered,game,katana,gatekeeper'
  export no_proxy="$NO_PROXY" NODE_EXTRA_CA_CERTS="$HOME/.config/teamclaude-ca.pem"
  # never the host's own login: the wrapper (teamclaude #66) exits 69 when the proxy is down unless one of
  # these opts into the direct seat, so an inherited opt-in must not ride along
  unset ANTHROPIC_BASE_URL TEAMCLAUDE_BYPASS TEAMCLAUDE_ALLOW_DIRECT
  export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
  # Pin any teammate a coordinator spawns to THIS scope: scope-attach.sh otherwise re-homes agent procs
  # into dreamteam-<repo>.scope, which has neither this night's aggregate cap nor its RuntimeMaxSec.
  export DREAMTEAM_SCOPE_NAME="dreamteam-$rid"
  local real_gh; real_gh=$(command -v gh 2>/dev/null || echo /usr/bin/gh)
  local watch="${DREAMTEAM_WATCH_SEC:-600}"
  local done_n=0 results='[]'
  for ((i=0; i<n; i++)); do
    local r name pr_only issues left
    r=$(jq -c ".repos[$i]" "$plan"); name=$(jq -r .name <<<"$r"); pr_only=$(jq -r .pr_only <<<"$r")
    left=$(( deadline - $(date +%s) ))
    if [ "$left" -lt $(( MIN_REPO_MIN * 60 )) ]; then log "runner $rid: stop before $name — ${left}s left to the $stop_words cap"; break; fi
    local clone="$wt/$night/$name"; [ -e "$clone" ] && clone="$clone-$rid"
    mkdir -p "$wt/$night"
    if ! git clone -q "https://github.com/$(jq -r .repo <<<"$r").git" "$clone" >/dev/null 2>&1; then
      log "runner $rid: clone of $name failed — skipped"; continue
    fi
    left=$(( deadline - $(date +%s) - 60 ))   # the clone took time; keep a minute for timeout's kill
    if [ "$left" -lt 300 ]; then log "runner $rid: stop at $name — the clone left ${left}s to the cap"; break; fi
    local cpath="$PATH"
    if [ "$pr_only" = "true" ]; then make_pr_only_guards "$dir/bin-$name" "$clone" "$real_gh"; cpath="$dir/bin-$name:$PATH"; fi
    # the night's FIRST coordinator needs the full start guard (the guard's probe is minutes old by now),
    # later ones the continuation floor; probed AFTER the clone, right before anything spends (xreview r2)
    local need="$CONT_MIN"; [ "$done_n" -eq 0 ] && need="$FIVE_MIN"
    if ! quota_ok "$need"; then log "runner $rid: stop before $name — quota under the floor ($QREASON)"; break; fi
    issues=$(jq -c '.issues' <<<"$r")
    local args; args=$(jq -c --argjson po "$pr_only" --argjson is "$issues" --arg gate "$ROOT/scripts/pr-gate.sh" \
      --argjson h $(( left / 3600 > 0 ? left / 3600 : 1 )) \
      '{repo: .repo, issues: $is, prOnly: $po, prGate: $gate, maxHours: $h}' <<<"$r")
    local rules
    if [ "$pr_only" = "true" ]; then
      rules="This is a PRODUCTION repo: open one PR per fix and NEVER merge, never push to main, never deploy. The oracle review still runs; record its verdict on each PR."
    else
      rules="Merge a PR only when ALL hold: the dreamteam:oracle review verdict is approve (read-only reviewer); \`bash $ROOT/scripts/pr-gate.sh $(jq -r .repo <<<"$r") <pr>\` exits 0 (exit 4 = no CI = do not merge); no other merge is in flight (one at a time, no-eager-merge). Anything else stays an open PR."
    fi
    local prompt
    prompt="Overnight guarded sweep $rid for $(jq -r .repo <<<"$r"). JP opted in on 2026-11-14 (ask 4c77a5b8f3ef, \"Guarded nightly\"), so use a workflow: call the Workflow tool with scriptPath $ROOT/workflows/overnight.js and args $args
Work only the listed dream-labelled issues (the args skip scouting). You are in a fresh clone at $clone; never touch ~/Projects (a synced tree).
$rules
Stop by $stop_words (the 07:03 briefing reads what you leave). Do not speak aloud, do not message JP, do not file asks; design, secrets or destructive changes are reported as too-large, never forced.
End your reply with ONE line: SWEEP-RESULT {\"fixed\":[{\"repo\":\"owner/name\",\"number\":N,\"pr\":N,\"sha\":\"<merge sha or empty>\"}],\"reviewed_not_merged\":[{\"repo\":\"owner/name\",\"pr\":N}],\"too_large\":[{\"repo\":\"owner/name\",\"number\":N}]}"
    log "runner $rid: start $name (pr_only=$pr_only, $(jq length <<<"$issues") issue(s), ${left}s to cap)"
    ( cd "$clone" && PATH="$cpath" exec timeout -k 60 "$left" "$claude_bin" -p "$prompt" --dangerously-skip-permissions --output-format json ) \
      > "$dir/$name.json" 2> "$dir/$name.err" &
    local cpid=$! tick=0
    # watchdog: re-probe the pool while the coordinator spends from it; under the floor → TERM it
    # (timeout forwards TERM to claude). One-second ticks so a finished run is noticed at once.
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 1; tick=$((tick+1))
      if [ $((tick % watch)) -eq 0 ] && kill -0 "$cpid" 2>/dev/null && ! quota_ok "$CONT_MIN"; then
        log "runner $rid: stopping $name mid-run — $QREASON"; kill -TERM "$cpid" 2>/dev/null; break
      fi
    done
    wait "$cpid"; local rc=$?
    log "runner $rid: $name finished rc=$rc"
    done_n=$((done_n+1))
    jq --arg r "$(jq -r .repo <<<"$r")" --arg t "$(date -Iseconds)" '.[$r]=$t' "$STATE/overnight-rotation.json" 2>/dev/null > "$STATE/overnight-rotation.json.tmp" \
      || jq -n --arg r "$(jq -r .repo <<<"$r")" --arg t "$(date -Iseconds)" '{($r):$t}' > "$STATE/overnight-rotation.json.tmp"
    mv -f "$STATE/overnight-rotation.json.tmp" "$STATE/overnight-rotation.json"
    local line; line=$(jq -r '.result // empty' "$dir/$name.json" 2>/dev/null | grep -o 'SWEEP-RESULT {.*}' | tail -n1 | sed 's/^SWEEP-RESULT //')
    if [ -n "$line" ] && jq -e 'type=="object"' <<<"$line" >/dev/null 2>&1; then results=$(jq -c --argjson x "$line" '. + [$x]' <<<"$results"); fi
  done
  # fold the per-repo results into the night's sweep-results.json
  local sw; sw=$(jq -c --argjson rs "$results" '
      .fixed = ([$rs[].fixed // [] | .[]]) | .reviewed_not_merged = ([$rs[].reviewed_not_merged // [] | .[]])
      | .too_large = ([$rs[].too_large // [] | .[]])' "$STATE/sweep-results.json" 2>/dev/null) && [ -n "$sw" ] && write_sweep "$sw"
  echo "FINISHED $rid at $(date '+%F %H:%M %Z'): $done_n of $n repo(s) swept." >> "$STATE/overnight-pending.md"
  log "runner $rid: finished $done_n of $n repo(s)"
}

if [ "${1:-}" = "--runner" ]; then
  [ -n "${2:-}" ] || { echo "usage: overnight-guarded.sh --runner RUN_DIR" >&2; exit 2; }
  run_runner "$2"; exit 0
fi
[ -z "${1:-}" ] || { echo "usage: overnight-guarded.sh [--runner RUN_DIR]" >&2; exit 2; }

# ════════════════════════════════ GUARD ════════════════════════════════
NOW_ISO=$(date -Iseconds)
NIGHT=$(date -d '12 hours ago' +%F)   # a 00:20 restart belongs to the night that began the evening before
RUN_ID="nightly-$(date +%Y%m%d-%H%M%S)"
GUARD="$STATE/overnight-guard.json"
record() { # decision reason repos_json issues_n run_id
  jq -n --arg at "$NOW_ISO" --arg f "$FIVE" --arg w "$WEEK" --arg d "$1" --arg r "$2" \
     --argjson repos "$3" --argjson n "$4" --arg rid "$5" \
     '{at:$at, quota_remaining:{five_hour:($f|tonumber? // null), seven_day:($w|tonumber? // null)},
       decision:$d, reason:$r, issues:$n, repos:$repos, run_id:(if $rid=="" then null else $rid end)}' \
     > "$GUARD.tmp" 2>/dev/null && mv -f "$GUARD.tmp" "$GUARD"
}
rm -f "$STATE/.quota-seq-idx"
# one guard at a time (two hand starts, or a hand start racing the timer)
exec 9>"$STATE/overnight-guarded.lock"
if ! flock -n 9; then log "another overnight-guarded holds $STATE/overnight-guarded.lock — exiting"; exit 0; fi
# A duplicate attempt only logs, and is checked FIRST: the guard record and sweep-results.json belong to
# the run that started (xreview r2/r3: a 00:20 restart must not overwrite the 23:30 run's report with a
# held-night or no-work record, whatever the quota or queue says by then).
dup() { log "duplicate start refused: $1 (the night's record is left as it is)"; exit 0; }
prev_live() {
  if [ -n "${DREAMTEAM_PREV_LIVE:-}" ]; then [ "$DREAMTEAM_PREV_LIVE" = "1" ]; return; fi
  [ "${DREAMTEAM_TEST:-0}" = "1" ] && return 1
  tmux -L "$TMUX_SOCK" ls >/dev/null 2>&1
}
prev_live && dup "a previous nightly run is still live on tmux -L $TMUX_SOCK"
# one start a night: the marker holds the night key of the last SUCCESSFUL start
if [ "$(cut -d' ' -f1 "$STATE/overnight-night" 2>/dev/null)" = "$NIGHT" ]; then
  dup "already started for the night of $NIGHT ($(cut -d' ' -f2 "$STATE/overnight-night" 2>/dev/null))"
fi

# (a) quota — probed first, judged after the work gate (no work = nothing to hold back, silent)
quota_ok "$FIVE_MIN"; QRC=$?; QR="$QREASON"
log "quota: five_hour=${FIVE:-?} seven_day=${WEEK:-?} → $([ $QRC -eq 0 ] && echo ok || echo "hold: $QR")"

# (b) work gate — queue candidates by rotation, confirmed live over REST
QUEUE="${DREAMTEAM_QUEUE:-$STATE/issues-queue.json}"
NEVER=$(olist never_sweep); PROD=$(olist production_repos); MERGE=$(olist merge_repos)
ROT=$(cat "$STATE/overnight-rotation.json" 2>/dev/null || echo '{}'); jq -e 'type=="object"' <<<"$ROT" >/dev/null 2>&1 || ROT='{}'
CANDS=$(jq -r --argjson never "$NEVER" --argjson rot "$ROT" '
   [.repos[]? | select((.dream // 0) > 0) | select((.repo|split("/")[1]) as $n | ($never | index($n)) | not)]
   | sort_by([($rot[.repo] // ""), -(.dream)]) | .[].repo' "$QUEUE" 2>/dev/null) || CANDS=""
declare -A PERM=()
trusted() { # repo login → rc 0 when the login holds write/maintain/admin there (cached per repo+login)
  [ -n "$2" ] || return 1
  local k="$1|$2"
  if [ -z "${PERM[$k]+x}" ]; then
    PERM[$k]=$(gh api "repos/$1/collaborators/$2/permission" 2>/dev/null | jq -r '.permission // "none"' 2>/dev/null)
  fi
  case "${PERM[$k]}" in admin|maintain|write) return 0;; *) return 1;; esac
}
REPOS='[]'; TOTAL=0; READS=0
for full in $CANDS; do
  [ "$(jq length <<<"$REPOS")" -ge "$MAX_REPOS" ] && break
  READS=$((READS+1)); [ "$READS" -gt $(( MAX_REPOS * 4 )) ] && break
  raw=$(gh api "repos/$full/issues?state=open&labels=dream&per_page=100" 2>/dev/null) || { log "work: cannot read $full — skipped"; continue; }
  # provenance (security review 2026-11-14): issue text is input to an unattended agent, so only issues
  # whose AUTHOR and whose `dream` LABELLER both hold write/maintain/admin on the repo are worked. An
  # outsider's issue on a public repo, or a label added by a read-only account, is skipped and logged.
  cand=$(jq -c --argjson m "$(( MAX_ISSUES * 3 ))" '[.[]? | select(.pull_request|not) | {number, title: (.title[:160]), author: (.user.login // "")}] | .[:$m]' <<<"$raw" 2>/dev/null) || continue
  iss='[]'
  while IFS= read -r it; do
    [ "$(jq length <<<"$iss")" -ge "$MAX_ISSUES" ] && break
    n=$(jq -r .number <<<"$it"); au=$(jq -r .author <<<"$it")
    # every page (xreview r6: a relabel past event 100 must be seen); an unreadable history = untrusted
    lb=""; ev=$(gh api --paginate "repos/$full/issues/$n/events?per_page=100" 2>/dev/null) \
      && lb=$(jq -rs 'add // [] | [.[]? | select(.event=="labeled" and .label.name=="dream")] | last | .actor.login // ""' <<<"$ev" 2>/dev/null)
    if trusted "$full" "$au" && trusted "$full" "$lb"; then iss=$(jq -c --argjson it "$it" '. + [$it | del(.author)]' <<<"$iss")
    else log "work: $full#$n skipped — author '${au:-?}' / dream labeller '${lb:-?}' lacks write access (untrusted input)"; fi
  done < <(jq -c '.[]' <<<"$cand")
  k=$(jq length <<<"$iss"); [ "${k:-0}" -gt 0 ] || continue
  name="${full#*/}"
  if jq -e --arg n "$name" 'index($n)' <<<"$PROD" >/dev/null; then po=true
  elif jq -e --arg n "$name" 'index($n)' <<<"$MERGE" >/dev/null; then po=false
  else po=true; log "work: $full is in neither production_repos nor merge_repos → PR-only"; fi
  REPOS=$(jq -c --arg r "$full" --arg n "$name" --argjson po "$po" --argjson is "$iss" '. + [{repo:$r, name:$n, pr_only:$po, issues:$is}]' <<<"$REPOS")
  TOTAL=$((TOTAL+k))
done
NAMES=$(jq -c '[.[].repo]' <<<"$REPOS")

if [ "$TOTAL" -eq 0 ]; then
  record no-work "no open dream-labelled issue in any queued repo" '[]' 0 ""
  log "no open dream issues (queue $QUEUE, live REST) — nothing to sweep (silent)"
  exit 0
fi

skip() { # reason
  record no-start "$1" "$NAMES" "$TOTAL" ""
  write_sweep "$(jq -n --arg night "$NIGHT" --arg at "$NOW_ISO" --argjson n "$TOTAL" --arg r "$1" \
    '{night:$night, mode:"active", armed_at:$at, fleet:0, quota_guard:{skipped:$n, reason:$r}, fixed:[], reviewed_not_merged:[], too_large:[]}')"
  log "no start: $1 ($TOTAL issue(s) in $NAMES held back)"
  exit 0
}
[ $QRC -eq 0 ] || skip "$QR"

DEADLINE=$(deadline_epoch); LEFT=$(( DEADLINE - $(date +%s) ))
# the night window: a start more than max_hours before stop_at is a daytime start, refused (not clamped:
# a 07:00 hand start must not become a 7.5-hour daytime sweep)
HCAP=$(awk -v h="$MAX_HOURS" 'BEGIN{printf "%d", h*3600}')
[ "$LEFT" -le "$HCAP" ] || skip "outside the night window: $STOP_AT is $((LEFT/3600))h away, more than max ${MAX_HOURS}h"

[ "$LEFT" -ge $(( MIN_START_MIN * 60 )) ] || skip "only $((LEFT/60)) min to the stop cap ($STOP_AT, max ${MAX_HOURS}h; needs $MIN_START_MIN)"



# (c)+(d) the plan and the contained launch
RUN_DIR="$STATE/overnight-runs/$RUN_ID"; mkdir -p "$RUN_DIR"
WT_BASE="${DREAMTEAM_WT_BASE:-$HOME/srv/wt/overnight}"
CLAUDE_BIN="${DREAMTEAM_CLAUDE_BIN:-$HOME/.cargo/bin/claude}"; [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN=claude
jq -n --arg rid "$RUN_ID" --arg night "$NIGHT" --argjson dl "$DEADLINE" --arg wt "$WT_BASE" --arg cb "$CLAUDE_BIN" --argjson repos "$REPOS" \
  '{run_id:$rid, night:$night, deadline_epoch:$dl, wt_base:$wt, claude_bin:$cb, repos:$repos}' > "$RUN_DIR/plan.json"

HIGH=$(sc memoryHigh 20G); MAX=$(sc memoryMax 24G); SWAP=$(sc memorySwapMax 8G)
# The runner goes to tmux as SEPARATE argv words: tmux 3.x execs a multi-argument command directly, with
# no shell, so no path needs quoting and tmux's default-shell does not matter (probed on tmux 3.6:
# "it's $(x)" arrived literally). Kept NUL-separated in runner.argv so the tests run exactly this array.
# Delegate=yes lets scope-attach.sh attach into this scope instead of creating another.
RUNNER=(env "CLAUDE_PLUGIN_ROOT=$ROOT" "DREAMTEAM_STATE=$STATE" "DREAMTEAM_CONFIG=$CFG" bash "$SELF" --runner "$RUN_DIR")
printf '%s\0' "${RUNNER[@]}" > "$RUN_DIR/runner.argv"
LAUNCH=(systemd-run --user --scope -q --unit="dreamteam-$RUN_ID"
        -p MemoryHigh="$HIGH" -p MemoryMax="$MAX" -p MemorySwapMax="$SWAP" -p RuntimeMaxSec="$LEFT" -p Delegate=yes
        tmux -L "$TMUX_SOCK" new-session -d -s "$RUN_ID" -c "$HOME/Projects" "${RUNNER[@]}")

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would start $RUN_ID — $TOTAL issue(s) in $NAMES, cap $(date -d "@$DEADLINE" '+%F %H:%M %Z') (${LEFT}s)"
  echo "DRY_RUN: plan $(jq -c '[.repos[] | {repo, pr_only, issues: [.issues[].number]}]' "$RUN_DIR/plan.json")"
  echo "DRY_RUN: $(printf '%q ' "${LAUNCH[@]}")"
  echo "DRY_RUN runner argv: $RUN_DIR/runner.argv"
  record dry-run "guard passed; DRY_RUN set, nothing started" "$NAMES" "$TOTAL" "$RUN_ID"
  log "dry run $RUN_ID: would start $TOTAL issue(s) in $NAMES"
  exit 0
fi

record started "guard passed: 5h ${FIVE} >= $FIVE_MIN, 7d ${WEEK} >= $SEVEN_MIN" "$NAMES" "$TOTAL" "$RUN_ID"
write_sweep "$(jq -n --arg night "$NIGHT" --arg at "$NOW_ISO" --argjson f "$(jq length <<<"$REPOS")" \
  '{night:$night, mode:"active", armed_at:$at, fleet:$f, quota_guard:{skipped:0, reason:""}, fixed:[], reviewed_not_merged:[], too_large:[]}')"
{
  echo "# Overnight guarded sweep — $NIGHT"
  echo ""
  echo "STARTED $RUN_ID at $(date '+%F %H:%M %Z') — $TOTAL issue(s), cap $(date -d "@$DEADLINE" '+%H:%M %Z'):"
  jq -r '.[] | "- \(.repo) (\(if .pr_only then "PR-only" else "merge after oracle + green" end)): \([.issues[] | "#\(.number)"] | join(" "))"' <<<"$REPOS"
  echo ""
} > "$STATE/overnight-pending.md"
log "started $RUN_ID: $TOTAL issue(s) in $NAMES, cap ${LEFT}s"

if [ "${DREAMTEAM_INLINE:-0}" = "1" ]; then
  echo "$NIGHT $RUN_ID" > "$STATE/overnight-night"
  run_runner "$RUN_DIR"
elif "${LAUNCH[@]}" >>"$LOG" 2>&1 9>&-; then
  echo "$NIGHT $RUN_ID" > "$STATE/overnight-night"
else
  # a failed launch does not consume the night: no marker, so a fixed retry can still start tonight
  log "launch of $RUN_ID FAILED (systemd-run/tmux) — see above; the night is not marked"
  record no-start "the contained launch failed (systemd-run/tmux)" "$NAMES" "$TOTAL" "$RUN_ID"
  echo "LAUNCH FAILED $RUN_ID at $(date '+%F %H:%M %Z') — see state/dreamteam.log" >> "$STATE/overnight-pending.md"
fi
exit 0
