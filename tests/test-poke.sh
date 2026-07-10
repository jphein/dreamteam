#!/usr/bin/env bash
# dreamteam tests — poke.sh (#28 submit-verification, #35 fresh pane attribution).
# Hermetic: pane-peek stubbed via DREAMTEAM_PANE_PEEK; tmux stubbed on PATH with a
# scripted pane whose input line clears only after `threshold` Enters — so we can
# drive submits-on-Nth-Enter, never-submits, and queued-acceptance deterministically.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POKE="$ROOT/scripts/poke.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$POKE" && ok "bash -n poke.sh" || bad "bash -n"

# poke MUTATES (send-keys) by design, but must NEVER kill a pane/session/server.
if grep -vE '^[[:space:]]*#' "$POKE" | grep -qE 'kill-pane|kill-session|kill-server|kill-window'; then
  bad "poke.sh contains a kill verb — poke nudges, never kills"
else
  ok "no kill verb in poke.sh (nudge-only)"
fi

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/tmux"
: > "$TMP/tmux/default"
S="$TMP/state"
export POKE_TEST_STATE="$S" POKE_TEST_SOCK="$TMP/tmux/default"

# ── pane-peek stub: JSON resolver; logs args (to assert @-strip); mode-switchable ─
cat > "$TMP/bin/peek-stub.sh" <<EOF
#!/bin/bash
echo "PEEKARGS: \$*" >> "$S/peek.log"
case "\$(cat "$S/peekmode" 2>/dev/null || echo found)" in
  found)    printf '{"found":true,"socket":"%s","pane":"sess:9.9","resolved_via":"pid"}\n' "$POKE_TEST_SOCK";;
  notfound) printf '{"found":false,"socket":null,"pane":null,"reason":"agent is dead"}\n';;
esac
EOF
chmod +x "$TMP/bin/peek-stub.sh"

# ── tmux stub: parses the (socket-prefixed) command; scripts pane states ─────────
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
S="$POKE_TEST_STATE"; sub=""; t=""; enter=0; lit=0
while [ $# -gt 0 ]; do
  if [ -z "$sub" ]; then
    case "$1" in
      -S) shift;;                                   # global socket path — consume
      send-keys|capture-pane|list-panes) sub="$1";;
    esac
  else
    case "$1" in
      -t) t="$2"; shift;;
      -l) lit=1;;
      Enter) enter=1;;
    esac
  fi
  shift
done
ag="${POKE_TEST_AGENT:-foo}"; m="${POKE_TEST_MSG:-hi}"
case "$sub" in
  send-keys)
    if [ "$enter" = 1 ]; then
      n=$(cat "$S/enters" 2>/dev/null || echo 0); echo $((n+1)) > "$S/enters"
      echo "ENTER $t" >> "$S/keys.log"
    elif [ "$lit" = 1 ]; then echo "LIT $t" >> "$S/keys.log"; fi
    ;;
  capture-pane)
    enters=$(cat "$S/enters" 2>/dev/null || echo 0)
    thr=$(cat "$S/threshold" 2>/dev/null || echo 1)
    mode=$(cat "$S/mode" 2>/dev/null || echo normal)
    if [ "$mode" = queued ]; then
      printf '  ...transcript...\n──── @%s ──\n❯ %s\n  ↑ press up to edit queued message\n────\n  Opus 4.8 · max\n' "$ag" "$m"
    elif [ "$enters" -ge "$thr" ]; then
      printf '  ...transcript...\n──── @%s ──\n❯ \n────\n  Opus 4.8 · max\n' "$ag"
    else
      printf '  ...transcript...\n──── @%s ──\n❯ %s\n────\n  Opus 4.8 · max\n' "$ag" "$m"
    fi
    ;;
  list-panes) printf 'sess:9.9\n';;
esac
EOF
chmod +x "$TMP/bin/tmux"

# reset per-scenario state
reset() { rm -f "$S/enters" "$S/keys.log" "$S/peek.log"; echo "$1" > "$S/threshold"; echo "${2:-normal}" > "$S/mode"; echo "${3:-found}" > "$S/peekmode"; }
run() { POKE_TEST_AGENT="$AG" POKE_TEST_MSG="$MSG" POKE_SETTLE=0 POKE_SUBMIT_RETRIES=3 \
        DREAMTEAM_PANE_PEEK="$TMP/bin/peek-stub.sh" CLAUDE_PLUGIN_ROOT="$ROOT" \
        PATH="$TMP/bin:$PATH" bash "$POKE" "$@"; }
enters() { cat "$S/enters" 2>/dev/null || echo 0; }

AG="lucid-x"; MSG="run tests now"

# ── #35: resolves FRESH via pane-peek, prints the ACTUALLY-resolved pane ────────
reset 1
out="$(run "$AG" $MSG)"; rc=$?
[ "$rc" = 0 ] && ok "#35 idle submit: exit 0" || bad "#35 exit=$rc ($out)"
echo "$out" | grep -q 'default@sess:9.9' && ok "#35 prints pane-peek's resolved pane (default@sess:9.9)" || bad "#35 pane in output: $out"
grep -q 'ENTER sess:9.9' "$S/keys.log" && ok "#35 send-keys targeted the resolved pane" || bad "#35 target: $(cat $S/keys.log)"
[ "$(enters)" = 1 ] && ok "#35 idle: submits on first Enter" || bad "#35 enters=$(enters)"

# ── @-strip: '@name' passed to resolver as bare name ────────────────────────────
reset 1
run "@$AG" $MSG >/dev/null 2>&1
grep -q "PEEKARGS:.* $AG\$" "$S/peek.log" && ok "leading '@' stripped before resolve" || bad "@-strip: $(cat $S/peek.log)"

# ── #28 retry: stuck on 1st Enter, submits on 2nd — no silent nonsense ──────────
reset 2
out="$(run "$AG" $MSG)"; rc=$?
[ "$rc" = 0 ] && ok "#28 retry: exit 0 after resubmit" || bad "#28 retry exit=$rc ($out)"
[ "$(enters)" = 2 ] && ok "#28 retry: re-pressed Enter until it submitted (2)" || bad "#28 enters=$(enters)"
echo "$out" | grep -q '^poked ' && ok "#28 retry: success line only after real submit" || bad "#28 no poked line"

# ── #28 REAL failure: never submits ⇒ exit 4, NO silent 'poked' ─────────────────
reset 99
out="$(run "$AG" $MSG 2>&1)"; rc=$?
[ "$rc" = 4 ] && ok "#28 never-submits: exits 4 (real failure)" || bad "#28 fail exit=$rc"
echo "$out" | grep -qi 'FAILED to submit' && ok "#28 never-submits: reports a REAL failure" || bad "#28 fail msg: $out"
echo "$out" | grep -q '^poked ' && bad "#28 never-submits: printed a SILENT success (bug!)" || ok "#28 never-submits: NO silent 'poked'"
[ "$(enters)" = 3 ] && ok "#28 never-submits: exhausted all RETRIES (3) before failing" || bad "#28 retries=$(enters)"

# ── queued-acceptance: mid-turn 'queued' indicator ⇒ success, no double-submit ──
reset 99 queued
out="$(run "$AG" $MSG)"; rc=$?
[ "$rc" = 0 ] && ok "queued: exit 0 (message accepted mid-turn)" || bad "queued exit=$rc ($out)"
[ "$(enters)" -lt 3 ] && ok "queued: stops early — no Enter-hammering ($(enters))" || bad "queued over-submitted: $(enters)"

# ── not-found: pane-peek says found=false ⇒ exit 3, no typing ───────────────────
reset 1 normal notfound
out="$(run "$AG" $MSG 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "not-found: exit 3" || bad "not-found exit=$rc ($out)"
[ ! -f "$S/keys.log" ] && ok "not-found: nothing typed" || bad "not-found: typed anyway ($(cat $S/keys.log 2>/dev/null))"

# ── --dry-run: resolves + prints, types NOTHING ─────────────────────────────────
reset 1
out="$(run --dry-run "$AG" $MSG)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'default@sess:9.9' && ok "--dry-run: prints resolved pane, exit 0" || bad "dry-run: $out"
[ ! -f "$S/keys.log" ] && ok "--dry-run: no send-keys at all" || bad "dry-run typed: $(cat $S/keys.log)"

# ── usage: empty message ⇒ exit 22 ──────────────────────────────────────────────
reset 1
run "$AG" >/dev/null 2>&1; [ $? = 22 ] && ok "empty message → exit 22" || bad "empty-msg exit"

# ── resilience: pane-peek ABSENT ⇒ embedded @handle scan still resolves ─────────
reset 1
out="$(POKE_TEST_AGENT="$AG" POKE_TEST_MSG="$MSG" POKE_SETTLE=0 POKE_SUBMIT_RETRIES=3 \
     DREAMTEAM_PANE_PEEK="$TMP/bin/DOES-NOT-EXIST" CLAUDE_PLUGIN_ROOT="$ROOT" \
     PATH="$TMP/bin:$PATH" bash "$POKE" "$AG" $MSG)"; rc=$?
[ "$rc" = 0 ] && ok "pane-peek absent: embedded @handle scan resolves + submits" || bad "fallback exit=$rc ($out)"
grep -q 'ENTER sess:9.9' "$S/keys.log" && ok "fallback: typed into scan-resolved pane" || bad "fallback target: $(cat $S/keys.log 2>/dev/null)"

echo "───────────────────────────────"
echo "test-poke: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
