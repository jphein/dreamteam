#!/usr/bin/env bash
# dreamteam tests — pane-peek.sh (issue #22: observer diagnostic, roster→pane join).
# Hermetic: fake /proc, fake tmux socket dir, stubbed tmux (list-panes + capture-pane),
# stubbed roster.sh (via the DREAMTEAM_ROSTER seam). No production script is touched.
#
# Fixture topology (roster NAME → pid → pane):
#   luna-x  201→200        200 is pane default@dream:2.1   (pid-join, DESCENDANT case)
#   echo-x  202            202 is pane default@dream:2.2   (pid-join, exact-match case)
#   nest-x  210→205→200    205 is pane default@dream:2.5   (CLOSEST pane_pid wins, not 200)
#   morph-x 301            301 is pane dreamteam@work:1.1   (multi-socket sweep)
#   lead-x  pid=null       footer "── @lead-x ──" @dream:2.3 (@handle FALLBACK)
#   guard-x pid=null       decoy "@guard-x" w/o box-dash @dream:2.4 (guard REJECTS it)
#   lost-x  999→998→1      no pane in chain                (alive-but-no-pane)
#   ghost-x pid=null,dead                                   (dead)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PEEK="$ROOT/scripts/pane-peek.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$PEEK" && ok "bash -n pane-peek.sh" || bad "bash -n"

# ── observer-only law: no pane-MUTATING tmux verb in the code (comments stripped) ──
if grep -vE '^[[:space:]]*#' "$PEEK" | grep -qE 'send-keys|kill-pane|kill-session|kill-server|respawn-pane|paste-buffer'; then
  bad "pane-peek.sh contains a pane-mutating tmux verb — forbidden by #22 (observer-only)"
else
  ok "no pane-mutating tmux verb exists in pane-peek.sh (observer-only)"
fi

# ── fixture: fake /proc PPid chains ──────────────────────────────────────────
mkproc() { mkdir -p "$TMP/proc/$1"; printf 'Name:\tclaude\nPPid:\t%s\n' "$2" > "$TMP/proc/$1/status"; }
mkproc 201 200   # luna-x → pane root 200
mkproc 200 1
mkproc 202 1     # echo-x is itself the pane root
mkproc 210 205   # nest-x → 205 (a pane) → 200 (also a pane); closest = 205
mkproc 205 200
mkproc 301 1     # morph-x (other socket)
mkproc 999 998   # lost-x: alive, chain has no pane
mkproc 998 1

# ── fixture: two tmux sockets + a branching tmux stub ────────────────────────
mkdir -p "$TMP/tmux" "$TMP/bin"
: > "$TMP/tmux/default"; : > "$TMP/tmux/dreamteam"
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
sock=""; subcmd=""; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -S) sock="$2"; shift 2;;
    list-panes|capture-pane) subcmd="$1"; shift;;
    -t) target="$2"; shift 2;;
    *) shift;;
  esac
done
sockname="$(basename "$sock")"
if [ "$subcmd" = list-panes ]; then
  case "$sockname" in
    default)   printf 'dream:2.1 200\ndream:2.2 202\ndream:2.3 500\ndream:2.4 600\ndream:2.5 205\n';;
    dreamteam) printf 'work:1.1 301\n';;
  esac
elif [ "$subcmd" = capture-pane ]; then
  case "$target" in
    dream:2.1) echo "LUNA_TAIL editing foo.py";;
    dream:2.2) echo "ECHO_TAIL running tests";;
    dream:2.3) echo "──────── @lead-x ────────";;   # box-dash footer → fallback matches
    dream:2.4) echo "roster: @guard-x is idle";;      # @name but NO box-dash → guard rejects
    dream:2.5) echo "NEST_TAIL migrating schema";;
    work:1.1)  echo "MORPH_TAIL refactoring";;
  esac
fi
EOF
chmod +x "$TMP/bin/tmux"

# ── fixture: stubbed roster.sh (prints canned --json; ignores args) ──────────
cat > "$TMP/roster.json" <<'EOF'
{"team":"t","counts":{},"agents":[
 {"name":"luna-x","status":"active","agentId":"luna-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":201},
 {"name":"echo-x","status":"active","agentId":"echo-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":202},
 {"name":"nest-x","status":"active","agentId":"nest-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":210},
 {"name":"morph-x","status":"active","agentId":"morph-x@t","cwd":"/home/jp/w","agentType":"dreamteam:morpheus","pid":301},
 {"name":"lead-x","status":"lead","agentId":"lead-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"team-lead","pid":null},
 {"name":"guard-x","status":"idle","agentId":"guard-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":null},
 {"name":"lost-x","status":"active","agentId":"lost-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":999},
 {"name":"ghost-x","status":"dead","agentId":"ghost-x@t","cwd":"/home/jp/Projects/dreamteam","agentType":"general-purpose","pid":null}
]}
EOF
cat > "$TMP/bin/roster-stub.sh" <<EOF
#!/bin/bash
cat "$TMP/roster.json"
EOF
chmod +x "$TMP/bin/roster-stub.sh"

run() { DREAMTEAM_TMUX_DIR="$TMP/tmux" DREAMTEAM_PROC="$TMP/proc" \
        DREAMTEAM_ROSTER="$TMP/bin/roster-stub.sh" CLAUDE_PLUGIN_ROOT="$ROOT" \
        PATH="$TMP/bin:$PATH" bash "$PEEK" "$@"; }

# ── pid-join: DESCENDANT case (agent pid is a child of the pane_pid) ─────────
out="$(run luna-x)"; rc=$?
[ "$rc" = 0 ] && ok "luna-x exit 0" || bad "luna-x exit=$rc"
echo "$out" | grep -q 'default@dream:2.1' && ok "luna-x pane via PPid descendant walk (201→200)" || bad "luna-x pane: $out"
echo "$out" | grep -q 'via pid' && ok "luna-x resolved_via pid" || bad "luna-x via"
echo "$out" | grep -q 'LUNA_TAIL' && ok "luna-x tail captured from the right pane" || bad "luna-x tail"

# ── pid-join: EXACT case (agent pid IS the pane_pid) ─────────────────────────
out="$(run echo-x)"
echo "$out" | grep -q 'default@dream:2.2' && ok "echo-x pane via exact pid==pane_pid" || bad "echo-x pane: $out"
echo "$out" | grep -q 'ECHO_TAIL' && ok "echo-x tail from right pane" || bad "echo-x tail"

# ── CLOSEST pane_pid wins (205 before its ancestor 200) — shadow guard ───────
out="$(run nest-x)"
echo "$out" | grep -q 'default@dream:2.5' && ok "nest-x resolves to CLOSEST pane 2.5 (not ancestor 2.1)" || bad "nest-x pane: $out"
echo "$out" | grep -q 'NEST_TAIL' && ok "nest-x tail from closest pane" || bad "nest-x tail"

# ── multi-socket sweep (agent lives on the 'dreamteam' server, not 'default') ─
out="$(run morph-x)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'dreamteam@work:1.1' && ok "morph-x found on 2nd socket (poke.sh's gap closed)" || bad "morph-x: $out"
echo "$out" | grep -q 'MORPH_TAIL' && ok "morph-x tail from 2nd-socket pane" || bad "morph-x tail"

# ── @handle FALLBACK (null pid → footer scan finds the box-dash @lead-x) ─────
out="$(run lead-x)"; rc=$?
[ "$rc" = 0 ] && ok "lead-x (null pid) exit 0 via fallback" || bad "lead-x exit=$rc"
echo "$out" | grep -q 'default@dream:2.3' && ok "lead-x pane via @handle footer scan" || bad "lead-x pane: $out"
echo "$out" | grep -q 'via handle' && ok "lead-x resolved_via handle" || bad "lead-x via"

# ── box-dash GUARD: a bare '@guard-x' (no box-dash) must NOT match ───────────
out="$(run --json guard-x)"; rc=$?
[ "$rc" = 3 ] && ok "guard-x not resolved (box-dash guard rejects bare @name) exit 3" || bad "guard-x exit=$rc"
echo "$out" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["found"] is False else 1)' \
  && ok "guard-x json found=false" || bad "guard-x json: $out"

# ── the three no-pane reasons, each exit 3 ───────────────────────────────────
out="$(run ghost-x 2>&1)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -qi 'dead' && ok "ghost-x → 'dead' reason, exit 3" || bad "ghost-x: rc=$rc $out"
out="$(run lost-x 2>&1)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -qi 'no tmux pane' && ok "lost-x → alive-but-no-pane, exit 3" || bad "lost-x: rc=$rc $out"
out="$(run no-such 2>&1)"; rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -qi 'not a current teammate' && ok "unknown → 'not a teammate', exit 3" || bad "unknown: rc=$rc $out"

# ── usage + ergonomics ───────────────────────────────────────────────────────
run --lines 5 >/dev/null 2>&1; [ $? = 22 ] && ok "no agent → usage exit 22" || bad "usage exit"
out="$(run @luna-x)"; echo "$out" | grep -q 'default@dream:2.1' && ok "leading '@' stripped (@luna-x == luna-x)" || bad "@-strip: $out"

# ── JSON contract (the guildmaster 'gm peek' consumer) ───────────────────────
J="$(run --json luna-x)"
echo "$J" | python3 -m json.tool >/dev/null 2>&1 && ok "--json valid JSON" || { bad "--json invalid: $J"; }
chk() { # jq-free: python assert key==value
  echo "$J" | KEY="$1" VAL="$2" python3 -c '
import json,os,sys
d=json.load(sys.stdin); k=os.environ["KEY"]; v=os.environ["VAL"]
sys.exit(0 if str(d.get(k))==v else 1)'; }
chk found True         && ok "json .found=true"           || bad "json found"
chk resolved_via pid   && ok "json .resolved_via=pid"     || bad "json via"
chk pane dream:2.1     && ok "json .pane=dream:2.1"        || bad "json pane"
chk resolved_pane default@dream:2.1 && ok "json .resolved_pane composed" || bad "json resolved_pane"
chk pid 201            && ok "json .pid=201 (int)"         || bad "json pid"
chk reason None        && ok "json .reason=null on success" || bad "json reason"
echo "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["lines"] and any("LUNA_TAIL" in l for l in d["lines"]) else 1)' \
  && ok "json .lines carries the captured tail" || bad "json lines"

# ── JSON negative contract ───────────────────────────────────────────────────
J="$(run --json ghost-x)"
echo "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d["found"] is False and d["reason"] and d["lines"]==[] and d["pane"] is None) else 1)' \
  && ok "json negative: found=false, reason set, lines=[], pane=null" || bad "json negative: $J"

echo "───────────────────────────────"
echo "pane-peek: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
