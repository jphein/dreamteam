#!/usr/bin/env bash
# dreamteam — automatic containment: attach agent processes to a capped scope.
#
# THE fix for the launch-discipline gap behind both OOM incidents: containment
# used to exist only for fleets launched via launch-dreamteam.sh, and nobody's
# fleets used it — so on 2026-07-01 16:06 systemd-oomd killed the shared Ghostty
# scope holding EVERYTHING. This script makes containment automatic:
#
#   1. Ensures a user scope `dreamteam-agents.scope` exists, capped with the
#      same MemoryHigh/Max/SwapMax the launcher uses (config.json .scope).
#   2. Attaches every live teammate process on the host (any session — the
#      plugin's guards are system-wide by design) into that scope via the
#      sanctioned systemd D-Bus call (AttachProcessesToUnit; verified working
#      on katana 2026-07-01). Their children (gradle/JVM daemons — the actual
#      killers) inherit the cgroup.
#
# Orchestrators/main sessions are deliberately NOT attached — when the scope is
# OOM-killed, the teams die and the orchestrators survive to recover them.
# Teammate procs are identified by the `--agent-id` flag in their argv.
#
# Called from spawn-accounting.sh on every spawn (idempotent; re-attach of an
# already-attached pid is skipped via /proc cgroup check). Always exits 0.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
SCOPE="dreamteam-agents"

# Master switch (default on). Disable via config: scope.autoAttach=false
# NOTE: not `// true` — jq's // treats false as empty, which would make the
# disable switch a no-op (found by tests/test-scope.sh).
ENABLED=$(jq -r 'if .scope.autoAttach == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)
[ "$ENABLED" = "false" ] && exit 0
command -v systemd-run >/dev/null 2>&1 && command -v busctl >/dev/null 2>&1 || exit 0

getscope() { jq -r --arg k "$1" --arg d "$2" ".scope[\$k] // \$d" "$CFG" 2>/dev/null || printf '%s' "$2"; }
HIGH=$(getscope memoryHigh 20G); MAX=$(getscope memoryMax 24G); SWAPMAX=$(getscope memorySwapMax 8G)

# 1. Ensure the capped scope exists (anchor `sleep infinity` keeps it alive
#    between waves; cleanup-marker stops it when only the anchor remains).
if ! systemctl --user is-active --quiet "$SCOPE.scope" 2>/dev/null; then
  # Delegate=yes is REQUIRED: AttachProcessesToUnit fails with "Process
  # migration not available on non-delegated units" without it (live-verified).
  systemd-run --user --scope --unit="$SCOPE" \
    -p MemoryHigh="$HIGH" -p MemoryMax="$MAX" -p MemorySwapMax="$SWAPMAX" \
    -p Delegate=yes \
    sleep infinity >/dev/null 2>&1 &
  disown 2>/dev/null || true
  # brief settle so this wave's attaches usually succeed; if not, next spawn retries
  for _ in 1 2 3 4 5 6; do
    systemctl --user is-active --quiet "$SCOPE.scope" 2>/dev/null && break
    sleep 0.2
  done
fi

# 2. Attach every live teammate proc not already in the scope.
ATTACHED=0
for pid in $(pgrep -f 'claude/versions' 2>/dev/null); do
  grep -q -- '--agent-id' "/proc/$pid/cmdline" 2>/dev/null || continue
  grep -q "$SCOPE.scope" "/proc/$pid/cgroup" 2>/dev/null && continue
  if busctl call --user org.freedesktop.systemd1 /org/freedesktop/systemd1 \
       org.freedesktop.systemd1.Manager AttachProcessesToUnit \
       "ssau" "$SCOPE.scope" "/" 1 "$pid" >/dev/null 2>&1; then
    ATTACHED=$((ATTACHED + 1))
  fi
done

if [ "$ATTACHED" -gt 0 ]; then
  mkdir -p "$STATE" 2>/dev/null
  echo "$(date +%FT%T) scope-attach: ${ATTACHED} agent proc(s) → ${SCOPE}.scope (MemoryMax=${MAX})" >> "$STATE/dreamteam.log" 2>/dev/null || true
fi
exit 0
