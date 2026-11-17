#!/usr/bin/env bash
# dreamteam — regression tests for scripts/issues-queue.py (the fix machine's queue file) and its
# systemd unit: the six hardening findings of #193 (post-merge xreview of #166).
#
# HERMETIC — nothing real is read or written:
#   • the script is COPIED into $TMP/root/scripts, so its ROOT (and state/) is $TMP/root, never the repo;
#   • PLAN_DATA points at $TMP/plan;
#   • gh is PATH-stubbed: `user/repos…` serves $FAKE/discovery (FAKE_DISCOVERY=fail|hang|object), and
#     `repos/<o>/<n>/issues…` serves $FAKE/<o>__<n>, or fails when $FAKE/<o>__<n>.fail exists, or sleeps
#     (as a CHILD process, so only a process-group kill ends it) when $FAKE/<o>__<n>.hang exists; argv → $TMP/gh.log;
#   • systemctl is PATH-stubbed: every timer inactive (FAKE_SYSTEMCTL=hang sleeps instead).
#
# Run standalone:  bash tests/test-issues-queue.sh   (exit 0 = all pass, 1 = any fail)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVC="$ROOT/systemd/issues-queue.service"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; R="$TMP/root"; FAKE="$TMP/fake"; P="$TMP/plan"
mkdir -p "$BIN" "$R/scripts"
cp "$ROOT/scripts/issues-queue.py" "$R/scripts/"

cat > "$BIN/gh" <<'S'
#!/bin/bash
echo "$*" >> "$TMP/gh.log"
p="${@: -1}"
case "$p" in
  user/repos*)
    case "${FAKE_DISCOVERY:-}" in
      fail) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
      hang) sleep 30 & echo $! > "$FAKE/discovery.pid"; wait; exit 0 ;;
      badbytes) printf '[\xff]'; exit 0 ;;
      emptyrecord) echo '[{}]'; exit 0 ;;
      nocount) echo '[{"full_name":"jphein/a","archived":false,"has_issues":true}]'; exit 0 ;;
      object) echo '{"message":"Bad credentials"}'; exit 0 ;;
      emptyobject) echo '{}'; exit 0 ;;
      scalars) echo '[1,2]'; exit 0 ;;
    esac
    cat "$FAKE/discovery" ;;
  repos/*/issues*)
    r="${p#repos/}"; r="${r%%/issues*}"; f="$FAKE/${r//\//__}"
    [ -e "$f.fail" ] && { echo "HTTP 500" >&2; exit 1; }
    [ -e "$f.hang" ] && { sleep 30 & echo $! > "$f.pid"; wait; exit 0; }
    if [ -e "$f" ]; then cat "$f"; else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
S
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "$*" >> "$FAKE/systemctl.log"
[ "${FAKE_SYSTEMCTL:-}" = hang ] && { sleep 30 & echo $! >> "$FAKE/systemctl.pids"; wait; exit 0; }
case "$*" in
  *is-active*dreamteam-nightly-guarded.timer*) [ "${FAKE_GUARDED:-0}" != 0 ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
  *NextElapseUSecRealtime*dreamteam-nightly-guarded.timer*) [ "${FAKE_GUARDED:-0}" = 2 ] && { echo "n/a"; exit 0; }; echo "Sat 2026-11-14 23:30:00 PST" ;;
  *is-active*) echo inactive; exit 3 ;;
  *NextElapseUSecRealtime*) echo "n/a" ;;
  *) exit 1 ;;
esac
S
chmod +x "$BIN/gh" "$BIN/systemctl"
export TMP FAKE
export DREAMTEAM_CHECKS_DIR="$TMP/checks" DREAMTEAM_CHECK_HOST=familiar   # never a real check line

# iss NUMBER TITLE [LABEL...] → one issue object
iss(){ local n="$1" t="$2"; shift 2; jq -nc --argjson n "$n" --arg t "$t" --args '{number:$n, title:$t, labels:[$ARGS.positional[]|{name:.}]}' "$@"; }
# disc REPO... → discovery page (each repo has open issues)
disc(){ jq -nc --args '[$ARGS.positional[] | {full_name:., archived:false, has_issues:true, open_issues_count:3}]' "$@"; }
reset(){ rm -rf "$FAKE" "$R/state" "$P" "$TMP/gh.log"; mkdir -p "$FAKE" "$P"; unset FAKE_DISCOVERY FAKE_SYSTEMCTL FAKE_GUARDED; }
# run → rc in $RC; output in $TMP/out; bounded by an outer timeout so a hang is a FAIL, not a stuck suite
run(){ (cd "$TMP" && umask 022 && PATH="$BIN:$PATH" PLAN_DATA="$P" ISSUES_QUEUE_TIMEOUT="${IQT:-20}" ISSUES_QUEUE_BUDGET="${IQB:-60}" \
        timeout "${OUTER:-15}" python3 -I "$R/scripts/issues-queue.py") > "$TMP/out" 2>&1; RC=$?; }
# alive PIDFILE... → rc 0 when any recorded child is still running
alive(){ local f p; for f in "$@"; do [ -s "$f" ] || continue; while read -r p; do kill -0 "$p" 2>/dev/null && return 0; done < "$f"; done; return 1; }
sj(){ jq -r "$1" "$R/state/issues-queue.json" 2>/dev/null; }
pj(){ jq -r "$1" "$P/issues-queue.json" 2>/dev/null; }
seed(){ mkdir -p "$R/state"; echo '{"generated":"OLD"}' > "$R/state/issues-queue.json"; echo '{"generated":"OLD"}' > "$P/issues-queue.json"; }

echo "── 1. pagination: successive JSON documents, not a string replace ──"
reset; disc jphein/a > "$FAKE/discovery"
{ printf '[%s]' "$(iss 1 'break ][ parser' bug)"; printf '[%s]' "$(iss 2 'second page')"; } > "$FAKE/jphein__a"
run
[ "$RC" = 0 ] && [ "$(sj '.repos[0].open')" = 2 ] && pass "two pages joined as ][ → 2 issues" || fail "][ pages: rc=$RC open=$(sj '.repos[0].open') $(tail -2 "$TMP/out")"
reset; disc jphein/a > "$FAKE/discovery"
{ printf '[%s]' "$(iss 1 'break ][ parser' dream)"; printf '[%s]' "$(iss 2 'second page')"; } > "$FAKE/jphein__a"
run
[ "$(sj '.repos[0].top[0].title')" = 'break ][ parser' ] && pass "a title holding ][ survives byte for byte" || fail "title corrupted: $(sj '.repos[0].top[0].title')"
reset; disc jphein/a > "$FAKE/discovery"
{ printf '[%s]\n' "$(iss 1 one)"; printf '\n[%s,%s]\n' "$(iss 2 two)" "$(iss 3 three)"; } > "$FAKE/jphein__a"
run
[ "$RC" = 0 ] && [ "$(sj '.repos[0].open')" = 3 ] && pass "pages separated by whitespace → 3 issues" || fail "whitespace pages: rc=$RC open=$(sj '.repos[0].open')"
reset; { disc jphein/a; disc jphein/b; } > "$FAKE/discovery"
run
[ "$(sj '[.repos[].repo]|join(",")')" = "jphein/a,jphein/b" ] && pass "discovery pages are joined too" || fail "discovery pages: $(sj '[.repos[].repo]')"
reset; disc jphein/a > "$FAKE/discovery"; printf '[%s] trailing-garbage' "$(iss 1 one)" > "$FAKE/jphein__a"
run
[ "$(sj '.complete')" = false ] && [ "$(sj '.failed_repos|join(",")')" = "jphein/a" ] && pass "a page that is not JSON fails that repo (not silently dropped)" || fail "garbage page: complete=$(sj .complete) failed=$(sj .failed_repos)"

echo "── 2. failure keeps the previous snapshot; partial runs say so ─────"
for mode in fail object emptyobject scalars emptyrecord nocount badbytes; do
  reset; disc jphein/a > "$FAKE/discovery"; seed; export FAKE_DISCOVERY=$mode
  run
  [ "$RC" = 2 ] && [ "$(sj .generated)" = OLD ] && [ "$(pj .generated)" = OLD ] \
    && pass "discovery $mode → rc $RC, both previous snapshots kept" || fail "discovery $mode: rc=$RC state=$(sj .generated) plan=$(pj .generated)"
done
reset; disc jphein/a jphein/b > "$FAKE/discovery"; touch "$FAKE/jphein__b.fail"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"
run
[ "$RC" = 1 ] && [ "$(sj .complete)" = false ] && [ "$(sj '.failed_repos|join(",")')" = "jphein/b" ] && [ "$(sj '.repos[0].repo')" = jphein/a ] \
  && [ "$(pj .complete)" = false ] && pass "one repo fails → published with complete=false, failed_repos=[jphein/b], rc 1" \
  || fail "per-repo failure: rc=$RC complete=$(sj .complete) failed=$(sj .failed_repos) plan=$(pj .complete)"
reset; disc jphein/a > "$FAKE/discovery"
run
[ "$RC" = 0 ] && [ "$(sj .complete)" = true ] && [ "$(sj '.failed_repos|length')" = 0 ] && pass "clean run → complete=true, failed_repos=[]" || fail "clean run: rc=$RC complete=$(sj .complete)"

reset; disc jphein/a jphein/b > "$FAKE/discovery"; echo '[{"number":1,"labels":[{"name":"dream"}]}]' > "$FAKE/jphein__a"
run
[ "$RC" = 1 ] && [ "$(sj '.failed_repos|join(",")')" = jphein/a ] && [ "$(sj '.repos[0].repo')" = jphein/b ] && pass "an issue with no title fails its repo, the rest publish" || fail "malformed issue: rc=$RC failed=$(sj .failed_repos) $(tail -1 "$TMP/out")"

for case in empty dream6 badbytes deep zero; do
  reset; disc jphein/a jphein/b > "$FAKE/discovery"
  case $case in
    empty) echo '[{}]' > "$FAKE/jphein__a" ;;
    dream6) { printf '['; for n in 1 2 3 4 5; do iss "$n" "d $n" dream; printf ','; done; echo '{"number":6,"labels":[{"name":"dream"}]}]'; } > "$FAKE/jphein__a" ;;
    badbytes) printf '[\xff]' > "$FAKE/jphein__a" ;;
    deep) python3 -c 'print("["*100000 + "]"*100000)' > "$FAKE/jphein__a" ;;
    zero) echo '[{"number":0,"title":"zero","labels":[{"name":"dream"}]}]' > "$FAKE/jphein__a" ;;
  esac
  run
  [ "$RC" = 1 ] && [ "$(sj '.failed_repos|join(",")')" = jphein/a ] && [ "$(sj '.repos[0].repo')" = jphein/b ] \
    && pass "issues answer '$case' fails its repo, the rest publish" || fail "issues '$case': rc=$RC failed=$(sj .failed_repos) $(tail -1 "$TMP/out")"
done

echo "── 3. OWNERS is an allowlist; files are private ────────────────────"
reset; disc jphein/a stranger/x techempower-org/t JPHein/c > "$FAKE/discovery"
run
[ "$(sj '[.repos[].repo]|join(",")')" = "JPHein/c,jphein/a,techempower-org/t" ] && pass "a repo outside OWNERS is not exported" || fail "owners: $(sj '[.repos[].repo]')"
grep -q 'repos/stranger/x/issues' "$TMP/gh.log" && fail "a repo outside OWNERS was read" || pass "a repo outside OWNERS is never read"
[ "$(stat -c %a "$R/state/issues-queue.json")" = 600 ] && [ "$(stat -c %a "$P/issues-queue.json")" = 600 ] \
  && pass "both files are 0600 under umask 022" || fail "modes: state=$(stat -c %a "$R/state/issues-queue.json") plan=$(stat -c %a "$P/issues-queue.json")"

echo "── 4. blocked_on_jp equals the needs_jp list length ────────────────"
reset; disc jphein/a > "$FAKE/discovery"
{ printf '['; for n in $(seq 1 25); do [ "$n" -gt 1 ] && printf ','; iss "$n" "needs $n" needs-jp; done; printf ']'; } > "$FAKE/jphein__a"
run
[ "$(sj '.repos[0].blocked_on_jp')" = 25 ] && [ "$(sj '.repos[0].needs_jp|length')" = 25 ] && pass "25 needs-jp → count 25, list 25" \
  || fail "needs_jp: count=$(sj '.repos[0].blocked_on_jp') list=$(sj '.repos[0].needs_jp|length')"

echo "── 5. deadlines: no subprocess can hold the run ────────────────────"
reset; disc jphein/a jphein/b > "$FAKE/discovery"; touch "$FAKE/jphein__b.hang"
S0=$(date +%s); IQT=1 run; S1=$(date +%s)
alive "$FAKE/jphein__b.pid" && fail "the hung gh's child survived the deadline" || pass "the hung gh's child is dead after the run"
[ "$RC" = 1 ] && [ $((S1-S0)) -lt 5 ] && [ "$(sj '.failed_repos|join(",")')" = jphein/b ] \
  && pass "a hung gh (child sleep) is killed at the deadline → that repo failed, run ends in $((S1-S0)) s" || fail "gh hang: rc=$RC $((S1-S0)) s failed=$(sj .failed_repos)"
reset; disc jphein/a > "$FAKE/discovery"; seed; export FAKE_DISCOVERY=hang
S0=$(date +%s); IQT=1 run; S1=$(date +%s)
alive "$FAKE/discovery.pid" && fail "the hung discovery's child survived" || pass "the hung discovery's child is dead after the run"
[ "$RC" = 2 ] && [ $((S1-S0)) -lt 5 ] && [ "$(sj .generated)" = OLD ] && pass "a hung discovery → rc $RC, previous snapshot kept" || fail "discovery hang: rc=$RC state=$(sj .generated)"
reset; disc jphein/a jphein/b jphein/c > "$FAKE/discovery"; touch "$FAKE/jphein__a.hang" "$FAKE/jphein__b.hang" "$FAKE/jphein__c.hang"
S0=$(date +%s); IQT=20 IQB=50 run; S1=$(date +%s)   # gh gets 50 - 44 reserve - 1 grace = 5 s
[ "$RC" = 1 ] && [ $((S1-S0)) -lt 10 ] && [ "$(sj '.failed_repos|length')" = 3 ] && [ "$(pj .complete)" = false ] \
  && pass "the run budget caps gh (3 hung repos, 20 s per call, 6 s of gh budget) → partial published in $((S1-S0)) s" || fail "budget: rc=$RC $((S1-S0)) s failed=$(sj .failed_repos)"
reset; disc jphein/a jphein/b jphein/c > "$FAKE/discovery"; touch "$FAKE/jphein__a.hang" "$FAKE/jphein__b.hang" "$FAKE/jphein__c.hang"; export FAKE_SYSTEMCTL=hang
S0=$(date +%s); IQT=4 IQB=24 OUTER=40 run; S1=$(date +%s)
[ "$RC" = 1 ] && [ $((S1-S0)) -le 24 ] && [ "$(sj '.failed_repos|length')" = 3 ] \
  && pass "hung gh AND hung systemctl stay inside the budget (24 s): run ends in $((S1-S0)) s" || fail "budget with systemctl: rc=$RC $((S1-S0)) s failed=$(sj .failed_repos)"
alive "$FAKE/systemctl.pids" && fail "a hung systemctl's child survived" || pass "every hung systemctl child is dead after the run"
reset; disc jphein/a jphein/b jphein/c jphein/d jphein/e > "$FAKE/discovery"; export FAKE_GUARDED=1
for r in a b c d e; do touch "$FAKE/jphein__$r.hang"; done
IQT=4 IQB=24 OUTER=40 run
[ "$RC" = 1 ] && [ "$(sj .next_sweep.mode)" = guarded ] && [ "$(sj '.failed_repos|length')" = 5 ] \
  && pass "gh cannot spend the systemctl reserve: 5 hung repos, guarded timer still read (mode guarded)" || fail "reserve: rc=$RC mode=$(sj .next_sweep.mode) failed=$(sj '.failed_repos|length')"
reset; disc jphein/a > "$FAKE/discovery"; export FAKE_GUARDED=2
run; n=$(wc -l < "$FAKE/systemctl.log")
k=$(cd "$TMP" && python3 -I -c "import importlib.util as u; s=u.spec_from_file_location('iq','$R/scripts/issues-queue.py'); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.SYS_CALLS)")
[ "$RC" = 0 ] && [ "$n" = 4 ] && [ "$k" -ge "$n" ] && pass "guarded timer active, elapse unreadable: $n systemctl calls, reserve sized for $k" || fail "systemctl calls: rc=$RC calls=$n reserve-for=$k"
reset; disc jphein/a > "$FAKE/discovery"; export FAKE_SYSTEMCTL=hang
S0=$(date +%s); IQT=1 run; S1=$(date +%s)
[ "$RC" = 0 ] && [ "$(sj .next_sweep.mode)" = pilot ] && pass "a hung systemctl → fallback next_sweep, run ends in $((S1-S0)) s" || fail "systemctl hang: rc=$RC mode=$(sj .next_sweep.mode)"
T=$(sed -n 's/^TimeoutStartSec=\([0-9]*\)\(min\|s\|\)$/\1 \2/p' "$SVC")
case "$T" in
  *" min") [ "${T% min}" -ge 1 ] && [ "${T% min}" -le 30 ] && pass "service has TimeoutStartSec=${T% min}min" || fail "TimeoutStartSec out of range: $T" ;;
  *" s") [ "${T% s}" -ge 60 ] && [ "${T% s}" -le 1800 ] && pass "service has TimeoutStartSec=${T% s}s" || fail "TimeoutStartSec out of range: $T" ;;
  *) fail "service has no bounded TimeoutStartSec (got '$T')" ;;
esac
if command -v systemd-analyze >/dev/null; then
  # only this unit's own lines count (verify also reports unrelated installed units); a missing ExecStart is fine
  out=$(systemd-analyze --user verify "$SVC" 2>&1 | grep -F "issues-queue.service:" | grep -v "is not executable\|No such file" || true)
  [ -z "$out" ] && pass "systemd-analyze verify: service clean" || fail "verify: $out"
fi

for v in nan inf -inf abc; do
  reset; disc jphein/a > "$FAKE/discovery"; seed; export FAKE_DISCOVERY=hang
  S0=$(date +%s); IQT=$v run; S1=$(date +%s)
  [ "$RC" = 2 ] && [ $((S1-S0)) -lt 5 ] && [ ! -e "$TMP/gh.log" ] && [ "$(sj .generated)" = OLD ] \
    && pass "ISSUES_QUEUE_TIMEOUT=$v → rc 2 before any gh call, snapshot kept" || fail "timeout=$v: rc=$RC $((S1-S0)) s gh=$(cat "$TMP/gh.log" 2>/dev/null | head -1) $(tail -1 "$TMP/out")"
done
reset; disc jphein/a > "$FAKE/discovery"; seed
IQB=nan run
[ "$RC" = 2 ] && [ ! -e "$TMP/gh.log" ] && pass "ISSUES_QUEUE_BUDGET=nan → rc 2 before any gh call" || fail "budget=nan: rc=$RC"

echo "── 5b. the CHECK line (issues-queue) ─────────────────────────────────"
ql(){ cat "$TMP/checks/issues-queue.line" 2>/dev/null; }
QSHAPE='^CHECK issues-queue (ok|warn|fail) · [^·]+ · next [0-9]{2}:50, owner Sen$'
reset; rm -rf "$TMP/checks"; disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 one dream)]" > "$FAKE/jphein__a"; run
[ "$RC" = 0 ] && [[ "$(ql)" =~ $QSHAPE ]] && [[ "$(ql)" == "CHECK issues-queue ok · 1 repos, open 1, dream 1, on JP 0, bad rows 0, complete · "* ]] \
  && pass "line: complete run → ok with the counts" || fail "line ok: rc=$RC '$(ql)'"
reset; rm -rf "$TMP/checks"; disc jphein/a jphein/b > "$FAKE/discovery"; touch "$FAKE/jphein__b.fail"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"; run
[ "$RC" = 1 ] && [[ "$(ql)" == "CHECK issues-queue warn · "*"INCOMPLETE: 1 repo(s) failed: jphein/b · "* ]] && pass "line: a failed repo → warn naming it" || fail "line warn: rc=$RC '$(ql)'"
reset; rm -rf "$TMP/checks"; disc jphein/a > "$FAKE/discovery"; export FAKE_DISCOVERY=fail; run
[ "$RC" = 2 ] && [[ "$(ql)" == "CHECK issues-queue fail · discovery failed, nothing published (previous snapshot kept)"* ]] && pass "line: discovery failure → fail" || fail "line disc: rc=$RC '$(ql)'"
reset; rm -rf "$TMP/checks"; disc jphein/a > "$FAKE/discovery"; IQT=nan run
[ "$RC" = 2 ] && [[ "$(ql)" == "CHECK issues-queue fail · bad configuration"* ]] && pass "line: bad configuration → fail" || fail "line config: rc=$RC '$(ql)'"
reset; rm -rf "$TMP/checks"; disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"; mkdir -p "$P"; rm -rf "$R/state"; : > "$R/state"; run
[[ "$(ql)" == "CHECK issues-queue fail · crashed: "* ]] && [ "$RC" -ne 0 ] && pass "line: a crash (state path is a file) → fail, crashed: <type>" || fail "line crash: rc=$RC '$(ql)'"
rm -f "$R/state"
reset; rm -rf "$TMP/checks"; mkdir -p "$TMP/checks"; echo SENTINEL > "$TMP/qsent"; ln -s "$TMP/qsent" "$TMP/checks/issues-queue.line"
disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"; run
[ "$(cat "$TMP/qsent")" = SENTINEL ] && [ -f "$TMP/checks/issues-queue.line" ] && [ ! -L "$TMP/checks/issues-queue.line" ] && pass "line: a symlink at the destination is replaced, never followed" || fail "line symlink followed"
reset; rm -rf "$TMP/checks"; mkdir -p "$TMP/checks/issues-queue.line"; disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"; run
[ "$RC" = 0 ] && [ -z "$(ls -A "$TMP/checks/issues-queue.line")" ] && pass "line: a directory at the destination is refused; the run still succeeds" || fail "line dir: rc=$RC"
rm -rf "$TMP/checks"
reset; rm -rf "$TMP/checks"; disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 $'one \u00b7 two')]" > "$FAKE/jphein__a"; DREAMTEAM_CHECK_HOST=katana run
[ -f "$TMP/checks/issues-queue-katana.line" ] && pass "line: off familiar the name carries the host" || fail "line host: $(ls "$TMP/checks")"

# check_line() itself (the Python twin of scripts/lib/check-line.sh), called directly on the copied script
pyline(){ (cd "$TMP" && DREAMTEAM_CHECKS_DIR="$TMP/pyc" DREAMTEAM_CHECK_HOST="${1:-familiar}" python3 -I - "$R/scripts/issues-queue.py" "${@:2}") 2>&1; }
rm -rf "$TMP/pyc"
out=$(pyline familiar <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("iq", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
print(m.check_line("ok", "a · b\r\nc"))
PY
)
[ "$(cat "$TMP/pyc/issues-queue.line")" = "$(head -1 <<<"$out")" ] && [[ "$(cat "$TMP/pyc/issues-queue.line")" == "CHECK issues-queue ok · a, b c · next "??":50, owner Sen" ]] \
  && pass "py check_line: ' · ' → ', ' and CR/LF → one space, one fact segment, published" || fail "py sanitize: [$(cat "$TMP/pyc/issues-queue.line" 2>/dev/null)] out=[$out]"
rm -rf "$TMP/pyc"; out=$(pyline familiar <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("iq", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
for f in ("a · · b", "a ·", "· a"):
    m.check_line("ok", f)
    print(open(m.pathlib.Path(m.os.environ["DREAMTEAM_CHECKS_DIR"]) / "issues-queue.line").read().strip())
PY
)
want=$'CHECK issues-queue ok · a, , b · next
CHECK issues-queue ok · a , · next
CHECK issues-queue ok · , a · next'
got=$(grep '^CHECK' <<<"$out" | awk 'NR%2==0' | sed -E 's/ [0-9]{2}:50, owner Sen$//')
[ "$got" = "$want" ] && pass "py check_line: 'a · · b', 'a ·', '· a' each stay ONE fact segment" || fail "py edges: [$got]"
rm -rf "$TMP/pyc"; out=$(pyline familiar <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("iq", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
m.check_line("maybe", "x")
PY
)
[[ "$(cat "$TMP/pyc/issues-queue.line" 2>/dev/null)" == "CHECK issues-queue fail · unknown status 'maybe': x · "* ]] && pass "py check_line: unknown status → fail" || fail "py status: $(cat "$TMP/pyc/issues-queue.line" 2>/dev/null)"
rm -rf "$TMP/pyc"; out=$(pyline familiar <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("iq", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
for bad in ("../x", "Upper", "a_b", "-lead"):
    m.check_name = lambda base, b=bad: b
    m.check_line("ok", "x")
PY
)
[ -z "$(ls -A "$TMP/pyc" 2>/dev/null)" ] && [ ! -e "$TMP/x.line" ] && [ "$(grep -c 'not one the Watch reads' <<<"$out")" = 4 ] \
  && pass "py check_line: names the Watch would not read are never published (4 cases)" || fail "py names: $(ls -A "$TMP/pyc" 2>/dev/null) $out"
rm -rf "$TMP/pyc"; pyline KATANA.lan >/dev/null <<'PY'
import importlib.util as u, sys
s = u.spec_from_file_location("iq", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
m.check_line("ok", "x")
PY
[ -f "$TMP/pyc/issues-queue-katanalan.line" ] && pass "py check_name: host lower-cased, [a-z0-9-] only" || fail "py host: $(ls "$TMP/pyc")"
rm -rf "$TMP/pyc"

echo "── 6. publication: unique temp names, atomic replace ───────────────"
reset; disc jphein/a > "$FAKE/discovery"; seed
mkdir "$P/issues-queue.json.tmp" "$R/state/issues-queue.json.tmp"   # a stale fixed temp name is in the way
I0=$(stat -c %i "$R/state/issues-queue.json")
run
[ "$RC" = 0 ] && [ "$(pj .complete)" = true ] && [ "$(sj .complete)" = true ] && pass "a stale *.tmp in either dir does not block publication" || fail "stale tmp: rc=$RC plan=$(pj .complete) state=$(sj .complete) $(tail -1 "$TMP/out")"
[ "$(stat -c %i "$R/state/issues-queue.json")" != "$I0" ] && pass "state file is replaced (new inode), not rewritten in place" || fail "state file rewritten in place"
left=$(find "$P" "$R/state" -maxdepth 1 -name '*issues-queue*' ! -name issues-queue.json ! -name issues-queue.json.tmp | wc -l)
[ "$left" = 0 ] && pass "no temp file left behind" || fail "temp files left: $(find "$P" "$R/state" -maxdepth 1 -name '*issues-queue*')"
reset; disc jphein/a > "$FAKE/discovery"; echo "[$(iss 1 one)]" > "$FAKE/jphein__a"
( run; echo "$RC" > "$TMP/rc1" ) & ( (cd "$TMP" && PATH="$BIN:$PATH" PLAN_DATA="$P" timeout 15 python3 -I "$R/scripts/issues-queue.py" >/dev/null 2>&1; echo $? > "$TMP/rc2") ) &
wait
[ "$(cat "$TMP/rc1")" = 0 ] && [ "$(cat "$TMP/rc2")" = 0 ] && [ "$(pj '.repos[0].open')" = 1 ] && [ "$(sj '.repos[0].open')" = 1 ] \
  && pass "smoke: two overlapping runs both exit 0 and leave a whole file" || fail "overlap: rc1=$(cat "$TMP/rc1") rc2=$(cat "$TMP/rc2") plan=$(pj '.repos[0].open')"
# white box: publish() never touches the destination before one os.replace from a same-dir temp holding the whole
# text, and two publishes use two temp names (an unlink-then-write, an in-place write or a fixed name fails here)
mkdir -p "$TMP/wb"; echo OLD > "$TMP/wb/q.json"; chmod 644 "$TMP/wb/q.json"
cat > "$TMP/wb.py" <<'WB'
import importlib.util, os, pathlib, sys
sp = importlib.util.spec_from_file_location("iq", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
dest = pathlib.Path(sys.argv[2]); seen = []; real = os.replace
def spy(src, dst):
    assert pathlib.Path(dst) == dest, dst
    assert pathlib.Path(src).parent == dest.parent, src
    want_old = "OLD\n" if not seen else "NEW0\n"
    assert dest.read_text() == want_old, "destination changed before the replace"
    assert pathlib.Path(src).read_text() == f"NEW{len(seen)}\n", "temp file is not the whole text"
    seen.append(str(src)); real(src, dst)
m.os.replace = spy
for k in range(2):
    m.publish(dest, f"NEW{k}\n")
assert len(seen) == 2 and seen[0] != seen[1], seen
assert dest.read_text() == "NEW1\n" and oct(dest.stat().st_mode & 0o777) == "0o600"
print("ok")
WB
wb=$(cd "$TMP" && python3 -I "$TMP/wb.py" "$R/scripts/issues-queue.py" "$TMP/wb/q.json" 2>&1 | tail -1)
[ "$wb" = ok ] && pass "publish(): one same-dir os.replace per file, whole text, unique temp names, 0600 even over a 0644 file" || fail "publish white box: $wb"
reset; disc jphein/a > "$FAKE/discovery"; rmdir "$P"
run
[ "$RC" = 0 ] && [ ! -e "$P" ] && [ "$(sj .complete)" = true ] && pass "no plan data dir → state only, nothing created" || fail "no plan dir: rc=$RC"

echo "─────────────────────────────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
