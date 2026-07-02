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

# Payload field discovery: `touch state/statusline-debug` → next render dumps
# its stdin to state/statusline-payload.json (payload shape is undocumented
# and has drifted before — the .effort object, 2026-07-01).
[ -f "$ROOT/state/statusline-debug" ] && printf '%s' "$IN" > "$ROOT/state/statusline-payload.json" 2>/dev/null

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

# Context tokens — the payload drifted (2026-07-01, live-captured): the old flat
# context_window_tokens_used/context_window_total_tokens keys became a nested
# .context_window object with a pre-computed used_percentage. Prefer the nested
# form, keep the flat keys as fallback for older builds.
fmt_tok() {  # 200964 → 201k · 1000000 → 1M
  local n=$1
  if [ "$n" -ge 1000000 ]; then printf '%dM' $(( (n + 500000) / 1000000 ))
  else printf '%dk' $(( (n + 500) / 1000 )); fi
}
CTX=""
PCT="$(jf '.context_window.used_percentage')"; PCT=${PCT//[!0-9]/}
if [ -n "$PCT" ]; then
  USED="$(jf '.context_window.total_input_tokens')"; USED=${USED//[!0-9]/}
  SIZE="$(jf '.context_window.context_window_size')"; SIZE=${SIZE//[!0-9]/}
  DETAIL=""
  [ -n "$USED" ] && [ -n "$SIZE" ] && [ "$SIZE" -gt 0 ] && DETAIL=" ($(fmt_tok "$USED")/$(fmt_tok "$SIZE"))"
  CTX=" · ctx ${PCT}%${DETAIL}"
else
  USED="$(jf '.context_window_tokens_used')"
  TOTAL="$(jf '.context_window_total_tokens')"
  case "$USED$TOTAL" in *[!0-9]*|"") ;; *)
    [ "$TOTAL" -gt 0 ] && CTX=" · ctx $(( USED * 100 / TOTAL ))%"
  ;; esac
fi

# Rate limits — the other "tokens": plan usage. 5h/7d used_percentage.
RL=""
H5="$(jf '.rate_limits.five_hour.used_percentage')"; H5=${H5//[!0-9]/}
D7="$(jf '.rate_limits.seven_day.used_percentage')"; D7=${D7//[!0-9]/}
[ -n "$H5" ] && RL=" · 5h:${H5}%${D7:+ 7d:${D7}%}"

# Dreamteam footprint — LIVE, not the log tail (a logged snapshot goes stale the
# moment agents exit and once showed a dead team as "11 agents"). pgrep + free
# are ~10ms, fine for the hot path. Labeled "procs" honestly: this is the
# system-wide claude process count — the same number the mem-gate budgets
# against — NOT the dream-team roster (that's roster.sh, too heavy per render).
DT=""
NPROCS=$(pgrep -fc 'claude/versions' 2>/dev/null); NPROCS=${NPROCS//[!0-9]/}
AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}'); AVAIL=${AVAIL//[!0-9]/}
# 🛡 = the auto-containment scope is live (agent procs are memory-capped)
SHIELD=""
systemctl --user is-active --quiet dreamteam-agents.scope 2>/dev/null && SHIELD=" 🛡"
[ -n "$NPROCS" ] && DT=" · 🕯 ${NPROCS} procs${SHIELD}${AVAIL:+ · ${AVAIL}MiB free}"

printf '%s · effort:%s%s%s%s\n' "$MODEL" "$EFF" "$CTX" "$RL" "$DT"

# Mirror into the tmux pane title — visible in choose-tree (C-b w) now, and in
# pane borders if JP ever turns on: tmux set -g pane-border-status top
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux select-pane -t "$TMUX_PANE" -T "🕯 ${MODEL} · ${EFF}" 2>/dev/null || true
fi
exit 0
