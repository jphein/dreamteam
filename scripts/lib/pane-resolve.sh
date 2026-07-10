#!/usr/bin/env bash
# dreamteam — pane-resolve.sh: the CANONICAL agent→pane resolver (issue #53).
#
# WHY THIS LIB EXISTS
#   "find the tmux sock@addr for a given agent" was independently re-implemented in
#   poke.sh, pane-peek.sh, agent-activity.sh and fleet.sh (Oracle #53 audit). Two
#   strategies, copied N times: pid-ancestry (roster NAME→pid→owning pane, the #32/#41
#   collision-resistant method) and an @handle-footer scan (for names with no pid —
#   forks). Per-resolver bugs (#28/#35/#61) then had to be fixed N times. This lib is
#   the ONE bash implementation the bash resolvers source; the footer RULE below is the
#   single definition of "structural footer match" (agent-activity.sh is embedded Python
#   and can't source bash — it mirrors THIS rule verbatim, guarded by the shared
#   tests/test-pane-resolve.sh footer-rule table).
#
# WHAT IT PROVIDES (source it, then call):
#   pr_sweep_panes                 populate PR_PANE_ADDR (pane_pid → "sock<TAB>addr")
#                                  and PR_PANES ("sock<TAB>addr<TAB>pane_pid" list) by
#                                  sweeping every socket under $TMUXDIR. Absent server
#                                  → skipped, never an error (multi-socket: default +
#                                  `-L dreamteam`).
#   pr_pane_of <pid>               walk the pid's PPid chain (via $PROC) until the FIRST
#                                  (closest) pane_pid in PR_PANE_ADDR matches; print
#                                  "sock<TAB>addr", exit 0. Closest-wins so a shared
#                                  ancestor (tmux-server/orchestrator) never shadows the
#                                  agent's own pane. Max 20 hops. Miss → exit 1.
#   pr_footer_matches <sock> <addr> <agent>
#                                  0 iff the pane's FOOTER structurally names @agent —
#                                  a single line that is box-dash-flanked around
#                                  "@agent" (── @agent ──), NOT merely a line that
#                                  CONTAINS "@agent" next to some box-dash elsewhere in
#                                  the capture. That laxer two-grep test (grep @name;
#                                  grep ─) false-matched a pane that only DISPLAYS the
#                                  string — a roster listing, a log line, or (the #61
#                                  self-poke) the agent's own typed command — sending
#                                  poke into the WRONG pane. See the regex note below.
#   pr_resolve_footer <agent>      first PR_PANES entry whose footer matches; print
#                                  "sock<TAB>addr", exit 0; none → exit 1.
#
# Seams (identical to the consumers/tests): DREAMTEAM_TMUX_DIR, DREAMTEAM_PROC. tmux/awk
# resolve via PATH (stubbable). Read-only: only list-panes/capture-pane/awk + /proc.

# Idempotent source guard.
[ -n "${_PANE_RESOLVE_SH:-}" ] && return 0 2>/dev/null || true
_PANE_RESOLVE_SH=1

: "${DREAMTEAM_TMUX_DIR:=/tmp/tmux-$(id -u)}"
: "${DREAMTEAM_PROC:=/proc}"

declare -A PR_PANE_ADDR   # pane_pid → "sock<TAB>addr"
PR_PANES=()               # "sock<TAB>addr<TAB>pane_pid"

# pr_sweep_panes — (re)build PR_PANE_ADDR + PR_PANES from every socket under $TMUXDIR.
pr_sweep_panes() {
  PR_PANE_ADDR=(); PR_PANES=()
  local sock line ppid addr
  [ -d "$DREAMTEAM_TMUX_DIR" ] || return 0
  for sock in "$DREAMTEAM_TMUX_DIR"/*; do
    [ -S "$sock" ] || [ -e "$sock" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ppid="${line##* }"; addr="${line% *}"     # split on LAST space (session names w/ spaces)
      [ -n "$ppid" ] || continue
      PR_PANE_ADDR["$ppid"]="$sock"$'\t'"$addr"
      PR_PANES+=("$sock"$'\t'"$addr"$'\t'"$ppid")
    done < <(tmux -S "$sock" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null || true)
  done
  return 0
}

# pr_pane_of <pid> — closest ancestor pane_pid → "sock<TAB>addr" (exit 0), else exit 1.
pr_pane_of() {
  local p="${1:-}" hops=0 ppid
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$hops" -lt 20 ]; do
    if [ -n "${PR_PANE_ADDR[$p]:-}" ]; then printf '%s' "${PR_PANE_ADDR[$p]}"; return 0; fi
    ppid="$(awk '/^PPid:/{print $2}' "$DREAMTEAM_PROC/$p/status" 2>/dev/null)" || return 1
    [ -n "$ppid" ] || return 1
    p="$ppid"; hops=$((hops+1))
  done
  return 1
}

# PR_FOOTER_ERE <name-ere> — the CANONICAL structural-footer regex (#61). This ONE
#   expression is the single source of truth for "what is a real footer"; agent-activity.sh's
#   Python matcher mirrors it verbatim and tests/test-pane-resolve.sh runs the SAME fixture
#   table through BOTH and asserts identical verdicts (the non-vacuous anti-drift lock).
#   A genuine footer is a horizontal-rule line whose ONLY non-rule content is the "@name"
#   token — "──── @name ────" OR "@name ────────". The two alternatives require ≥1 box-dash
#   BEFORE @name, or ≥1 box-dash AFTER it; either way the WHOLE line is box-dashes/space
#   around @name and nothing else. This REJECTS a content line that merely mentions @name
#   (a roster line, a log line, or the #61 self-poke command "echo ──── @name ────" — all
#   have other text so neither anchor holds) AND a bare "@name" (no dash), and it
#   word-boundaries the name (@name2 ≠ @name). Keep byte-for-byte in sync with
#   agent-activity.sh's _footer_re.
PR_FOOTER_ERE() {
  printf '^[─[:space:]]*─[─[:space:]]*@%s[─[:space:]]*$|^[─[:space:]]*@%s[─[:space:]]*─[─[:space:]]*$' "$1" "$1"
}

# pr_footer_matches <sock> <addr> <agent> — 0 iff the pane's footer structurally names @agent.
# -S -5 limits the capture to the footer region.
pr_footer_matches() {
  local sock="$1" addr="$2" agent="$3" esc
  esc="$(pr__ere_escape "$agent")"
  tmux -S "$sock" capture-pane -p -t "$addr" -S -5 2>/dev/null \
    | grep -qE "$(PR_FOOTER_ERE "$esc")"
}

# pr_resolve_footer <agent> — first PR_PANES entry whose footer matches (exit 0), else 1.
pr_resolve_footer() {
  local agent="${1:-}" entry esock rest eaddr
  for entry in "${PR_PANES[@]:-}"; do
    [ -n "$entry" ] || continue
    esock="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"; eaddr="${rest%%$'\t'*}"
    if pr_footer_matches "$esock" "$eaddr" "$agent"; then
      printf '%s\t%s' "$esock" "$eaddr"; return 0
    fi
  done
  return 1
}

# pr__ere_escape — escape ERE metachars in an agent name (kebab names are safe, but a
# stray '.' or '+' must not become a wildcard). Internal helper.
pr__ere_escape() { printf '%s' "$1" | sed 's/[][(){}.*+?^$|\\]/\\&/g'; }
