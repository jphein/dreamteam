#!/usr/bin/env bash
# dreamteam — idle-agent oracle + context-affinity scorer.
#
# Reads the harness-maintained team config(s) (~/.claude/teams/<team>/config.json),
# which carry per-member { isActive, cwd, prompt }. An agent that is alive but
# isActive:false is REUSABLE — assign it via SendMessage instead of spawning a
# fresh ~400 MB process. When a task is supplied, ranks idle agents by context
# affinity (same cwd = strong; shared task keywords = weak) so the orchestrator
# reuses the agent that already has the warmest context.
#
# LIVENESS SOURCE — why pgrep, not `claude agents --json`:
# `claude agents --json` tracks logical SESSIONS keyed by UUID. In-process team
# subagents (Agent-tool spawns — the reuse targets here) do NOT appear there as
# separate entries, and team config members carry no sessionId join key. So
# `claude agents` cannot see teammates; using it for liveness would mark every
# teammate "dead" and silently disable reuse. pgrep `--agent-id <id>` is the only
# source that sees in-process subagents — it stays. (`claude agents` IS used for
# the system-wide count in mem-gate.sh / mem-budget.sh, where it fits.)
#
# Usage:
#   idle-agents.sh [--team NAME] [--task "text"] [--json]
#   (no args = scan the most-recently-updated team, human-readable)
set -uo pipefail
TEAMS_DIR="${DREAMTEAM_TEAMS_DIR:-$HOME/.claude/teams}"

TEAM=""; TASK=""; FMT="human"
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2;;
    --task) TASK="${2:-}"; shift 2;;
    --json) FMT="json"; shift;;
    *) shift;;
  esac
done

ORG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" \
python3 - "$TEAMS_DIR" "$TEAM" "$TASK" "$FMT" <<'PY'
import json, os, sys, glob, re, subprocess

teams_dir, team, task, fmt = sys.argv[1:5]

def alive(agent_id):
    # an agent process runs with `--agent-id <id>` in its args
    return subprocess.run(["pgrep","-f","agent-id %s" % re.escape(agent_id)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

# pick config(s)
cfgs = []
if team:
    p = os.path.join(teams_dir, team, "config.json")
    if os.path.exists(p): cfgs = [p]
if not cfgs:
    all_cfgs = glob.glob(os.path.join(teams_dir, "*", "config.json"))
    # most-recently-modified team wins when none specified
    cfgs = sorted(all_cfgs, key=os.path.getmtime, reverse=True)[:1] if not team else []

STOP = set("the a an and or to of in on for with this that your you are is be it as by from at into will not do".split())
def toks(s): return {w for w in re.findall(r"[a-z0-9_./-]{3,}", (s or "").lower()) if w not in STOP}
ttoks = toks(task)

idle = []
for cfg in cfgs:
    try: data = json.load(open(cfg))
    except Exception: continue
    for m in data.get("members", []):
        if m.get("agentType") == "team-lead": continue
        if m.get("isActive") is True: continue          # busy
        aid = m.get("agentId","")
        if not aid or not alive(aid): continue           # dead/exited — not reusable
        prompt = m.get("prompt",""); cwd = m.get("cwd","")
        score = 0; why = []
        if task:
            if cwd and cwd in task: score += 50; why.append("same cwd")
            shared = ttoks & toks(prompt + " " + cwd)
            if shared: score += min(len(shared)*5, 45); why.append("kw:" + ",".join(sorted(shared)[:6]))
        # one-line context summary from the prompt
        summary = re.sub(r"\s+"," ", prompt).strip()
        m_task = re.search(r"task:\s*\*?\*?(.+?)(\.|\*\*|$)", summary, re.I)
        summary = (m_task.group(1) if m_task else summary)[:90]
        idle.append({"name": m.get("name"), "agentId": aid, "cwd": cwd,
                     "score": score, "why": "; ".join(why), "context": summary})

idle.sort(key=lambda x: -x["score"])

# org map (optional, lib/org_lookup.py): adds department/owner/escalates_to/escalation
# to a row ONLY when the agent resolves in lexicon agents.yaml. No catalog ⇒ unchanged.
# A row that resolves to a NON-spawnable role (orchestrator, local model such as
# ember, a proposed/non-active role, or spawnable:false) is NOT reusable: it is
# moved out of `idle` so neither --json nor the reuse gate can offer it, and is
# shown only in the human output's separate "not reusable" block with its flag.
held = []
try:
    sys.dont_write_bytecode = True   # plugin runs from the source tree: no __pycache__ litter
    sys.path.insert(0, os.environ.get("ORG_LIB") or "")
    import org_lookup as _ol
    _agents = _ol.load() if idle else []
    for a in idle:
        _ol.enrich(a, agents=_agents)
    if _agents:
        keep = []
        for a in idle:
            if a.get("spawnable") is False:
                held.append((a, _ol.spawn_flag(_ol.resolve(a.get("name"), _agents))))
            else:
                keep.append(a)
        idle = keep
except Exception:
    pass

def print_held():
    if not held: return
    print("not reusable (org map — assign nothing to these):")
    for a, flag in held:
        print("  • %-22s %s" % (a["name"], flag or "[not spawnable]"))

if fmt == "json":
    print(json.dumps(idle)); sys.exit(0)

if not idle:
    print("no reusable idle agents (all members busy, or none alive)"); print_held(); sys.exit(0)
print("reusable idle agents%s:" % (" (ranked by affinity to task)" if task else ""))
for a in idle:
    tag = ("  [score %d: %s]" % (a["score"], a["why"])) if task else ""
    print("  • %-22s cwd=%s%s" % (a["name"], a["cwd"] or "-", tag))
    print("      context: %s" % a["context"])
    if a.get("department") or a.get("owner"):
        print("      org:     %s" % " · ".join(x for x in (a.get("department"), a.get("owner") and "owner " + a["owner"]) if x))
print_held()
PY
