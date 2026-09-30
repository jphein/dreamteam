#!/usr/bin/env bash
# dreamteam tests — the Fleet lessons (measured 2026-09-29/30) stay in the docs.
#
# Every lesson check runs against the Fleet lessons SECTION only (from its
# heading to the next level-two heading), so a phrase that also appears in the
# spawn template cannot keep a deleted lesson green. Also asserts: all 14
# numbered lessons, placement between REACHING JP and Org map, all four report
# fields in the spawn template, the Oracle's coverage-before-verdict order, and
# the README/CONTRIBUTING pointers.
#
# The section scope, spawn-template and Oracle checks each have targeted
# perturbations: the same check function runs on a copy with one thing removed
# or reordered and must go red. Fixture creation is checked, so a failed write
# cannot pass as a detected mutation. Placement and README/CONTRIBUTING checks
# are plain greps with no perturbation.
#
# Pure grep over the committed docs — no scripts executed, nothing to isolate.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/dreamteam/SKILL.md"
ORACLE="$ROOT/agents/oracle.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing: '$2' in ${1#"$ROOT"/})"; }

# section FILE — the Fleet lessons section, heading through the line before the next "## "
section() { awk '/^## ✅ Fleet lessons/{on=1; print; next} on && /^## /{exit} on' "$1"; }

# One load-bearing phrase per lesson (label|phrase).
LESSONS=(
  'L1 lead rejects reports without Not verified|rejects a report with no "Not verified"'
  "L2 relayed fact is not verified|A relayed or planned fact isn't a verified one"
  'L3 cross-model check via xreview|~/.claude/scripts/xreview'
  "L3 xreview is evidence, not a gate|It's evidence, not a gate"
  'L4 answers ledger|ANSWERS.jsonl'
  'L4 re-ask checker|answers.py'
  'L5 Q: line format|Q: <question> [option / option]'
  'L6 rm rewrite with :? guards|"${SP:?}/${f:?}.new"'
  'L6 :? limits stated|does not check the destination'
  'L6 settings.json hooks hot-reload|hot-reload'
  'L7 heavy builds on familiar|katana-build-guard.sh'
  'L8 competition data guard|competition-data-guard.sh'
  'L9 quota stalls auto-resume|quota-resume.timer'
  'L10 read the full command before approving|reads the **full** command'
  'L11 headless familiar lane launch form|bash -lc'
  'L12 (gstack /qa) red before green|fails on the unfixed code'
  'L13 (gstack /cso) coverage stated|`complete`, `partial` or `not assessed`'
  'L14 (gstack /investigate) three strikes|Three strikes, then investigate'
)

# lessons_ok FILE [quiet] — 0 iff the section holds every phrase and lessons 1..14
lessons_ok() {
  local f="$1" quiet="${2:-}" sec entry label phrase n miss=0
  sec="$(section "$f")"
  [ -n "$sec" ] || { [ -n "$quiet" ] || bad "section: Fleet lessons heading not found"; return 1; }
  [ -n "$quiet" ] || ok "section: Fleet lessons present"
  for entry in "${LESSONS[@]}"; do
    label="${entry%%|*}"; phrase="${entry#*|}"
    if grep -qF -- "$phrase" <<<"$sec"; then [ -n "$quiet" ] || ok "$label"
    else miss=$((miss+1)); [ -n "$quiet" ] || bad "$label (missing from the section: '$phrase')"; fi
  done
  for n in $(seq 1 14); do
    if grep -qE "^${n}\. \*\*" <<<"$sec"; then :; else
      miss=$((miss+1)); [ -n "$quiet" ] || bad "numbered lesson $n missing from the section"; fi
  done
  [ -n "$quiet" ] || { [ "$miss" -eq 0 ] && ok "numbered lessons 1-14 all in the section"; }
  [ "$miss" -eq 0 ]
}

# template_ok FILE — the spawn template carries all four report fields + red-before-green
template_ok() {
  local tmpl field
  tmpl="$(sed -n '/^### Spawn template/,/^### Anti-collision/p' "$1")"
  [ -n "$tmpl" ] || return 1
  for field in 'Changed:' 'Checked:' 'Evidence:' 'Not verified:' 'Red before green'; do
    grep -qF -- "$field" <<<"$tmpl" || return 1
  done
}

# oracle_ok FILE — the report shape names coverage BEFORE the verdict, and has the footer
oracle_ok() {
  local shape cov ver
  shape="$(sed -n '/^\*\*Report shape:\*\*/,/^$/p' "$1" | tr '\n' ' ')"
  cov="${shape%%\`complete\`*}"; ver="${shape%%verdict*}"
  [ "$cov" != "$shape" ] && [ "$ver" != "$shape" ] || return 1   # both markers present
  [ "${#cov}" -lt "${#ver}" ] || return 1                        # coverage comes first
  local field
  for field in 'Changed:' 'Checked:' 'Evidence:' 'Not verified:'; do
    grep -qF -- "$field" <<<"$shape" || return 1
  done
}

[ -f "$SKILL" ] && ok "SKILL.md exists" || { bad "SKILL.md missing"; echo "FAIL"; exit 1; }

# ── the real docs ─────────────────────────────────────────────────────────────
lessons_ok "$SKILL"

reach=$(grep -n '^## 🔴 REACHING JP' "$SKILL" | cut -d: -f1)
less=$(grep -n '^## ✅ Fleet lessons' "$SKILL" | cut -d: -f1)
org=$(grep -n '^## Org map' "$SKILL" | cut -d: -f1)
if [ -n "$reach" ] && [ -n "$less" ] && [ -n "$org" ] && [ "$reach" -lt "$less" ] && [ "$less" -lt "$org" ]; then
  ok "placement: REACHING JP < Fleet lessons < Org map"
else
  bad "placement: expected REACHING JP ($reach) < Fleet lessons ($less) < Org map ($org)"
fi

template_ok "$SKILL" && ok "template: Changed/Checked/Evidence/Not verified + red-before-green in the lane prompt" \
  || bad "template: lane prompt lacks a report field or red-before-green"
oracle_ok "$ORACLE" && ok "oracle: coverage before verdict, four-part footer" \
  || bad "oracle: report shape lacks coverage-before-verdict or the Not verified footer"

has "$ROOT/README.md" '## Fleet lessons'       "README: Fleet lessons section"
has "$ROOT/README.md" 'Not verified'           "README: four-part report listed"
has "$ROOT/CONTRIBUTING.md" 'Not verified'     "CONTRIBUTING: definition of done"
has "$ROOT/CONTRIBUTING.md" 'xreview'          "CONTRIBUTING: merge gate names xreview"
has "$ROOT/CONTRIBUTING.md" 'Inside a wave'    "CONTRIBUTING: wave vs self-merge scope stated"

# ── perturbations: each check must go red on a targeted mutation ──────────────
tmp="$(mktemp -d)" && [ -d "$tmp" ] || { bad "perturbation: mktemp failed"; echo "lessons: $PASS passed, $FAIL failed"; exit 1; }
trap 'rm -rf -- "$tmp"' EXIT

# mutate NAME SRC SED-EXPR — write a mutated copy, prove it was written AND differs
mutate() {
  local out="$tmp/$1"
  sed "$3" "$2" > "$out" && [ -s "$out" ] && ! cmp -s "$2" "$out" && echo "$out"
}
# expect_red LABEL CHECK FILE — CHECK on FILE must fail
expect_red() {
  if [ -z "$3" ]; then bad "perturbation: $1 (fixture not created)"; return; fi
  if "$2" "$3" quiet 2>/dev/null; then bad "perturbation: $1 did NOT go red (vacuous)"
  else ok "perturbation: $1 goes red"; fi
}

# Delete lesson 14 WHOLE (heading through its Why) — but its phrase survives nowhere else.
f=$(mutate l14 "$SKILL" '/^14\. \*\*Three strikes/,/under patches/d'); expect_red "delete lesson 14" lessons_ok "$f"
# Delete lesson 12 body: "Red before green" also lives in the template, so only a section-scoped check catches this.
f=$(mutate l12 "$SKILL" '/^12\. \*\*Red before green/,/^13\. /{/^13\. /!d}'); expect_red "delete lesson 12 (phrase survives in template)" lessons_ok "$f"
# Move a lesson phrase out of the section (into the file's tail) — whole-file grep would stay green.
f=$(mutate mv9 "$SKILL" '/quota-resume.timer/d;$a quota-resume.timer'); expect_red "lesson 9 moved outside the section" lessons_ok "$f"
# Drop "Evidence:" from the spawn template only.
f=$(mutate tmplev "$SKILL" '/^### Spawn template/,/^### Anti-collision/s/Evidence:/Proof:/'); expect_red "template without Evidence:" template_ok "$f"
# Oracle: verdict before coverage.
f=$(mutate orcev "$ORACLE" 's/`Evidence:` the deciding output/the deciding output/'); expect_red "oracle footer without Evidence:" oracle_ok "$f"
f=$(mutate orc "$ORACLE" 's/coverage first (\(.*\)), then the verdict/the verdict first, then coverage (\1)/'); expect_red "oracle verdict before coverage" oracle_ok "$f"

echo ""
echo "lessons: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
