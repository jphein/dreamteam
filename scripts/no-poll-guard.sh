#!/usr/bin/env bash
# dreamteam — NO-POLL GUARD  (PreToolUse hook, matcher: Bash|Monitor)
#
# Blocks a TEAMMATE from polling GitHub for CI status in a loop.
#
# WHY (measured, 2026-09-11). Three lanes each armed a 30 s `gh pr checks` loop
# to watch their own PRs. The GitHub quota is per-ACCOUNT, not per-session, so
# the three pollers summed: every `gh pr …` call in the fleet began failing with
# "API rate limit already exceeded", including the lead's merge cascade. Two
# things made it worse than a slow afternoon:
#
#   * `gh api rate_limit` reported 5000 remaining THROUGHOUT. It cannot see
#     GraphQL *secondary* limits, which is what `gh pr checks` burns. So the
#     one instrument an agent would reach for to check said everything was fine.
#   * A watch armed against a PR head survives a force-push. The head it was
#     polling no longer exists, so it never reaches a terminal state and never
#     stops. Orphaned pollers accumulate silently across a rebase-heavy wave.
#
# The protocol that replaces it: push, report "pushed", and let the LEAD run the
# gate ONCE (scripts/pr-gate.sh, REST-only). A lane does not need CI status —
# the lead gates, and the lead tells the lane when to rebase.
#
# WHAT IT BLOCKS: a GraphQL-heavy CI-status read (`gh pr checks`, or `gh pr view
# --json …statusCheckRollup…`) that appears in a LOOPING context — any Monitor
# call, or a Bash command containing while/until/for/watch/sleep. A single
# one-shot `gh pr checks` is cheap and stays allowed; so does the REST route
# (`gh api repos/…/check-runs`), which is what pr-gate.sh uses and which the
# secondary limiter does not punish the same way.
#
# WHO IT APPLIES TO: teammates only. The orchestrator runs the gate and the
# cascade; blocking it would break the very workflow this exists to protect.
#
# CONSERVATIVE BY DESIGN: it matches command TEXT, so a loop that merely prints
# the string "gh pr checks" is blocked too. That is the right trade — the
# message says exactly what to do instead, and the cost of a false block is one
# rephrase, while the cost of a miss is a fleet-wide quota outage.
#
# SAFETY POSTURE — FAIL OPEN. No identity, malformed payload, missing config,
# non-Linux/no /proc → exit 0. Kill-switch: config `nopoll.enforce=false`.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
. "$ROOT/scripts/lib/agent-id.sh"

# ── (a) stdin: tool_name + the command text, in one jq. Monitor and Bash both
#        carry it at .tool_input.command.
INPUT="$(cat 2>/dev/null || true)"
TOOL=""; CMD=""
IFS=$'\t' read -r TOOL CMD < <(
  printf '%s' "$INPUT" | jq -r '[(.tool_name // ""), ((.tool_input.command // "") | gsub("[\n\t]"; " "))] | @tsv' 2>/dev/null
) || true
case "$TOOL" in Bash|Monitor) ;; *) exit 0 ;; esac
[ -z "$CMD" ] && exit 0

# ── (b) master switch. `if .. == false` not `// true` — jq's // treats false as
#        empty, which would make enforce=false unreachable (the reuse-gate bug).
ENFORCE=$(jq -r 'if .nopoll.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# ── (c) teammates only. The lead's gate and cascade must never be blocked.
dt_is_teammate || exit 0

# ── (d) is this a GraphQL-heavy CI-status read?
POLLS_CI=0
case "$CMD" in
  *"gh pr checks"*) POLLS_CI=1 ;;
esac
if [ "$POLLS_CI" -eq 0 ]; then
  case "$CMD" in
    *"gh pr view"*statusCheckRollup*) POLLS_CI=1 ;;
  esac
fi
[ "$POLLS_CI" -eq 1 ] || exit 0

# ── (e) is it in a loop? A Monitor IS a poller by construction, whatever it
#        runs. For Bash, look for the loop/repeat constructs the measured
#        incident used (`for i in $(seq 1 40); do … sleep 30; done`).
LOOPING=0
[ "$TOOL" = "Monitor" ] && LOOPING=1
if [ "$LOOPING" -eq 0 ]; then
  case " $CMD " in
    *" while "*|*" until "*|*" for "*|*" watch "*|*"sleep "*|*";sleep"*|*"&& sleep"*) LOOPING=1 ;;
  esac
fi
[ "$LOOPING" -eq 1 ] || exit 0

# ── BLOCK. exit 2 = deny + surface stderr to the agent.
{
  echo "🛑 DREAMTEAM NO-POLL GUARD — CI polling blocked (tool: $TOOL)"
  echo "   You are a teammate looping a GraphQL-heavy GitHub read (gh pr checks /"
  echo "   gh pr view --json statusCheckRollup). The quota is per-ACCOUNT: on"
  echo "   2026-09-11 three lanes' 30s pollers exhausted it and every gh call in"
  echo "   the fleet failed, including the lead's merge cascade."
  echo "   \`gh api rate_limit\` will NOT warn you — it cannot see GraphQL secondary"
  echo "   limits, and it read 5000 remaining throughout that outage."
  echo "   A watch also survives a force-push: it polls a head that no longer"
  echo "   exists, never concludes, and never stops."
  echo ""
  echo "   DO THIS INSTEAD: push, then SendMessage the lead \"pushed\". The lead"
  echo "   runs the gate once (scripts/pr-gate.sh, REST-only) and tells you when"
  echo "   to rebase. You do not need CI status to finish your lane."
  echo "   One-shot reads are fine; so is REST: gh api repos/O/R/commits/<sha>/check-runs"
} >&2
exit 2
