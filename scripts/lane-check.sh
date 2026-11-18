#!/usr/bin/env bash
# lane-check.sh: may a NEW lane (an interactive Claude Code session) start on this host now? (Sen 2026-11-17)
# Reads .lane.minAvailableMB and .lane.minSwapFreeMB from config.json with this host's config.<host>.json merged over it
# (scripts/lib/config.sh); both default to 0 = no floor, so a host without an overlay is never held.
# Prints one line; exit 0 = room, 1 = held (the line names the number and the floor). A lane launcher calls it first.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
. "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"
CFGJSON="$(dreamteam_config "$CFG")"
# an unreadable or invalid number is HELD (exit 1), never read as "no floor" (xreview #230 r1)
held() { echo "lane-check held: $1 ($(dreamteam_host))"; exit 1; }
num() { # key → NUM (no subshell, so a held line reaches stdout)
  local v; v=$(jq -r --arg k "$1" '.lane[$k] // 0 | tostring' <<<"$CFGJSON" 2>/dev/null) || v=x
  dreamteam_uint "$v" 10000000 || held "lane.$1 is '$v', not an integer"; NUM=$((10#$v)); }
num minAvailableMB; MA=$NUM; num minSwapFreeMB; MS=$NUM
AV=$(free -m | awk '/^Mem:/{print $7}'); SF=$(free -m | awk '/^Swap:/{print $4}')
dreamteam_uint "${AV:-x}" 10000000 || held "free -m gave no readable available memory"
dreamteam_uint "${SF:-x}" 10000000 || held "free -m gave no readable swap free"
if [ "$MA" -gt 0 ] && [ "${AV:-0}" -lt "$MA" ]; then echo "lane-check held: ${AV} MiB available < ${MA} ($(dreamteam_host))"; exit 1; fi
if [ "$MS" -gt 0 ] && [ "${SF:-0}" -lt "$MS" ]; then echo "lane-check held: ${SF} MiB swap free < ${MS} ($(dreamteam_host))"; exit 1; fi
echo "lane-check ok: ${AV} MiB available, ${SF} MiB swap free (floors ${MA}/${MS}, $(dreamteam_host))"
