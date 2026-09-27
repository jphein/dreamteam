#!/usr/bin/env bash
# dreamteam — org-lookup.sh: "what department am I in, who owns me, who do I
# escalate to?" for one or more agent names, from lexicon's agents.yaml.
#
# Logic lives in scripts/lib/org_lookup.py (shared with roster-live.sh and
# idle-agents.sh); see its header for the catalog path, resolution order and
# the escalation-channel rule. OPTIONAL: no catalog / no match ⇒ no output,
# exit 0 — callers treat silence as "no org data", never as an error.
#
# Usage: org-lookup.sh NAME [NAME ...] [--json]
#   human:  <name>: <department> · owner <id> · escalate <a> → <human> (<channel>)
#   --json: {"<name>": {agent, department, owner, escalates_to, chain, human, channel} | null, ...}
# Seams: DREAMTEAM_AGENTS_CATALOG=<path>|off, CLAUDE_PLUGIN_ROOT (config.json .org).
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FMT="human"; NAMES=()
for a in "$@"; do
  case "$a" in
    --json) FMT="json";;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) NAMES+=("$a");;
  esac
done
[ "${#NAMES[@]}" -gt 0 ] || { echo "usage: org-lookup.sh NAME [NAME ...] [--json]" >&2; exit 22; }

ORG_LIB="$ROOT/scripts/lib" FMT="$FMT" python3 - "${NAMES[@]}" <<'PY'
import json, os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["ORG_LIB"])
import org_lookup as ol

names = sys.argv[1:]
agents = ol.load()
res = {n: ol.resolve(n, agents) for n in names}
if os.environ.get("FMT") == "json":
    print(json.dumps(res, indent=2))
    sys.exit(0)
for n in names:
    if res[n]:
        print("%s: %s" % (n, ol.summary(res[n])))
PY
