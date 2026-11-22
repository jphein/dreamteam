#!/usr/bin/env bash
# dreamteam — WIDE-KILL GUARD  (PreToolUse hook, matcher: Bash|Monitor; acts on Bash only)
#
# Blocks a HOST-WIDE pattern kill of a test runner.
#
# WHY (measured on serialhub, Flow row 62d79dae). Lanes restarted their own suite with
#     for p in $(ps -eo pid,args | grep -E "make test|python.* -m pytest" | …); do kill $p; done
# and with `pkill -f "[p]ython3 -m pytest -q plugins/system-updates"`. A command line carries no owner
# (`make test` reads the same in every worktree), so each call ended every lane's suite on the host:
# 2026-11-20 12:35:59, 12:37:44 and 12:38:41, two lanes' runs dead in the same second each time, and nine
# calls on 11-18. The victims saw only "Terminated" at a random test; `setsid nohup` could not help, and the
# row's first suspects (the Bash tool timeout, a reaper timer) were both innocent.
#
# WHAT IT BLOCKS, in the command text:
#   (A) `pkill` / `killall` whose own arguments name a test runner, unless that same call narrows itself by
#       parent, process group, session, terminal or cgroup (-P -g -s -t --cgroup and their long forms);
#   (B) `ps` or `pgrep` … a test runner's name … `kill` in one command: a selection by name fed to kill.
#   A "test runner" is the list in RUNNERS below. The `[p]ytest` self-match trick is read as `pytest`.
# NOT BLOCKED: `kill "$PID"` of a pid captured at launch; a pattern kill of anything else (a server, a
# browser); `ps | grep pytest` with no kill; scripts/kill-mine.py, which is the replacement:
#       "$CLAUDE_PLUGIN_ROOT"/scripts/kill-mine.py 'make test|python.* -m pytest'      # this worktree only
#
# WHO: every session, the lead too. Unlike the no-poll guard there is no role for which ending another
# lane's suite is the job. A host you have to yourself, or a kill you mean: lead the command with
# WIDE_KILL_OK=1. Kill switch: config `widekill.enforce=false`. A missing config ENFORCES.
#
# TEXT MATCH, CONSERVATIVE: a command that only prints such a line is blocked too, except a heredoc body
# that ends as data (a commit message, an issue body): scripts/lib/nopoll_text.py removes those, as it does
# for the no-poll guard (#191). FAIL OPEN on a malformed payload or no jq. `timeout` in hooks.json is SECONDS.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

INPUT="$(cat 2>/dev/null || true)"
case "$INPUT" in *kill*) ;; *) exit 0 ;; esac          # nearly every Bash call leaves here, before any fork
command -v jq >/dev/null 2>&1 || exit 0
TOOL=""; CMD=""
IFS=$'\t' read -r TOOL CMD < <(
  printf '%s' "$INPUT" | jq -r '[(.tool_name // ""), ((.tool_input.command // "") | gsub("\t"; " ") | gsub("\n"; " ; "))] | @tsv' 2>/dev/null
) || true
[ "$TOOL" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0
case "$CMD" in WIDE_KILL_OK=1\ *) exit 0 ;; esac

ENFORCE=$(jq -r 'if .widekill.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

RUNNERS='pytest|py\.test|unittest|make +(test|check)|tests/run\.sh|cargo +test|go +test|npm +(run +)?test|jest|vitest'
SCOPED='(^|[[:space:]])(-P|-g|-s|-t|--parent|--pgroup|--session|--terminal|--cgroup)([[:space:]=]|$)'

# wide TEXT → 0 when the text holds form (A) or (B).
wide() {
  local text seg
  text="$(printf '%s' "$1" | sed -E 's/\[([[:alnum:]])\]/\1/g')"      # [p]ytest → pytest
  # (A) each pkill/killall call, up to the next `;` or `&` (a newline is read as `;`; a `|` may sit inside the
  #     quoted pattern, so it does not end the call)
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    printf '%s' "$seg" | grep -Eq -- "$RUNNERS" || continue
    printf '%s' "$seg" | grep -Eq -- "$SCOPED" && continue
    return 0
  done < <(printf '%s' "$text" | grep -Eo '(^|[^[:alnum:]_./-])(pkill|killall)[[:space:]][^;&]*' || true)
  # (B) a listing by name, then kill. The runner's name must sit in the listing's OWN statement (no `;` or
  #     newline between): `pgrep -c workerd ; npm test ; kill "$P"` lists one thing, tests, and kills a pid it
  #     captured (replay 2026-11-02: that shape was the one false block in 4136 commands).
  printf '%s' "$text" | grep -Eq "(^|[^[:alnum:]_./-])(ps|pgrep)[[:space:]][^;]*($RUNNERS).*(^|[^[:alnum:]_-])kill([[:space:]]|\$)" && return 0
  return 1
}

wide "$CMD" || exit 0

# heredoc data: judge again without the bodies that only ever land as data. No python3 or any error: keep the block.
case "$CMD" in
  *"<<"*)
    RAW="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)"
    if [ -n "$RAW" ] && DATA="$(printf '%s' "$RAW" | python3 -I "$ROOT/scripts/lib/nopoll_text.py" 2>/dev/null)"; then
      DATA="${DATA//$'\n'/ ; }"; DATA="${DATA//$'\t'/ }"
      wide "$DATA" || exit 0
    fi
    ;;
esac

{
  echo "🛑 DREAMTEAM WIDE-KILL GUARD — a host-wide kill of a test runner, blocked"
  echo "   This selects processes by NAME (pkill/killall, or ps/pgrep fed to kill). A command line carries"
  echo "   no owner: \`make test\` and \`python -m pytest\` read the same in every lane's worktree, so this ends"
  echo "   every lane's suite on the host. On serialhub (11-18, 11-20) it killed other lanes' 7-minute runs"
  echo "   twelve times; they saw only \"Terminated\". setsid/nohup does not protect a run from it."
  echo ""
  echo "   DO THIS INSTEAD, one of:"
  echo "     ${ROOT}/scripts/kill-mine.py 'make test|python.* -m pytest'     # this worktree only (--under DIR)"
  echo "     kill \"\$PID\"            # the pid you captured with \$! when you launched the run"
  echo "   Alone on the host and you mean it: lead the command with WIDE_KILL_OK=1."
} >&2
exit 2
