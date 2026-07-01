#!/usr/bin/env bash
# dreamteam — dashboard data collector for the live Artifact dashboard.
#
# Gathers the team's live state into the JSON contract consumed by
# templates/dashboard.html (window.DREAMTEAM_DATA). Reuses the SAME memory
# budget math as mem-budget.sh / mem-gate.sh so the dashboard and the spawn
# gate never disagree.
#
# Usage:
#   dashboard-data.sh                      # print the JSON snapshot (default)
#   dashboard-data.sh --team NAME          # pin a specific team (else newest)
#   dashboard-data.sh --inject [TEMPLATE]  # print the full HTML with data
#                                          #   injected between the markers
#                                          #   (TEMPLATE defaults to the bundled
#                                          #    templates/dashboard.html)
#
# Then deploy the --inject output via the Artifact tool (favicon: 🕯️).
# PRs come from `gh pr list` run in $DREAMTEAM_REPO (default: the cwd).
# "pending" timeline items are read from $ROOT/state/pending.txt (one per line)
# if present — the orchestrator can drop notes there; otherwise it's empty.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"
STATE="${DREAMTEAM_STATE:-$ROOT/state}"
# Consumer repo for PRs/tags: env override, else the cwd — the orchestrator runs
# from the repo it's orchestrating (was a candela hardcode; flagged in the
# 2026-07-01 audit as project-specific for a generic plugin).
REPO="${DREAMTEAM_REPO:-$PWD}"
TEMPLATE_DEFAULT="$ROOT/templates/dashboard.html"

TEAM=""; MODE="json"; TEMPLATE="$TEMPLATE_DEFAULT"
while [ $# -gt 0 ]; do
  case "$1" in
    --team)   TEAM="${2:-}"; shift 2;;
    --inject) MODE="inject"
              if [ "${2:-}" ] && [ "${2#--}" = "${2}" ]; then TEMPLATE="$2"; shift 2; else shift; fi;;
    --json)   MODE="json"; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) shift;;
  esac
done

export DT_ROOT="$ROOT" DT_CFG="$CFG" DT_TEAMS_DIR="$TEAMS_DIR" DT_STATE="$STATE" \
       DT_REPO="$REPO" DT_TEAM="$TEAM" DT_MODE="$MODE" DT_TEMPLATE="$TEMPLATE"

python3 - <<'PY'
import json, os, re, glob, socket, subprocess
from datetime import datetime, timezone

ROOT      = os.environ["DT_ROOT"]
CFG       = os.environ["DT_CFG"]
TEAMS_DIR = os.environ["DT_TEAMS_DIR"]
STATE     = os.environ["DT_STATE"]
REPO      = os.environ["DT_REPO"]
TEAM      = os.environ["DT_TEAM"]
MODE      = os.environ["DT_MODE"]
TEMPLATE  = os.environ["DT_TEMPLATE"]

def run(cmd, cwd=None, timeout=15):
    try:
        return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout,
                              text=True).stdout
    except Exception:
        return ""

# ── config (same keys/defaults as mem-budget.sh) ───────────────────────────
cfg = {}
try: cfg = json.load(open(CFG)).get("memory", {})
except Exception: cfg = {}
def m(k, d):
    try: return int(cfg.get(k, d))
    except Exception: return d
PER_AGENT = m("perAgentMB", 400);  HOST_RES = m("hostReserveMB", 6000)
BALLOON   = m("balloonReserveMB", 8000); MIN_AVAIL = m("minAvailableMB", 8000)
MAX_AGENTS= m("maxAgents", 30)

# ── memory (free -m: Mem/Swap rows) ────────────────────────────────────────
total=used=avail=swt=swu=0
for line in run(["free","-m"]).splitlines():
    p = line.split()
    if p and p[0]=="Mem:"  and len(p)>=7: total,used,avail = int(p[1]),int(p[2]),int(p[6])
    if p and p[0]=="Swap:" and len(p)>=4: swt,swu = int(p[1]),int(p[2])

# live claude agents + their total RSS (matches mem-gate.sh / spawn-accounting.sh)
nproc = run(["pgrep","-fc","claude/versions"]).strip()
live  = int(nproc) if nproc.isdigit() else 0
rss_total = 0
for line in run(["ps","-eo","rss,args"]).splitlines():
    if "claude/versions" in line and "pgrep" not in line:
        try: rss_total += int(line.split(None,1)[0])
        except Exception: pass
rss_total //= 1024  # KiB → MiB

# budget math — identical to mem-budget.sh
budget = max(0, (avail - HOST_RES - BALLOON) // PER_AGENT)
cap    = min(MAX_AGENTS, budget)
room   = max(0, cap - live)
if avail < MIN_AVAIL:
    cap = 0; room = 0

# thresholds + tier
red_below    = round(total * 0.10)               # earlyoom SIGTERM line (mem<=10%)
orange_below = MIN_AVAIL                          # dreamteam spawn floor
yellow_below = round(MIN_AVAIL * 1.5)             # caution band
if   avail < red_below:    tier = "Red"
elif avail < orange_below: tier = "Orange"
elif avail < yellow_below or room <= 0: tier = "Yellow"
else: tier = "Green"

# ── agent roster (AUTHORITATIVE via scripts/roster.sh) ──────────────────────
# roster.sh is the SINGLE source of truth for status + liveness (lead/active/
# idle/dead) AND the matched pid. Do NOT recompute any of that here — that drift
# produced the stale-roster bug. We only ENRICH each agent with dashboard-only
# fields: task (config prompt), branch (git), rssMb (ps, keyed on roster's pid).
# No pgrep / status logic remains in this file.
def pid_rss(pid):
    out = run(["ps","-o","rss=","-p",str(pid)]).strip()
    return int(out)//1024 if out.isdigit() else None

def branch_of(cwd):
    if not cwd or not os.path.isdir(cwd): return None
    b = run(["git","-C",cwd,"rev-parse","--abbrev-ref","HEAD"]).strip()
    return b or None

def task_of(prompt):
    s = re.sub(r"\s+"," ", prompt or "").strip()
    mt = re.search(r"task:\s*\*{0,2}(.+?)(\.\s|\*\*|$)", s, re.I)
    return ((mt.group(1) if mt else s)[:90]).strip() or None

# Ask roster.sh for the roster (pass --team through; else it selects the newest
# team config — identical selection to the old inline logic).
roster_cmd = ["bash", os.path.join(ROOT, "scripts", "roster.sh"), "--json"]
if TEAM: roster_cmd += ["--team", TEAM]
try: roster = json.loads(run(roster_cmd) or "{}")
except Exception: roster = {}
team_name = roster.get("team") or ""

# Map agentId -> prompt from the SAME config roster.sh resolved, for task text.
prompt_by_id = {}
if team_name:
    try:
        for mem_ in json.load(open(os.path.join(TEAMS_DIR, team_name, "config.json"))).get("members", []):
            prompt_by_id[mem_.get("agentId","")] = mem_.get("prompt","")
    except Exception: pass

# The dashboard pill contract is active|idle|dead — there is no 'lead' pill
# (dashboard.html: line-22 contract, .pill.* CSS, countByStatus). Project
# roster.sh's 'lead' onto 'active' (the orchestrator is the always-on session),
# preserving the prior output exactly. The lead/idle/dead DECISION still lives
# solely in roster.sh; this is presentation only.
STATUS_MAP = {"lead": "active"}

agents = []
for a in roster.get("agents", []):
    aid = a.get("agentId") or ""
    cwd = a.get("cwd") or ""
    raw_status = a.get("status")
    pid = a.get("pid")            # authoritative — from roster.sh's single ps snapshot
    agents.append({
        "name": a.get("name") or aid or "?",
        "status": STATUS_MAP.get(raw_status, raw_status),
        "task": task_of(prompt_by_id.get(aid, "")),
        "worktree": cwd or None,
        "branch": branch_of(cwd),
        "agentId": aid or None,
        "pid": pid,
        "rssMb": pid_rss(pid) if pid else None,
    })

# ── pull requests (gh, run inside the repo) ────────────────────────────────
def ci_state(rollup):
    if not rollup: return "none"
    saw_pending = False
    for c in rollup:
        concl = (c.get("conclusion") or "").upper()
        st    = (c.get("status") or c.get("state") or "").upper()
        if concl in ("FAILURE","TIMED_OUT","CANCELLED","ERROR","ACTION_REQUIRED","STARTUP_FAILURE") or st in ("FAILURE","ERROR"):
            return "failure"
        if st in ("IN_PROGRESS","QUEUED","PENDING","WAITING","REQUESTED","EXPECTED") or (not concl and st not in ("SUCCESS","COMPLETED")):
            saw_pending = True
    return "pending" if saw_pending else "success"

prs = []
if os.path.isdir(REPO):
    raw = run(["gh","pr","list","--state","open","--limit","30","--json",
               "number,title,author,headRefName,statusCheckRollup,url,state"], cwd=REPO, timeout=25)
    try:
        for p in json.loads(raw or "[]"):
            prs.append({
                "number": p.get("number"),
                "title": p.get("title",""),
                "author": (p.get("author") or {}).get("login",""),
                "branch": p.get("headRefName",""),
                "ci": ci_state(p.get("statusCheckRollup")),
                "state": p.get("state","OPEN"),
                "url": p.get("url","#"),
            })
    except Exception:
        prs = []

# ── timeline ───────────────────────────────────────────────────────────────
shipped = []
if os.path.isdir(REPO):
    raw = run(["git","-C",REPO,"for-each-ref","refs/tags","--sort=-creatordate",
               "--count=6","--format=%(refname:short)|%(creatordate:iso-strict)|%(contents:subject)"])
    for line in raw.splitlines():
        parts = line.split("|",2)
        if not parts or not parts[0]: continue
        ref = parts[0]; at = parts[1] if len(parts)>1 else ""
        subj = (parts[2] if len(parts)>2 else "").strip()
        # strip a leading "chore(release): v1.6.0 — " style prefix to keep the tagline
        subj = re.sub(r"^[a-z]+(\([^)]*\))?:\s*", "", subj, flags=re.I)
        subj = re.sub(r"^v?\d+\.\d+\.\d+\s*[—-]\s*", "", subj)
        label = "%s — %s" % (ref, subj) if subj else ref
        shipped.append({"label": label[:80], "ref": ref, "at": at})

inflight = [{"label": "#%s %s" % (p["number"], p["title"]),
             "status": {"success":"CI passing","failure":"CI failing","pending":"CI running","none":"no checks"}.get(p["ci"], p["ci"]),
             "url": p["url"]} for p in prs]

pending = []
pf = os.path.join(STATE, "pending.txt")
if os.path.exists(pf):
    for ln in open(pf):
        ln = ln.strip()
        if ln and not ln.startswith("#"): pending.append({"label": ln})

# ── waydroid ───────────────────────────────────────────────────────────────
waydroid = bool(re.search(r"Session.*RUNNING", run(["waydroid","status"])))

# ── assemble ───────────────────────────────────────────────────────────────
out = {
    "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    "host": socket.gethostname(),
    "team": team_name or "—",
    "waydroidRunning": waydroid,
    "memory": {
        "totalMb": total, "usedMb": used, "availableMb": avail,
        "swapTotalMb": swt, "swapUsedMb": swu, "agentTotalRssMb": rss_total,
        "perAgentMb": PER_AGENT, "hostReserveMb": HOST_RES, "balloonReserveMb": BALLOON,
        "minAvailableMb": MIN_AVAIL, "maxAgents": MAX_AGENTS,
        "budget": budget, "cap": cap, "liveAgents": live, "room": room,
        "thresholds": {"redBelowMb": red_below, "orangeBelowMb": orange_below, "yellowBelowMb": yellow_below},
    },
    "tier": tier,
    "agents": agents,
    "prs": prs,
    "timeline": {"shipped": shipped, "inFlight": inflight, "pending": pending},
}

if MODE == "inject":
    try:
        html = open(TEMPLATE).read()
    except Exception as e:
        raise SystemExit("dashboard-data.sh: cannot read template %s (%s)" % (TEMPLATE, e))
    payload = json.dumps(out, indent=2).replace("</", "<\\/")   # never break out of <script>
    block = ("/* DREAMTEAM_DATA:BEGIN — injected %s by dashboard-data.sh */\n"
             "window.DREAMTEAM_DATA = %s;\n"
             "/* DREAMTEAM_DATA:END */") % (out["generatedAt"], payload)
    new, n = re.subn(r"/\* DREAMTEAM_DATA:BEGIN.*?DREAMTEAM_DATA:END \*/",
                     lambda _m: block, html, count=1, flags=re.S)
    if n == 0:
        raise SystemExit("dashboard-data.sh: injection markers not found in template")
    print(new)
else:
    print(json.dumps(out, indent=2))
PY
