#!/usr/bin/env python3
"""dreamteam config + per-host overlay: the ONE parser every reader uses (xreview #230 r7).

The shell readers (scripts/lib/config.sh → mem-gate, mem-budget, overnight-guarded, lane-check) call this as a CLI, and
dashboard-data.sh imports it, so "is this file valid, and what does it say" has one answer everywhere (jq and Python
disagreed on leading-zero numbers like 03000, on NaN, and on what counts as one document).

  python3 config_merge.py <config.json>   → the merged config, one JSON object, on stdout
      exit 0  ok (with or without this host's overlay)
      exit 3  this host's overlay EXISTS (a dangling link counts) but is not one strict-JSON object: the base is printed,
              and callers must treat the config as invalid (the overlay may hold floors the base does not have)

Strict JSON: Python's json, plus NaN/Infinity rejected. A file must hold exactly one value, an object. The base, if
unreadable, is {} (every reader then uses its baked defaults). The overlay is deep-merged like jq `*`: objects merge
recursively, anything else is replaced. The host: DREAMTEAM_HOST, else the short hostname, lower-cased, and it must then
match ^[a-z0-9][a-z0-9-]{0,62}$ as is (never cleaned into another host's name); an invalid name takes no overlay.
"""
import json
import os
import re
import socket
import sys


def host():
    h = os.environ.get("DREAMTEAM_HOST") or socket.gethostname().split(".")[0]
    h = h.lower()
    return h if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", h) else ""


def _reject_constant(name):
    raise ValueError(f"non-JSON constant {name}")


def load_object(path):
    """The file's single JSON object, or raise."""
    with open(path, encoding="utf-8") as f:
        v = json.load(f, parse_constant=_reject_constant)
    if not isinstance(v, dict):
        raise ValueError("not an object")
    return v


def deep(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = deep(a[k], v) if k in a else v
        return out
    return b


def load(cfg_path):
    """(merged config, error). error is "" or why this host's overlay could not be used (then the base is returned)."""
    try:
        base = load_object(cfg_path)
    except Exception:
        base = {}
    h = host()
    if not h:
        return base, ""
    ov_path = (cfg_path[:-5] if cfg_path.endswith(".json") else cfg_path) + "." + h + ".json"
    if not os.path.lexists(ov_path):
        return base, ""
    try:
        return deep(base, load_object(ov_path)), ""
    except Exception:
        return base, "this host's overlay exists but is not one readable JSON object"


if __name__ == "__main__":
    merged, err = load(sys.argv[1])
    json.dump(merged, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.exit(3 if err else 0)
