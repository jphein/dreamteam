#!/usr/bin/env bash
# dreamteam tests — agent-activity.sh (#34): reliable per-agent ACTIVE/IDLE
# detector with pane-trusted verdict + stale-isActive cross-check + orthogonal
# queued-input flag (the #33 fix).
#
# AUTHORING NOTE: written by echo-liveness in scratch because #34's branch lives
# in a shared checkout (no worktree). Drop this file at tests/test-agent-activity.sh
# on fix/agent-activity-detection — then `$ROOT/scripts/agent-activity.sh` resolves
# and it joins run.sh automatically. (AGENT_ACTIVITY_SH overrides the SUT path for
# out-of-tree validation; harmless in-tree.)
#
# Hermetic + self-isolating (same discipline as test-fleet.sh / test-lifecycle.sh):
#   • tmux + pgrep are PATH-stubbed under $TMP/bin — the real ones are never called,
#     so this never reads the host's panes or process table.
#   • the team config is a $TMP fixture (DREAMTEAM_TEAMS_DIR seam).
#   • python3 is the REAL interpreter (only tmux/pgrep are stubbed).
#   No production script or state is touched.
#
# COVERAGE — Oracle's six required fixtures + the brittle parses Oracle flagged:
#   (1) ACTIVE spinner glyph        → active-spin
#   (2) IDLE = past-tense + prompt  → idle-done
#   (3) queued-input ORTHOGONAL     → queued-active (ACTIVE+queued, the #33 killer)
#                                     + queued-idle (IDLE+queued)
#   (4) stale-isActive disagreement → stale-active (⚠stale-isActive) +
#                                     between-rounds (⚠isActive=busy, reverse)
#   (5) no-pane                     → nopane-idle
#   (6) dead                        → dead-one
#   brittle: "Waiting for input…" must NOT be active → waiting-input
#            unicode "…" vs ASCII "..."             → ascii-dots (ASCII ⇒ IDLE)
#            most-recent status line, not any glyph → stale-above (+ above-control)
#            "esc to interrupt" only in last 4 lines→ esc-active / esc-old
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="${AGENT_ACTIVITY_SH:-$ROOT/scripts/agent-activity.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$SUT" && ok "bash -n agent-activity.sh" || bad "bash -n agent-activity.sh"

# ── stubs ─────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/fix" "$TMP/teams/faketeam"

# tmux: serves the SUT's three call shapes, keyed by subcommand + the -S window.
#   list-panes …            → the pane inventory ($TMUX_PANES)
#   capture-pane … -S -6    → footer fixture  ($TMUX_FIX/<pane>.foot)  (handle map)
#   capture-pane … -S -14   → body fixture    ($TMUX_FIX/<pane>.body)  (classifier)
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
sub="$1"; pane=""; s=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) pane="$2"; shift 2;;
    -S) s="$2"; shift 2;;
    *)  shift;;
  esac
done
case "$sub" in
  list-panes)   cat "$TMUX_PANES" 2>/dev/null ;;
  capture-pane) if [ "$s" = "-6" ]; then cat "$TMUX_FIX/$pane.foot" 2>/dev/null
                else cat "$TMUX_FIX/$pane.body" 2>/dev/null; fi ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/tmux"

# pgrep: the SUT calls `pgrep -f "agent-id <aid>"`; alive iff <aid> ∈ $ALIVE_IDS.
# (agentIds are hyphen-free on purpose: re.escape() is then a no-op, so the
# stubbed pattern matches the id verbatim — no backslash surprises.)
cat > "$TMP/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
pat="${@: -1}"; aid="${pat#agent-id }"
for id in $ALIVE_IDS; do [ "$id" = "$aid" ] && exit 0; done
exit 1
STUB
chmod +x "$TMP/bin/pgrep"

# ── fixture team ────────────────────────────────────────────────────────────
# team-lead is skipped by the SUT; dead-one's id is absent from ALIVE_IDS.
cat > "$TMP/teams/faketeam/config.json" <<'EOF'
{"members":[
  {"name":"team-lead","agentType":"team-lead","agentId":"lead"},
  {"name":"active-spin","agentId":"aActive","isActive":true},
  {"name":"idle-done","agentId":"aIdle","isActive":false},
  {"name":"stale-active","agentId":"aStale","isActive":false},
  {"name":"between-rounds","agentId":"aBetween","isActive":true},
  {"name":"queued-active","agentId":"aQa","isActive":true},
  {"name":"queued-idle","agentId":"aQi","isActive":false},
  {"name":"nopane-idle","agentId":"aNopane","isActive":false},
  {"name":"waiting-input","agentId":"aWait","isActive":false},
  {"name":"ascii-dots","agentId":"aAscii","isActive":false},
  {"name":"stale-above","agentId":"aAbove","isActive":false},
  {"name":"esc-active","agentId":"aEsc","isActive":true},
  {"name":"esc-old","agentId":"aEscold","isActive":false},
  {"name":"above-control","agentId":"aAbovectl","isActive":false},
  {"name":"dead-one","agentId":"aDead","isActive":false}
]}
EOF
ALIVE="aActive aIdle aStale aBetween aQa aQi aNopane aWait aAscii aAbove aEsc aEscold aAbovectl"

# ── panes + footers (handle == member name; nopane-idle & dead-one get none) ──
declare -A PANE_NAME=(
  [s:1.0]=active-spin   [s:1.1]=idle-done    [s:1.2]=stale-active
  [s:1.3]=between-rounds [s:1.4]=queued-active [s:1.5]=queued-idle
  [s:1.6]=waiting-input [s:1.7]=ascii-dots   [s:1.8]=stale-above
  [s:1.9]=esc-active    [s:1.10]=esc-old     [s:1.11]=above-control
)
: > "$TMP/panes"
for p in "${!PANE_NAME[@]}"; do
  echo "$p" >> "$TMP/panes"
  # the footer handle is box-dash-flanked: `@name ─` (SUT regex @([...])\s*─)
  printf '@%s ────────────────\n' "${PANE_NAME[$p]}" > "$TMP/fix/$p.foot"
done

# ── pane bodies (what `capture-pane -S -14` returns; classifier input) ────────
# (1) ACTIVE: present-progressive spinner ("…" present, " for " absent)
cat > "$TMP/fix/s:1.0.body" <<'B'
Working on the thing.
✻ Computing… (12s)
B
# (2) IDLE: past-tense completion + bare prompt, NO live spinner
cat > "$TMP/fix/s:1.1.body" <<'B'
✻ Brewed for 3m 12s
❯
B
# (4a) pane ACTIVE while cfg.isActive=false → ⚠stale-isActive
cat > "$TMP/fix/s:1.2.body" <<'B'
Compiling modules.
✻ Synthesizing… (8s)
B
# (4b) pane IDLE while cfg.isActive=true → ⚠isActive=busy (reverse disagreement)
cat > "$TMP/fix/s:1.3.body" <<'B'
✻ Delivered for 1m
❯
B
# (3) #33 KILLER: ACTIVE spinner WITH the queued footer — must stay ACTIVE and
#     report queued=true (the queued footer must NOT flip it to idle).
cat > "$TMP/fix/s:1.4.body" <<'B'
✻ Reticulating… (33s)
❯ Press up to edit queued messages
B
# (3b) queued footer on an IDLE pane — IDLE, queued=true (queued is orthogonal)
cat > "$TMP/fix/s:1.5.body" <<'B'
✻ Rendered for 2m
❯ Press up to edit queued messages
B
# brittle: "Waiting for input…" — has "…" but ALSO " for " ⇒ must be IDLE
cat > "$TMP/fix/s:1.6.body" <<'B'
✻ Waiting for input…
B
# brittle: ASCII "..." is NOT unicode "…" ⇒ SUT classifies IDLE (unicode-only)
cat > "$TMP/fix/s:1.7.body" <<'B'
✻ Computing... (thinking)
B
# brittle: a stale ACTIVE spinner ABOVE a newer past-tense completion — the SUT
# must use the MOST-RECENT status line (IDLE), not "any ellipsis in the window".
cat > "$TMP/fix/s:1.8.body" <<'B'
✶ Pondering… (thinking)
intermediate output line
✻ Churned for 3m
❯
B
# brittle: "esc to interrupt" in the last 4 lines ⇒ ACTIVE (even with no glyph)
cat > "$TMP/fix/s:1.9.body" <<'B'
Running the build.
(press esc to interrupt)
B
# brittle: "esc to interrupt" ABOVE the last 4 lines ⇒ ignored; past-tense ⇒ IDLE
cat > "$TMP/fix/s:1.10.body" <<'B'
esc to interrupt
line a
line b
line c
line d
✻ Compiled for 5m
❯
B
# control: the SAME phrasing as stale-above's OLD line, alone ⇒ ACTIVE. Proves
# stale-above=IDLE is a real most-recent-line win, not a vacuous pass.
cat > "$TMP/fix/s:1.11.body" <<'B'
✶ Pondering… (thinking)
B

# ── run ───────────────────────────────────────────────────────────────────────
run() { DREAMTEAM_TEAMS_DIR="$TMP/teams" TMUX_PANES="$TMP/panes" TMUX_FIX="$TMP/fix" \
        ALIVE_IDS="$ALIVE" PATH="$TMP/bin:$PATH" bash "$SUT" "$@"; }

J="$(run --team faketeam --json)"
printf '%s' "$J" | jq -e . >/dev/null 2>&1 && ok "--json emits valid JSON" || bad "--json invalid ($J)"

# field <name> <key> → that member's value as a string ("null" if absent).
# NB: use tostring, NOT `// x` — jq's // treats boolean false as empty, which
# would make every queued=false read as MISSING.
field() { printf '%s' "$J" | jq -r --arg n "$1" --arg f "$2" \
          'map(select(.name==$n))[0] | .[$f] | tostring'; }

# team-lead is skipped entirely
[ "$(printf '%s' "$J" | jq -r 'map(select(.name=="team-lead")) | length')" = "0" ] \
  && ok "team-lead excluded from output" || bad "team-lead leaked into output"

# (1) ACTIVE spinner glyph
[ "$(field active-spin pane_state)" = "ACTIVE" ] && ok "(1) spinner glyph ⇒ pane ACTIVE" || bad "(1) active-spin pane_state=$(field active-spin pane_state)"
[ "$(field active-spin verdict)" = "ACTIVE" ]    && ok "(1) agree ⇒ verdict ACTIVE"     || bad "(1) active-spin verdict=$(field active-spin verdict)"
[ "$(field active-spin queued)" = "false" ]      && ok "(1) no queued footer ⇒ queued=false (control)" || bad "(1) active-spin queued=$(field active-spin queued)"

# (2) IDLE = past-tense + bare prompt
[ "$(field idle-done pane_state)" = "IDLE" ] && ok "(2) past-tense + prompt ⇒ pane IDLE" || bad "(2) idle-done pane_state=$(field idle-done pane_state)"
[ "$(field idle-done verdict)" = "IDLE" ]    && ok "(2) agree ⇒ verdict IDLE"            || bad "(2) idle-done verdict=$(field idle-done verdict)"

# (3) queued-input ORTHOGONAL — the #33 regression
[ "$(field queued-active pane_state)" = "ACTIVE" ] && ok "(3) ACTIVE pane w/ queued footer stays ACTIVE (#33)" || bad "(3) queued-active pane_state=$(field queued-active pane_state)"
[ "$(field queued-active queued)" = "true" ]       && ok "(3) queued reported orthogonally (#33)"              || bad "(3) queued-active queued=$(field queued-active queued)"
case "$(field queued-active verdict)" in *IDLE*) bad "(3) queued footer misread ACTIVE agent as IDLE — #33 regression";; *) ok "(3) verdict is not IDLE for a busy+queued agent";; esac
[ "$(field queued-idle pane_state)" = "IDLE" ] && ok "(3) IDLE pane w/ queued footer stays IDLE" || bad "(3) queued-idle pane_state=$(field queued-idle pane_state)"
[ "$(field queued-idle queued)" = "true" ]     && ok "(3) queued=true on an idle agent (orthogonal)" || bad "(3) queued-idle queued=$(field queued-idle queued)"

# (4) stale-isActive disagreement flagged (both directions)
case "$(field stale-active verdict)" in *"stale-isActive"*) ok "(4) pane ACTIVE + cfg idle ⇒ ⚠stale-isActive";; *) bad "(4) stale-active verdict=$(field stale-active verdict)";; esac
[ "$(field stale-active pane_state)" = "ACTIVE" ] && ok "(4) stale-active trusts the live pane (ACTIVE)" || bad "(4) stale-active pane_state=$(field stale-active pane_state)"
case "$(field between-rounds verdict)" in *"isActive=busy"*) ok "(4) pane IDLE + cfg busy ⇒ ⚠isActive=busy (reverse)";; *) bad "(4) between-rounds verdict=$(field between-rounds verdict)";; esac

# (5) no-pane
case "$(field nopane-idle verdict)" in *"no-pane"*) ok "(5) alive but unresolved pane ⇒ ?(no-pane)";; *) bad "(5) nopane-idle verdict=$(field nopane-idle verdict)";; esac
[ "$(field nopane-idle pane_state)" = "null" ] && ok "(5) no-pane ⇒ pane_state null" || bad "(5) nopane-idle pane_state=$(field nopane-idle pane_state)"

# (6) dead
[ "$(field dead-one verdict)" = "DEAD" ] && ok "(6) agent-id not alive ⇒ DEAD" || bad "(6) dead-one verdict=$(field dead-one verdict)"

# brittle: "Waiting for input…" must NOT be ACTIVE (the ' for ' guard)
[ "$(field waiting-input pane_state)" = "IDLE" ] && ok "brittle: 'Waiting for input…' ⇒ IDLE (not active)" || bad "brittle: waiting-input pane_state=$(field waiting-input pane_state)"

# brittle: ASCII "..." is not unicode "…" ⇒ IDLE (documents the unicode-only match)
[ "$(field ascii-dots pane_state)" = "IDLE" ] && ok "brittle: ASCII '...' ⇒ IDLE (only unicode '…' is active)" || bad "brittle: ascii-dots pane_state=$(field ascii-dots pane_state)"

# brittle: most-recent status line wins (stale spinner above a newer completion)
[ "$(field stale-above pane_state)" = "IDLE" ]      && ok "brittle: newer completion beats a stale spinner above ⇒ IDLE" || bad "brittle: stale-above pane_state=$(field stale-above pane_state)"
[ "$(field above-control pane_state)" = "ACTIVE" ]  && ok "brittle: control — that same spinner ALONE ⇒ ACTIVE (non-vacuous)" || bad "brittle: above-control pane_state=$(field above-control pane_state)"

# brittle: esc-to-interrupt window is the last 4 lines only
[ "$(field esc-active pane_state)" = "ACTIVE" ] && ok "brittle: 'esc to interrupt' in last 4 lines ⇒ ACTIVE" || bad "brittle: esc-active pane_state=$(field esc-active pane_state)"
[ "$(field esc-old pane_state)" = "IDLE" ]      && ok "brittle: 'esc to interrupt' above last 4 lines ⇒ ignored (IDLE)" || bad "brittle: esc-old pane_state=$(field esc-old pane_state)"

# ── human output ──────────────────────────────────────────────────────────────
H="$(run --team faketeam)"
echo "$H" | grep -q "agent activity" && ok "human: header line present" || bad "human: header missing"
echo "$H" | grep -- "queued-active" | grep -q "\[queued-input\]" && ok "human: queued-input suffix rendered" || bad "human: queued-input suffix missing"
echo "$H" | grep -- "dead-one" | grep -q "DEAD" && ok "human: dead agent shown DEAD" || bad "human: DEAD row missing"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
