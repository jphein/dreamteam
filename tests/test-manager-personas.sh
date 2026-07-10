#!/usr/bin/env bash
# dreamteam tests — manager persona definitions (agents/hypnos.md, agents/nyx.md).
#
# Static-only: no scripts run, just the markdown persona files. Asserts the two
# new manager personas parse with the SAME frontmatter shape as the five existing
# personas (name/description/color present + non-empty), that their name matches
# the filename, and that they carry their spec'd colors + a voice line. This is
# the light check the manager-roles spec (Testing §) calls for.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$ROOT/agents"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Emit only the YAML frontmatter block (between the first two '---' fences).
frontmatter() { awk 'NR==1&&$0!="---"{exit} NR==1{next} $0=="---"{exit} {print}' "$1"; }
# Trimmed value of a frontmatter key (first match).
fm_val()  { frontmatter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n1; }
# True iff key present with a non-empty value.
has_key() { frontmatter "$1" | grep -Eq "^$2:[[:space:]]*[^[:space:]]"; }

# --- Shape baseline: every existing persona exposes name/description/color ---
missing=0
for p in morpheus oracle lucid luna nebula; do
  f="$AGENTS/$p.md"
  [ -f "$f" ] || { bad "baseline persona missing: $p.md"; missing=1; continue; }
  for k in name description color; do
    has_key "$f" "$k" || { bad "baseline $p.md missing frontmatter '$k'"; missing=1; }
  done
done
[ "$missing" -eq 0 ] && ok "baseline: 5 existing personas expose name/description/color"

# --- The two new manager personas parse with the same shape ---
for p in hypnos nyx; do
  f="$AGENTS/$p.md"
  if [ ! -f "$f" ]; then bad "$p.md does not exist"; continue; fi
  if [ "$(head -n1 "$f")" = "---" ]; then ok "$p.md: opens with '---' frontmatter fence"
  else bad "$p.md: no leading frontmatter fence"; fi
  for k in name description color; do
    if has_key "$f" "$k"; then ok "$p.md: frontmatter '$k' present"
    else bad "$p.md: frontmatter '$k' missing/empty"; fi
  done
  if [ "$(fm_val "$f" name)" = "$p" ]; then ok "$p.md: name == $p"
  else bad "$p.md: name is '$(fm_val "$f" name)', expected $p"; fi
done

# --- Spec'd colors (brief: hypnos cyan, nyx magenta) ---
[ "$(fm_val "$AGENTS/hypnos.md" color)" = "cyan" ] \
  && ok "hypnos.md: color == cyan" \
  || bad "hypnos.md: color is '$(fm_val "$AGENTS/hypnos.md" color)', expected cyan"
[ "$(fm_val "$AGENTS/nyx.md" color)" = "magenta" ] \
  && ok "nyx.md: color == magenta" \
  || bad "nyx.md: color is '$(fm_val "$AGENTS/nyx.md" color)', expected magenta"

# --- Persona body sanity: each carries a DragonHD voice line ---
for p in hypnos nyx; do
  grep -q "DragonHDLatestNeural" "$AGENTS/$p.md" \
    && ok "$p.md: carries a voice line" \
    || bad "$p.md: no voice line"
done

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
