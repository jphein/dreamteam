#!/usr/bin/env bash
# dreamteam — gpu-guard.sh: PreToolUse(Bash) hook. A lane cannot launch GPU work on a card it does not
# hold. Spec: docs/superpowers/specs/2026-09-29-gpu-fleet-design.md §5.
#
# WHAT COUNTS (the decision lives in scripts/lib/gpu_fleet.py `detect`, tested in tests/test-gpu.sh):
#   - CUDA_VISIBLE_DEVICES=<n>, ZE_AFFINITY_MASK=<n>, or --device cuda:<n> / xpu:<n> on a command;
#   - the GEMS launchers: gpu1_launch.sh, run_exp.sh, remote_run.sh, guest_run.sh with a GPU cap, and
#     safe_run.sh --protected (a training run);
#   - python, torchrun, accelerate or `ollama run` over ssh to a GPU-only host (gpu0, gpu1, game);
#   - `docker run` with --gpus, --runtime=nvidia or --device /dev/nvidia* (luna's audits, vesper's verify windows).
#   `dreamteam gpu run` passes: it checks the claim itself. Reads never count (nvidia-smi, tail, board).
#   v1.3: only where a shell RUNS it. A launcher named as an argument (cat, sed, grep, scp), a heredoc written
#   to a file, or a commit message is not a launch; scripts the command writes or runs locally are followed.
#
# MODES (config.json gpu.guard): warn (the rollout default: allow, and log the would-block line to
# ~/.claude/state/dreamteam/gpu/guard.log) · enforce (exit 2 = deny, with the reason on stderr) · off.
# A missing config is warn, never off: an absent switch is not a disabled guard.
#
# FAIL OPEN: no identity (an orchestrator or JP), a malformed payload, no python or jq, or an ssh to a
# host that cannot be resolved all allow. A guard bug must never brick an agent. The fast pre-filter
# below keeps python off the path of every ordinary Bash call.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INPUT="$(cat 2>/dev/null || true)"
# The pre-filter is a SUPERSET of what detect can call a launch (gpu_detect.py): python, a script it may follow
# (.sh), the GPU variables, the launchers, the GPU runners, and docker/podman. tests/test-gpu.sh replays every
# positive control through this wrapper, so a trigger missing here goes red there.
case "$INPUT" in
  *CUDA_VISIBLE_DEVICES*|*ZE_AFFINITY_MASK*|*--device*cuda*|*--device*xpu*) ;;
  *gpu1_launch.sh*|*run_exp.sh*|*remote_run.sh*|*guest_run.sh*|*safe_run.sh*) ;;
  *python*|*.sh*|*torchrun*|*deepspeed*|*accelerate*|*ollama*) ;;
  *./*|*"sh "*|*"source "*|*". "*|*tmux*|*screen*|*xargs*|*"eval "*|*"su "*) ;;   # scripts it may follow (Oracle 09-29)
  *docker*|*podman*) ;;
  *) exit 0 ;;
esac
command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || exit 0
. "$ROOT/scripts/lib/agent-id.sh" 2>/dev/null || exit 0
AGENT_ID="$(dt_agent_id 2>/dev/null || true)"
RES="$(printf '%s' "$INPUT" | DREAMTEAM_AGENT_ID="$AGENT_ID" python3 "$ROOT/scripts/lib/gpu_fleet.py" guard 2>/dev/null)" || exit 0
# The allow path (nearly every call) never forks jq: json.dumps writes `{"action": "allow", …` verbatim.
case "$RES" in '{"action": "allow"'*) exit 0 ;; esac
ACTION="$(printf '%s' "$RES" | jq -r '.action // "allow"' 2>/dev/null || echo allow)"
MSG="$(printf '%s' "$RES" | jq -r '.message // ""' 2>/dev/null || true)"
case "$ACTION" in
  block)
    {
      echo "🛑 DREAMTEAM GPU GUARD — launch on a card you do not hold"
      echo "   $MSG"
      echo "   See the board: dreamteam gpu board. Claims are granted by the lead or a Nyx-class agent."
    } >&2
    exit 2 ;;
  warn)
    echo "dreamteam gpu-guard (warn mode, allowed and logged): $MSG" >&2
    exit 0 ;;
  *) exit 0 ;;
esac
