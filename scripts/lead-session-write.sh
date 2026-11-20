#!/bin/bash
# lead-session-write.sh — SessionStart hook: when THIS session is the fleet lead's, record where it runs and how to
# bring it back, for scripts/lead-watchdog.sh.
#
# Why (2026-11-19 14:07): the lead died and the watchdog could not help: it watched one fixed pane (spire:0.0) and
# could only relaunch from a "Resume this session with: claude --resume <id>" hint still visible in that pane.
# With this file it knows the pane the lead really runs in and the session id, whatever the pane shows.
#
# Writes ~/.local/state/dreamteam/lead.session (0600, atomic), three KEY=VALUE lines, never sourced by anyone:
#   session=<uuid>      the session id Claude Code handed this hook on stdin
#   pane=<s>:<w>.<p>    the tmux pane this session runs in
#   launch=. <env file>; claude --resume <uuid> --permission-mode bypassPermissions
# "The lead" = a session inside tmux whose tmux session is $DREAMTEAM_LEAD_SESSION (default `spire`) and whose
# working directory is $HOME (FOR-AGENTS: the fleet lead is tmux `spire`, Claude in ~). Any other session: nothing.
# A hook must never block a session start: every path exits 0 and prints nothing, every wait is bounded (2 s each
# for stdin, the id parse and tmux), and the script runs itself under `timeout 5` with an outer exit 0.
set -u
# The whole hook runs once more under `timeout 5`, and this outer call ALWAYS exits 0: a stall or a crash inside can
# neither hold nor fail a session start. (hooks.json keeps the plain `bash <script>` form every other hook uses.)
if [ -z "${LEAD_SESSION_WRITE_INNER:-}" ]; then
    LEAD_SESSION_WRITE_INNER=1 timeout 5 bash "${BASH_SOURCE[0]}" "$@" >/dev/null 2>&1
    exit 0
fi
STATE="${LEAD_WATCHDOG_STATE:-$HOME/.local/state/dreamteam}"
LEAD_SESSION="${DREAMTEAM_LEAD_SESSION:-spire}"
ENVF="${LEAD_LAUNCH_ENV:-$HOME/.config/claude-code/env.sh}"
[ -n "${TMUX_PANE:-}" ] || exit 0                     # not in tmux: not the lead; stdin is not even read
# bounded: a stdin that never closes, or a tmux that does not answer, must not hold a session start
input=$(timeout 2 cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | timeout 2 python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: pass' 2>/dev/null)
[[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 0
pane=$(timeout 2 tmux ${LEAD_TMUX_SOCKET:+-L "$LEAD_TMUX_SOCKET"} display -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || exit 0
[[ "$pane" =~ ^[A-Za-z0-9_.-]+:[0-9]+\.[0-9]+$ ]] || exit 0
[ "${pane%%:*}" = "$LEAD_SESSION" ] || exit 0
[ "$(pwd -P)" = "$(cd "$HOME" && pwd -P)" ] || exit 0
[[ "$ENVF" =~ ^[A-Za-z0-9_./-]+$ ]] || exit 0
umask 077
mkdir -p "$STATE" 2>/dev/null || exit 0
f="$STATE/lead.session"
tmp=$(mktemp "$STATE/.lead.session.XXXXXX" 2>/dev/null) || exit 0
printf 'session=%s\npane=%s\nlaunch=. %s; claude --resume %s --permission-mode bypassPermissions\n' "$sid" "$pane" "$ENVF" "$sid" > "$tmp" \
  && mv -T -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
exit 0
