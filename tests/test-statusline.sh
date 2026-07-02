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

# PATH-stub pgrep/free so the live footprint is deterministic (7 procs, 12345 MiB)
mkdir -p "$TMP/bin"
printf '#!/bin/bash\necho 7\n' > "$TMP/bin/pgrep"
printf '#!/bin/bash\necho "Mem: 32000 15000 2000 100 3000 12345"\n' > "$TMP/bin/free"
chmod +x "$TMP/bin/pgrep" "$TMP/bin/free"
run()  { env -u TMUX -u TMUX_PANE PATH="$TMP/bin:$PATH" HOME="$TMP" CLAUDE_PLUGIN_ROOT="$TMP" bash "$SL"; }

bash -n "$SL" && ok "bash -n statusline.sh" || bad "bash -n statusline.sh"

# 1. Payload effort wins; model + ctx rendered. REAL shape: effort is an OBJECT
# ({"level":"max"} — live-verified 2026-07-01; a raw jq -r of it once rendered
# the statusline as three lines).
OUT=$(echo '{"model":{"display_name":"Fable 5"},"effort":{"level":"max"},"context_window":{"used_percentage":23,"total_input_tokens":229000,"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":34},"seven_day":{"used_percentage":16}}}' | run)
case "$OUT" in *"Fable 5"*) ok "model from payload";; *) bad "model from payload ($OUT)";; esac
case "$OUT" in *"effort:max"*) ok "effort from payload object (.effort.level)";; *) bad "effort from payload object ($OUT)";; esac
case "$OUT" in *"ctx 23% (229k/1M)"*) ok "ctx from nested context_window (pct + counts)";; *) bad "nested ctx ($OUT)";; esac
case "$OUT" in *"5h:34% 7d:16%"*) ok "rate limits rendered (5h/7d)";; *) bad "rate limits ($OUT)";; esac
# legacy flat keys still work (pre-drift builds)
OUT=$(echo '{"model":{"display_name":"Fable 5"},"effort":{"level":"max"},"context_window_tokens_used":420000,"context_window_total_tokens":1000000}' | run)
case "$OUT" in *"ctx 42%"*) ok "legacy flat ctx keys still computed (42%)";; *) bad "legacy ctx fallback ($OUT)";; esac
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] && ok "single-line output (no pretty-printed object)" || bad "single-line output (got: $OUT)"
OUT=$(echo '{"model":{"display_name":"Fable 5"},"effort":"high"}' | run)
case "$OUT" in *"effort:high"*) ok "effort as plain string still accepted";; *) bad "effort as plain string ($OUT)";; esac

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

# 6. Footprint is LIVE (stubbed pgrep/free), labeled "procs" — never the stale
# log tail (regression: a dead team once rendered as "11 agents"), and never
# the misleading word "agents" for a system-wide process count.
OUT=$(echo '{"model":{"display_name":"Fable 5"}}' | run)
case "$OUT" in *"7 procs"*"12345MiB free"*) ok "live footprint from pgrep+free (7 procs, 12345MiB)";; *) bad "live footprint ($OUT)";; esac
case "$OUT" in *"agents"*) bad "'agents' label banned in footprint ($OUT)";; *) ok "footprint labeled 'procs', not 'agents'";; esac
# pgrep failing entirely → footprint suppressed, still exits 0
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/pgrep"
OUT=$(echo '{"model":{"display_name":"Fable 5"}}' | run); RC=$?
[ "$RC" -eq 0 ] && ok "pgrep failure: exits 0" || bad "pgrep failure exits $RC"
case "$OUT" in *procs*) bad "footprint suppressed when pgrep fails ($OUT)";; *) ok "footprint suppressed when pgrep fails";; esac

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
