#!/usr/bin/env bash
# dreamteam — dashboard OUTPUT-contract test.
#
# Verifies scripts/dashboard-data.sh produces the JSON shape that
# templates/dashboard.html consumes, and that --inject swaps the data block
# into the template cleanly. We assert on OUTPUT ONLY (keys + injected HTML),
# never on the script's internals — so this stays decoupled from any refactor
# of dashboard-data.sh's guts. If a refactor drops a contract key, this fails.
#
# Standalone-runnable:  bash tests/test-dashboard.sh
# Requires jq for JSON structure checks (skips those with a note if absent).
# Only writes to a private $TMP; never mutates templates/dashboard.html.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/dashboard-data.sh"
TEMPLATE="$ROOT/templates/dashboard.html"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dt-dash-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Pin config + template resolution to THIS repo so the test is hermetic and
# never picks up an installed plugin cache.
export CLAUDE_PLUGIN_ROOT="$ROOT"
export DREAMTEAM_REPO="$ROOT"

pass=0; fail=0; skip=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
sk(){ echo "SKIP: $1"; skip=$((skip+1)); }

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else
  sk "jq not installed — JSON structure checks will be skipped (install jq for full coverage)"
fi

# Count occurrences of an open/close tag pair and assert they balance (>0).
tagbal(){
  local f="$1" t="$2" o c
  o=$(grep -oE "<$t[ >]" "$f" | wc -l | tr -d ' ')
  c=$(grep -oE "</$t>"    "$f" | wc -l | tr -d ' ')
  if [ "$o" -gt 0 ] && [ "$o" -eq "$c" ]; then
    ok "inject tag balance <$t> ($o open == $c close)"
  else
    no "inject tag balance <$t> ($o open vs $c close)"
  fi
}

echo "=== preflight ==="
[ -f "$SCRIPT" ]   && ok "dashboard-data.sh present" || no "dashboard-data.sh missing at $SCRIPT"
[ -f "$TEMPLATE" ] && ok "dashboard.html present"    || no "dashboard.html missing at $TEMPLATE"

# ───────────────────────────────────────────────────────────────────────────
# 1. --json : exit 0, valid JSON, required top-level + nested keys
# ───────────────────────────────────────────────────────────────────────────
echo; echo "=== --json contract ==="
JSON="$TMP/data.json"
bash "$SCRIPT" --json >"$JSON" 2>"$TMP/json.err"
rc=$?
[ "$rc" -eq 0 ] && ok "--json exits 0" || no "--json exit $rc (stderr: $(head -1 "$TMP/json.err"))"
[ -s "$JSON" ]   && ok "--json produced non-empty output" || no "--json produced no output"

if [ "$HAVE_JQ" -eq 1 ]; then
  if jq . "$JSON" >/dev/null 2>&1; then ok "--json output is valid JSON"; else no "--json output is NOT valid JSON"; fi

  # top-level keys the dashboard reads
  for k in generatedAt host team memory tier agents prs timeline; do
    if jq -e "has(\"$k\")" "$JSON" >/dev/null 2>&1; then ok "--json has top-level .$k"
    else no "--json MISSING top-level .$k"; fi
  done

  # nested keys the dashboard reads
  for expr in \
    '.memory|has("perAgentMb")' \
    '.memory|has("cap")' \
    '.memory|has("availableMb")' \
    '.timeline|has("shipped")' \
    '.timeline|has("inFlight")' \
    '.timeline|has("pending")'; do
    if jq -e "$expr" "$JSON" >/dev/null 2>&1; then ok "--json $expr"
    else no "--json MISSING $expr"; fi
  done

  # shape sanity: collections are the right JSON types
  for expr in \
    '.agents|type=="array"' \
    '.prs|type=="array"' \
    '.timeline.shipped|type=="array"' \
    '.memory|type=="object"'; do
    if jq -e "$expr" "$JSON" >/dev/null 2>&1; then ok "--json $expr"
    else no "--json wrong type: $expr"; fi
  done
else
  sk "--json key/type assertions (needs jq)"
  # Without jq we can still sanity-check it looks like a JSON object.
  if head -c 64 "$JSON" | grep -q '{'; then ok "--json output starts like a JSON object"
  else no "--json output does not look like JSON"; fi
fi

# ───────────────────────────────────────────────────────────────────────────
# 2. --inject : exit 0, markers replaced, data block non-empty, tags balance
# ───────────────────────────────────────────────────────────────────────────
echo; echo "=== --inject contract ==="
OUT="$TMP/out.html"
bash "$SCRIPT" --inject "$TEMPLATE" >"$OUT" 2>"$TMP/inject.err"
rc=$?
[ "$rc" -eq 0 ] && ok "--inject exits 0" || no "--inject exit $rc (stderr: $(head -1 "$TMP/inject.err"))"
[ -s "$OUT" ]   && ok "--inject produced non-empty HTML" || no "--inject produced no output"

# The BEGIN marker must now be the INJECTED variant, and the sample-only
# phrasing must be gone → proves the block was actually swapped.
if grep -q 'DREAMTEAM_DATA:BEGIN.*injected.*by dashboard-data.sh' "$OUT"; then
  ok "--inject replaced BEGIN marker with injected variant"
else
  no "--inject did not produce the injected BEGIN marker"
fi
if grep -q 'orchestrator replaces this block' "$OUT"; then
  no "--inject left the sample marker text behind (block not replaced)"
else
  ok "--inject removed the sample marker text"
fi

# Extract just the lines between the markers and confirm the assignment is there
# and non-trivial.
awk '/DREAMTEAM_DATA:BEGIN/{f=1;next} /DREAMTEAM_DATA:END/{f=0} f' "$OUT" >"$TMP/block.js"
blocksz=$(wc -c <"$TMP/block.js" | tr -d ' ')
if grep -q 'window.DREAMTEAM_DATA' "$TMP/block.js" && [ "${blocksz:-0}" -gt 100 ]; then
  ok "--inject block has window.DREAMTEAM_DATA assignment ($blocksz bytes)"
else
  no "--inject block missing/empty window.DREAMTEAM_DATA ($blocksz bytes)"
fi
if grep -q 'generatedAt' "$TMP/block.js"; then ok "--inject block carries live data (generatedAt)"
else no "--inject block missing live data"; fi

# The injected payload must itself be valid JSON (end-to-end contract check).
if [ "$HAVE_JQ" -eq 1 ]; then
  if sed '1s/^window\.DREAMTEAM_DATA = //' "$TMP/block.js" \
       | sed '$s/;[[:space:]]*$//' \
       | jq . >/dev/null 2>&1; then
    ok "--inject payload parses as valid JSON"
  else
    no "--inject payload is not valid JSON"
  fi
else
  sk "--inject payload JSON validation (needs jq)"
fi

# Basic tag-balance sanity on the rendered HTML. These 5 tags never appear
# inside the JS string literals, so raw grep counts are reliable.
for t in script style table section svg; do
  tagbal "$OUT" "$t"
done

# ───────────────────────────────────────────────────────────────────────────
# 3. Template stays standalone-renderable (sample data + favicon intact)
# ───────────────────────────────────────────────────────────────────────────
echo; echo "=== template standalone integrity ==="
if grep -q 'DREAMTEAM_DATA:BEGIN' "$TEMPLATE" \
   && grep -q 'window.DREAMTEAM_DATA' "$TEMPLATE" \
   && grep -q 'generatedAt' "$TEMPLATE" \
   && grep -q 'memory' "$TEMPLATE"; then
  ok "template retains a standalone sample DREAMTEAM_DATA block"
else
  no "template is missing its standalone sample data block"
fi
# It must be the SAMPLE block (not a committed injected copy).
if grep -q 'orchestrator replaces this block' "$TEMPLATE"; then
  ok "template's data block is the sample variant (not an injected copy)"
else
  no "template's sample marker is gone — was an injected copy committed?"
fi
if grep -q 'rel="icon"' "$TEMPLATE" && grep -q 'data:image/svg' "$TEMPLATE"; then
  ok "template has an inline SVG favicon"
else
  no "template missing inline SVG favicon"
fi

# ───────────────────────────────────────────────────────────────────────────
echo
echo "──────────────── summary ────────────────"
echo "PASS=$pass  FAIL=$fail  SKIP=$skip"
if [ "$fail" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: OK"
exit 0
