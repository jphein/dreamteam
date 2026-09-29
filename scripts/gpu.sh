#!/usr/bin/env bash
# dreamteam — gpu.sh: the GPU fleet front door (`dreamteam gpu <verb>`). Spec:
# docs/superpowers/specs/2026-09-29-gpu-fleet-design.md.
#
#   board [--json]                        who holds which card, windows, live VRAM, host memory
#   inventory [--json] [--check HOST]     the cards and capabilities; --check re-measures and reports drift
#   claim CARD --lane L --until T --peak-ram MB --peak-vram MiB [--grows] [--protected] [--purpose P]
#                                         (granters: the orchestrator, or config gpu.granters)
#   release CARD [--force]                (granters or the holder)
#   window CARD HH:MM-HH:MM|always|never  (granters)
#   admit --card CARD [--peak-ram MB]     dry-run the admission arithmetic for a run
#   run --card CARD [--protected] [--grows] [--peak-ram MB] [--gpu-mem GiB] [--log P] [--name N] [--dry-run] -- CMD...
#                                         THE launcher: checks your claim, the window and the host budget,
#                                         then runs CMD in the host's form (familiar / guest / remote)
# Exit: 0 ok · 2 usage · 5 install or GPU failure · 75 admission refused (retry later) · 77 not permitted.
#
# Identity: computed HERE with lib/agent-id.sh (the one ancestry walk) and handed to the python lib, so
# the library never re-implements the walk.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
. "$ROOT/scripts/lib/agent-id.sh"
if [ -z "${DREAMTEAM_AGENT_ID+set}" ]; then
  DREAMTEAM_AGENT_ID="$(dt_agent_id 2>/dev/null || true)"
fi
export DREAMTEAM_AGENT_ID
case "${1:-}" in
  ""|-h|--help|help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
exec python3 "$ROOT/scripts/lib/gpu_fleet.py" "$@"
