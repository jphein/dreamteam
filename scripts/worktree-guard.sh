#!/usr/bin/env bash
# dreamteam — WORKTREE GUARD  (PreToolUse hook, matcher: Edit|Write)
#
# Enforces the skill's #1 failure mode BY HARNESS LAW instead of prompt
# discipline. The dreamteam skill mandates: each team agent works ONLY inside
# its pre-created worktree (.claude/worktrees/<agent>-…). Editing outside it —
# especially the shared main checkout — causes catastrophic cross-agent
# collisions (two real incidents: agents racing `git branch -m` / overwriting
# each other's files in the shared index). Today we confirmed plugin hooks fire
# inside TEAMMATE sessions too, so a PreToolUse guard running in the agent's OWN
# session can block an out-of-worktree write before it lands.
#
# WHAT IT DOES
#   On an Edit/Write, identify WHICH agent this session is (env override, else a
#   pure-bash /proc ancestry walk for the `--agent-id <name@team>` flag every
#   teammate proc carries — orchestrators/main sessions lack it). Look up that
#   member's assigned cwd in the harness team config. ONLY when that cwd is a
#   worktree assignment (…/.claude/worktrees/…) do we enforce: writes must land
#   inside the worktree (or /tmp, or a */scratch/* findings path). Anything else
#   → BLOCK (exit 2) with the skill's escalation language. Shared-checkout
#   spawns (cwd is a plain project dir — the legitimate disjoint-ownership mode)
#   are never touched.
#
# WHY /proc, NOT the tool payload: the payload names the file, not the caller.
# Teammate identity lives in the process argv (`--agent-id`), the same signal
# scope-attach.sh / idle-agents.sh / roster.sh use to tell teammates from
# orchestrators. The walk is the only in-session way to answer "who am I".
#
# SAFETY POSTURE — FAIL OPEN. Any ambiguity (no identity, missing/malformed team
# config, unknown member, parse error, non-Linux/no /proc) → exit 0. A guard bug
# must never brick an agent; the cost of a rare missed block is far below the
# cost of wedging a fleet. Master kill-switch: config worktree.enforce=false.
#
# FAST (<100ms): one jq over stdin, one jq over the team config, a pure-bash
# /proc walk (no subprocess per hop). set -uo pipefail, always explicit exits.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"

# ── (a) stdin: tool_name + file_path in ONE jq. Not Edit/Write, or no path → allow.
INPUT="$(cat 2>/dev/null || true)"
TOOL=""; FILE_PATH=""
IFS=$'\t' read -r TOOL FILE_PATH < <(
  printf '%s' "$INPUT" | jq -r '[(.tool_name // ""), (.tool_input.file_path // "")] | @tsv' 2>/dev/null
) || true
case "$TOOL" in Edit|Write) ;; *) exit 0 ;; esac
[ -z "$FILE_PATH" ] && exit 0

# ── (b) master switch. NOTE: `if .. == false` not `// true` — jq's // treats
#        false as empty, which would make enforce=false unreachable (the exact
#        bug fixed in reuse-gate.sh ~line 24 / scope-attach.sh, guarded by tests).
ENFORCE=$(jq -r 'if .worktree.enforce == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENFORCE" = "false" ] && exit 0

# ── (c) which agent is this session? env override (test seam / future-proofing)
#        first, else walk /proc ancestry for the `--agent-id <name@team>` flag.
#        Pure bash, max 8 hops, no subprocess per hop. Not found → we're the
#        orchestrator/main session (no --agent-id) → guard does not apply.
find_agent_id() {
  local cur="$1" hops=0 i ppid k v
  local -a args
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null && [ "$hops" -lt 8 ]; do
    if [ -r "/proc/$cur/cmdline" ]; then
      args=()
      mapfile -d '' -t args < "/proc/$cur/cmdline" 2>/dev/null || args=()
      for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
          --agent-id)
            if [ $((i+1)) -lt ${#args[@]} ] && [ -n "${args[i+1]}" ]; then
              printf '%s' "${args[i+1]}"; return 0
            fi ;;
          --agent-id=*)
            printf '%s' "${args[i]#--agent-id=}"; return 0 ;;
        esac
      done
    fi
    # ascend to parent via /proc/<pid>/status (pure bash, no subprocess)
    ppid=""
    while read -r k v _; do
      [ "$k" = "PPid:" ] && { ppid="$v"; break; }
    done < "/proc/$cur/status" 2>/dev/null
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -le 1 ] && break
    cur="$ppid"; hops=$((hops+1))
  done
  return 1
}

AGENT_ID="${DREAMTEAM_AGENT_ID:-}"
[ -z "$AGENT_ID" ] && AGENT_ID="$(find_agent_id "$$" 2>/dev/null || true)"
[ -z "$AGENT_ID" ] && exit 0                       # no teammate identity → orchestrator → allow
case "$AGENT_ID" in *@*) ;; *) exit 0 ;; esac      # need name@team to resolve → else fail open

# ── (d) split identity, load the member's assigned cwd from the team config.
NAME="${AGENT_ID%%@*}"       # before first @
TEAM="${AGENT_ID#*@}"        # after first @ (team dir; may contain hyphens)
TCFG="$TEAMS_DIR/$TEAM/config.json"
[ -r "$TCFG" ] || exit 0                            # unknown team → fail open
CWD=$(jq -r --arg n "$NAME" --arg id "$AGENT_ID" \
  '[.members[]? | select(.agentId == $id or .name == $n) | .cwd] | .[0] // empty' \
  "$TCFG" 2>/dev/null || true)
[ -z "$CWD" ] && exit 0                             # member/cwd not found → fail open

# ── (e) ONLY enforce for worktree assignments. Shared-checkout spawns (cwd is a
#        plain project dir, the legitimate disjoint-ownership mode) are exempt.
case "$CWD" in */.claude/worktrees/*) ;; *) exit 0 ;; esac

# ── (f) resolve file_path to absolute (against the hook's cwd if relative),
#        then allow: inside the assigned worktree, /tmp, or any */scratch/*
#        findings path. Everything else → BLOCK.
FP="$FILE_PATH"
case "$FP" in /*) ;; *) FP="${PWD:-.}/$FP" ;; esac
case "$FP" in
  "$CWD"|"$CWD"/*) exit 0 ;;      # inside the assigned worktree (trailing-slash-guarded: luna-1 ≠ luna-12)
  /tmp/*)          exit 0 ;;      # scratch temp
  */scratch/*)     exit 0 ;;      # findings scratch (agents legitimately write here)
esac

# ── BLOCK. exit 2 = deny + surface stderr to the agent (skill escalation language).
{
  echo "🛑 DREAMTEAM WORKTREE GUARD — write blocked: ${FILE_PATH}"
  echo "   Agent '${NAME}' — your worktree is ${CWD}."
  echo "   Writing outside it risks cross-agent collision (the #1 dreamteam failure mode; 2 real incidents)."
  echo "   Allowed: your worktree, /tmp, or a */scratch/* findings path."
  echo "   If you believe this is wrong, STOP and SendMessage the orchestrator — do not work around the guard."
} >&2
exit 2
