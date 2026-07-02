#!/usr/bin/env bash
# dreamteam — the single resilient palace writer (issue #10).
#
# Files ONE memory card into the palace daemon so the dream team records its own
# history automatically — no more manual post-completion protocol. On ANY failure
# the card is appended to state/palace-queue.jsonl so nothing is lost while
# familiar sleeps (the daemon 502'd 2026-07-01 — resilience is the whole point).
# On a successful send it opportunistically drains up to 10 queued cards.
#
# Usage:
#   palace-file.sh --topic <t> [--wing <w>] "entry text"
#   printf '%s' "entry text" | palace-file.sh --topic <t> [--wing <w>]
#
# HOOK CONTRACT (this runs from Pre/PostCompact + SessionEnd hooks):
#   • NEVER writes stdout        — hooks capture stdout as their protocol channel.
#   • NEVER exits nonzero        — a writer failure must never fail a hook.
#   • NEVER blocks >~10s         — bounded curl timeouts + drain short-circuits on
#                                   the first failure.
#   • Silent no-op when: DREAMTEAM_TEST is set (test seam, matches team-events.sh),
#     the daemon env file is missing, creds are empty, or curl/jq are absent.
#
# Endpoint contract (verified 2026-07-01): POST $PALACE_DAEMON_URL/silent-save,
#   headers X-API-Key + Content-Type: application/json,
#   body {"entry","wing","agent_name":"Sandman","topic"}.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
ENV_FILE="${PALACE_ENV_FILE:-$HOME/.config/palace-daemon/env}"
QUEUE="$STATE/palace-queue.jsonl"
WING="dreamteam"; TOPIC="dreamteam"; ENTRY=""

# Test kill-switch — same seam team-events.sh honors. Keeps hooks that are
# exercised by the sibling suites (compact-guard, cleanup-marker) from touching
# the network or the real palace during tests.
[ -n "${DREAMTEAM_TEST:-}" ] && exit 0

while [ $# -gt 0 ]; do
  case "$1" in
    --topic) TOPIC="${2:-dreamteam}"; shift 2;;
    --wing)  WING="${2:-dreamteam}";  shift 2;;
    --) shift; ENTRY="${*:-}"; break;;
    *) ENTRY="$1"; shift;;
  esac
done
[ -n "$ENTRY" ] || ENTRY="$(cat 2>/dev/null || true)"   # entry may arrive on stdin
[ -n "$ENTRY" ] || exit 0                                # nothing to file

# Resilience needs a known daemon target + the tools to reach it; without any of
# these we can't send OR meaningfully queue, so silent no-op (never nonzero).
[ -f "$ENV_FILE" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
# shellcheck source=/dev/null
. "$ENV_FILE" 2>/dev/null || true
[ -n "${PALACE_DAEMON_URL:-}" ] && [ -n "${PALACE_API_KEY:-}" ] || exit 0

mkdir -p "$STATE" 2>/dev/null || true

# jq owns escaping so arbitrary entry text (newlines, quotes) can't break the JSON.
payload() { jq -cn --arg e "$1" --arg w "$2" --arg t "$3" \
  '{entry:$e, wing:$w, agent_name:"Sandman", topic:$t}'; }

# One bounded POST of a ready JSON body. Total time capped well under the 10s hook
# budget: per-attempt max 8s, retry window also capped at 8s, connect within 3s.
post() {
  curl -s -o /dev/null \
    --connect-timeout 3 --max-time 8 --retry 1 --retry-delay 0 --retry-max-time 8 \
    -X POST "$PALACE_DAEMON_URL/silent-save" \
    -H "X-API-Key: $PALACE_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "$1" 2>/dev/null
}

BODY="$(payload "$ENTRY" "$WING" "$TOPIC")"

if post "$BODY"; then
  # Daemon is up → drain up to 10 queued cards. Stop at the first failure and
  # requeue everything not successfully sent (no card is ever lost or duplicated).
  if [ -s "$QUEUE" ]; then
    tmpq="$(mktemp "${TMPDIR:-/tmp}/palace-drain.XXXXXX" 2>/dev/null || true)"
    sent=0; stop=0
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if [ "$stop" -eq 0 ] && [ "$sent" -lt 10 ] && post "$line"; then
        sent=$((sent + 1))                       # delivered → drop from queue
      else
        stop=1                                   # a failure (or the 10-cap) ends the drain
        [ -n "$tmpq" ] && printf '%s\n' "$line" >> "$tmpq"
      fi
    done < "$QUEUE"
    if [ -n "$tmpq" ]; then mv -f "$tmpq" "$QUEUE" 2>/dev/null || rm -f "$tmpq" 2>/dev/null; fi
  fi
else
  # Daemon unreachable → append the card so the next successful send drains it.
  printf '%s\n' "$BODY" >> "$QUEUE" 2>/dev/null || true
fi
exit 0
