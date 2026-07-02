#!/usr/bin/env bash
# dreamteam — nightly overnight launcher (PILOT — issues #12/#14).
#
# WHAT / WHY
#   The nightly systemd timer (dreamteam-nightly.timer) runs THIS at ~02:11. It is
#   the durable, cross-session replacement for the session-only CronCreate job (which
#   died with its session — see docs/README + the project memory "durable schedules
#   are systemd user units").
#
#   PILOT SCOPE (deliberately conservative — JP arms the real thing after a dry cycle):
#     • Gate on open `dream`-labelled issues. NONE → log one line, exit 0 (silent when
#       idle — same doctrine as morning-briefing: a scheduler that cries wolf gets muted).
#     • SOME → write state/overnight-pending.md listing them + speak ONE line. It does
#       NOT auto-start a coordinator. Recording intent ≠ spending tokens unattended;
#       auto-launch is a surface-don't-guess decision that stays JP's.
#
#   FULL ACTIVATION (JP's call): swap the pending-writer below for launch-dreamteam.sh
#   in dreamteam-nightly.service. Legitimate from a timer — a timer start IS "JP starting
#   it from outside any session", so the nested-coordinator bug (commands/dreamteam.md)
#   does not apply. Until then this only *surfaces* the work.
#
# SEAMS (for tests/test-timers.sh): DREAMTEAM_STATE, DREAMTEAM_REPO_SLUG,
#   DREAMTEAM_SPEAK_BIN, DREAMTEAM_TEST=1 (silences voice). gh is called by bare name
#   so a PATH stub works. Always exits 0 (a timer target must never fail the unit).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
REPO_SLUG="${DREAMTEAM_REPO_SLUG:-jphein/dreamteam}"
SPEAK_BIN="${DREAMTEAM_SPEAK_BIN:-$ROOT/scripts/speak.sh}"
mkdir -p "$STATE"
LOG="$STATE/dreamteam.log"
PENDING="$STATE/overnight-pending.md"
TS=$(date +%FT%T)

speak() {  # lucid contract: speak.sh "<text>" --voice davis. Silent under test / until it lands.
  [ "${DREAMTEAM_TEST:-0}" = "1" ] && return 0
  [ -f "$SPEAK_BIN" ] && bash "$SPEAK_BIN" "$1" --voice davis >/dev/null 2>&1 || true
}

# ── gate: open `dream`-labelled issues (gh PATH-stubbable in tests) ──
ISSUES_JSON=$(gh issue list -R "$REPO_SLUG" --label dream --state open --json number,title 2>/dev/null || echo '[]')
N=$(printf '%s' "$ISSUES_JSON" | jq 'length' 2>/dev/null || echo 0); N=${N//[!0-9]/}; N=${N:-0}

if [ "$N" -eq 0 ]; then
  echo "$TS overnight-launch: no open 'dream' issues in $REPO_SLUG — nothing to sweep (silent)." >> "$LOG" 2>/dev/null || true
  exit 0
fi

# ── issues exist → record pending (PILOT: surface only, no auto-start) ──
{
  echo "# Overnight pending — $TS"
  echo ""
  echo "$N open \`dream\`-labelled issue(s) in \`$REPO_SLUG\` awaiting a sweep:"
  echo ""
  printf '%s' "$ISSUES_JSON" | jq -r '.[] | "- #\(.number) \(.title)"' 2>/dev/null
  echo ""
  echo "_PILOT mode: NOT auto-started. Run the sweep manually (/dreamteam-overnight), or arm full"
  echo "activation by swapping launch-dreamteam.sh into dreamteam-nightly.service (a timer counts as"
  echo "an out-of-session start, so the nested-coordinator guard does not apply)._"
} > "$PENDING" 2>/dev/null || true

echo "$TS overnight-launch: $N 'dream' issue(s) → wrote $PENDING (PILOT: no auto-start)." >> "$LOG" 2>/dev/null || true
speak "Overnight: $N dream issue$([ "$N" -eq 1 ] || echo s) queued and waiting for a sweep."
exit 0
