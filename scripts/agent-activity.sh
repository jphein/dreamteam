#!/usr/bin/env bash
# dreamteam — reliable per-agent ACTIVE/IDLE detector (real-time, cross-checked).
#
# WHY THIS EXISTS (the trap it fixes):
#   Two naive signals are each unreliable on their own —
#   1) The harness team-config `isActive` field can LAG (dreamteam #21: an "idle"
#      reading fires while the agent is still generating).
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
# Usage: agent-activity.sh [--team NAME] [--json]
#   (no args = most-recently-updated team, human-readable)
set -uo pipefail
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"
TEAM=""; FMT="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2;;
    --json) FMT="json"; shift;;
    *) shift;;
  esac
done

python3 - "$TEAMS_DIR" "$TEAM" "$FMT" <<'PY'
import json, os, sys, glob, re, subprocess

teams_dir, team, fmt = sys.argv[1:4]

def sh(*a):
    try: return subprocess.run(a, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True).stdout
    except Exception: return ""

def alive(aid):
    return subprocess.run(["pgrep","-f","agent-id %s" % re.escape(aid)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

# --- pick config (most-recently-updated team unless named) ---
cfgs = []
if team:
    p = os.path.join(teams_dir, team, "config.json")
    if os.path.exists(p): cfgs = [p]
if not cfgs and not team:
    allc = glob.glob(os.path.join(teams_dir, "*", "config.json"))
    cfgs = sorted(allc, key=os.path.getmtime, reverse=True)[:1]

# --- index panes once: map "@handle" -> "sess:win.pane" (footer match, like poke.sh) ---
panes = [l for l in sh("tmux","list-panes","-a","-F","#{session_name}:#{window_index}.#{pane_index}").splitlines() if l]
handle_pane = {}
pane_body = {}
for p in panes:
    foot = sh("tmux","capture-pane","-p","-t",p,"-S","-6")
    m = re.search(r"@([A-Za-z0-9_-]+)\s*─", foot)   # box-dash-flanked footer handle
    if m: handle_pane.setdefault(m.group(1), p)

SPIN = "·✻✶✽✢✳●✷◐◓◑◒*✺"
SPIN_SET = set(SPIN)
def classify(body):
    # Examine only the MOST RECENT status line — NOT any glyph line in the window.
    # A stale "…thinking" line can linger above a newer "✻ Churned for 3m" completion;
    # matching "any ellipsis in the window" (the original bug) false-reports IDLE as ACTIVE.
    lines = [l for l in body.splitlines() if l.strip()]
    tail_lines = lines[-12:]
    queued = any("Press up to edit queued" in l for l in tail_lines)
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
    # present-progressive ("Billowing… (1m 3s)") = ACTIVE; past-tense ("Churned for 3m") = IDLE
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
        if not aid or not alive(aid):
            rows.append({"name":name,"verdict":"DEAD","isActive":m.get("isActive"),
                         "pane":None,"pane_state":None,"queued":False}); continue
        p = handle_pane.get(name)
        pane_state, queued = (None, False)
        if p:
            pane_state, queued = classify(sh("tmux","capture-pane","-p","-t",p,"-S","-14"))
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
                     "pane":p,"pane_state":pane_state,"queued":queued})

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
