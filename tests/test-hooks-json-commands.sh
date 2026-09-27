#!/usr/bin/env bash
# Every hooks.json command must resolve to a script that exists when the harness runs it via
# `bash -c` with CLAUDE_PLUGIN_ROOT set. Caught 2026-09-27 (lucid, dreamteam#95): the mode inside the
# quotes ("…/idle-assign.sh context") exits 127, and the script-level test could not see it.
#   tests/test-hooks-json-commands.sh [hooks.json]
set -u; ROOT=$(cd "$(dirname "$0")/.." && pwd); HJ=${1:-$ROOT/hooks/hooks.json}
python3 - "$HJ" "$ROOT" <<'PY'
import json, os, re, shlex, sys
hj, root = sys.argv[1], sys.argv[2]
cmds = [h["command"] for ev in json.load(open(hj))["hooks"].values() for g in ev for h in g.get("hooks", []) if h.get("type") == "command"]
bad = 0
for c in cmds:
    expanded = c.replace("${CLAUDE_PLUGIN_ROOT}", root)
    argv = shlex.split(expanded)
    script = argv[1] if argv and argv[0] == "bash" and len(argv) > 1 else None
    if not script or not os.path.isfile(script):
        print(f"  FAIL: {c!r} → script {script!r} does not exist"); bad += 1
print(f"{len(cmds)} hook commands checked, {bad} broken")
sys.exit(1 if bad else 0)
PY
