#!/usr/bin/env bash
# pane-peek.sh — observer diagnostic: show what a (possibly non-responding) teammate
# is ACTUALLY doing, by joining the roster to its live tmux pane and dumping the tail.
#
# WHY: SendMessage delivery queues until the TARGET's next tool round, so the
# orchestrator can't tell *stuck* from *mid-tool-chain* from a silent teammate
# (project_sendmessage_unreliable). SKILL.md § Pane visibility prescribes a MANUAL
# `tmux capture-pane` to see ground truth; this automates it into one verb. It is the
# read-only twin of scripts/poke.sh (which TYPES into a pane): peek observes, never acts.
#
# HOW IT RESOLVES THE PANE (two joins, pid-truth first, footer-text fallback):
#   1. PID-ancestry (primary, unambiguous): `roster.sh --json` maps the agent NAME to
#      its `pid` (the process carrying `--agent-id <id>`). We sweep EVERY tmux socket
#      under $TMUXDIR, build pane_pid→pane, then walk the agent pid's PPid chain until
#      the FIRST (closest) pane_pid matches — reusing scripts/fleet.sh's proven
#      technique. Closest-wins so a shared ancestor (orchestrator/tmux-server) can
#      never shadow the agent's own pane. Verified on the live harness: the agent's
#      claude IS the pane's root process (pane_pid == roster pid), but the walk also
#      handles a wrapped-shell pane (pid a DESCENDANT of pane_pid) per issue #22.
#   2. @handle footer (fallback): when there's no pid (e.g. the lead) or the walk finds
#      no pane, scan each pane's FOOTER (poke.sh's technique: capture -S -5, require the
#      box-dash-flanked "@<name>" so a roster listing higher in a pane can't false-hit).
#      The footer carries the UNIQUE agent name, so it disambiguates across sessions
#      where pane TITLES (agentType only, e.g. "dreamteam:lucid") collide.
#
# Multi-socket: agents live on the `default` server AND a `-L dreamteam` server; the
# latter may not exist. We iterate the socket FILES ($TMUXDIR/*) so an absent server is
# simply skipped, never an error — a gap in poke.sh, which only saw the default socket.
#
# OBSERVER-ONLY: this script only reads — `tmux list-panes`, `tmux capture-pane`, the
# roster, and /proc. It never types into, terminates, or otherwise mutates a pane. The
# test suite enforces this by asserting no pane-mutating tmux verb appears in the code.
#
# Usage: pane-peek.sh [--lines N] [--team NAME] [--json] <agent-name>
#   --lines N   lines of scrollback tail to capture (default 50; issue #22's -S -50).
#   --team NAME roster team to resolve against (default: newest — roster.sh's default).
#   --json      machine output (contract for guildmaster `gm peek`); else human text.
#   <agent>     teammate name (a leading '@' is stripped, so `@luna` == `luna`).
# Exit: 0 pane found & captured · 3 no live pane (dead / not in tmux / unknown) · 22 usage.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── seams (mirror fleet.sh / roster.sh; all stubbable in tests) ──────────────
TMUXDIR="${DREAMTEAM_TMUX_DIR:-/tmp/tmux-$(id -u)}"
PROC="${DREAMTEAM_PROC:-/proc}"
ROSTER="${DREAMTEAM_ROSTER:-$ROOT/scripts/roster.sh}"

LINES=50; TEAM=""; FMT="human"; AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lines) LINES="${2:-50}"; shift 2;;
    --team)  TEAM="${2:-}"; shift 2;;
    --json)  FMT="json"; shift;;
    -h|--help) sed -n '2,45p' "$0"; exit 0;;
    --) shift; break;;
    -*) echo "pane-peek: unknown option '$1'" >&2; exit 22;;
    *) AGENT="$1"; shift;;
  esac
done
[ $# -gt 0 ] && [ -z "$AGENT" ] && { AGENT="$1"; shift; }
AGENT="${AGENT#@}"                                  # tolerate `@name`
case "$LINES" in ''|*[!0-9]*) LINES=50;; esac       # guard non-numeric --lines
[ -n "$AGENT" ] || { echo "usage: pane-peek.sh [--lines N] [--team NAME] [--json] <agent-name>" >&2; exit 22; }

# ── 1. roster: NAME → { pid, status, cwd } (authoritative, reuses roster.sh) ──
roster_json="$(bash "$ROSTER" --json ${TEAM:+--team "$TEAM"} 2>/dev/null || true)"
# found(0/1) pid(int|-) status(token) cwd(rest); cwd last so a spaced path stays intact.
read -r R_FOUND R_PID R_STATUS R_CWD < <(
  printf '%s' "$roster_json" | python3 -c '
import json,sys
name=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: d={}
for a in d.get("agents",[]):
    if a.get("name")==name:
        print("1", a.get("pid") if isinstance(a.get("pid"),int) else "-",
              a.get("status") or "-", a.get("cwd") or "-"); break
else:
    print("0","-","-","-")
' "$AGENT" 2>/dev/null || echo "0 - - -")
R_FOUND="${R_FOUND:-0}"; R_PID="${R_PID:--}"; R_STATUS="${R_STATUS:--}"; R_CWD="${R_CWD:--}"

# ── 2. sweep every socket → pane_pid map + a (sock,addr) list for the fallback ─
declare -A PANE_ADDR                                # pane_pid → "sock\taddr"
PANES=()                                            # "sock\taddr\tpane_pid"
if [ -d "$TMUXDIR" ]; then
  for sock in "$TMUXDIR"/*; do
    [ -S "$sock" ] || [ -e "$sock" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ppid="${line##* }"; addr="${line% *}"         # split on LAST space (session names w/ spaces)
      [ -n "$ppid" ] || continue
      PANE_ADDR["$ppid"]="$sock"$'\t'"$addr"
      PANES+=("$sock"$'\t'"$addr"$'\t'"$ppid")
    done < <(tmux -S "$sock" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null || true)
  done
fi

# Walk a pid's PPid chain until the FIRST pane_pid matches (max 20 hops). fleet.sh's pane_of.
pane_of() {
  local p="$1" hops=0 ppid
  while [ "$p" != "0" ] && [ "$p" != "1" ] && [ $hops -lt 20 ]; do
    [ -n "${PANE_ADDR[$p]:-}" ] && { printf '%s' "${PANE_ADDR[$p]}"; return 0; }
    ppid="$(awk '/^PPid:/{print $2}' "$PROC/$p/status" 2>/dev/null)" || return 1
    [ -n "$ppid" ] || return 1
    p="$ppid"; hops=$((hops+1))
  done
  return 1
}

# ── 3. resolve the pane: pid-ancestry first, then @handle footer ──────────────
SOCK=""; ADDR=""; VIA=""
if [ "$R_PID" != "-" ]; then
  if hit="$(pane_of "$R_PID")"; then
    SOCK="${hit%%$'\t'*}"; ADDR="${hit##*$'\t'}"; VIA="pid"
  fi
fi
if [ -z "$ADDR" ]; then                             # fallback: footer @handle scan
  for entry in "${PANES[@]:-}"; do
    [ -n "$entry" ] || continue
    esock="${entry%%$'\t'*}"; rest="${entry#*$'\t'}"; eaddr="${rest%%$'\t'*}"
    # footer-only (-S -5) + box-dash guard: the "──── @name ────" line, not a listing.
    if tmux -S "$esock" capture-pane -p -t "$eaddr" -S -5 2>/dev/null \
         | grep -F "@${AGENT}" | grep -q '─'; then
      SOCK="$esock"; ADDR="$eaddr"; VIA="handle"; break
    fi
  done
fi

# ── 4a. no pane: explain WHY (dead vs. no-pane vs. unknown), exit 3 ───────────
if [ -z "$ADDR" ]; then
  if [ "$R_FOUND" = "1" ] && [ "$R_STATUS" = "dead" ]; then
    reason="agent '$AGENT' is dead (no live process)"
  elif [ "$R_FOUND" = "1" ] && [ "$R_PID" != "-" ]; then
    reason="agent '$AGENT' is alive (pid $R_PID) but has no tmux pane"
  elif [ "$R_FOUND" = "1" ]; then
    reason="agent '$AGENT' is in the roster but not attached to a tmux pane"
  else
    reason="no live pane found for '$AGENT' (not a current teammate / not in tmux)"
  fi
  if [ "$FMT" = "json" ]; then
    R_PID="$R_PID" R_STATUS="$R_STATUS" R_CWD="$R_CWD" AGENT="$AGENT" REASON="$reason" \
    python3 -c '
import json,os
def norm(v): return None if v in ("","-") else v
print(json.dumps({"agent":os.environ["AGENT"],"found":False,"resolved_via":None,
  "status":norm(os.environ["R_STATUS"]) or "unknown","pid":(int(os.environ["R_PID"]) if os.environ["R_PID"].isdigit() else None),
  "cwd":norm(os.environ["R_CWD"]),"socket":None,"pane":None,"lines":[],"reason":os.environ["REASON"]}))'
  else
    echo "pane-peek: $reason" >&2
  fi
  exit 3
fi

# ── 4b. capture the tail; strip trailing blank rows (idle panes end in blanks) ─
TAIL="$(tmux -S "$SOCK" capture-pane -p -t "$ADDR" -S -"$LINES" 2>/dev/null || true)"
TAIL="$(printf '%s\n' "$TAIL" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}')"
DISP_ADDR="$(basename "$SOCK")@${ADDR}"
DISP_STATUS="$R_STATUS"; [ "$DISP_STATUS" = "-" ] && DISP_STATUS="unknown"
DISP_CWD="$R_CWD"; [ "$DISP_CWD" = "-" ] && DISP_CWD=""

if [ "$FMT" = "json" ]; then
  R_PID="$R_PID" R_STATUS="$DISP_STATUS" R_CWD="$R_CWD" AGENT="$AGENT" \
  SOCK="$SOCK" ADDR="$ADDR" VIA="$VIA" TAIL="$TAIL" \
  python3 -c '
import json,os
def norm(v): return None if v in ("","-") else v
print(json.dumps({"agent":os.environ["AGENT"],"found":True,"resolved_via":os.environ["VIA"],
  "status":norm(os.environ["R_STATUS"]) or "unknown","pid":(int(os.environ["R_PID"]) if os.environ["R_PID"].isdigit() else None),
  "cwd":norm(os.environ["R_CWD"]),"socket":os.environ["SOCK"],"pane":os.environ["ADDR"],
  "resolved_pane":os.path.basename(os.environ["SOCK"])+"@"+os.environ["ADDR"],
  "lines":os.environ["TAIL"].split("\n") if os.environ["TAIL"] else [],"reason":None}))'
else
  echo "── pane-peek @${AGENT} · ${DISP_STATUS} · ${DISP_ADDR} · via ${VIA}${DISP_CWD:+ · $DISP_CWD} ──"
  printf '%s\n' "$TAIL"
fi
exit 0
