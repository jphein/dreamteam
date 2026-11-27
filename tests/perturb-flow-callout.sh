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
  'list-unvalidated|s/jq -se '"'"'length == 1 and (\.\[0\] | type == "object"/jq -se '"'"'true or length == 1 and (.[0] | type == "object"/'
  'list-stream-accepted|s/jq -se '"'"'length == 1 and (\.\[0\] | type == "object"/jq -se '"'"'length >= 1 and (.[0] | type == "object"/'
  'detail-stream-accepted|s/if length != 1 or (\.\[0\] | type) != "object"/if length < 1 or (.[0] | type) != "object"/'
  'tmux-read-unbounded|s/if IFS= read -r -t "\$(rem)" -u "\$tfd" tname; then/if IFS= read -r -u "$tfd" tname; then/'
  'tmux-no-cleanup|s/^      reap_tree "\$tpid" "\$tpst" "\$tgot" || true$/      :/'
  'tmux-no-kill-after-grace|s/^    sig KILL$/    :/'
  'tmux-cleanup-unreported|s/^  note "tmux fallback overran its bound: \$n process(es) of its pid tree (root \$root) signalled (\$sent); none left"$/  :/'
  'tmux-gone-unreported|s/if \[ -z "\$CUR" \]; then note "tmux fallback: nothing left of its process tree (pid \$root): nothing signalled"; return 0; fi/if [ -z "$CUR" ]; then return 0; fi/'
  'tmux-clean-exit-is-signalled|s/nothing signalled"; return 0; fi$/nothing signalled"; fi/'
  'reap-failure-exits-0|s/if \[ "\$rc" -eq 0 \] \&\& \[ "\$REAPFAIL" = 1 \]; then/if false; then/'
  'still-alive-is-no-failure|s/if \[ -n "\$CUR" \]; then REAPFAIL=1; note "tmux fallback overran/if [ -n "$CUR" ]; then note "tmux fallback overran/'
  'unread-table-is-no-failure|s/unread() { REAPFAIL=1; note/unread() { note/'
  'unread-table-reads-as-empty|s/^  \[ -n "\${PS\[\$\$\]:-}" \]$/  true/'
  'kill-set-by-printed-session-id|s/^      reap_tree "\$tpid" "\$tpst" "\$tgot" || true$/      reap_tree "${tsid:-$tpid}" "$(start_of "${tsid:-$tpid}")" "$tgot" || true/'
  'member-identity-unchecked|s/\[ "\$(start_of "\$q")" = "\${K\[\$q\]}" \] \&\& kill/kill/'
  'descendants-not-in-the-tree|s/if \[ -z "\${K\[\$q\]:-}" \] \&\& \[ -n "\${K\[\${PP\[\$q\]}\]:-}" \]; then/if false; then/'
  'grace-has-a-floor|s/\[ "\$g" -gt 1000 \] \&\& g=1000; \[ "\$g" -lt 0 \] \&\& g=0/[ "$g" -gt 1000 ] \&\& g=1000; [ "$g" -lt 100 ] \&\& g=100/'
  'wait-ignores-a-spent-budget|s/^    local dl r l; l=\$(left); r=\$1; \[ "\$l" -lt "\$r" \] \&\& r=\$l; dl=/    local dl r l; r=$1; dl=/;s/^      r=\$(( dl - \$(now_ms) )); l=\$(left); \[ "\$l" -lt "\$r" \] \&\& r=\$l$/      r=$(( dl - $(now_ms) ))/'
  'tmux-partial-line-is-a-name|s/if IFS= read -r -t "\$(rem)" -u "\$tfd" tname; then add "\$tname"; tgot=1; fi/IFS= read -r -t "$(rem)" -u "$tfd" tname; add "$tname"/'
  'row-cap-removed|s/(\$all\[:\$max\]\[\]/($all[:999999][]/'
  'row-cap-unlogged|s/rowcapped=\$(( TOTAL - MAX_ROWS ))/rowcapped=0/'
  'owner-filter-dropped|s/| map(select((\.lane | type) == "string" and/| map(select(true or (.lane | type) == "string" and/'
  'log-shape-unchecked|s/(\.ts | type) == "number" and (\.who | type) == "string"/true and (.who | type) != "never"/'
  'key-path-type-unchecked|s/if \[ -f "\$KF" \] \&\& \[ ! -L "\$KF" \]; then/if true; then/'
  'log-append-unguarded|s/if \[ ! -e "\$LOG" \] || { \[ -f "\$LOG" \]/if true || { [ -f "$LOG" ]/'
  'outage-unlogged|s/note "plan unreachable or refused/true "plan unreachable or refused/'
  'budget-never-stops|s/\[ "\$(left)" -lt 200 \]/[ "$(left)" -lt -999999 ]/'
  'clock-starts-after-tmux|s/^KEY="\${ASK_KEY:-}"$/T0=$(( $(date +%s%N) \/ 1000000 )); KEY="${ASK_KEY:-}"/'
  'tmux-despite-identity|s/if \[ "\${#names\[@\]}" -eq 0 \] \&\& \[ -n "\${TMUX:-}" \]/if [ -n "${TMUX:-}" ]/'
  'tmux-outside-tmux|s/\[ -n "\${TMUX:-}" \] \&\& command -v tmux/command -v tmux/'
  'key-in-argv|s/printf '"'"'X-Ask-Key: %s\\n'"'"' "\$KEY" | curl -fsS -m "\$(secs "\$m")" --max-filesize 1048576 -H @-/curl -fsS -m "$(secs "$m")" --max-filesize 1048576 -H "X-Ask-Key: $KEY"/'
  'no-key-still-asks|s/^if \[ -z "\$KEY" \]; then$/if false; then/'
  'cap-skips-silently|s/then capped=\$((capped + 1)); continue; fi/then continue; fi/'
  'ordered-not-plainly-silent|s/if \[ "\$state" = "ordered" \]/if [ "$state" = "ordered-X" ]/'
  'lane-prefix-rule-dropped|s/startswith(\$x + ":")/startswith($x + "X:")/'
  'key-read-untimed|s/KEY="\$(timeout -k 1 "\$(readcap)" head -c 200/KEY="$(head -c 200/'
  'config-type-unchecked|s/if \[ ! -f "\$CFG" \] || \[ -L "\$CFG" \]; then/if false; then/'
  'config-read-untimed|s/CFGTXT=\$(timeout -k 1 "\$(readcap)" head -c 1048576/CFGTXT=$(head -c 1048576/'
  'read-timeout-ignores-budget|s/^readcap() { local l; l=\$(left); \[ "\$l" -gt 1000 \] \&\& l=1000;/readcap() { local l; l=1000;/'
)

# one mutation per job, JOBS at a time (the suite carries deliberate sleeps: serial runs took over 40 minutes for 22
# mutations on 2026-11-17); each job has its own copy of the hook and its own result file, printed in order at the end
JOBS="${PERTURB_JOBS:-4}"
one() { # one <index> <name|expr>
  local i="$1" name="${2%%|*}" expr="${2#*|}" d="$TMP/m$1" out reds
  mkdir -p "$d"; cp "$HOOK" "$d/hook.sh"
  if ! sed -i -e "$expr" "$d/hook.sh" || cmp -s "$HOOK" "$d/hook.sh"; then
    echo "NOT APPLIED $name: the sed expression changed nothing (the hook moved under it)" > "$d/result"; return
  fi
  # a mutation that drops a hang guard makes the SUITE hang (a FIFO case waits forever): that is the mutation caught,
  # so a run past 10 minutes is red as "hung" (2026-11-18: the first unbounded run sat 10 hours with nothing written)
  out="$(CLAUDE_PLUGIN_ROOT="$ROOT" FLOW_CALLOUT_HOOK="$d/hook.sh" timeout -k 5 600 bash "$ROOT/tests/test-flow-callout.sh" 2>&1)"; rc=$?
  reds="$(printf '%s\n' "$out" | grep -c '^FAIL:')"
  if [ "$rc" = 124 ]; then
    printf 'RED  %-28s hung: the suite did not finish in 10 min (a dropped hang guard)\n' "$name" > "$d/result"; return
  fi
  if [ "$reds" -gt 0 ]; then
    printf 'RED  %-28s %s red: %s\n' "$name" "$reds" "$(printf '%s\n' "$out" | grep -m1 '^FAIL:' | cut -c1-110)" > "$d/result"
  else
    printf 'GREEN %-28s stayed green: the suite does not pin this rule\n' "$name" > "$d/result"
  fi
}
n=0; running=0
for m in "${MUTATIONS[@]}"; do
  n=$((n + 1)); one "$n" "$m" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait
bad=0
for i in $(seq 1 "$n"); do
  r="$(cat "$TMP/m$i/result" 2>/dev/null || echo "NO RESULT for mutation $i")"
  echo "$r"; case "$r" in RED*) ;; *) bad=$((bad + 1)) ;; esac
done
echo "perturb-flow-callout: $n mutations, $bad not red"
[ "$bad" -eq 0 ]
