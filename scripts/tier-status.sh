#!/usr/bin/env bash
# tier-status.sh — read the durable memory-tier blackboard (#57 / S7).
#
# team-events.sh's tier_note() writes $STATE/tier-status (atomic) whenever it crosses a
# memory tier (RED / SCOPE-pressure / ORANGE). The hook fires on WHATEVER session crossed
# the tier — often NOT Nyx — so the in-context systemMessage can't be Nyx's source of
# truth. This file, in the shared per-project $STATE, IS: Nyx polls it and acts on the
# CURRENT pressure regardless of which session's hook fired (the S7 wrong-session fix).
#
# Green does NOT rewrite the blackboard (that would thrash on every turn boundary), so a
# tier that has since CLEARED shows up as STALE by its age — this tool reports the age and
# a stale flag so a poll can treat an old reading as "pressure resolved".
#
# Usage: tier-status.sh [--json]
# Seams: DREAMTEAM_STATE (default <plugin>/state) · DREAMTEAM_TIER_STALE_SEC (default 300).
#   Per-PROJECT plugin state — no --team needed: this reads plugin state, NOT a team
#   config, so R4's wrong-team-resolution hazard does not apply here.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
F="$STATE/tier-status"
STALE_SEC="${DREAMTEAM_TIER_STALE_SEC:-300}"
FMT="human"; [ "${1:-}" = "--json" ] && FMT="json"

if [ ! -f "$F" ]; then
  if [ "$FMT" = json ]; then echo '{"tier":"none","ageSec":null,"stale":false}'
  else echo "tier: none — no memory pressure recorded"; fi
  exit 0
fi

now="$(date +%s)"
tier="$(jq -r '.tier // "none"' "$F" 2>/dev/null || echo none)"
ts="$(jq -r '.ts // empty' "$F" 2>/dev/null)"; ts="${ts//[!0-9]/}"
age=""; if [ -n "$ts" ]; then age=$(( now - ts )); [ "$age" -lt 0 ] && age=0; fi
stale=false; [ -n "$age" ] && [ "$age" -gt "$STALE_SEC" ] && stale=true

if [ "$FMT" = json ]; then
  # echo the recorded state verbatim under .state, plus the derived age/stale.
  jq -c --argjson age "${age:-null}" --argjson stale "$stale" \
     '{tier:(.tier // "none"), ageSec:$age, stale:$stale, state:.}' "$F" 2>/dev/null \
    || printf '{"tier":"%s","ageSec":%s,"stale":%s}\n' "$tier" "${age:-null}" "$stale"
  exit 0
fi

line="tier: $tier"
[ -n "$age" ] && line="$line  (${age}s ago$([ "$stale" = true ] && printf ' — STALE, likely cleared'))"
avail="$(jq -r '.avail // empty' "$F" 2>/dev/null)"; floor="$(jq -r '.floor // empty' "$F" 2>/dev/null)"
[ -n "$avail" ] && [ -n "$floor" ] && line="$line  [${avail}MiB avail / ${floor}MiB floor]"
echo "$line"
