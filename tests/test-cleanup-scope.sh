#!/usr/bin/env bash
# cleanup-marker.sh (SessionEnd) must never tear down a scope it does not own (2026-11-16 23:41): the guarded nightly
# runner exports DREAMTEAM_SCOPE_NAME=dreamteam-<run id> to its coordinator, tmux 3.6 had moved every pane process into
# its own tmux-spawn-*.scope, so the coordinator's SessionEnd saw no claude process in the night's scope, judged it
# empty and stopped it: the tmux server died, the runner got SIGHUP and the night ended with no FINISHED line.
#   • systemctl is PATH-stubbed: is-active → active; every `stop` is logged; nothing real is stopped.
#   • pgrep is PATH-stubbed to list no claude process (the night's state: every pane re-scoped by tmux).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -p "${TMPDIR:-$HOME/.cache/tmp}" 2>/dev/null || mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $*"; }
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
case " $* " in
  *" is-active "*) exit 0;;
  *" stop "*) echo "stop ${@: -1}" >> "$STOP_LOG"; exit 0;;
esac
exit 0
S
printf '#!/bin/bash\nexit 1\n' > "$BIN/pgrep"
chmod +x "$BIN"/*
run(){ : > "$TMP/stop.log"; STOP_LOG="$TMP/stop.log" DREAMTEAM_TEST=1 DREAMTEAM_STATE="$TMP/state" CLAUDE_PLUGIN_ROOT="$ROOT" \
  PATH="$BIN:$PATH" "$@" bash "$ROOT/scripts/cleanup-marker.sh" </dev/null >/dev/null 2>&1; }

# positive control: an ordinary project scope with no agent left is still retired (existing behaviour)
run env DREAMTEAM_SCOPE_NAME=dreamteam-someproject
grep -qx 'stop dreamteam-someproject.scope' "$TMP/stop.log" && pass "an empty project scope is still stopped (control)" || fail "control: $(cat "$TMP/stop.log")"

# the night's scope is the runner's to end, never a SessionEnd's
run env DREAMTEAM_SCOPE_NAME=dreamteam-nightly-20261116-233001
! grep -q 'dreamteam-nightly-20261116-233001' "$TMP/stop.log" && pass "a guarded night's scope is never stopped by a coordinator's SessionEnd" || fail "night scope stopped: $(cat "$TMP/stop.log")"

# a runner-owned scope by marker too, whatever its name
run env DREAMTEAM_SCOPE_NAME=dreamteam-anything DREAMTEAM_SCOPE_OWNED=1
! grep -q 'dreamteam-anything' "$TMP/stop.log" && pass "DREAMTEAM_SCOPE_OWNED=1: the session does not own its scope, so it never stops it" || fail "owned scope stopped: $(cat "$TMP/stop.log")"

echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
