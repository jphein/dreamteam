#!/usr/bin/env bash
# dreamteam — reliable per-agent ACTIVE/IDLE detector (real-time, cross-checked).
#
# WHY THIS EXISTS (the trap it fixes):
#   Two naive signals are each unreliable on their own —
#   1) The harness team-config `isActive` field can LAG (dreamteam #21: an "idle"
#      reading fires while the agent is still generating). fleet.sh's LIVE column
#      has the same disease from the other end (#41): it shows STALE latched hook
#      stamps ("working@1488m" for an agent that has long gone idle). Neither the
#      config flag nor a push-stamp is the truth — the LIVE PANE is.
#   2) A quick tmux-pane grep misreads state: the FOOTER line
#         "❯ Press up to edit queued m…"
#      means there is QUEUED INPUT (e.g. a poke) — it does NOT mean idle. The agent
#      is very often actively "thinking" WITH input queued on top. Grepping the footer
#      reports working agents as idle → the orchestrator over-pokes / miscounts idlers.
#
#   The reliable real-time activity signal is the SPINNER line (a spinner glyph + a
#   gerund + "…", e.g. "✶ Computing… (thinking)" / "✻ Beboppin'… (5m 3s)"), or the
#   "esc to interrupt" hint — NOT the footer. An IDLE agent shows a past-tense
#   "✻ Brewed for 3m" completion + a bare "❯" prompt and NO "…" spinner.
#
#   This tool reports BOTH signals per agent, trusts the live PANE for the verdict,
#   flags DISAGREEMENT (stale isActive), and reports `queued` separately.
#
# PANE RESOLUTION — UNIFIED on PID-ANCESTRY (Oracle #41: three overlapping resolvers
#   — poke.sh @handle match, this tool's old @handle match, pane-peek's pid-ancestry —
#   collapsed onto the collision-resistant one). We take ONE `ps -ww` snapshot, match
#   each member's `agent-id <id>` token to its pid (same technique as roster.sh; pid
#   found ⇒ alive, gives us the pid for the walk), sweep EVERY tmux socket under
#   $TMUXDIR for a pane_pid→pane map, then walk the agent pid's PPid chain (via /proc)
#   until the FIRST (closest) pane_pid matches — reusing pane-peek.sh/fleet.sh's proven
#   pane_of(). Closest-wins so a shared ancestor (tmux-server/orchestrator) can never
#   shadow the agent's own pane, and the all-sockets sweep sees agents on the
#   `-L dreamteam` server too. The old @handle-footer match is kept ONLY as a fallback
#   for a pid-walk miss (wrapped shell / detached pane) — it is no longer the primary,
#   so the socket-wide false-match that bit poke.sh (#28/#35, two 'manager' windows)
#   can't drive the verdict.
#
# Usage: agent-activity.sh [--team NAME] [--json]
#   (no args = most-recently-updated team, human-readable)
# Seams (tests): DREAMTEAM_TEAMS_DIR, DREAMTEAM_TMUX_DIR, DREAMTEAM_PROC; ps/tmux
#   resolve via PATH (stubbable). No production state is read or written.
set -uo pipefail
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"
TMUXDIR="${DREAMTEAM_TMUX_DIR:-/tmp/tmux-$(id -u)}"
PROC="${DREAMTEAM_PROC:-/proc}"
TEAM=""; FMT="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2;;
    --json) FMT="json"; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) shift;;
  esac
done

python3 - "$TEAMS_DIR" "$TEAM" "$FMT" "$TMUXDIR" "$PROC" <<'PY'
import json, os, sys, glob, re, subprocess

teams_dir, team, fmt, tmuxdir, proc = sys.argv[1:6]

def sh(*a):
    try: return subprocess.run(a, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True).stdout
    except Exception: return ""

# --- pick config (most-recently-updated team unless named) ---
cfgs = []
if team:
    p = os.path.join(teams_dir, team, "config.json")
    if os.path.exists(p): cfgs = [p]
if not cfgs and not team:
    allc = glob.glob(os.path.join(teams_dir, "*", "config.json"))
    cfgs = sorted(allc, key=os.path.getmtime, reverse=True)[:1]

# --- ONE ps snapshot; match each member's agent-id → pid (roster.sh's technique) ---
# -ww = unlimited width so a long claude cmdline never truncates the agent-id off the
# end. pid found ⇒ the agent process is live AND we have its pid for the PPid walk.
SNAP = sh("ps", "-ww", "-eo", "pid,args")
def pid_for(aid):
    if not aid: return None
    needle = "agent-id %s" % aid                 # id carries @session-…, can't prefix-collide
    for line in SNAP.splitlines():
        if needle in line:
            head = line.split(None, 1)[0]
            if head.isdigit(): return int(head)
    return None

# --- sweep EVERY socket → pane_pid map (+ a (sock,addr) list for the footer fallback) ---
pane_addr = {}          # pane_pid(str) -> (sock, addr)
panes = []              # [(sock, addr, pane_pid)]
if os.path.isdir(tmuxdir):
    for sock in sorted(glob.glob(os.path.join(tmuxdir, "*"))):
        out = sh("tmux", "-S", sock, "list-panes", "-a", "-F",
                 "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}")
        for line in out.splitlines():
            line = line.strip()
            if not line: continue
            addr, _, ppid = line.rpartition(" ")   # split on LAST space (sessions w/ spaces)
            if not ppid: continue
            pane_addr[ppid] = (sock, addr)
            panes.append((sock, addr, ppid))

def read_ppid(p):
    try:
        with open(os.path.join(proc, p, "status")) as f:
            for ln in f:
                if ln.startswith("PPid:"): return ln.split()[1]
    except Exception: pass
    return None

def pane_of(pid):
    # Walk the PPid chain until the FIRST pane_pid matches (max 20 hops). fleet.sh's pane_of.
    p = str(pid); hops = 0
    while p not in ("0", "1", "", None) and hops < 20:
        if p in pane_addr: return pane_addr[p]
        p = read_ppid(p)
        if not p: return None
        hops += 1
    return None

def cap(sock, addr, scroll):
    return sh("tmux", "-S", sock, "capture-pane", "-p", "-t", addr, "-S", str(scroll))

def handle_pane(name):
    # Fallback ONLY: scan each pane's FOOTER for the box-dash-flanked "@name ─" line
    # (poke.sh's guard). Used when the pid-walk finds no pane (wrapped shell / detached).
    for sock, addr, _ in panes:
        foot = cap(sock, addr, -6)
        if re.search(r"@%s\b" % re.escape(name), foot) and "─" in foot:
            return (sock, addr)
    return None

SPIN = "·✻✶✽✢✳●✷◐◓◑◒*✺"
SPIN_SET = set(SPIN)
def classify(body):
    # Examine only the MOST RECENT status line — NOT any glyph line in the window.
    # A stale "…thinking" line can linger above a newer "✻ Churned for 3m" completion;
    # matching "any ellipsis in the window" (the original bug) false-reports IDLE as ACTIVE.
    lines = [l for l in body.splitlines() if l.strip()]
    queued = any("Press up to edit queued" in l for l in lines[-12:])
    # "esc to interrupt" only counts if it's in the last few lines (current generation)
    if any("esc to interrupt" in l for l in lines[-4:]):
        return "ACTIVE", queued
    # most recent line that starts (after indent) with a spinner glyph = the live status
    status = None
    for l in reversed(lines):
        s = l.strip()
        if s and s[0] in SPIN_SET:
            status = s; break
    if status is None:
        return "IDLE", queued                      # sitting at a bare prompt
    # present-progressive ("Billowing… (1m 3s)") = ACTIVE; past-tense ("Churned for 3m") = IDLE.
    # NB: the "…" test is UNICODE-ONLY (U+2026) BY DESIGN (#38 nit 1) — real Claude Code
    # panes always render the ellipsis as "…", so an ASCII "..." line is NOT a live Claude
    # spinner (non-Claude pane / copied text) and is correctly treated as not-active. Widen
    # this only if a real pane is ever seen emitting ASCII dots (none has), and update the
    # test in lockstep — tests/test-agent-activity.sh pins ASCII "..." ⇒ IDLE.
    if "…" in status and " for " not in status:
        return "ACTIVE", queued
    return "IDLE", queued

rows = []
for cfg in cfgs:
    try: data = json.load(open(cfg))
    except Exception: continue
    tname = os.path.basename(os.path.dirname(cfg))
    for m in data.get("members", []):
        if m.get("agentType") == "team-lead": continue
        aid = m.get("agentId",""); name = m.get("name","?")
        pid = pid_for(aid)
        if not aid or pid is None:
            # #38 nit 2: DEAD rows carry the same `team` key alive rows do (consumers
            # that key on team — e.g. manager roles / roster-live.sh — no longer see a gap).
            rows.append({"name":name,"team":tname,"verdict":"DEAD","isActive":m.get("isActive"),
                         "pid":None,"pane":None,"pane_state":None,"queued":False}); continue
        loc = pane_of(pid) or handle_pane(name)
        pane_state, queued = (None, False)
        pane_disp = None
        if loc:
            sock, addr = loc
            pane_disp = "%s@%s" % (os.path.basename(sock), addr)
            pane_state, queued = classify(cap(sock, addr, -14))
        is_active = bool(m.get("isActive"))
        # verdict: trust the live pane; flag disagreement with config isActive
        if pane_state is None:
            verdict = ("ACTIVE" if is_active else "IDLE") + "?(no-pane)"
        elif pane_state == "ACTIVE" and not is_active:
            verdict = "ACTIVE ⚠stale-isActive(cfg=idle)"
        elif pane_state == "IDLE" and is_active:
            verdict = "IDLE ⚠isActive=busy(between-rounds?)"
        else:
            verdict = pane_state
        rows.append({"name":name,"team":tname,"verdict":verdict,"isActive":is_active,
                     "pid":pid,"pane":pane_disp,"pane_state":pane_state,"queued":queued})

if fmt == "json":
    print(json.dumps(rows)); sys.exit(0)

if not rows: print("no live team members found"); sys.exit(0)
w = max(len(r["name"]) for r in rows)
print("agent activity (verdict trusts the live pane; ⚠ = disagrees with config isActive):")
for r in rows:
    q = " [queued-input]" if r["queued"] else ""
    pane = r["pane"] or "-"
    print("  • %-*s  %-34s  cfg.isActive=%-5s pane=%-6s %s%s" % (
        w, r["name"], r["verdict"], str(r["isActive"]), str(r["pane_state"]), pane, q))
PY
