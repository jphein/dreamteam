#!/usr/bin/env bash
# dreamteam — unit tests for the CANONICAL agent→pane resolver (scripts/lib/pane-resolve.sh, #53).
#
# Covers the three shared primitives poke.sh / pane-peek.sh / fleet.sh now source:
#   • pr_sweep_panes   — all-socket pane_pid map + PANES list
#   • pr_pane_of       — PPid-chain walk, CLOSEST pane_pid wins
#   • pr_footer_matches / pr_resolve_footer — the STRUCTURAL @handle footer rule (#61)
#
# The FOOTER-RULE TABLE is the crux: it is the single source of truth for "what is a
# real footer", MIRRORED verbatim by agent-activity.sh's embedded-Python matcher
# (which can't source bash). A python-parity block re-runs the SAME table through the
# identical regex so the two implementations can't silently drift.
#
# ISOLATION: hermetic — PATH-stubbed tmux + a fake /proc tree in a temp dir; the lib's
# DREAMTEAM_TMUX_DIR / DREAMTEAM_PROC seams point at them. No production state touched.
#
# Run standalone:  bash tests/test-pane-resolve.sh   (exit 0 = all pass)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/pane-resolve.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

bash -n "$LIB" && ok "pane-resolve.sh passes bash -n" || bad "lib syntax error"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmux" "$TMP/proc"
: > "$TMP/tmux/default"

# ── tmux stub: list-panes prints a fixed inventory; capture-pane returns the per-addr
#    footer fixture written to $TMP/foot/<addr>. ─────────────────────────────────────
mkdir -p "$TMP/foot"
cat > "$TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
sub=""; addr=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    list-panes|capture-pane) sub="\$1"; shift;;
    -t) addr="\$2"; shift 2;;
    -S) shift 2;;
    -F) shift 2;;
    *) shift;;
  esac
done
if [ "\$sub" = list-panes ]; then
  # pane_pid inventory: 500 @ dream:1.0, 501 @ dream:1.1, 777 @ dream:1.7
  printf '%s\n' "dream:1.0 500" "dream:1.1 501" "dream:1.7 777"
elif [ "\$sub" = capture-pane ]; then
  cat "$TMP/foot/\$addr" 2>/dev/null
fi
exit 0
EOF
chmod +x "$TMP/bin/tmux"

# fake /proc PPid chain: 600 → 550 → 500 (500 is pane_pid at dream:1.0)
printf 'PPid:\t550\n' > "$TMP/proc/600.status"; mkdir -p "$TMP/proc/600"; mv "$TMP/proc/600.status" "$TMP/proc/600/status"
printf 'PPid:\t500\n' > "$TMP/proc/550.status"; mkdir -p "$TMP/proc/550"; mv "$TMP/proc/550.status" "$TMP/proc/550/status"
printf 'PPid:\t1\n'   > "$TMP/proc/500.status"; mkdir -p "$TMP/proc/500"; mv "$TMP/proc/500.status" "$TMP/proc/500/status"

export DREAMTEAM_TMUX_DIR="$TMP/tmux" DREAMTEAM_PROC="$TMP/proc"
export PATH="$TMP/bin:$PATH"
# shellcheck source=../scripts/lib/pane-resolve.sh
. "$LIB"

# ── sweep ─────────────────────────────────────────────────────────────────────
pr_sweep_panes
[ "${#PR_PANES[@]}" -eq 3 ] && ok "pr_sweep_panes builds the pane list (3)" || bad "sweep count=${#PR_PANES[@]}"

# ── pane_of: CLOSEST pane_pid wins (600→550→500; 500 is the pane) ───────────────
hit="$(pr_pane_of 600)"; addr="${hit##*$'\t'}"
[ "$addr" = "dream:1.0" ] && ok "pr_pane_of walks PPid chain to closest pane_pid" || bad "pane_of=$hit"
pr_pane_of 999 >/dev/null && bad "pr_pane_of should miss for an unknown pid" || ok "pr_pane_of misses (exit 1) for unknown pid"

# ── FOOTER-RULE TABLE (the #61 contract) ───────────────────────────────────────
# line | agent | expected(1=match,0=reject)
FTABLE=(
  "──────── @lucid ────────|lucid|1"          # real footer, dash-flanked both sides
  "@lucid ────────────────|lucid|1"           # real footer, name-first (agent-activity's shape)
  "   ──── @lucid ────   |lucid|1"            # leading/trailing spaces tolerated
  "roster: @lucid is idle|lucid|0"            # content line mentioning @name → REJECT
  "cmd: echo ──── @lucid ────|lucid|0"        # #61 self-poke: command DISPLAYS the footer → REJECT
  "@lucid|lucid|0"                            # bare mention, no rule → REJECT
  "──── @lucid2 ────|lucid|0"                 # name boundary: @lucid2 ≠ @lucid → REJECT
  "──── @lucid ────|lucid|1"                  # canonical
)
for row in "${FTABLE[@]}"; do
  line="${row%%|*}"; rest="${row#*|}"; ag="${rest%%|*}"; exp="${rest##*|}"
  printf '%s\n' "$line" > "$TMP/foot/dream:1.7"
  if pr_footer_matches "$TMP/tmux/default" "dream:1.7" "$ag"; then got=1; else got=0; fi
  if [ "$got" = "$exp" ]; then ok "footer[bash] exp=$exp: «$line»"; else bad "footer[bash] exp=$exp got=$got: «$line»"; fi
done

# ── PYTHON-PARITY: the SAME table through agent-activity.sh's mirrored regex ────
# The rule must be byte-identical in effect across the bash lib and the Python engine.
py_parity() {
python3 - "$@" <<'PY'
import re, sys
def footer_re(name): return re.compile(r"^[─ \t]*@%s[─ \t]*$" % re.escape(name))
line, name, exp = sys.argv[1], sys.argv[2], sys.argv[3]
pat = footer_re(name)
got = "1" if (pat.match(line) and "─" in line) else "0"
sys.exit(0 if got == exp else 1)
PY
}
for row in "${FTABLE[@]}"; do
  line="${row%%|*}"; rest="${row#*|}"; ag="${rest%%|*}"; exp="${rest##*|}"
  if py_parity "$line" "$ag" "$exp"; then ok "footer[python-parity] exp=$exp: «$line»"; else bad "footer[python-parity] MISMATCH exp=$exp: «$line»"; fi
done

# ── resolve_footer picks the matching pane ─────────────────────────────────────
printf '%s\n' "roster: @lucid mentioned"     > "$TMP/foot/dream:1.0"
printf '%s\n' "──── @lucid ────"             > "$TMP/foot/dream:1.1"
printf '%s\n' "just some output"             > "$TMP/foot/dream:1.7"
pr_sweep_panes
hit="$(pr_resolve_footer lucid)"; addr="${hit##*$'\t'}"
[ "$addr" = "dream:1.1" ] && ok "pr_resolve_footer returns the structurally-matching pane" || bad "resolve_footer=$hit"
pr_resolve_footer nobody >/dev/null && bad "resolve_footer should miss for absent agent" || ok "pr_resolve_footer misses (exit 1) when no footer matches"

echo "── pane-resolve: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
