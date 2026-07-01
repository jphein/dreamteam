#!/usr/bin/env bash
# dreamteam — statusline: model · effort · ctx% · team footprint.
# Wired via ~/.claude/settings.json → statusLine.command (user-level; the harness
# pipes a session JSON payload on stdin and renders our stdout under the prompt).
#
# Effort resolution — the payload has no reliable effort field, so:
#   1. payload .effort / .effortLevel (if a future build adds it)
#   2. the session transcript: /effort emits "Set effort level to <x>" stdout,
#      which is recorded verbatim in the transcript JSONL (catches session-only
#      levels like "max" that settings can never hold)
#   3. persisted effortLevel in ~/.claude/settings.json
#   4. "default"
# Keep this FAST — it runs on every statusline refresh. LC_ALL=C grep, no ps,
# no claude CLI, one bounded log read.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
IN="$(cat 2>/dev/null || true)"
jf() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }

MODEL="$(jf '.model.display_name')"
[ -n "$MODEL" ] || MODEL="$(jf '.model.id')"
MODEL="${MODEL:-?}"

# .effort is an OBJECT in the live payload ({"level":"max"} — verified 2026-07-01);
# accept object, plain string, or effortLevel, in that order.
EFF="$(jf 'if (.effort|type) == "object" then .effort.level else .effort end')"
[ -n "$EFF" ] || EFF="$(jf '.effortLevel')"
if [ -z "$EFF" ]; then
  TP="$(jf '.transcript_path')"
  if [ -n "$TP" ] && [ -f "$TP" ]; then
    EFF=$(LC_ALL=C grep -oE 'Set effort level to [a-z]+' "$TP" 2>/dev/null | tail -1 | awk '{print $5}') || true
  fi
fi
[ -n "$EFF" ] || EFF=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null) || true
EFF="${EFF:-default}"

# Context % — same math as the previous inline-jq statusline this replaces.
CTX=""
USED="$(jf '.context_window_tokens_used')"
TOTAL="$(jf '.context_window_total_tokens')"
case "$USED$TOTAL" in *[!0-9]*|"") ;; *)
  [ "$TOTAL" -gt 0 ] && CTX=" · ctx $(( USED * 100 / TOTAL ))%"
;; esac

# Dreamteam footprint — last spawn-accounting line, only if a team ran recently.
DT=""
LOG="$ROOT/state/dreamteam.log"
if [ -f "$LOG" ] && [ -n "$(find "$LOG" -mmin -360 2>/dev/null)" ]; then
  LAST=$(tail -n 1 "$LOG" 2>/dev/null) || true
  AG=$(printf '%s' "$LAST" | grep -oE 'agents=[0-9]+' | cut -d= -f2) || true
  AV=$(printf '%s' "$LAST" | grep -oE 'avail=[0-9]+' | cut -d= -f2) || true
  [ -n "$AG" ] && DT=" · 🕯 ${AG} agents${AV:+ · ${AV}MiB free}"
fi

printf '%s · effort:%s%s%s\n' "$MODEL" "$EFF" "$CTX" "$DT"

# Mirror into the tmux pane title — visible in choose-tree (C-b w) now, and in
# pane borders if JP ever turns on: tmux set -g pane-border-status top
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux select-pane -t "$TMUX_PANE" -T "🕯 ${MODEL} · ${EFF}" 2>/dev/null || true
fi
exit 0
