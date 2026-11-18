#!/usr/bin/env bash
# dreamteam — PERTURBATIONS for the Flow callout (xreview #237 r1 item 6, r2 item 3): one mutation per rule of
# scripts/flow-callout.sh, applied to a COPY, with the suite run against that copy. Every mutation must turn at least
# one case red; the first red line of each is the evidence (pasted in the PR body). The real hook is never touched.
#
#   bash tests/perturb-flow-callout.sh          # exit 0 iff every mutation is red
#
# Not a test-*.sh: run.sh would run the whole suite once per mutation. Run it by hand before asking for a review.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/flow-callout.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# name|sed expression (applied once, must change the copy)
MUTATIONS=(
  'detail-read-as-silence|s/then "unreadable"/then "silent"/'
  'list-rows-unvalidated|s/all(\.rows\[\];/all([];/'
  'list-unvalidated|s/jq -e '"'"'type == "object" and (\.rows/jq -e '"'"'true or type == "object" and (.rows/'
  'outage-unlogged|s/note "plan unreachable or refused/true "plan unreachable or refused/'
  'budget-never-stops|s/\[ "\$(left)" -lt 200 \]/[ "$(left)" -lt -999999 ]/'
  'clock-starts-after-tmux|s/^left() {/T0=$(( $(date +%s%N) \/ 1000000 )); left() {/'
  'tmux-despite-identity|s/if \[ "\${#names\[@\]}" -eq 0 \] \&\& \[ -n "\${TMUX:-}" \]/if [ -n "${TMUX:-}" ]/'
  'tmux-outside-tmux|s/\[ -n "\${TMUX:-}" \] \&\& command -v tmux/command -v tmux/'
  'key-in-argv|s/printf '"'"'X-Ask-Key: %s\\n'"'"' "\$KEY" | curl -fsS -m "\$(secs "\$m")" -H @-/curl -fsS -m "$(secs "$m")" -H "X-Ask-Key: $KEY"/'
  'no-key-still-asks|s/^if \[ -z "\$KEY" \]; then$/if false; then/'
  'cap-skips-silently|s/then capped=\$((capped + 1)); continue; fi/then continue; fi/'
  'ordered-not-plainly-silent|s/if \[ "\$state" = "ordered" \]/if [ "$state" = "ordered-X" ]/'
  'lane-prefix-rule-dropped|s/startswith(\$x + ":")/startswith($x + "X:")/'
)

bad=0; n=0
for m in "${MUTATIONS[@]}"; do
  name="${m%%|*}"; expr="${m#*|}"; n=$((n + 1))
  cp "$HOOK" "$TMP/hook.sh"
  if ! sed -i -e "$expr" "$TMP/hook.sh" || cmp -s "$HOOK" "$TMP/hook.sh"; then
    echo "NOT APPLIED $name: the sed expression changed nothing (the hook moved under it)"; bad=$((bad + 1)); continue
  fi
  out="$(CLAUDE_PLUGIN_ROOT="$ROOT" FLOW_CALLOUT_HOOK="$TMP/hook.sh" bash "$ROOT/tests/test-flow-callout.sh" 2>&1)"
  reds="$(printf '%s\n' "$out" | grep -c '^FAIL:')"
  if [ "$reds" -gt 0 ]; then
    printf 'RED  %-28s %s red: %s\n' "$name" "$reds" "$(printf '%s\n' "$out" | grep -m1 '^FAIL:' | cut -c1-110)"
  else
    printf 'GREEN %-28s stayed green: the suite does not pin this rule\n' "$name"; bad=$((bad + 1))
  fi
done
echo "perturb-flow-callout: $n mutations, $bad not red"
[ "$bad" -eq 0 ]
