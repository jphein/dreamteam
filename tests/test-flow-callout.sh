#!/usr/bin/env bash
# dreamteam — regression tests for the FLOW CALLOUT (Stop hook).
#
#   • scripts/flow-callout.sh — Stop hook: a lane cannot end a turn while it holds an open Flow row it has not
#     spoken on since that row's last order (docs/MANAGEMENT.md practice 3, §5 item 1; Flow row 76b3ff47).
#
# THE RULE IT ENCODES. The Flow ledger (plan.realm.watch, FOR-AGENTS rule 27) holds one row per ordered item. A row
# is "silent" when it is open (ordered | in-progress | blocked | needs-jp) and its log has no event by this lane after
# its `ordered` event. A lead's checkpoint written on the lane's behalf counts when its note starts with "<lane>:"
# (the documented --who workaround, TOOLING-FRICTION 2026-11-17 18:58). The hook exits 2 naming each silent row and
# the verbs that end the silence; otherwise 0.
#
# SAFETY POSTURE — FAIL OPEN, with one logged line. No identity, the lead, stop_hook_active (the harness already
# continued once), the kill switch, no key, the plan server unreachable or answering nonsense: exit 0, and (for the
# outage cases) ONE line in the callout log saying why nothing was checked.
#
# ISOLATION: curl and tmux are PATH stubs that serve fixture files and record what the hook asked for. Identity
# through ASK_WHO / DREAMTEAM_AGENT_ID; the key through ASK_KEY; the log through DREAMTEAM_FLOW_LOG; the kill switch
# through DREAMTEAM_CONFIG. No network, no real ledger.
#
# Run standalone:  bash tests/test-flow-callout.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/flow-callout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$FIX" "$TMP/bin"
printf '%s\n' '{"flow":{"enforce":true}}'  > "$TMP/on.json"
printf '%s\n' '{"flow":{"enforce":false}}' > "$TMP/off.json"

# ── stubs ─────────────────────────────────────────────────────────────────────
# curl: the first http(s) argument is the URL; /api/flow?… → list.json, /api/flow/<id> → show-<id>.json. Every call
# is logged with its headers. $FIX/rc forces an exit code (7 = could not connect, 22 = HTTP error with -f).
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; hdrs=""
printf '%s\n' "$*" >> "$FIX/argv.log"     # what any process on the host can read from /proc/<pid>/cmdline
while [ $# -gt 0 ]; do
  case "$1" in
    -H) if [ "$2" = "@-" ]; then hdrs="$hdrs|$(tr '\n' '|' < /dev/stdin)"; else hdrs="$hdrs|$2"; fi; shift ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
printf '%s\t%s\n' "$url" "$hdrs" >> "$FIX/curl.log"
[ -f "$FIX/rc" ] && exit "$(cat "$FIX/rc")"
case "$url" in
  */api/flow\?*) cat "$FIX/list.json" ;;
  */api/flow/*)  id="${url##*/api/flow/}"; id="${id%%\?*}"; cat "$FIX/show-$id.json" 2>/dev/null || exit 22 ;;
  *) exit 22 ;;
esac
EOF
# tmux: the session name, so a lane with no ASK_WHO is still named
printf '#!/usr/bin/env bash\necho "%s"\n' "example-lane" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/curl" "$TMP/bin/tmux"

row() { # row <id> <lane> <state> <ordered_at> <last_checkpoint_at|null>
  printf '{"id":"%s","lane":"%s","what":"Example item %s","ordered_by":"sen","ordered_at":%s,"expected_by":%s,"state":"%s","state_at":%s,"last_checkpoint_at":%s,"last_line":"","parent":null,"updated_at":%s,"stuck":null}' \
    "$1" "$2" "$1" "$4" "$(( ${4%.*} + 14400 ))" "$3" "$4" "$5" "$4"
}
list() { printf '{"count":%d,"rows":[%s]}\n' "$#" "$(IFS=,; echo "$*")" > "$FIX/list.json"; }
show() { # show <id> <row-json> <log-json-array>
  printf '{%s,"log":%s}\n' "$(printf '%s' "$2" | sed 's/^{//; s/}$//')" "$3" > "$FIX/show-$1.json"
}
reset() { rm -f "$FIX"/*; printf '{"count":0,"rows":[]}\n' > "$FIX/list.json"; : > "$TMP/callout.log"; }

RC=0
# run [stdin-json] — the hook with the test seams; env overrides come before the call
run() {
  RC=0
  printf '%s' "${1:-{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false\}}" \
    | PATH="$TMP/bin:$PATH" FIX="$FIX" ASK_URL="http://plan.test" ASK_KEY="${ASK_KEY-k0000000000000000000000000000000000000000}" \
      ASK_WHO="${ASK_WHO-example-lane}" DREAMTEAM_AGENT_ID="${DREAMTEAM_AGENT_ID-}" DREAMTEAM_CONFIG="${CFG:-$TMP/on.json}" \
      TMUX="${TMUXV-/stub/tmux-socket,1,0}" \
      DREAMTEAM_FLOW_LOG="$TMP/callout.log" bash "$HOOK" >"$TMP/out" 2>"$TMP/err" || RC=$?
}
blocked() { [ "$RC" -eq 2 ] && grep -q 'FLOW CALLOUT' "$TMP/err"; }
allowed() { [ "$RC" -eq 0 ]; }
loglines() { wc -l < "$TMP/callout.log" | tr -d ' '; }
calls() { if [ -f "$FIX/curl.log" ]; then wc -l < "$FIX/curl.log" | tr -d ' '; else echo 0; fi; }

T0=1763430000   # an epoch in 2026-11

echo "── flow-callout.sh (Stop hook: say where your open rows stand) ──────────"

# 0) static
[ -f "$HOOK" ] && pass "hook script exists" || fail "hook script missing: $HOOK"
bash -n "$HOOK" 2>/dev/null && pass "hook parses" || fail "hook has a syntax error"
if command -v jq >/dev/null 2>&1; then
  jq -e '.hooks.Stop[]?.hooks[]? | select(.command | test("flow-callout.sh"))' "$ROOT/hooks/hooks.json" >/dev/null 2>&1 \
    && pass "hooks.json wires flow-callout.sh as a Stop hook" || fail "hooks.json has no Stop entry for flow-callout.sh"
  t=$(jq -r '[.hooks.Stop[]?.hooks[]? | select(.command | test("flow-callout.sh")) | .timeout] | first // 0' "$ROOT/hooks/hooks.json" 2>/dev/null)
  [ "${t:-0}" -ge 5 ] && [ "${t:-0}" -le 15 ] && pass "the Stop hook's timeout is in seconds (5–15)" || fail "Stop hook timeout $t (seconds, not ms)"
fi

# 1) POSITIVE CONTROL: an ordered row of mine with no word → blocked, the id and the verbs named
reset; A=$(row aaaa0001 example-lane ordered $T0 null); list "$A"
run
blocked && grep -q 'aaaa0001' "$TMP/err" && grep -q 'flow checkpoint aaaa0001' "$TMP/err" \
  && pass "ordered row, no word → blocked, names the id and the checkpoint verb" || fail "ordered row: rc=$RC $(cat "$TMP/err")"
grep -q 'mine=' "$FIX/curl.log" && grep -q 'open=1' "$FIX/curl.log" && pass "asks the ledger for MY open rows (mine=, open=1)" || fail "list query: $(cat "$FIX/curl.log")"
grep -q 'X-Ask-Key: k0000000000000000000000000000000000000000' "$FIX/curl.log" && pass "sends the ask key" || fail "no X-Ask-Key: $(cat "$FIX/curl.log")"
! grep -q 'k0000000000000000000000000000000000000000' "$FIX/argv.log" && pass "the key never rides in curl's argv (readable from /proc by any process of this uid)" || fail "key in argv: $(cat "$FIX/argv.log")"
grep -q 'X-Ask-Who: example-lane' "$FIX/curl.log" && pass "sends who it is" || fail "no X-Ask-Who: $(cat "$FIX/curl.log")"
[ "$(loglines)" -eq 0 ] && pass "a block writes no outage line" || fail "block logged: $(cat "$TMP/callout.log")"

# 2) in-progress with my own checkpoint after the order → allowed
reset; B=$(row bbbb0002 example-lane in-progress $T0 $((T0+600))); list "$B"
show bbbb0002 "$B" "[{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"},{\"ts\":$((T0+600)),\"who\":\"example-lane\",\"event\":\"checkpoint\",\"note\":\"started\"}]"
run; allowed && pass "my checkpoint after the order → allowed" || fail "my checkpoint: rc=$RC $(cat "$TMP/err")"

# 3) in-progress only because the LEAD wrote on it (no prefix) → still silent → blocked
reset; C=$(row cccc0003 example-lane in-progress $T0 $((T0+600))); list "$C"
show cccc0003 "$C" "[{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"},{\"ts\":$((T0+600)),\"who\":\"sen\",\"event\":\"checkpoint\",\"note\":\"assigned to example-lane\"}]"
run; blocked && grep -q cccc0003 "$TMP/err" && pass "the lead's own note is not the lane's word → blocked" || fail "lead note: rc=$RC $(cat "$TMP/err")"
# 3b) …but the lead's note with the lane's prefix IS the lane's word (the --who workaround) → allowed
show cccc0003 "$C" "[{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"},{\"ts\":$((T0+600)),\"who\":\"sen\",\"event\":\"checkpoint\",\"note\":\"example-lane: order read back\"}]"
run; allowed && pass "a lead note prefixed '<lane>:' counts as the lane's word → allowed" || fail "prefixed note: rc=$RC $(cat "$TMP/err")"
# 3c) my word BEFORE the order does not count (the order is the last one)
show cccc0003 "$C" "[{\"ts\":$((T0-600)),\"who\":\"example-lane\",\"event\":\"checkpoint\",\"note\":\"old\"},{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"}]"
run; blocked && pass "a word before the order is not a word since it → blocked" || fail "pre-order word: rc=$RC"
# 3d) a block or a needs-jp by me is a word too
show cccc0003 "$C" "[{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"},{\"ts\":$((T0+60)),\"who\":\"example-lane\",\"event\":\"blocked\",\"note\":\"waiting on x\"}]"
run; allowed && pass "my block is a word → allowed" || fail "my block: rc=$RC"
# 3e) my session suffix counts as me (example-lane-8f ↔ example-lane)
show cccc0003 "$C" "[{\"ts\":$T0,\"who\":\"sen\",\"event\":\"ordered\",\"note\":\"Example\"},{\"ts\":$((T0+60)),\"who\":\"example-lane-8f\",\"event\":\"checkpoint\",\"note\":\"moving\"}]"
run; allowed && pass "another session of my lane spoke → allowed" || fail "lane family: rc=$RC"

# 4) two silent rows → both named; a done row in the answer is ignored
reset; D1=$(row dddd0004 example-lane ordered $T0 null); D2=$(row dddd0005 example-lane ordered $T0 null); D3=$(row dddd0006 example-lane done $T0 $((T0+9)))
list "$D1" "$D2" "$D3"; run
blocked && grep -q dddd0004 "$TMP/err" && grep -q dddd0005 "$TMP/err" && ! grep -q dddd0006 "$TMP/err" \
  && pass "every silent row is named; a closed row is not" || fail "two rows: rc=$RC $(cat "$TMP/err")"

# 5) nothing open → allowed, no log line, exactly one request
reset; run; allowed && [ "$(loglines)" -eq 0 ] && [ "$(calls)" -eq 1 ] && pass "no open rows → allowed with one request" || fail "empty: rc=$RC calls=$(calls)"

# 6) FAIL OPEN with ONE logged line: the server unreachable
reset; echo 7 > "$FIX/rc"; run
allowed && [ "$(loglines)" -eq 1 ] && grep -qi 'unreach\|could not\|no answer\|outage' "$TMP/callout.log" \
  && pass "plan unreachable → allowed, one logged line" || fail "outage: rc=$RC log=[$(cat "$TMP/callout.log")]"
# 6b) an HTTP error (401 with -f → 22)
reset; echo 22 > "$FIX/rc"; run
allowed && [ "$(loglines)" -eq 1 ] && pass "an HTTP error → allowed, one logged line" || fail "http error: rc=$RC log=[$(cat "$TMP/callout.log")]"
# 6c) nonsense instead of JSON
reset; echo "<html>sorry</html>" > "$FIX/list.json"; run
allowed && [ "$(loglines)" -eq 1 ] && pass "a non-JSON answer → allowed, one logged line" || fail "non-json: rc=$RC log=[$(cat "$TMP/callout.log")]"
# 6d) the show call fails for one row → that row is treated as unchecked (allowed), logged once; a silent ordered row still blocks
reset; E1=$(row eeee0007 example-lane in-progress $T0 $((T0+5))); list "$E1"; run
allowed && [ "$(loglines)" -eq 1 ] && pass "an unreadable row log → that row unchecked, one logged line" || fail "show fail: rc=$RC log=[$(cat "$TMP/callout.log")]"
reset; list "$E1" "$(row eeee0008 example-lane ordered $T0 null)"; run
blocked && grep -q eeee0008 "$TMP/err" && pass "…while a plainly silent row still blocks" || fail "mixed: rc=$RC"

# 7) no key → allowed, one logged line, no request
reset; ASK_KEY="" run; allowed && [ "$(loglines)" -eq 1 ] && [ "$(calls)" -eq 0 ] && pass "no ask key → allowed, logged, nothing asked" || fail "no key: rc=$RC calls=$(calls) log=[$(cat "$TMP/callout.log")]"

# 8) stop_hook_active → allowed without a request (the harness already continued once; never loop)
reset; list "$(row ffff0009 example-lane ordered $T0 null)"
run '{"hook_event_name":"Stop","stop_hook_active":true}'
allowed && [ "$(calls)" -eq 0 ] && pass "stop_hook_active → allowed, nothing asked" || fail "stop_hook_active: rc=$RC calls=$(calls)"

# 9) kill switch
reset; list "$(row ffff0010 example-lane ordered $T0 null)"; CFG="$TMP/off.json" run
allowed && [ "$(calls)" -eq 0 ] && pass "flow.enforce=false → allowed, nothing asked" || fail "kill switch: rc=$RC"
# 9b) a missing config still ENFORCES
reset; list "$(row ffff0011 example-lane ordered $T0 null)"; CFG="$TMP/none.json" run
blocked && pass "a missing config file still enforces" || fail "missing config: rc=$RC"

# 10) the lead is never blocked
reset; list "$(row ffff0012 sen ordered $T0 null)"; ASK_WHO=sen run
allowed && [ "$(calls)" -eq 0 ] && pass "the lead (sen) → allowed, nothing asked" || fail "lead: rc=$RC"

# 11) identity: no ASK_WHO → the tmux session names the lane; a teammate id adds its name; none at all → allowed
reset; list "$(row ffff0013 example-lane ordered $T0 null)"; ASK_WHO="" run
blocked && grep -q 'mine=example-lane' "$FIX/curl.log" && pass "no ASK_WHO → the tmux session is the lane" || fail "tmux name: rc=$RC $(cat "$FIX/curl.log")"
reset; list "$(row ffff0014 example-lane ordered $T0 null)"; ASK_WHO="" DREAMTEAM_AGENT_ID="morpheus-x@team" run
grep -q 'mine=.*morpheus-x' "$FIX/curl.log" && pass "a teammate id adds its name to mine=" || fail "agent id: $(cat "$FIX/curl.log")"
# (the tmux stub answers nothing here, as tmux does outside any server; a real tmux on PATH must not leak the
#  runner's own session name into this case, so the stub stays first on PATH and fails)
reset; printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/tmux"; list "$(row ffff0015 example-lane ordered $T0 null)"; ASK_WHO="" run
printf '#!/usr/bin/env bash\necho "%s"\n' "example-lane" > "$TMP/bin/tmux"
allowed && [ "$(calls)" -eq 0 ] && pass "no identity at all → allowed, nothing asked" || fail "no identity: rc=$RC calls=$(calls)"
# 11b) OUTSIDE tmux ($TMUX unset) the tmux name is never consulted: `tmux display-message` then answers with the
#      host's most recent session, which is somebody else's lane (measured on familiar 2026-11-17 20:09: "spire")
reset; list "$(row ffff0017 example-lane ordered $T0 null)"; ASK_WHO="" TMUXV="" run
allowed && [ "$(calls)" -eq 0 ] && pass "outside tmux the session name is not used → no identity → allowed" || fail "outside tmux: rc=$RC calls=$(calls) $(cat "$FIX/curl.log" 2>/dev/null)"

# 12) malformed stdin → allowed
reset; run 'not json'; allowed && pass "malformed stdin → allowed" || fail "malformed: rc=$RC"

# 13) the block message says what to do, in the ledger's own verbs
reset; list "$(row ffff0016 example-lane ordered $T0 null)"; run
grep -q 'flow checkpoint ffff0016' "$TMP/err" && grep -q 'flow block ffff0016' "$TMP/err" && grep -q 'flow done ffff0016 --evidence' "$TMP/err" \
  && pass "the block names checkpoint, block and done --evidence" || fail "verbs: $(cat "$TMP/err")"

echo ""
echo "flow-callout: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
