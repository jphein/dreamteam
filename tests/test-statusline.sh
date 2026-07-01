#!/usr/bin/env bash
# dreamteam tests — statusline.sh (model · effort · ctx% · footprint).
# Hermetic: HOME + CLAUDE_PLUGIN_ROOT point at $TMP (isolates the settings
# fallback and the footprint log), TMUX/TMUX_PANE unset (skips pane titling).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SL="$ROOT/scripts/statusline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run()  { env -u TMUX -u TMUX_PANE HOME="$TMP" CLAUDE_PLUGIN_ROOT="$TMP" bash "$SL"; }

bash -n "$SL" && ok "bash -n statusline.sh" || bad "bash -n statusline.sh"

# 1. Payload effort wins; model + ctx rendered
OUT=$(echo '{"model":{"display_name":"Fable 5"},"effort":"max","context_window_tokens_used":420000,"context_window_total_tokens":1000000}' | run)
case "$OUT" in *"Fable 5"*) ok "model from payload";; *) bad "model from payload ($OUT)";; esac
case "$OUT" in *"effort:max"*) ok "effort from payload field";; *) bad "effort from payload field ($OUT)";; esac
case "$OUT" in *"ctx 42%"*) ok "ctx% computed (420k/1M=42%)";; *) bad "ctx% computed ($OUT)";; esac

# 2. Effort falls back to the transcript's /effort stdout line
printf '{"note":"user ran /effort","stdout":"Set effort level to high (this session only)"}\n' > "$TMP/tr.jsonl"
OUT=$(echo "{\"model\":{\"display_name\":\"Opus\"},\"transcript_path\":\"$TMP/tr.jsonl\"}" | run)
case "$OUT" in *"effort:high"*) ok "effort from transcript fallback";; *) bad "effort from transcript fallback ($OUT)";; esac

# 3. Effort falls back to persisted settings effortLevel
mkdir -p "$TMP/.claude" && echo '{"effortLevel":"xhigh"}' > "$TMP/.claude/settings.json"
OUT=$(echo '{"model":{"display_name":"Opus"}}' | run)
case "$OUT" in *"effort:xhigh"*) ok "effort from settings effortLevel";; *) bad "effort from settings effortLevel ($OUT)";; esac
rm -f "$TMP/.claude/settings.json"

# 4. No sources at all → default; empty stdin must not crash
OUT=$(printf '' | run); RC=$?
[ "$RC" -eq 0 ] && ok "empty stdin exits 0" || bad "empty stdin exits $RC"
case "$OUT" in *"effort:default"*) ok "effort default when no source";; *) bad "effort default ($OUT)";; esac

# 5. ctx omitted when fields missing
case "$OUT" in *"ctx "*) bad "ctx suppressed when fields absent ($OUT)";; *) ok "ctx suppressed when fields absent";; esac

# 6. Footprint appears for a fresh log, not for a stale one
mkdir -p "$TMP/state"
echo "2026-07-01T14:00:00 post-spawn: agents=13 total_rss=4910MB avail=17321MiB" > "$TMP/state/dreamteam.log"
OUT=$(echo '{"model":{"display_name":"Fable 5"}}' | run)
case "$OUT" in *"13 agents"*"17321MiB"*) ok "footprint from fresh dreamteam.log";; *) bad "footprint from fresh log ($OUT)";; esac
touch -d '10 hours ago' "$TMP/state/dreamteam.log"
OUT=$(echo '{"model":{"display_name":"Fable 5"}}' | run)
case "$OUT" in *"agents"*) bad "stale log suppressed ($OUT)";; *) ok "stale (>6h) log suppressed";; esac

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
