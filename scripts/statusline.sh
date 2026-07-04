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
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"   # scope.memoryHigh for the shield segment
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
fmt_bytes() {  # bytes → "3.2G" (≥1 GiB, one decimal, rounded) or "512M" (<1 GiB, integer MiB)
  local b=$1
  if [ "$b" -ge 1073741824 ]; then
    local t=$(( (b * 10 + 536870912) / 1073741824 ))   # tenths of a GiB, half-up
    printf '%d.%dG' $(( t / 10 )) $(( t % 10 ))
  else
    printf '%dM' $(( (b + 524288) / 1048576 ))
  fi
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
# 🛡 <cur>/<high> = the auto-containment scope is live. MemoryCurrent is the TRUE
# team footprint — it counts the gradle/JVM child procs the pgrep/RSS accounting is
# blind to (root cause of the 2026-07-01 16:06 oomd kill; see postmortem §5). One
# extra `systemctl show` beyond the existing is-active, and ONLY when active.
SHIELD=""
# shellcheck source=lib.sh
. "$ROOT/scripts/lib.sh" 2>/dev/null || true
DT_SCOPE="$(command -v dreamteam_scope_name >/dev/null 2>&1 && dreamteam_scope_name || echo dreamteam-agents)"
if systemctl --user is-active --quiet "$DT_SCOPE.scope" 2>/dev/null; then
  SHIELD=" 🛡"
  SMC=$(systemctl --user show "$DT_SCOPE.scope" -p MemoryCurrent --value 2>/dev/null)
  SMC=${SMC//[!0-9]/}   # empty / "[not set]" / "infinity" / non-numeric → ""
  SHIGH=$(jq -r '.scope.memoryHigh // "20G"' "$CFG" 2>/dev/null); [ -n "$SHIGH" ] || SHIGH="20G"
  # ${#SMC}<=15 rejects the uint64 "not-available" sentinel; real usage on a 32G host is ~11 digits
  [ -n "$SMC" ] && [ "${#SMC}" -le 15 ] && SHIELD=" 🛡 $(fmt_bytes "$SMC")/${SHIGH}"
fi
[ -n "$NPROCS" ] && DT=" · 🕯 ${NPROCS} procs${SHIELD}${AVAIL:+ · ${AVAIL}MiB free}"

printf '%s · effort:%s%s%s%s\n' "$MODEL" "$EFF" "$CTX" "$RL" "$DT"

# Mirror into the tmux pane title — visible in choose-tree (C-b w) now, and in
# pane borders if JP ever turns on: tmux set -g pane-border-status top
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux select-pane -t "$TMUX_PANE" -T "🕯 ${MODEL} · ${EFF}" 2>/dev/null || true
fi
exit 0
