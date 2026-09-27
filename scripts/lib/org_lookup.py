"""dreamteam — org map lookup: agent name → department, human owner, escalation.

SOURCE OF TRUTH
  lexicon.realm.watch/catalog/agents.yaml (the fleet-wide durable-agent catalog).
  Its optional org fields — department, owner, escalates_to — are plain ids;
  the owning org resolves them (TechEMPOWER: techempower-admin/org/, which has
  its own validator). dreamteam only READS the catalog; it never writes it,
  and it never touches the harness team config.

OPTIONAL + BACKWARD-COMPATIBLE
  No catalog file, no PyYAML, an unparseable file, or no matching entry ⇒
  resolve() returns None and every caller emits exactly what it emitted before
  this module existed. Nothing here raises.

CATALOG PATH (first hit wins)
  1. $DREAMTEAM_AGENTS_CATALOG           ("off" disables the lookup entirely)
  2. config.json .org.agentsCatalog      (~ expanded)
  3. ~/Projects/lexicon.realm.watch/catalog/agents.yaml

RESOLUTION ORDER for an agent name such as "morpheus-org" or "money-e8"
  1. exact match on an entry's id or current_name
  2. a session-lane `match` glob (money-*, techempower-*, jp-*)
  3. the dream-name prefix before the FIRST hyphen, matched against id and
     current_name (the spawn gate splits names the same way)

ESCALATION
  escalates_to is a person id or another agent's id; the chain is followed
  through agents (cycle-safe) until it reaches a non-agent id = the human.
  If that human is listed in config.json .org.threeChannelOwners (default
  ["jp"]) the channel is "three-channel" (gnome-speaks + Slack DM + a bold
  block at the TOP of the reply — skill § REACHING JP); otherwise
  "slack+text" (a durable message plus the top-of-reply block).

STATUS
  lexicon does not validate `status`; by convention anything other than
  "active" (e.g. "proposed") is a designed-but-unapproved role. resolve()
  reports it and sets spawnable=false; enrich() adds `org_status` only then.
"""
import fnmatch
import json
import os

_DEFAULT_CATALOG = "~/Projects/lexicon.realm.watch/catalog/agents.yaml"
_cache = {}


def _root():
    env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env and os.path.exists(os.path.join(env, "config.json")):
        return env
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _config():
    try:
        with open(os.path.join(_root(), "config.json"), encoding="utf-8") as fh:
            return (json.load(fh) or {}).get("org") or {}
    except Exception:
        return {}


def catalog_path():
    env = os.environ.get("DREAMTEAM_AGENTS_CATALOG")
    if env is not None and env != "":
        return None if env.lower() == "off" else os.path.expanduser(env)
    cfg = _config().get("agentsCatalog")
    return os.path.expanduser(cfg or _DEFAULT_CATALOG)


def three_channel_owners():
    v = _config().get("threeChannelOwners")
    return v if isinstance(v, list) else ["jp"]


def load(path=None):
    """Return the list of agent dicts, or [] when unavailable (never raises)."""
    path = path or catalog_path()
    if not path or not os.path.isfile(path):
        return []
    try:
        mtime = os.path.getmtime(path)
        hit = _cache.get(path)
        if hit and hit[0] == mtime:
            return hit[1]
        import yaml  # optional dependency: absent ⇒ feature off
        with open(path, encoding="utf-8") as fh:
            # CSafeLoader when libyaml is present: this runs inside the reuse-gate
            # hook (via idle-agents.sh) whenever idle agents exist — keep it cheap.
            doc = yaml.load(fh, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader)) or {}
        agents = [a for a in (doc.get("agents") or []) if isinstance(a, dict) and a.get("id")]
        _cache[path] = (mtime, agents)
        return agents
    except Exception:
        return []


def _find(name, agents):
    if not name:
        return None
    n = name.strip().lower()
    for a in agents:
        if n in (str(a.get("id", "")).lower(), str(a.get("current_name", "")).lower()):
            return a
    for a in agents:
        m = a.get("match")
        if m and fnmatch.fnmatchcase(n, str(m).lower()):
            return a
    if "-" in n:
        prefix = n.split("-", 1)[0]
        for a in agents:
            if prefix in (str(a.get("id", "")).lower(), str(a.get("current_name", "")).lower()):
                return a
    return None


def resolve(name, agents=None):
    """name → {agent, department, owner, escalates_to, chain, human, channel} or None.

    Returns None unless the matched entry carries at least one org field, so a
    catalog without org data changes nothing downstream.
    """
    agents = load() if agents is None else agents
    a = _find(name, agents)
    if not a or not any(a.get(k) for k in ("department", "owner", "escalates_to")):
        return None
    by_id = {x["id"]: x for x in agents}
    chain, cur, seen = [a["id"]], a, {a["id"]}
    while cur is not None and cur.get("escalates_to"):
        nxt = cur["escalates_to"]
        chain.append(nxt)
        if nxt in seen:
            break
        seen.add(nxt)
        cur = by_id.get(nxt)
    # the chain ends at a human (a non-agent id); if it never gets there (no
    # escalates_to, or a cycle) the accountable human is the owner.
    human = chain[-1] if chain[-1] not in by_id else (a.get("owner") or None)
    out = {
        "agent": a["id"],
        "department": a.get("department") or None,
        "owner": a.get("owner") or None,
        "escalates_to": a.get("escalates_to") or None,
        "chain": chain[1:],
        "human": human,
        "channel": ("three-channel" if human in three_channel_owners() else "slack+text") if human else None,
        # lexicon does not validate status values; "proposed" (or anything other
        # than active) means the role is designed but NOT yet approved to spawn.
        "status": a.get("status") or None,
        "spawnable": bool(a.get("spawnable", True)) and (a.get("status") or "active") == "active",
    }
    return out


def enrich(row, name_key="name", agents=None):
    """Add org fields to a JSON row IN PLACE, only when resolved. Returns row."""
    info = resolve(row.get(name_key), agents)
    if info:
        row["department"] = info["department"]
        row["owner"] = info["owner"]
        row["escalates_to"] = info["escalates_to"]
        row["escalation"] = {"chain": info["chain"], "human": info["human"], "channel": info["channel"]}
        if info.get("status") and info["status"] != "active":
            row["org_status"] = info["status"]
    return row


def summary(info):
    """One human line: 'technology · owner jp · escalate sandman → jp (three-channel)'."""
    if not info:
        return ""
    parts = []
    if info.get("department"):
        parts.append(info["department"])
    if info.get("owner"):
        parts.append("owner " + info["owner"])
    if info.get("chain"):
        esc = " → ".join(info["chain"])
        if info.get("channel"):
            esc += " (%s)" % info["channel"]
        parts.append("escalate " + esc)
    line = " · ".join(parts)
    if info.get("status") and info["status"] != "active":
        line += " [%s — not yet spawnable]" % info["status"]
    return line
