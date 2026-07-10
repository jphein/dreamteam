#!/usr/bin/env bash
# dreamteam — regression tests for the #26 WorktreeCreate hook adapter.
#
#   THE BUG (#26): WorktreeCreate was wired ONLY to team-events.sh (async logger
#   that returns nothing), so the runtime got no path and failed:
#     "WorktreeCreate hook failed: hook succeeded but returned no worktree path".
#
#   THE FIX: scripts/worktree-create-hook.sh — a SYNC command hook that provisions
#   the worktree and prints ONLY its absolute path on stdout (the command-hook
#   contract), branching off HEAD and copying opt-in git-ignored build inputs.
#
# ISOLATION: fully hermetic — a throwaway git repo in a temp dir, a LOCAL base
# (no network/origin), removed on exit. The adapter is pointed at the real
# provision script but run entirely inside the temp repo. No production state is
# touched. (Sibling test-worktree-provision.sh covers the provision script alone;
# test-worktree.sh covers the worktree-GUARD hook.)
#
# Run standalone:  bash tests/test-worktree-create.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/worktree-create-hook.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# 0) static: the adapter must parse.
if bash -n "$HOOK" 2>/dev/null; then pass "worktree-create-hook.sh passes bash -n"; else fail "syntax error in adapter"; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/sub/dir"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo x > "$REPO/sub/dir/f"
git -C "$REPO" add sub/dir/f
git -C "$REPO" commit -qm init >/dev/null
git -C "$REPO" branch -M main

# run_hook <payload-json>  → OUT (stdout), HRC (exit), $TMP/err (stderr).
# CLAUDE_PLUGIN_ROOT/DREAMTEAM_PROVISION seams pin the adapter at the real scripts.
OUT=""; HRC=0
run_hook() {
  HRC=0
  OUT="$(printf '%s' "$1" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_PROVISION="$ROOT/scripts/worktree-provision.sh" \
      bash "$HOOK" 2>"$TMP/err")" || HRC=$?
}
payload() { printf '{"hook_event_name":"WorktreeCreate","name":"%s","cwd":"%s","agent_type":"morpheus","session_id":"s1"}' "$1" "$2"; }

# ── (1) THE #26 CONTRACT: from a SUBDIR cwd, stdout is EXACTLY the repo-root path.
run_hook "$(payload modelA-33 "$REPO/sub/dir")"
EXPECT="$REPO/.claude/worktrees/modelA-33"
[ "$HRC" -eq 0 ]         && pass "adapter exits 0 on success"                 || fail "exit $HRC; stderr: $(tail -1 "$TMP/err")"
[ "$OUT" = "$EXPECT" ]   && pass "stdout is the repo-root worktree path"      || fail "path: expected '$EXPECT' got '$OUT'"
# stdout PURITY — the crux of #26: git chatter must be on stderr, stdout ONLY the path.
if [ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" = "0" ] && [ -n "$OUT" ] && case "$OUT" in /*) true;; *) false;; esac; then
  pass "stdout is a single clean absolute-path line (no git chatter leak)"
else
  fail "stdout not a lone absolute path: [$OUT]"
fi
[ -d "$EXPECT" ]         && pass "worktree exists at REPO ROOT (cwd-independent)" || fail "worktree missing at repo root"
[ ! -e "$REPO/sub/dir/.claude/worktrees/modelA-33" ] && pass "NOT nested under the subdir cwd" || fail "nested under subdir — bug"
git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $EXPECT" \
  && pass "worktree registered with git" || fail "worktree not registered"
git -C "$REPO" show-ref --verify --quiet "refs/heads/dream/modelA-33" \
  && pass "branch dream/modelA-33 created off HEAD" || fail "branch not created"

# ── (2) copyIgnored: opt-in marker copies git-ignored build inputs so it compiles.
mkdir -p "$REPO/.claude" "$REPO/build"
printf '# ignored build inputs\nbuild/secrets.rs\n\n' > "$REPO/.claude/worktree-copy"
echo "const KEY=1;" > "$REPO/build/secrets.rs"     # git-ignored (never added/committed)
run_hook "$(payload withcopy "$REPO")"
CP="$REPO/.claude/worktrees/withcopy/build/secrets.rs"
[ "$HRC" -eq 0 ] && [ -f "$CP" ] && [ "$(cat "$CP")" = "const KEY=1;" ] \
  && pass "copyIgnored: marker-listed input copied into new worktree" \
  || fail "copyIgnored: '$CP' missing/mismatched (exit $HRC)"

# ── (3) NEGATIVE CONTROL: without the marker, nothing is copied (no-op) but the
#        worktree still provisions cleanly. Proves the copy is genuinely opt-in.
rm -f "$REPO/.claude/worktree-copy"
run_hook "$(payload nocopy "$REPO")"
[ "$HRC" -eq 0 ] && [ ! -e "$REPO/.claude/worktrees/nocopy/build/secrets.rs" ] \
  && pass "no marker → no copy, provision still succeeds (opt-in confirmed)" \
  || fail "no-marker case wrong (exit $HRC)"

# ── (4) name sanitization: slashes/spaces collapse to ONE safe dir segment.
run_hook "$(payload "weird/../name here" "$REPO")"
SAN="$OUT"
case "$SAN" in
  "$REPO/.claude/worktrees/"*) seg="${SAN##*/worktrees/}" ;;
  *) seg="" ;;
esac
if [ -n "$seg" ] && case "$seg" in */*|*" "*|"") false;; *) true;; esac && [ -d "$SAN" ]; then
  pass "unsafe name sanitized to one path segment ('$seg')"
else
  fail "name sanitization failed: [$SAN]"
fi

# ── (5) fallback: missing .name uses .agent_type, still provisions.
run_hook '{"hook_event_name":"WorktreeCreate","cwd":"'"$REPO"'","agent_type":"lucid","session_id":"s2"}'
[ "$HRC" -eq 0 ] && [ -n "$OUT" ] && [ -d "$OUT" ] \
  && pass "missing .name falls back (agent_type) and still provisions" \
  || fail "name fallback failed (exit $HRC, out '$OUT')"

# ── (6) FAILURE PATH: cwd is NOT a git repo → NON-ZERO exit (fails creation
#        cleanly), NOT a silent exit-0-with-no-path (the #26 confusion).
run_hook "$(payload x "$TMP/not-a-repo")"
[ "$HRC" -ne 0 ] && pass "non-repo cwd → non-zero exit (creation fails cleanly, no phantom success)" \
  || fail "non-repo cwd should fail — got exit 0, out '$OUT'"

# ── (7) #66 REGRESSION GUARD: the WorktreeCreate matcher must contain EXACTLY ONE
#        hook — the path producer. #66's root cause: a 2nd (async team-events) hook
#        shared the matcher, and the runtime consumed the logger (no path) instead of
#        the path producer → "hook succeeded but returned no worktree path", no worktree
#        (verified live: no dream/* branch ever created). This fails if a second hook is
#        re-added to WorktreeCreate. Negative control: team-events must STILL be wired
#        elsewhere (proves we removed it from ONE matcher, not unwired it globally).
WCINV="$(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])).get("hooks",{})
cmds=[x.get("command","") for g in h.get("WorktreeCreate",[]) for x in g.get("hooks",[])]
prob=[]
if len(cmds)!=1: prob.append("WorktreeCreate has %d hooks, must be exactly 1"%len(cmds))
if not (cmds and "worktree-create-hook.sh" in cmds[0]): prob.append("sole hook must be worktree-create-hook.sh")
if any("team-events" in c for c in cmds): prob.append("team-events still shares the WorktreeCreate matcher (#66)")
te_elsewhere=any("team-events" in x.get("command","")
  for ev,a in h.items() if ev!="WorktreeCreate" for g in a for x in g.get("hooks",[]))
if not te_elsewhere: prob.append("team-events unwired from ALL events (over-removed)")
print("OK" if not prob else "BAD: "+"; ".join(prob))
PY
)"
[ "$WCINV" = "OK" ] && pass "#66: WorktreeCreate is a single path-producer hook (team-events still wired elsewhere)" \
  || fail "#66 matcher invariant — $WCINV"

# ── (8) #66: the sole hook now self-logs the WorktreeCreate event (team-events used to,
#        from the shared matrix). Logging must go to events.log, NEVER stdout (stdout is
#        the path the runtime reads). DREAMTEAM_EVENTS_LOG seam redirects the log here.
EVL="$TMP/events.log"; : > "$EVL"
OUT="$(printf '%s' "$(payload logtest "$REPO")" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" DREAMTEAM_PROVISION="$ROOT/scripts/worktree-provision.sh" \
    DREAMTEAM_EVENTS_LOG="$EVL" bash "$HOOK" 2>/dev/null)"
if grep -q '"event":"WorktreeCreate"' "$EVL" && grep -q '"who":"logtest"' "$EVL"; then
  pass "#66: hook self-logs WorktreeCreate to events.log (observability preserved)"
else
  fail "#66: WorktreeCreate not logged — [$(cat "$EVL")]"
fi
[ "$OUT" = "$REPO/.claude/worktrees/logtest" ] \
  && pass "#66: stdout remains EXACTLY the path (event log did not leak to stdout)" \
  || fail "#66: stdout polluted — expected path, got [$OUT]"

echo "── worktree-create: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
