#!/usr/bin/env bash
# dreamteam — probe: does a REAL session get the lane style by its role, keep it over a restart, and does the lead
# stay without it? (by hand, NOT under tests/run.sh: it starts real Claude Code sessions.)
#
#   tests/probe-lane-restart.sh
#
# Each session is asked for text that is in output-styles/lane.md and NOT in the question, so a guess cannot
# pass: "print the first bullet under the heading 'What the limit yields to', or NOSECTION".
# The sessions run in panes of a THROWAWAY tmux server (its own socket), so the role comes from where it comes
# from in production: the pane's tmux session name. No seam is used.
#   1. session `fx-lane`, a new conversation                      → the bullet
#   2. the same pane, the conversation continued (`--continue`):  → the bullet again (a restart keeps the style)
#   3. session `spire` (the lead's name), a new conversation      → NOSECTION
#   4. a session outside tmux                                     → NOSECTION
# The plugin tree is this checkout (--plugin-dir). Prints one line per case and PROBE OK or PROBE FAILED.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v claude >/dev/null && command -v tmux >/dev/null || { echo "needs claude and tmux" >&2; exit 2; }
T="$(mktemp -d)"; S="$T/sock"; trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
WANT="$(awk '/^## What the limit yields to/ {on=1; next} on && /^- / {print; exit}' "$ROOT/output-styles/lane.md")"
[ -n "$WANT" ] || { echo "the style file has no such section" >&2; exit 2; }
Q='Do not use any tool. One line, nothing else: if your instructions contain a section headed "What the limit yields to", print its first bullet verbatim; otherwise print NOSECTION.'
printf '%s' "$Q" > "$T/q"
mkdir -p "$T/lane" "$T/lead" "$T/bare"
ask() {  # ask <tmux session> <dir> <out file> [extra claude args]: run one claude -p in a pane of that session
  local s=$1 d=$2 o=$3; shift 3
  tmux -S "$S" has-session -t "=$s" 2>/dev/null || env -u TMUX tmux -S "$S" new-session -d -s "$s" -x 200 -y 50 -c "$d" "bash --norc --noprofile"
  sleep 0.5; rm -f "$o.done"
  tmux -S "$S" send-keys -t "=$s:" -l "cd $d && claude --plugin-dir $ROOT $* -p \"\$(cat $T/q)\" > $o 2>/dev/null; touch $o.done"
  tmux -S "$S" send-keys -t "=$s:" Enter
  for _ in $(seq 1 150); do [ -e "$o.done" ] && return 0; sleep 1; done
  return 1
}
rc=0
judge() {  # judge <label> <file> <want: bullet|none>
  local got; got=$(grep -v '^SessionEnd hook' "$2" 2>/dev/null | head -1)
  # a session may quote the bullet with or without its dash, or the sentence that opens the section: any of the
  # section's own text counts, and none of it is in the question
  if [ "$3" = bullet ] && { grep -qF "${WANT#- }" <<<"$got" || grep -qF "None of it is ever cut to fit" <<<"$got"; }; then echo "ok    $1: the style's own text quoted back (${got:0:60}…)"
  elif [ "$3" = none ] && [ "$got" = NOSECTION ]; then echo "ok    $1: NOSECTION"
  else echo "FAIL  $1: wanted $3, got: ${got:0:120}"; rc=1; fi
}
ask fx-lane "$T/lane" "$T/1.out" || echo "(case 1 timed out)"
judge "1 a lane (tmux session fx-lane), new conversation" "$T/1.out" bullet
ask fx-lane "$T/lane" "$T/2.out" --continue || echo "(case 2 timed out)"
judge "2 the same lane restarted, conversation continued" "$T/2.out" bullet
ask spire "$T/lead" "$T/3.out" || echo "(case 3 timed out)"
judge "3 the lead (tmux session spire), new conversation" "$T/3.out" none
( cd "$T/bare" && env -u TMUX -u TMUX_PANE timeout 150 claude --plugin-dir "$ROOT" -p "$Q" > "$T/4.out" 2>/dev/null )
judge "4 a session outside tmux" "$T/4.out" none
[ "$rc" -eq 0 ] && echo "PROBE OK ($(claude --version | head -1), $(date '+%F %T'))" || echo "PROBE FAILED"
exit "$rc"
