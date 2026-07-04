#!/usr/bin/env bash
# dreamteam — shared helpers. Sourced by the gates + budget/idle scripts.
# Defensive: every function falls back cleanly if the `claude` CLI is absent.

# dreamteam_project_root — this session's project directory, worktree-aware:
# an agent running inside <repo>/.claude/worktrees/<name>/… belongs to <repo>.
# Seam: DREAMTEAM_PROJECT_DIR (tests / non-cwd callers).
dreamteam_project_root() {
  local d="${DREAMTEAM_PROJECT_DIR:-$PWD}"
  case "$d" in */.claude/worktrees/*) d="${d%%/.claude/worktrees/*}" ;; esac
  readlink -f "$d" 2>/dev/null || printf '%s' "$d"
}

# dreamteam_scope_name — the containment scope for THIS project (issue #19).
# Per-project scopes replace the one shared cap: scope membership == project
# membership (attribution for fleet.sh becomes trivial) and one project's
# runaway can no longer throttle every other project's fleet.
# Precedence: DREAMTEAM_SCOPE_NAME (tests + launch-dreamteam.sh) >
#   config .scope.name (pin per repo) > dreamteam-<project-basename,sanitized>
#   > dreamteam-agents (legacy shared fallback, unreachable in practice).
# Same-basename repos in different paths share a scope — acceptable, documented.
dreamteam_scope_name() {
  if [ -n "${DREAMTEAM_SCOPE_NAME:-}" ]; then printf '%s' "$DREAMTEAM_SCOPE_NAME"; return; fi
  local cfg="${DREAMTEAM_CONFIG:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/config.json}"
  local n
  n="$(jq -r '.scope.name // empty' "$cfg" 2>/dev/null)" || n=""
  if [ -n "$n" ]; then printf '%s' "$n"; return; fi
  local p
  p="$(basename "$(dreamteam_project_root)" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  p="$(printf '%s' "$p" | sed 's/-*$//; s/^-*//' | cut -c1-32)"
  if [ -n "$p" ]; then printf 'dreamteam-%s' "$p"; else printf 'dreamteam-agents'; fi
}

# count_agents — number of live Claude agents/sessions, system-wide.
# Combines two signals and takes the MAX, each cleaned of a distinct false-count:
#   • pgrep  — live `claude/versions` processes, EXCLUDING `claude agents` helper
#              invocations (the CLI call below is itself such a process; counting it
#              would be a self-inflating feedback loop, since this runs on every spawn).
#              This is the truth for in-process team subagents, which do NOT appear as
#              separate `claude agents` entries.
#   • claude agents --json — active sessions, EXCLUDING `done` AND `blocked`. Blocked
#              background sessions are often parked/stale (observed: a 10-day-old entry)
#              and aren't RAM consumers; any blocked session with a LIVE process is
#              already counted by pgrep. Excluding them avoids ghost-inflation of the cap.
# Bounded with `timeout` so a slow/hung CLI never stalls a hook.
count_agents() {
  local cli pg
  pg=$(pgrep -af 'claude/versions' 2>/dev/null | grep -vc ' agents ' || true); pg=${pg:-0}
  cli=$(timeout 4 claude agents --json 2>/dev/null \
        | jq '[.[] | (.state // .status // "active") as $s | select($s != "done" and $s != "blocked")] | length' 2>/dev/null)
  if [ -n "$cli" ] && [ "$cli" -ge 0 ] 2>/dev/null; then
    [ "$pg" -gt "$cli" ] && cli=$pg
    echo "$cli"
  else
    echo "$pg"                                # CLI unavailable → pgrep fallback
  fi
}
