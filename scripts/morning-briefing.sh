#!/usr/bin/env bash
# dreamteam — morning briefing (issue #13).
#
# WHAT / WHY
#   After an overnight autonomous run (the nightly-dreamteam cron), JP wakes to a
#   pile of merged PRs, agent events, and maybe an OOM scar — scattered across
#   gh, the plugin logs, and journalctl. This assembles them into ONE artifact:
#     • a tight markdown briefing → state/briefing-<date>.md (the record)
#     • a ≤4-sentence spoken summary via speak.sh (davis) + a desktop notify
#   so the state of the night is legible in ten seconds, by ear or by file.
#
#   If nothing actually ran overnight (no fresh HANDOFF-auto, no recent events),
#   it stays SILENT — writes a one-line "nothing happened" briefing and exits 0.
#   A 7am voice that says "nothing happened" every quiet morning trains JP to
#   ignore it; silence when idle keeps the spoken channel meaningful.
#
# CONTRACTS CONSUMED (owned by siblings; silent no-op until they land):
#   • scripts/speak.sh "<text>" --voice davis      (lucid, #?)
#   Called only if executable — absence must not error this script.
#
# Flags: --repo <path> (default $PWD)   --quiet (write the file, speak nothing)
# Always exits 0 (a cron-invoked reporter must never fail the session).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
mkdir -p "$STATE"

REPO="$PWD"; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-$PWD}"; shift 2;;
    --quiet) QUIET=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) shift;;
  esac
done

DATE=$(date +%F)
NOW=$(date +%s)
CUTOFF=$(date -d '12 hours ago' +%FT%T 2>/dev/null || echo "")   # GNU date (this host)
SINCE_DATE=$(date -d '12 hours ago' +%F 2>/dev/null || date +%F)
BRIEF="$STATE/briefing-$DATE.md"

# ── contract shims (silent no-op until the real scripts land) ──────────────
speak() {   # lucid: scripts/speak.sh "<text>" --voice davis
  [ "$QUIET" = "1" ] && return 0
  [ -f "$ROOT/scripts/speak.sh" ] && bash "$ROOT/scripts/speak.sh" "$1" --voice davis >/dev/null 2>&1 || true
}
notify() {  # best-effort desktop toast; needs a session bus (may be absent under cron)
  # #51: hook/cron contexts inherit NO session-bus address → notify-send silently
  # no-ops (can't reach the user's D-Bus). Point it at the systemd user bus (respect an
  # inherited value); add DISPLAY. Same fix as team-events.sh notify_red — this is the
  # briefing's toast call-site (the second half of #51). Harmless no-op when absent.
  local bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
  command -v notify-send >/dev/null 2>&1 \
    && DBUS_SESSION_BUS_ADDRESS="$bus" DISPLAY="${DISPLAY:-:0}" \
       notify-send "🕯 Dreamteam briefing" "$1" >/dev/null 2>&1 || true
}

# ── gather ─────────────────────────────────────────────────────────────────
# 1. HANDOFF-auto.md freshness (<12h ⇒ a compaction/handoff happened overnight)
HANDOFF="$STATE/HANDOFF-auto.md"; HANDOFF_FRESH=0; HANDOFF_AGE_H="n/a"
if [ -f "$HANDOFF" ]; then
  age=$(( NOW - $(stat -c %Y "$HANDOFF" 2>/dev/null || echo "$NOW") ))
  HANDOFF_AGE_H=$(( age / 3600 ))
  [ "$age" -lt 43200 ] && HANDOFF_FRESH=1
fi

# 2. events.log — count + per-type tally in the overnight window (ISO ts sorts lexically)
EV_COUNT=0; EV_SUMMARY=""
if [ -f "$STATE/events.log" ] && [ -n "$CUTOFF" ]; then
  WIN=$(jq -rc --arg c "$CUTOFF" 'select(.ts >= $c)' "$STATE/events.log" 2>/dev/null || true)
  EV_COUNT=$(printf '%s' "$WIN" | grep -c . 2>/dev/null || echo 0); EV_COUNT=${EV_COUNT//[!0-9]/}; EV_COUNT=${EV_COUNT:-0}
  EV_SUMMARY=$(printf '%s\n' "$WIN" | jq -r '.event' 2>/dev/null | sort | uniq -c | sort -rn \
               | awk '{printf "%s×%s ", $1, $2}' || true)
fi

# ── nothing ran overnight → one-liner, no voice, exit 0 ──────────────────────
if [ "$HANDOFF_FRESH" -eq 0 ] && [ "$EV_COUNT" -eq 0 ]; then
  { echo "# Dreamteam briefing — $DATE"; echo ""
    echo "_No overnight dreamteam activity (no fresh HANDOFF-auto, no agent events in the last 12h)._"
  } > "$BRIEF"
  echo "no overnight activity — briefing: $BRIEF"
  exit 0
fi

# 3. gh PRs — merged in the window + currently open (run inside the repo)
OPEN_N=0; MERGED_N=0; OPEN_TITLES=""
if command -v gh >/dev/null 2>&1 && [ -d "$REPO" ]; then
  OPEN_JSON=$( cd "$REPO" 2>/dev/null && gh pr list --state open --json number,title --limit 30 2>/dev/null || echo '[]' )
  OPEN_N=$(printf '%s' "$OPEN_JSON" | jq 'length' 2>/dev/null || echo 0)
  OPEN_TITLES=$(printf '%s' "$OPEN_JSON" | jq -r '.[] | "  - #\(.number) \(.title)"' 2>/dev/null | head -8 || true)
  MERGED_JSON=$( cd "$REPO" 2>/dev/null && gh pr list --state merged --search "merged:>=$SINCE_DATE" --json number,title --limit 30 2>/dev/null || echo '[]' )
  MERGED_N=$(printf '%s' "$MERGED_JSON" | jq 'length' 2>/dev/null || echo 0)
fi
OPEN_N=${OPEN_N//[!0-9]/}; OPEN_N=${OPEN_N:-0}
MERGED_N=${MERGED_N//[!0-9]/}; MERGED_N=${MERGED_N:-0}

# 4. palace queue depth — best-effort daemon probe, report-only (never blocks)
QUEUE="n/a"
ENVF="$HOME/.config/palace-daemon/env"
if [ -f "$ENVF" ]; then
  # shellcheck disable=SC1090
  . "$ENVF" 2>/dev/null || true
  if [ -n "${PALACE_DAEMON_URL:-}" ]; then
    Q=$(curl -m 5 -fsS "$PALACE_DAEMON_URL/health" 2>/dev/null \
        | jq -r '.queue_depth // .queue // .pending // empty' 2>/dev/null || true)
    [ -n "$Q" ] && QUEUE="$Q"
  fi
fi

# 5. last systemd-oomd kill overnight (same source as incident-report.sh)
OOMD=$(journalctl -u systemd-oomd --since '12 hours ago' --no-pager 2>/dev/null \
       | grep -E 'Killed .* due to' | tail -1 || true)
if [ -n "$OOMD" ]; then OOMD_NOTE="⚠ OOM kill overnight: ${OOMD##*]: }"; else OOMD_NOTE="✓ no OOM kills overnight"; fi

# ── compose: markdown record ─────────────────────────────────────────────────
{
  echo "# Dreamteam briefing — $DATE"
  echo ""
  echo "- **PRs**: ${MERGED_N} merged (last 12h) · ${OPEN_N} open"
  echo "- **Agent events (12h)**: ${EV_COUNT} — ${EV_SUMMARY:-none}"
  echo "- **Last HANDOFF-auto**: $([ "$HANDOFF_FRESH" -eq 1 ] && echo "${HANDOFF_AGE_H}h ago (fresh)" || echo "stale/none")"
  echo "- **Palace queue depth**: ${QUEUE}"
  echo "- **Memory**: ${OOMD_NOTE}"
  if [ -n "$OPEN_TITLES" ]; then echo ""; echo "## Open PRs"; printf '%s\n' "$OPEN_TITLES"; fi
} > "$BRIEF"

# ── compose: spoken summary (≤4 sentences, davis) ────────────────────────────
MEM_SENTENCE=$([ -n "$OOMD" ] && echo "Heads up — there was an OOM kill overnight" || echo "No memory incidents overnight")
SPOKEN="Good morning. Overnight the dream team merged ${MERGED_N} and left ${OPEN_N} pull requests open, across ${EV_COUNT} agent events. ${MEM_SENTENCE}. The full briefing is saved for ${DATE}."

echo "briefing written: $BRIEF"
speak "$SPOKEN"
notify "${MERGED_N} merged · ${OPEN_N} open · ${EV_COUNT} events · $([ -n "$OOMD" ] && echo 'OOM!' || echo 'no OOM')"
exit 0
