#!/usr/bin/env bash
# dreamteam tests — palace-file.sh (resilient writer) + the compact-guard and
# cleanup-marker card integrations (#10).
#
# Hermetic:
#   • curl is PATH-stubbed — records every invocation's argv + POST body, and
#     fails (exit 7) whenever $TMP/curl-fail exists (switchable daemon outage).
#   • systemctl is PATH-stubbed to report the scope INACTIVE, so cleanup-marker's
#     real scope-teardown branch short-circuits and never touches the live
#     dreamteam-agents.scope this session is running inside.
#   • the daemon env is a $TMP fixture selected via PALACE_ENV_FILE.
#   • DREAMTEAM_STATE is a $TMP dir → the queue lands in $TMP.
#   • DREAMTEAM_TEST is explicitly UNSET (env -u) so the REAL logic runs; a
#     dedicated case proves the DREAMTEAM_TEST kill-switch no-ops.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PF="$ROOT/scripts/palace-file.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$TMP/bin" "$TMP/state"
QUEUE="$TMP/state/palace-queue.jsonl"

# curl stub: log argv (one line per call, prefixed CURL) + each --data-binary body.
cat > "$TMP/bin/curl" <<EOF
#!/bin/bash
{ printf 'CURL'; for a in "\$@"; do printf ' %s' "\$a"; done; printf '\n'; } >> "$TMP/curl.args"
prev=""; for a in "\$@"; do [ "\$prev" = "--data-binary" ] && printf '%s\n' "\$a" >> "$TMP/curl.bodies"; prev="\$a"; done
[ -f "$TMP/curl-fail" ] && exit 7 || exit 0
EOF
# systemctl stub: scope always INACTIVE → cleanup-marker teardown short-circuits.
printf '#!/bin/bash\ncase "$*" in *is-active*) exit 3;; *) exit 0;; esac\n' > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/curl" "$TMP/bin/systemctl"

# fake daemon env (fixture creds; the stubbed curl never leaves the box)
cat > "$TMP/env" <<'EOF'
PALACE_API_KEY=TESTKEY123
PALACE_DAEMON_URL=http://palace.test:9999
EOF

runpf() { env -u DREAMTEAM_TEST PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$TMP/state" \
  PALACE_ENV_FILE="$TMP/env" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PF" "$@"; }
# run any owned script under the same hermetic env (integrations)
runscript() { local s="$1"; shift; env -u DREAMTEAM_TEST PATH="$TMP/bin:$PATH" \
  DREAMTEAM_STATE="$TMP/state" PALACE_ENV_FILE="$TMP/env" DREAMTEAM_TEAMS_DIR="$TMP/noteams" \
  CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/$s" "$@"; }
reset() { : > "$TMP/curl.args"; : > "$TMP/curl.bodies"; rm -f "$TMP/curl-fail" "$QUEUE"; }
# grep -c already prints "0" and exits 1 on no match; the old `|| echo 0` appended
# a SECOND "0" → a "0\n0" that broke `-eq` (the postmortem's line-21 bug class).
# Let grep own the count; `|| true` only swallows the exit status.
nposts() { grep -c '^CURL' "$TMP/curl.args" 2>/dev/null || true; }

bash -n "$PF" && ok "bash -n palace-file.sh" || bad "bash -n palace-file.sh"
for s in compact-guard incident-report cleanup-marker; do
  bash -n "$ROOT/scripts/$s.sh" && ok "bash -n $s.sh" || bad "bash -n $s.sh"
done

# ── 1. Happy path: exit 0, silent, correct POST shape ───────────────────────
reset
OUT="$(runpf --topic dreamteam "hello palace")"; RC=$?
[ "$RC" -eq 0 ] && ok "happy: exits 0" || bad "happy: exit $RC"
[ -z "$OUT" ] && ok "happy: no stdout (hook-safe)" || bad "happy: stdout leaked ($OUT)"
grep -q 'silent-save' "$TMP/curl.args" && ok "happy: POSTs to /silent-save" || bad "happy: URL ($(cat "$TMP/curl.args"))"
grep -q 'X-API-Key: TESTKEY123' "$TMP/curl.args" && ok "happy: sends X-API-Key header" || bad "happy: API key header"
grep -q 'Content-Type: application/json' "$TMP/curl.args" && ok "happy: sends JSON content-type" || bad "happy: content-type"
grep -q -- '-X POST' "$TMP/curl.args" && ok "happy: uses POST" || bad "happy: not POST"
B="$(cat "$TMP/curl.bodies")"
printf '%s' "$B" | jq -e '.entry=="hello palace" and .wing=="dreamteam" and .topic=="dreamteam" and .agent_name=="Sandman"' >/dev/null 2>&1 \
  && ok "happy: body {entry,wing:dreamteam,topic:dreamteam,agent_name:Sandman}" || bad "happy: body shape ($B)"
[ ! -s "$QUEUE" ] && ok "happy: nothing queued on success" || bad "happy: queue not empty"

# ── 2. Entry on stdin + custom --topic ──────────────────────────────────────
reset
printf 'from stdin' | runpf --topic incident >/dev/null
B="$(cat "$TMP/curl.bodies")"
printf '%s' "$B" | jq -e '.entry=="from stdin" and .topic=="incident" and .wing=="dreamteam"' >/dev/null 2>&1 \
  && ok "stdin entry + --topic honored" || bad "stdin/topic ($B)"

# ── 3. Empty entry → no-op ───────────────────────────────────────────────────
reset
printf '' | runpf --topic dreamteam >/dev/null; RC=$?
{ [ "$RC" -eq 0 ] && [ ! -s "$TMP/curl.args" ] && [ ! -s "$QUEUE" ]; } && ok "empty entry → no-op exit 0" || bad "empty entry not a no-op (rc=$RC)"

# ── 4. Failure → queued, exit 0 ─────────────────────────────────────────────
reset; touch "$TMP/curl-fail"
OUT="$(runpf --topic dreamteam "will fail")"; RC=$?
[ "$RC" -eq 0 ] && ok "fail: still exits 0" || bad "fail: exit $RC"
[ -z "$OUT" ] && ok "fail: no stdout" || bad "fail: stdout leaked ($OUT)"
{ [ -s "$QUEUE" ] && [ "$(wc -l < "$QUEUE")" -eq 1 ]; } && ok "fail: exactly one card queued" || bad "fail: queue lines=$(wc -l < "$QUEUE" 2>/dev/null)"
grep -q '"entry":"will fail"' "$QUEUE" && ok "fail: queued line is the card body" || bad "fail: queued content ($(cat "$QUEUE"))"

# ── 5. Success drains the queue (resilience: nothing lost) ──────────────────
reset
printf '%s\n' '{"entry":"q1","wing":"dreamteam","agent_name":"Sandman","topic":"dreamteam"}' >> "$QUEUE"
printf '%s\n' '{"entry":"q2","wing":"dreamteam","agent_name":"Sandman","topic":"dreamteam"}' >> "$QUEUE"
runpf --topic dreamteam "fresh card" >/dev/null
[ "$(nposts)" -eq 3 ] && ok "drain: fresh + 2 queued = 3 POSTs" || bad "drain: expected 3 POSTs, got $(nposts)"
{ grep -q '"entry":"q1"' "$TMP/curl.bodies" && grep -q '"entry":"q2"' "$TMP/curl.bodies"; } && ok "drain: both queued cards re-sent" || bad "drain: queued not re-sent"
[ ! -s "$QUEUE" ] && ok "drain: queue emptied after successful drain" || bad "drain: queue not emptied ($(cat "$QUEUE"))"

# ── 6. Failure with a non-empty queue: append new, keep old (no data loss) ──
reset; touch "$TMP/curl-fail"
printf '%s\n' '{"entry":"old","wing":"dreamteam","agent_name":"Sandman","topic":"dreamteam"}' >> "$QUEUE"
runpf --topic dreamteam "new fail" >/dev/null
{ grep -q '"entry":"old"' "$QUEUE" && grep -q '"entry":"new fail"' "$QUEUE"; } && ok "fail+queue: preserves old, appends new" || bad "fail+queue: ($(cat "$QUEUE"))"

# ── 7. Missing env → total no-op ────────────────────────────────────────────
reset
env -u DREAMTEAM_TEST PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$TMP/state" \
  PALACE_ENV_FILE="$TMP/NOPE" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PF" --topic dreamteam "nope"; RC=$?
{ [ "$RC" -eq 0 ] && [ ! -s "$TMP/curl.args" ] && [ ! -s "$QUEUE" ]; } && ok "missing env → total no-op (no curl, no queue, exit 0)" || bad "missing env not a no-op (rc=$RC)"

# ── 8. DREAMTEAM_TEST kill-switch → total no-op even with a valid env ───────
reset
env DREAMTEAM_TEST=1 PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$TMP/state" \
  PALACE_ENV_FILE="$TMP/env" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$PF" --topic dreamteam "suppressed"; RC=$?
{ [ "$RC" -eq 0 ] && [ ! -s "$TMP/curl.args" ] && [ ! -s "$QUEUE" ]; } && ok "DREAMTEAM_TEST kill-switch → total no-op" || bad "DREAMTEAM_TEST not honored (rc=$RC, curl=$(cat "$TMP/curl.args"))"

# ── 9. compact-guard PreCompact files exactly one index card ────────────────
reset
echo '{"hook_event_name":"PreCompact","trigger":"auto","cwd":"'"$ROOT"'"}' | runscript compact-guard.sh >/dev/null
[ "$(nposts)" -eq 1 ] && ok "compact-guard PreCompact files exactly one card" || bad "compact-guard cards=$(nposts)"
{ grep -qi 'compaction checkpoint' "$TMP/curl.bodies" && grep -q '"agent_name":"Sandman"' "$TMP/curl.bodies"; } && ok "compact-guard card is a Sandman compaction checkpoint" || bad "compact-guard card ($(cat "$TMP/curl.bodies"))"
# PostCompact must NOT file a card (re-arm only)
reset
echo '{"hook_event_name":"PostCompact"}' | runscript compact-guard.sh >/dev/null
[ "$(nposts)" -eq 0 ] && ok "compact-guard PostCompact files no card (re-arm only)" || bad "PostCompact carded ($(nposts))"

# ── 10. cleanup-marker: one card iff a team ran (marker present) ────────────
reset
printf '{"team":"session-spawned","repo":"/tmp/x","started":"2026-07-02T00:00:00"}\n' > "$TMP/state/active"
runscript cleanup-marker.sh >/dev/null 2>&1
[ "$(nposts)" -eq 1 ] && ok "cleanup-marker files exactly one clean-shutdown card" || bad "cleanup-marker cards=$(nposts)"
grep -qi 'clean shutdown' "$TMP/curl.bodies" && ok "cleanup-marker card says 'clean shutdown'" || bad "cleanup card ($(cat "$TMP/curl.bodies"))"
[ ! -f "$TMP/state/active" ] && ok "cleanup-marker clears the marker after filing" || bad "marker not cleared"
# no marker → no team ran → no card
reset
runscript cleanup-marker.sh >/dev/null 2>&1
[ "$(nposts)" -eq 0 ] && ok "cleanup-marker files NO card when no team ran" || bad "cleanup-marker carded with no marker ($(nposts))"

# ── 11. incident-report --save files one card and still prints the report ───
reset
OUT="$(runscript incident-report.sh --save 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "incident --save exits 0" || bad "incident --save exit $RC"
case "$OUT" in *"# dreamteam incident report"*) ok "incident --save still prints the report to stdout";; *) bad "incident --save lost the report";; esac
[ "$(nposts)" -eq 1 ] && ok "incident --save files exactly one card" || bad "incident --save cards=$(nposts)"
# without --save: no card (proves the flag gates it)
reset
runscript incident-report.sh >/dev/null 2>&1
[ "$(nposts)" -eq 0 ] && ok "incident WITHOUT --save files no card" || bad "incident carded without --save ($(nposts))"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
