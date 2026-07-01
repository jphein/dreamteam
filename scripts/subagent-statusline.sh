#!/usr/bin/env bash
# dreamteam — per-subagent status line (user settings → subagentStatusLine).
# The harness pipes each agent-panel row's context JSON on stdin and renders
# our one-line stdout in that row. Payload shape is undocumented — parse
# defensively, first field that exists wins, never fail. HOT PATH: renders per
# row per refresh, so a single jq pass and zero file/process reads.
set -uo pipefail
IN="$(cat 2>/dev/null || true)"

LINE=$(printf '%s' "$IN" | jq -r '
  def first_of($keys): [ $keys[] as $k | getpath($k | split(".")) // empty ] | map(select(. != null and . != "")) | .[0] // "";
  (first_of(["name","teammate_name","agent_name","agent_id","subagent_type","description"])) as $who
  | (first_of(["status","state","phase"])) as $st
  | (first_of(["model.display_name","model.id","model"])) as $model
  | [$who, $st, $model] | map(select(. != null and . != "" and (type=="string"))) | join(" · ")
' 2>/dev/null) || true

[ -n "${LINE:-}" ] && printf '🕯 %s\n' "$LINE" || printf '🕯 dreaming…\n'
exit 0
