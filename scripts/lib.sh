#!/usr/bin/env bash
# dreamteam — shared helpers. Sourced by the gates + budget/idle scripts.
# Defensive: every function falls back cleanly if the `claude` CLI is absent.

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
