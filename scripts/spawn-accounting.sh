#!/usr/bin/env bash
# dreamteam — POST-SPAWN accounting  (PostToolUse hook, matcher: Agent|Task)
#
# 1. Logs footprint to dreamteam.log (disk record)
# 2. Emits live agent count + memory to stdout JSON (injected into Claude's context)
# 3. Appends the TRUE team roster (from roster.sh, which reads the authoritative
#    harness team config) to that message. The old lossy state/agents.json roster
#    file is RETIRED — it only saw new spawns and never marked idle/dead.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
LOG="$STATE/dreamteam.log"
mkdir -p "$STATE"

INPUT="$(cat 2>/dev/null || true)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in Agent|Task) ;; *) exit 0 ;; esac

# Robust metric capture. NEVER use `pipe || echo 0`: under `set -o pipefail` a
# failed/restricted `ps` (as in the hook sandbox) fails the pipe AND fires the
# fallback — while awk already printed "0" — yielding a multiline "0\n0" that
# then breaks the arithmetic below. Instead: let awk own the default (it always
# exits 0), then sanitize each value to bare digits before any math.
NAGENTS=$(pgrep -fc 'claude/versions' 2>/dev/null); NAGENTS=${NAGENTS//[!0-9]/}; NAGENTS=${NAGENTS:-0}
RSS_KB=$(ps -eo rss,args 2>/dev/null | awk '/claude\/versions/ && !/awk/ {s+=$1} END{print s+0}')
RSS_KB=${RSS_KB//[!0-9]/}; RSS_KB=${RSS_KB:-0}
TOTAL_MB=$(( RSS_KB / 1024 ))
AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); AVAIL=${AVAIL//[!0-9]/}; AVAIL=${AVAIL:-0}
TS=$(date +%FT%T)

echo "$TS post-spawn: agents=${NAGENTS} total_rss=${TOTAL_MB}MB avail=${AVAIL}MiB" >> "$LOG"

# Crash-detection marker for PLAIN sessions. launch-dreamteam.sh writes this for
# isolated launches, but fleets spawned in ordinary sessions had no marker — so
# the 2026-07-01 16:06 systemd-oomd kill produced NO crash-audit notice on
# restart. First spawn writes it; SessionEnd (cleanup-marker.sh) clears it on a
# clean exit; a survivor at SessionStart = unclean death, recovery checklist fires.
if [ ! -f "$STATE/active" ]; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"; CWD="${CWD:-$PWD}"
  printf '{"team":"%s","repo":"%s","started":"%s"}\n' "session-spawned" "$CWD" "$TS" > "$STATE/active" 2>/dev/null || true
fi

# Automatic containment (incident-2 fix): attach agent procs to the capped
# dreamteam-agents.scope so a runaway team is oomd's victim, not the host.
bash "$ROOT/scripts/scope-attach.sh" 2>/dev/null || true

# Build roster summary from the AUTHORITATIVE harness team config (via roster.sh)
# — every member with its TRUE status, not just spawns this session saw. roster.sh
# always exits 0; if it can't resolve a team, .agents is empty → blank line.
ROSTER_LINE=$(bash "$ROOT/scripts/roster.sh" --json 2>/dev/null \
  | jq -r 'if (.agents|length) > 0 then [.agents[] | "\(.name)(\(.status))"] | join(" ") else "" end' 2>/dev/null || true)

# Emit to stdout as JSON — PostToolUse hooks use systemMessage to inject into Claude's context
MSG="dreamteam: ${NAGENTS} agents | ${TOTAL_MB}MB RSS | ${AVAIL}MB free | ${ROSTER_LINE}"
jq -n --arg msg "$MSG" '{"systemMessage": $msg}'
