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
# systemctl stub — makes the auto-containment scope deterministic (the real host may
# have a live dreamteam-agents.scope). Mode-switchable via marker files, DEFAULT OFF
# (no $TMP/scope-active) so every pre-existing check runs with the scope inactive.
#   is-active      → exit 0 iff $TMP/scope-active exists
#   MemoryCurrent  → echoes the contents of $TMP/scope-memcurrent (raw, so we can
#                    feed "[not set]"/"infinity" to exercise the sanitize guard)
cat > "$TMP/bin/systemctl" <<EOF
#!/bin/bash
case "\$*" in
  *is-active*)     [ -f "$TMP/scope-active" ] && exit 0 || exit 3 ;;
  *MemoryCurrent*) cat "$TMP/scope-memcurrent" 2>/dev/null; exit 0 ;;
  *)               exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/pgrep" "$TMP/bin/free" "$TMP/bin/systemctl"
run()  { env -u TMUX -u TMUX_PANE -u DREAMTEAM_CONFIG PATH="$TMP/bin:$PATH" HOME="$TMP" CLAUDE_PLUGIN_ROOT="$TMP" bash "$SL"; }

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

# 7. Auto-containment scope shield: 🛡 <current>/<high>. MemoryCurrent (from the
# systemctl stub) is the TRUE footprint incl. child procs (postmortem §5). Restore a
# WORKING pgrep first — test 6 left it failing, and the shield rides the procs line.
printf '#!/bin/bash\necho 7\n' > "$TMP/bin/pgrep"
BASE='{"model":{"display_name":"Fable 5"}}'

# 7a. scope inactive (default) → NO shield anywhere on the line
rm -f "$TMP/scope-active"
OUT=$(echo "$BASE" | run)
case "$OUT" in *"🛡"*) bad "no shield when scope inactive ($OUT)";; *) ok "no 🛡 when scope inactive";; esac

# 7b. scope active + readable MemoryCurrent + memoryHigh READ from config (18G, so
#     it can't be the 20G fallback) → 🛡 3.2G/18G
touch "$TMP/scope-active"
printf '3435973837\n' > "$TMP/scope-memcurrent"          # ≈3.2 GiB, in bytes
printf '{"scope":{"memoryHigh":"18G"}}\n' > "$TMP/config.json"
OUT=$(echo "$BASE" | run)
case "$OUT" in *"🛡 3.2G/18G"*) ok "🛡 <cur>/<high> reads memoryHigh from config (🛡 3.2G/18G)";; *) bad "shield from config ($OUT)";; esac

# 7c. no config → memoryHigh falls back to 20G (the canonical render)
rm -f "$TMP/config.json"
OUT=$(echo "$BASE" | run)
case "$OUT" in *"🛡 3.2G/20G"*) ok "memoryHigh falls back to 20G (🛡 3.2G/20G)";; *) bad "shield high fallback ($OUT)";; esac

# 7d. sub-GiB current → integer MiB (M branch), never fractional G
printf '536870912\n' > "$TMP/scope-memcurrent"           # 512 MiB
OUT=$(echo "$BASE" | run)
case "$OUT" in *"🛡 512M/20G"*) ok "sub-GiB current shown as integer M (🛡 512M/20G)";; *) bad "shield M-format ($OUT)";; esac

# 7e. unreadable MemoryCurrent ("[not set]") → bare 🛡, NO figure (sanitize guard)
printf '[not set]\n' > "$TMP/scope-memcurrent"
OUT=$(echo "$BASE" | run)
case "$OUT" in
  *"🛡 "[0-9]*) bad "rendered a figure despite unreadable MemoryCurrent ($OUT)";;
  *"🛡"*)       ok "unreadable MemoryCurrent → bare 🛡, guarded (no figure)";;
  *)            bad "shield missing when scope active ($OUT)";;
esac

# 7f. scope active must not break the exit contract
OUT=$(echo "$BASE" | run); RC=$?
[ "$RC" -eq 0 ] && ok "exits 0 with scope active" || bad "exit $RC with scope active"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
