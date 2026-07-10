#!/usr/bin/env bash
# dreamteam tests — SKILL.md manager-roles integration (issue #40).
#
# Asserts the mechanically-checkable invariants of the prose change: the
# <dreamname>-<role> naming convention, the standing Manager roles section
# (Hypnos/Nyx), the Revision-2 safety rules (R4 team-targeting, R5 kill-safety,
# D3 ACK, D4 asymmetric activation, D6 single-writer, D7 promotion), and the
# §5/S6 Argus+Iona retirement (no active overnight rows / re-spawn refs).
#
# Pure grep over the committed docs — no scripts executed, nothing to isolate.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/dreamteam/SKILL.md"
CRASH="$ROOT/scripts/crash-audit.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# present PATTERN LABEL  — assert an ERE matches somewhere in SKILL.md
present() { grep -qE "$1" "$SKILL" && ok "$2" || bad "$2 (missing: /$1/)"; }
# absent PATTERN LABEL   — assert an ERE matches NOWHERE in SKILL.md
absent()  { grep -qE "$1" "$SKILL" && bad "$2 (present but should be gone: /$1/)" || ok "$2"; }

[ -f "$SKILL" ] && ok "SKILL.md exists" || { bad "SKILL.md missing"; echo "FAIL"; exit 1; }

# ── Naming (§2): <dreamname>-<role>, role examples, no Nyx in worker pool ──────
present '<dreamname>-<role>'                        "naming: convention is <dreamname>-<role>"
present 'lucid-debugger'                            "naming: role-style example lucid-debugger"
present 'morpheus-architect'                        "naming: role-style example morpheus-architect"
absent  '<dreamname>-<task>'                        "naming: old <dreamname>-<task> convention removed"
# Nyx must NOT be in the extended worker name pool ("draw from:" line) ...
if grep -E 'draw from:' "$SKILL" | grep -q 'Nyx'; then
  bad "naming: Nyx still in the extended worker name pool"
else
  ok "naming: Nyx removed from the extended worker name pool"
fi
# ... but SHOULD be named as a reserved fixed-role name.
present 'reserved fixed-role name'                  "naming: Hypnos/Nyx reserved as fixed-role names"

# ── Manager roles (standing) section (items 3–7) ──────────────────────────────
present '## Manager roles \(standing\)'             "managers: section present"
present '\*\*Hypnos\*\*'                            "managers: Hypnos in the roles table"
present '\*\*Nyx\*\*'                               "managers: Nyx in the roles table"
present 'dreamteam:hypnos'                          "managers: typed-teammate spawn (never fork)"
present 'NEVER forks'                               "managers: fork rule stated"

# D4 asymmetric activation
present 'minTeamSize'                               "activation: gated on config .managers.minTeamSize"
present 'Asymmetric activation'                     "activation: asymmetric section present"
present '≥5 workers OR after a wave hit Yellow'     "activation: Nyx scale/pressure gate"

# D7 promotion restates role in-message
present 'PROMOTION —'                               "promotion: in-message role-restating template"

# R4 team-targeting
present '\-\-team <own-team>'                       "R4: manager reads pass --team <own-team>"

# R5 kill-safety
present 'shed-EXEMPT'                               "R5: managers are shed-exempt"
present 'not-killable-by-Nyx'                       "R5: managers not killable by Nyx"
present 'pane-state confirmation'                   "R5: pane-state confirmation before non-RED TaskStop"

# D3 ACK convention + D1/S3 cadence + token cost
present 'ACK <task>'                                "D3: closed-loop ACK convention"
present 'Event-driven first'                        "D1/S3: event-driven, long idle-poll fallback"
present 'Token cost is real'                        "D1/S3: token cost noted"
present 'poke\.sh'                                  "D2: poke.sh delivery fallback"

# D6 single-writer roster.md + role column + scratch location (R3)
present 'Single-writer handoff'                     "D6: single-writer roster handoff"
present 'scratch/<team>/roster\.md'                 "R3: roster.md lives under scratch/<team>/"
present '\| Agent ID \| Dream Name \| Role \|'      "roster: role column added to the table"

# Startup: managers before the worker wave
present '5\.5 Managers'                             "startup: manager-spawn step before the worker wave"

# ── §5 / S6: Argus + Iona retirement ─────────────────────────────────────────
# No ACTIVE overnight table row for either (a retirement NOTE naming them is fine).
absent  '^\| \*\*Argus\*\*'                         "retirement: no active Argus overnight-table row"
absent  '^\| \*\*Iona\*\*'                          "retirement: no active Iona overnight-table row"
# No stale re-spawn list naming Argus (SKILL.md HANDOFF template + crash-audit.sh).
absent  'Reeve/Hermes/Argus'                        "retirement: SKILL.md re-spawn list drops Argus"
if grep -qE 'Reeve/Hermes/Argus' "$CRASH"; then
  bad "retirement: crash-audit.sh re-spawn list still names Argus"
else
  ok "retirement: crash-audit.sh re-spawn list drops Argus"
fi
# The retirement is documented (so a reader who remembers Argus/Iona understands).
present 'retired'                                   "retirement: documented in the overnight section"

echo ""
echo "test-manager-skill: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
