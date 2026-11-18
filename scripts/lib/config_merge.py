#!/usr/bin/env python3
"""dreamteam config + per-host overlay: the ONE parser every reader uses (xreview #230 r7).

The shell readers (scripts/lib/config.sh → mem-gate, mem-budget, overnight-guarded, lane-check) call this as a CLI, and
dashboard-data.sh imports it, so "is this file valid, and what does it say" has one answer everywhere (jq and Python
disagreed on leading-zero numbers like 03000, on NaN, and on what counts as one document).

  python3 config_merge.py <config.json>   → the merged config, one JSON object, on stdout
      exit 0  ok (with or without this host's overlay)
      exit 3  this host's overlay EXISTS (a dangling link counts), or its existence cannot be checked (EACCES), but
              is not one readable strict-JSON object: the base is printed,
              and callers must treat the config as invalid (the overlay may hold floors the base does not have)

Strict JSON: Python's json, plus NaN/Infinity rejected. A file must hold exactly one value, an object. The base, if
unreadable, is {} (every reader then uses its baked defaults). The overlay is deep-merged like jq `*`: objects merge
recursively, anything else is replaced. The host: DREAMTEAM_HOST, else the short hostname, lower-cased, and it must then
match ^[a-z0-9][a-z0-9-]{0,62}$ as is (never cleaned into another host's name); an invalid name takes no overlay.
"""
import decimal
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


def _exact_number(lit):
    """A JSON number with a fraction or an exponent, decided EXACTLY from its literal (xreview #230 r8):
    an integral value becomes an exact int (7.5e2 → 750, -0.0 → 0); a magnitude beyond 10^18, or below 10^-18, makes the
    file invalid (1e400 never becomes Infinity, and 1e400000000 is never built into an int); a non-integral value that a binary float would round to an integer (-1e-400 → -0.0, 3000.0000000000000001
    → 3000.0) makes the file invalid; any other fraction stays a float (the quota thresholds such as 0.70 need it)."""
    d = decimal.Decimal(lit)
    if not d.is_finite():
        raise ValueError(f"non-finite number {lit}")
    if d != 0 and abs(d.adjusted()) > 18:   # beyond 64-bit magnitude (or a vanishing fraction): never built into an int
        raise ValueError(f"number {lit} is out of range")
    if d == d.to_integral_value():
        return int(d)
    f = float(lit)
    if f != f or f in (float("inf"), float("-inf")) or f.is_integer():
        raise ValueError(f"number {lit} is not exactly what a float would read")
    return f


def _bounded_int(lit):
    """A JSON integer literal, bounded like every other number (xreview #230 r9): 10^19 or more in magnitude makes the
    file invalid before any int is built, so a 4000-digit literal costs nothing and never reaches a reader."""
    if len(lit.lstrip("-")) > 19:
        raise ValueError(f"integer {lit[:24]}… is out of range")
    n = int(lit)
    if abs(n) >= 10 ** 19:
        raise ValueError(f"integer {lit} is out of range")
    return n


def load_object(path):
    """The file's single JSON object, or raise."""
    with open(path, encoding="utf-8") as f:
        v = json.load(f, parse_constant=_reject_constant, parse_float=_exact_number, parse_int=_bounded_int)
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
    try:
        os.lstat(ov_path)   # only "no such file" means no overlay: EACCES, ELOOP and the rest mean unknown → invalid
    except FileNotFoundError:
        return base, ""
    except OSError:
        return base, "this host's overlay could not be checked"
    try:
        return deep(base, load_object(ov_path)), ""
    except Exception:
        return base, "this host's overlay exists but is not one readable JSON object"


if __name__ == "__main__":
    merged, err = load(sys.argv[1])
    json.dump(merged, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    sys.exit(3 if err else 0)
