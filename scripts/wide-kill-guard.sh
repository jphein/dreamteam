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
# WHAT IT BLOCKS (the judgement is scripts/lib/widekill_text.py, tested in tests/test-wide-kill.sh):
#   (A) `pkill` / `killall` whose own arguments name a test runner, unless a pkill call narrows its selection
#       by parent, process group, session, terminal, pid file or cgroup (killall has no such flag);
#   (B) `ps`, `pgrep` or `pidof` with a runner's name, whose result feeds a kill: later in the same
#       statement (`| xargs kill`), or through a variable bound to it (`for p in $(…); do kill $p`);
#   (C) `kill $( … such a listing … )`.
# NOT BLOCKED: `kill "$PID"` of a pid captured at launch; a pattern kill of anything else (a server, a
# browser); `ps | grep pytest` with no kill; scripts/kill-mine.py, which is the replacement:
#       "$CLAUDE_PLUGIN_ROOT"/scripts/kill-mine.py 'make test|python.* -m pytest'      # this worktree only
#
# WHO: every session, the lead too. Unlike the no-poll guard there is no role for which ending another
# lane's suite is the job. A host you have to yourself, or a kill you mean: lead the command with
# WIDE_KILL_OK=1. Kill switch: config `widekill.enforce=false`. A missing config ENFORCES.
#
# A SPEED BUMP, NOT A BOUNDARY: it matches command text, so a kill hidden in a script file passes and a
# command that only prints such a line is blocked (except a heredoc body that ends as data, #191's reader).
# FAIL OPEN only where nothing can be read at all: a malformed payload, no jq. FAIL CLOSED once the text is
# known to name a killer or a listing: no python3, or a detector that errors, is a block with one line.
# `timeout` in hooks.json is SECONDS.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

INPUT="$(cat 2>/dev/null || true)"
case "$INPUT" in *kill*) ;; *) exit 0 ;; esac          # nearly every Bash call leaves here, before any fork
command -v jq >/dev/null 2>&1 || exit 0
TOOL=""; CMD=""
{ IFS= read -r TOOL; CMD="$(cat)"; } < <(printf '%s' "$INPUT" | jq -r '(.tool_name // ""), (.tool_input.command // "")' 2>/dev/null) || true
[ "$TOOL" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0
case "$CMD" in WIDE_KILL_OK=1\ *) exit 0 ;; esac
# no killer and no listing in the text: nothing for the judge to find, so python is never started
printf '%s' "$CMD" | grep -Eq '(pkill|killall|pgrep|pidof|(^|[^[:alnum:]_.-])ps[[:space:]])' || exit 0

ENFORCE=$(jq -r 'if .widekill.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# FAIL CLOSED from here (Sen, xreview #279 r1; as no-poll-guard does): this text names a killer or a listing, and
# if it cannot be judged it is not run. The kill switch above is the only bypass.
if ! command -v python3 >/dev/null 2>&1; then
  echo "🛑 DREAMTEAM WIDE-KILL GUARD — python3 is missing, so this kill or listing command cannot be judged: blocked (kill switch: config widekill.enforce=false)" >&2
  exit 2
fi
printf '%s' "$CMD" | python3 -I "$ROOT/scripts/lib/widekill_text.py" 2>/dev/null
JRC=$?
[ "$JRC" -eq 1 ] && exit 0                             # 1 = judged: not a wide kill
if [ "$JRC" -ne 0 ]; then
  echo "🛑 DREAMTEAM WIDE-KILL GUARD — the detector failed (exit $JRC), so this kill or listing command cannot be judged: blocked (kill switch: config widekill.enforce=false)" >&2
  exit 2
fi

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
