#!/usr/bin/env bash
# dreamteam test runner — executes every tests/test-*.sh and aggregates results.
#
# Each suite is standalone (own PASS:/FAIL: lines, exits non-zero on any failure)
# and self-isolating (PATH-stubbed free/ps/pgrep, fixture team configs, temp
# state via the scripts' DREAMTEAM_* env seams — no production script is touched).
#
# Usage: bash tests/run.sh        # exit 0 iff every suite is green
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# No suite may touch REAL state (2026-11-17: a mutated run.sh kept an inherited checks dir and its cleanup rm -rf'd
# familiar's real ~/.local/state/checks). So every suite runs with a PRIVATE HOME and a private checks dir, both under
# ONE dir this script creates itself; the cleanup target is only ever that dir, never a path from the environment,
# and the trap is set only after the dir is known to exist. No suite runs if it cannot be made. The live roster check
# reads the real team config through DREAMTEAM_REAL_HOME, read-only.
PRIV="$(mktemp -d 2>/dev/null)"
if [ -z "$PRIV" ] || [ ! -d "$PRIV" ] || ! mkdir -p "$PRIV/home/.config" "$PRIV/home/.local/state" "$PRIV/home/.local/share" "$PRIV/home/.cache" "$PRIV/checks"; then
  echo "run.sh: cannot create a private test home; no suite run"; exit 1
fi
trap 'rm -rf -- "$PRIV"' EXIT
export DREAMTEAM_REAL_HOME="$HOME" HOME="$PRIV/home" DREAMTEAM_CHECKS_DIR="$PRIV/checks" \
       XDG_CONFIG_HOME="$PRIV/home/.config" XDG_STATE_HOME="$PRIV/home/.local/state" \
       XDG_DATA_HOME="$PRIV/home/.local/share" XDG_CACHE_HOME="$PRIV/home/.cache"   # an inherited XDG dir never leaks in

fail=0; ran=0; failed_suites=""
for t in "$DIR"/test-*.sh; do
  [ -f "$t" ] || continue
  ran=$((ran + 1))
  name="$(basename "$t")"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ $name"
  # TMUX unset for every suite: the weekly audit runs this under a systemd timer, where TMUX is never set, so an
  # interactive run must see the same environment (self-audit 2026-11-15: test-standards.sh read the caller's tmux).
  if env -u TMUX bash "$t"; then
    echo "  → $name: OK"
  else
    echo "  → $name: FAILED (exit $?)"
    fail=$((fail + 1)); failed_suites="$failed_suites $name"
  fi
  echo ""
done

echo "═══════════════════════════════════════════════"
if [ "$ran" -eq 0 ]; then
  echo "no test suites found in $DIR"; exit 1
fi
if [ "$fail" -eq 0 ]; then
  echo "ALL SUITES PASS ($ran/$ran)"; exit 0
fi
echo "FAILED: $fail/$ran suites —$failed_suites"; exit 1
