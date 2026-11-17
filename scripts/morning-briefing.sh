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
STATE="${DREAMTEAM_STATE:-$ROOT/state}"   # created only after the --check-only exit below (it changes nothing else)

REPO="$PWD"; QUIET=0; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-$PWD}"; shift 2;;
    --quiet) QUIET=1; shift;;
    --check-only) CHECK_ONLY=1; shift;;   # write today's CHECK line from the briefing already on disk; change nothing else
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) shift;;
  esac
done

DATE=$(date +%F)
NOW=$(date +%s)
CUTOFF=$(date -d '12 hours ago' +%FT%T 2>/dev/null || echo "")   # GNU date (this host)
SINCE_DATE=$(date -d '12 hours ago' +%F 2>/dev/null || date +%F)
BRIEF="$STATE/briefing-$DATE.md"

# ── the CHECK line (docs/CHECKS.md rows dreamteam-briefing[-<host>]; scripts/lib/check-line.sh) ──────────────
# ok: today's briefing exists (written by THIS run, unless --check-only) and carries the nightly sweep line.
# warn: it exists but has no nightly sweep line (no guard record in the last 12 h) or reports an OOM kill.
# fail: no briefing for today (or, after a run, one this run did not write). Runs on every exit (trap).
. "$ROOT/scripts/lib/check-line.sh"
BRIEF_OK=0
write_brief() {  # stdin → $BRIEF atomically (unique same-dir temp, mv -T); rc 0 only when it landed whole.
  # Called as the LAST stage of a pipeline (a subshell): the caller sets BRIEF_OK from ${PIPESTATUS[1]}.
  local tmp
  tmp=$(mktemp "$STATE/.briefing-$DATE.md.XXXXXX" 2>/dev/null) || { cat >/dev/null; return 1; }
  if cat > "$tmp" && mv -T -f "$tmp" "$BRIEF" 2>/dev/null; then return 0; fi
  rm -f "$tmp"; return 1
}
# The nightly line's post-cap reconciliation: the guard and the runner write nightly-guarded.line, but a runner that
# dies never writes again, so its "running until 06:30" ok would stand. The 07:03 briefing is the first timer after
# the cap: on the host whose guarded timer is enabled it re-reads the record (overnight-guarded.sh --check-line),
# which turns a dead night into fail. DREAMTEAM_RECONCILE_NIGHTLY=1 forces it, 0 skips it (tests).
reconcile_nightly() {
  # no existence gate: a MISSING record on the timer's host must turn the line to fail, not leave a stale ok
  case "${DREAMTEAM_RECONCILE_NIGHTLY:-auto}" in
    0) return 0 ;;
    1) ;;
    *) systemctl --user is-enabled --quiet dreamteam-nightly-guarded.timer 2>/dev/null || return 0 ;;
  esac
  bash "$ROOT/scripts/overnight-guarded.sh" --check-line >/dev/null 2>&1 || true
}
brief_check() {
  local name st fact n at nightly
  [ "$CHECK_ONLY" -eq 1 ] || reconcile_nightly   # --check-only changes nothing but its own line
  name="${DREAMTEAM_CHECK_NAME:-$(check_name dreamteam-briefing)}"
  if [ ! -f "$BRIEF" ]; then
    st=fail; fact="no $(basename "$BRIEF") (today's briefing was not written)"
  elif [ "$CHECK_ONLY" -eq 0 ] && [ "$BRIEF_OK" -ne 1 ]; then
    st=fail; fact="this run did not write $(basename "$BRIEF") (the one on disk is older)"
  else
    n=$(grep -c . "$BRIEF" 2>/dev/null || echo 0); at=$(date -r "$BRIEF" +%H:%M 2>/dev/null || echo "?")
    nightly=$(grep -m1 '^- \*\*Nightly sweep\*\*: ' "$BRIEF" 2>/dev/null | sed 's/^- \*\*Nightly sweep\*\*: //' | cut -c1-90)
    fact="$(basename "$BRIEF") written $at, $n lines, nightly sweep: ${nightly:-no record in the last 12 h}"
    if [ -z "$nightly" ] || grep -q -E 'OOM kill overnight|OOM unmeasured' "$BRIEF" 2>/dev/null; then st=warn; else st=ok; fi
    grep -q 'OOM kill overnight' "$BRIEF" 2>/dev/null && fact="$fact, OOM kill overnight"
    grep -q 'OOM unmeasured' "$BRIEF" 2>/dev/null && fact="$fact, OOM unmeasured (journal unreadable)"
  fi
  check_line "$name" "$st" "$fact" "next 07:03, owner Sen" >/dev/null || true
}
if [ "$CHECK_ONLY" -eq 1 ]; then brief_check; exit 0; fi
mkdir -p "$STATE"
trap brief_check EXIT

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

# 2b. the guarded nightly (scripts/overnight-guarded.sh): its decision, when made in the last 12h.
#     A started run counts as overnight activity even if its agents logged no team events.
NIGHTLY=""; NIGHTLY_DEC=""
GREC="$STATE/overnight-guard.json"
if [ -f "$GREC" ]; then
  GAT=$(jq -r '.at // empty' "$GREC" 2>/dev/null || true)
  GEP=$(date -d "${GAT:-@0}" +%s 2>/dev/null || echo 0)
  if [ -n "$GAT" ] && [ "$GEP" -ge $(( NOW - 43200 )) ]; then
    NIGHTLY_DEC=$(jq -r '.decision // empty' "$GREC" 2>/dev/null || true)
    NIGHTLY=$(jq -r 'if .decision=="started" then "started \(.run_id): \(.issues) dream issue(s) in \((.repos // []) | map(split("/")[1]) | join(", "))"
                     elif .decision=="no-work" then "nothing queued (no open dream issues)"
                     else "\(.decision): \(.reason)" end' "$GREC" 2>/dev/null || true)
    FIN=$(grep -m1 '^FINISHED' "$STATE/overnight-pending.md" 2>/dev/null || true)
    [ -n "$FIN" ] && NIGHTLY="$NIGHTLY; ${FIN%%:*}"
    # one clause per repo from the guard record's .runs lines
    PER=$(jq -r '[(.runs // [])[] | (.repo | split("/")[1]) + " " + .status
           + (if .status == "finished" or .status == "stopped" then " (PRs \((.prs_opened // []) | length), merged \((.merged // []) | length))" else "" end)
           + (if (.reason // "") != "" then ": " + .reason else "" end)] | join("; ")' "$GREC" 2>/dev/null || true)
    [ -n "$PER" ] && NIGHTLY="$NIGHTLY — $PER"
  fi
fi

# last systemd-oomd kill overnight (same source as incident-report.sh). Measured BEFORE the quiet-night exit below, so
# an OOM night with no other activity still says so (and its CHECK line warns).
# A journal that cannot be read is NOT "no OOM" (unknown is never ok): it is said, and the CHECK line warns.
# journalctl can also exit 0 while hiding system messages from a user without journal access (its hint goes to
# stderr): that is unmeasured too. One call, stderr merged; the hint never matches the kill pattern.
OOMJ=$(journalctl -u systemd-oomd --since '12 hours ago' --no-pager 2>&1); OOMJ_RC=$?
grep -q -i 'not seeing messages from other users and the system' <<<"$OOMJ" && OOMJ_RC=${OOMJ_RC/#0/77}
OOMD=$(printf '%s\n' "$OOMJ" | grep -E 'Killed .* due to' | tail -1 || true)
if [ "$OOMJ_RC" -ne 0 ]; then OOMD=""; OOMD_NOTE="? OOM unmeasured (journalctl exit $OOMJ_RC$( [ "$OOMJ_RC" = 77 ] && echo ', no system journal access'))"
elif [ -n "$OOMD" ]; then OOMD_NOTE="⚠ OOM kill overnight: ${OOMD##*]: }"; else OOMD_NOTE="✓ no OOM kills overnight"; fi

# ── nothing ran overnight → one-liner, no voice, exit 0 ──────────────────────
if [ "$HANDOFF_FRESH" -eq 0 ] && [ "$EV_COUNT" -eq 0 ] && [ "$NIGHTLY_DEC" != "started" ]; then
  { echo "# Dreamteam briefing — $DATE"; echo ""
    echo "_No overnight dreamteam activity (no fresh HANDOFF-auto, no agent events in the last 12h)._"
    echo "- **Memory**: ${OOMD_NOTE}"
    [ -n "$NIGHTLY" ] && echo "- **Nightly sweep**: $NIGHTLY"
  } | write_brief; [ "${PIPESTATUS[1]}" -eq 0 ] && BRIEF_OK=1
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


# ── compose: markdown record ─────────────────────────────────────────────────
{
  echo "# Dreamteam briefing — $DATE"
  echo ""
  echo "- **PRs**: ${MERGED_N} merged (last 12h) · ${OPEN_N} open"
  echo "- **Agent events (12h)**: ${EV_COUNT} — ${EV_SUMMARY:-none}"
  echo "- **Last HANDOFF-auto**: $([ "$HANDOFF_FRESH" -eq 1 ] && echo "${HANDOFF_AGE_H}h ago (fresh)" || echo "stale/none")"
  echo "- **Palace queue depth**: ${QUEUE}"
  echo "- **Memory**: ${OOMD_NOTE}"
  [ -n "$NIGHTLY" ] && echo "- **Nightly sweep**: $NIGHTLY"
  if [ -n "$OPEN_TITLES" ]; then echo ""; echo "## Open PRs"; printf '%s\n' "$OPEN_TITLES"; fi
} | write_brief; [ "${PIPESTATUS[1]}" -eq 0 ] && BRIEF_OK=1

# ── compose: spoken summary (≤4 sentences, davis) ────────────────────────────
if [ "$OOMJ_RC" -ne 0 ]; then MEM_SENTENCE="Memory incidents could not be measured — the journal was unreadable"
elif [ -n "$OOMD" ]; then MEM_SENTENCE="Heads up — there was an OOM kill overnight"
else MEM_SENTENCE="No memory incidents overnight"; fi
SPOKEN="Good morning. Overnight the dream team merged ${MERGED_N} and left ${OPEN_N} pull requests open, across ${EV_COUNT} agent events. ${MEM_SENTENCE}. The full briefing is saved for ${DATE}."

echo "briefing written: $BRIEF"
speak "$SPOKEN"
notify "${MERGED_N} merged · ${OPEN_N} open · ${EV_COUNT} events · $([ -n "$OOMD" ] && echo 'OOM!' || echo 'no OOM')"
exit 0
