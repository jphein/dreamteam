#!/usr/bin/env bash
# dreamteam — authoritative team roster (harness team config + liveness).
#
# WHY THIS EXISTS / SOURCE OF TRUTH
#   The harness team config (~/.claude/teams/<team>/config.json) is the ONLY
#   complete, live roster: it lists EVERY member with { isActive, cwd, prompt },
#   maintained by the harness itself. The retired state/agents.json was lossy —
#   it only captured NEW spawns (never pre-existing members), never marked
#   idle/dead, and had a crash bug. This prints the TRUE roster from the config,
#   so injection (crash-audit.sh) and accounting (spawn-accounting.sh) stop
#   calling live agents "stale".
#
#   The status/liveness computation MIRRORS scripts/dashboard-data.sh (its
#   alive-by-agent-id check + status precedence) — the shared source of truth for
#   "who is live". Kept in lockstep on purpose: change one, change both.
#
# LIVENESS — matched by the `agent-id <id>` token in process args (an agent runs
#   with `--agent-id <id>`). See idle-agents.sh's header for the full rationale on
#   why pgrep-by-agent-id, not `claude agents --json` (the latter cannot see
#   in-process team subagents, so it would mark every teammate dead).
#   HOT PATH: this is called from spawn-accounting.sh (PostToolUse, fires on every
#   spawn), so we take ONE `ps -ww -eo pid,args` snapshot (-ww = unlimited width,
#   so a long cmdline never truncates the agent-id off the end) and test all
#   members against it in a single pass — not a pgrep per member.
#
# STATUS: lead (team-lead) · active (isActive:true & alive) · idle (alive &
#   !active — REUSABLE via SendMessage) · dead (!alive).
#
# Usage: roster.sh [--team NAME] [--json]   (default: newest team, human text)
#   --team defaults to the most-recently-modified team config (same selection
#   logic as idle-agents.sh / dashboard-data.sh). Always exits 0.
set -uo pipefail
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"

TEAM=""; FMT="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2;;
    --json) FMT="json"; shift;;
    -h|--help) sed -n '2,29p' "$0"; exit 0;;
    *) shift;;
  esac
done

python3 - "$TEAMS_DIR" "$TEAM" "$FMT" <<'PY'
import json, os, sys, glob, subprocess

teams_dir, team, fmt = sys.argv[1:4]

# ── pick config (same selection as idle-agents.sh / dashboard-data.sh) ──────
cfgs = []
if team:
    p = os.path.join(teams_dir, team, "config.json")
    if os.path.exists(p): cfgs = [p]
if not cfgs and not team:
    allc = glob.glob(os.path.join(teams_dir, "*", "config.json"))
    cfgs = sorted(allc, key=os.path.getmtime, reverse=True)[:1]

# ── ONE process snapshot; every member matched against it in a single pass ──
# -ww = unlimited width so a long claude cmdline never truncates the agent-id.
def ps_snapshot():
    try:
        return subprocess.run(["ps", "-ww", "-eo", "pid,args"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=10).stdout
    except Exception:
        return ""
SNAP = ps_snapshot()

def alive(agent_id):
    # the full `agent-id <id>` (id carries @session-…, so ids can't prefix-collide)
    return bool(agent_id) and ("agent-id %s" % agent_id) in SNAP

team_name = ""
agents = []
counts = {"lead": 0, "active": 0, "idle": 0, "dead": 0}
for cfgp in cfgs:
    team_name = os.path.basename(os.path.dirname(cfgp))
    try:
        data = json.load(open(cfgp))
    except Exception:
        continue
    for m in data.get("members", []):
        aid = m.get("agentId", "")
        if m.get("agentType") == "team-lead":
            status = "lead"
        elif not alive(aid):
            status = "dead"
        elif m.get("isActive") is True:
            status = "active"
        else:
            status = "idle"
        counts[status] = counts.get(status, 0) + 1
        agents.append({
            "name": m.get("name") or aid or "?",
            "status": status,
            "agentId": aid or None,
            "cwd": m.get("cwd") or None,
            "agentType": m.get("agentType") or None,
        })

if fmt == "json":
    print(json.dumps({"team": team_name or None, "counts": counts, "agents": agents}, indent=2))
    sys.exit(0)

if not agents:
    print("no team roster found (no team config under %s)" % teams_dir)
    sys.exit(0)
print("dreamteam roster — team '%s' (%d members: %d active, %d idle, %d dead)" % (
    team_name or "?", len(agents), counts["active"], counts["idle"], counts["dead"]))
for a in agents:
    print("  • %-24s %-7s %s" % (a["name"], a["status"], a["cwd"] or ""))
PY
