#!/usr/bin/env bash
# dreamteam tests — agent-activity.sh (#34 + #41 + #38): reliable per-agent
# ACTIVE/IDLE detector with a PANE-TRUSTED verdict, stale-isActive cross-check, an
# orthogonal queued-input flag (#33), and — as of #41 — PID-ANCESTRY pane resolution
# (the @handle name-match is demoted to a fallback). #38's two nits are pinned here:
#   nit 1: ASCII "..." classifies IDLE (unicode "…" only is a live Claude spinner).
#   nit 2: DEAD rows carry the same `team` key alive rows do.
#
# Hermetic + self-isolating (same discipline as test-pane-peek.sh / test-fleet.sh):
#   • ps + tmux are PATH-stubbed under $TMP/bin — the host process table and panes
#     are never touched. ps serves a canned `pid args` snapshot; tmux is SOCKET-AWARE
#     (list-panes per socket → pane_pid inventory; capture-pane -S -14 → body fixture,
#     -S -6 → footer fixture for the fallback).
#   • /proc is a $TMP fixture (DREAMTEAM_PROC seam) giving PPid chains for the walk.
#   • the team config is a $TMP fixture (DREAMTEAM_TEAMS_DIR seam).
#   • python3 is the REAL interpreter (only ps/tmux are stubbed).
#
# RESOLUTION TOPOLOGY (member → agent pid → pane_pid → pane):
#   exact (pid == pane_pid) for most members; plus three that exercise the resolver:
#     stale-above  1108 → /proc PPid 1008 == pane_pid   → DESCENDANT walk
#     above-control 1011 pane on the 2nd socket 'dreamteam' → MULTI-SOCKET sweep
#     fallback-x   1013 → /proc PPid 1 (no pane in chain) → @handle FOOTER fallback
#     nopane-idle  1012 → /proc PPid 1 (no pane, no footer) → no-pane
#     dead-one     absent from ps → DEAD
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="${AGENT_ACTIVITY_SH:-$ROOT/scripts/agent-activity.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$SUT" && ok "bash -n agent-activity.sh" || bad "bash -n agent-activity.sh"

mkdir -p "$TMP/bin" "$TMP/fix" "$TMP/panes" "$TMP/proc" "$TMP/teams/faketeam" "$TMP/tmux"

# ── ps stub: one `pid args` line per LIVE agent (agent-id token drives the match) ──
# dead-one (aDead) is absent → pid_for returns None → DEAD. IDs are chosen so none is
# a prefix of another (no "agent-id X" substring-collides with "agent-id XY").
cat > "$TMP/ps.snap" <<'EOF'
  PID COMMAND
 1000 node claude --agent-id aSpin
 1001 node claude --agent-id aIdle
 1002 node claude --agent-id aStaleAct
 1003 node claude --agent-id aBetween
 1004 node claude --agent-id aQact
 1005 node claude --agent-id aQidle
 1006 node claude --agent-id aWait
 1007 node claude --agent-id aAscii
 1108 node claude --agent-id aAbove
 1009 node claude --agent-id aEscAct
 1010 node claude --agent-id aEscOld
 1011 node claude --agent-id aCtrl
 1012 node claude --agent-id aNopane
 1013 node claude --agent-id aFall
EOF
cat > "$TMP/bin/ps" <<EOF
#!/usr/bin/env bash
cat "$TMP/ps.snap"
EOF
chmod +x "$TMP/bin/ps"

# ── tmux stub: socket-aware. FIRST -S (before subcmd) = socket; a -S after = scroll ──
cat > "$TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
sock=""; sub=""; addr=""; scroll=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -S) if [ -z "\$sub" ]; then sock="\$2"; else scroll="\$2"; fi; shift 2;;
    list-panes|capture-pane) sub="\$1"; shift;;
    -t) addr="\$2"; shift 2;;
    -F) shift 2;;
    -a|-p) shift;;
    *) shift;;
  esac
done
name="\$(basename "\$sock")"
if [ "\$sub" = list-panes ]; then
  cat "$TMP/panes/\$name.panes" 2>/dev/null
elif [ "\$sub" = capture-pane ]; then
  if [ "\$scroll" = "-6" ]; then cat "$TMP/fix/\$addr.foot" 2>/dev/null
  else cat "$TMP/fix/\$addr.body" 2>/dev/null; fi
fi
exit 0
EOF
chmod +x "$TMP/bin/tmux"

# ── socket files (globbed by the SUT) + per-socket pane inventories ──────────────
: > "$TMP/tmux/default"; : > "$TMP/tmux/dreamteam"
cat > "$TMP/panes/default.panes" <<'EOF'
s:1.0 1000
s:1.1 1001
s:1.2 1002
s:1.3 1003
s:1.4 1004
s:1.5 1005
s:1.6 1006
s:1.7 1007
s:1.8 1008
s:1.9 1009
s:1.10 1010
s:1.13 1113
EOF
cat > "$TMP/panes/dreamteam.panes" <<'EOF'
w:1.0 1011
EOF

# ── /proc PPid chains (only the walk cases need them; exact matches short-circuit) ──
mkproc() { mkdir -p "$TMP/proc/$1"; printf 'Name:\tclaude\nPPid:\t%s\n' "$2" > "$TMP/proc/$1/status"; }
mkproc 1108 1008   # stale-above: agent pid 1108 → pane_pid 1008 (descendant)
mkproc 1012 1      # nopane-idle: chain reaches init with no pane
mkproc 1013 1      # fallback-x:  chain reaches init with no pane → footer fallback

# ── fixture team ────────────────────────────────────────────────────────────────
cat > "$TMP/teams/faketeam/config.json" <<'EOF'
{"members":[
  {"name":"team-lead","agentType":"team-lead","agentId":"lead"},
  {"name":"active-spin","agentId":"aSpin","isActive":true},
  {"name":"idle-done","agentId":"aIdle","isActive":false},
  {"name":"stale-active","agentId":"aStaleAct","isActive":false},
  {"name":"between-rounds","agentId":"aBetween","isActive":true},
  {"name":"queued-active","agentId":"aQact","isActive":true},
  {"name":"queued-idle","agentId":"aQidle","isActive":false},
  {"name":"nopane-idle","agentId":"aNopane","isActive":false},
  {"name":"waiting-input","agentId":"aWait","isActive":false},
  {"name":"ascii-dots","agentId":"aAscii","isActive":false},
  {"name":"stale-above","agentId":"aAbove","isActive":false},
  {"name":"esc-active","agentId":"aEscAct","isActive":true},
  {"name":"esc-old","agentId":"aEscOld","isActive":false},
  {"name":"above-control","agentId":"aCtrl","isActive":false},
  {"name":"fallback-x","agentId":"aFall","isActive":false},
  {"name":"dead-one","agentId":"aDead","isActive":false}
]}
EOF

# ── footer fixture (fallback only): box-dash-flanked @handle on fallback-x's pane ──
printf '@fallback-x ────────────────\n' > "$TMP/fix/s:1.13.foot"

# ── pane bodies (what capture-pane -S -14 returns; classifier input) ─────────────
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
# (3) #33 KILLER: ACTIVE spinner WITH the queued footer — must stay ACTIVE, queued=true
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
# brittle: ASCII "..." is NOT unicode "…" ⇒ IDLE (#38 nit 1, documented in the SUT)
cat > "$TMP/fix/s:1.7.body" <<'B'
✻ Computing... (thinking)
B
# brittle: a stale ACTIVE spinner ABOVE a newer past-tense completion — MOST-RECENT wins
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
# control (2nd socket): the SAME phrasing as stale-above's OLD line, ALONE ⇒ ACTIVE.
cat > "$TMP/fix/w:1.0.body" <<'B'
✶ Pondering… (thinking)
B
# fallback-x pane body: IDLE — proves the @handle-fallback pane is captured & classified
cat > "$TMP/fix/s:1.13.body" <<'B'
✻ Wove for 4m
❯
B

# ── run ───────────────────────────────────────────────────────────────────────
run() { DREAMTEAM_TEAMS_DIR="$TMP/teams" DREAMTEAM_TMUX_DIR="$TMP/tmux" \
        DREAMTEAM_PROC="$TMP/proc" PATH="$TMP/bin:$PATH" bash "$SUT" "$@"; }

J="$(run --team faketeam --json)"
printf '%s' "$J" | jq -e . >/dev/null 2>&1 && ok "--json emits valid JSON" || bad "--json invalid ($J)"

# field <name> <key> → that member's value as a string ("null" if absent).
# tostring, NOT `// x`: jq's // treats boolean false as empty → queued=false would read MISSING.
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

# brittle: ASCII "..." is not unicode "…" ⇒ IDLE (#38 nit 1: documented unicode-only match)
[ "$(field ascii-dots pane_state)" = "IDLE" ] && ok "brittle: ASCII '...' ⇒ IDLE (only unicode '…' is active, #38-1)" || bad "brittle: ascii-dots pane_state=$(field ascii-dots pane_state)"

# brittle: most-recent status line wins (stale spinner above a newer completion)
[ "$(field stale-above pane_state)" = "IDLE" ]      && ok "brittle: newer completion beats a stale spinner above ⇒ IDLE" || bad "brittle: stale-above pane_state=$(field stale-above pane_state)"
[ "$(field above-control pane_state)" = "ACTIVE" ]  && ok "brittle: control — that same spinner ALONE ⇒ ACTIVE (non-vacuous)" || bad "brittle: above-control pane_state=$(field above-control pane_state)"

# brittle: esc-to-interrupt window is the last 4 lines only
[ "$(field esc-active pane_state)" = "ACTIVE" ] && ok "brittle: 'esc to interrupt' in last 4 lines ⇒ ACTIVE" || bad "brittle: esc-active pane_state=$(field esc-active pane_state)"
[ "$(field esc-old pane_state)" = "IDLE" ]      && ok "brittle: 'esc to interrupt' above last 4 lines ⇒ ignored (IDLE)" || bad "brittle: esc-old pane_state=$(field esc-old pane_state)"

# ── #41: PID-ANCESTRY resolution (the unified resolver) ──────────────────────────
[ "$(field active-spin pid)" = "1000" ] && ok "#41: JSON carries the matched pid (active-spin=1000)" || bad "#41: active-spin pid=$(field active-spin pid)"
[ "$(field active-spin pane)" = "default@s:1.0" ] && ok "#41: exact pid==pane_pid ⇒ pane default@s:1.0" || bad "#41: active-spin pane=$(field active-spin pane)"
[ "$(field stale-above pane)" = "default@s:1.8" ] && ok "#41: DESCENDANT PPid walk resolves pane (1108→1008)" || bad "#41: stale-above pane=$(field stale-above pane)"
[ "$(field above-control pane)" = "dreamteam@w:1.0" ] && ok "#41: MULTI-SOCKET sweep finds pane on 2nd socket" || bad "#41: above-control pane=$(field above-control pane)"
[ "$(field nopane-idle pane)" = "null" ] && ok "#41: alive-but-no-pane ⇒ pane null" || bad "#41: nopane-idle pane=$(field nopane-idle pane)"

# ── #41: @handle FOOTER fallback (pid-walk miss → box-dash footer scan) ───────────
[ "$(field fallback-x pane)" = "default@s:1.13" ] && ok "#41: pid-walk miss ⇒ @handle footer fallback resolves pane" || bad "#41: fallback-x pane=$(field fallback-x pane)"
[ "$(field fallback-x pane_state)" = "IDLE" ] && ok "#41: fallback pane captured & classified (IDLE)" || bad "#41: fallback-x pane_state=$(field fallback-x pane_state)"

# ── #38 nit 2: DEAD rows carry the `team` key (parity with alive rows) ────────────
[ "$(field dead-one team)" = "faketeam" ] && ok "#38-2: DEAD row carries team key (=faketeam)" || bad "#38-2: dead-one team=$(field dead-one team)"
[ "$(field active-spin team)" = "faketeam" ] && ok "#38-2: alive row carries team key (parity)" || bad "#38-2: active-spin team=$(field active-spin team)"
[ "$(field dead-one pid)" = "null" ] && ok "#38-2: DEAD row pid=null" || bad "#38-2: dead-one pid=$(field dead-one pid)"

# ── human output ──────────────────────────────────────────────────────────────
H="$(run --team faketeam)"
echo "$H" | grep -q "agent activity" && ok "human: header line present" || bad "human: header missing"
echo "$H" | grep -- "queued-active" | grep -q "\[queued-input\]" && ok "human: queued-input suffix rendered" || bad "human: queued-input suffix missing"
echo "$H" | grep -- "dead-one" | grep -q "DEAD" && ok "human: dead agent shown DEAD" || bad "human: DEAD row missing"
echo "$H" | grep -- "above-control" | grep -q "dreamteam@w:1.0" && ok "human: multi-socket pane rendered" || bad "human: multi-socket pane missing"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
