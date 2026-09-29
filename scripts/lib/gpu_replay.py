#!/usr/bin/env python3
"""dreamteam GPU fleet: replay the lanes' real Bash calls through the GPU guard, offline (`dreamteam gpu replay`).
Spec: docs/superpowers/specs/2026-09-29-gpu-fleet-design.md §5.3.

Why: plugin hooks load at session start, and every lane session alive on 2026-09-29 started before
gpu-guard reached main (09:40). So guard.log stays empty however many GPU launches happen, and a
"0 false positives" read from it is a zero from an instrument that cannot see. This replays what the
guard WOULD have decided on each teammate Bash/Monitor call in the transcripts: the same pre-filter
globs (on the JSON payload, as gpu-guard.sh matches it), then gpu_fleet.decide() with the lane's
identity.

Two uses:
  - `dreamteam gpu replay` (the false-positive review): an EMPTY claims ledger (the pre-seed state), so every
    detected launch is listed. `--claims` evaluates against the real ledger instead (read-only: the claims
    live at each command's own time). `--plugin <checkout>` replays another plugin version on the same window.
  - `dreamteam gpu board` (its guard section): incremental. A cache in the state dir keeps each transcript's
    read offset and the rows found so far, so a board run reads only what the lanes wrote since the last one.
    The cache is rebuilt when the day, the detection code, fleet.json, the pre-filter or the claims change,
    or when a transcript shrinks or is replaced.
Read-only apart from that cache: it never writes the ledger or guard.log and never touches a host.
"""
import argparse
import contextlib
import fcntl
import fnmatch
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
from collections import Counter, defaultdict
from datetime import datetime

SECRETISH = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|[A-Za-z0-9+/=_-]{40,})")
CACHE_VERSION = 1


def prefilter_of(plugin: str) -> list:
    """The pass patterns of THIS plugin version's gpu-guard.sh (its `case "$INPUT" in` block)."""
    src = open(os.path.join(plugin, "scripts", "gpu-guard.sh")).read()
    block = src.split('case "$INPUT" in', 1)[1].split("esac", 1)[0]
    pats = []
    for line in block.splitlines():
        line = re.sub(r"\)\s*;;\s*(#.*)?$", ") ;;", line.strip())    # a trailing comment is not a pattern
        if line.endswith(") ;;") and not line.startswith("*)"):
            # bash case quoting: *"sh "* and *bash\ * mean the literal text, so drop the quotes and escapes
            pats += [p.replace('"', "").replace("\\ ", " ") for p in line[:-len(") ;;")].split("|") if p]
    return pats


def local_epoch(s: str) -> float:
    return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M"))


def excerpt(c: str, n: int = 220) -> str:
    c = SECRETISH.sub("<redacted>", " ".join(c.split()))
    return c[:n] + ("…" if len(c) > n else "")


def transcripts(projects: str, t0: float) -> list:
    return sorted(f for f in glob.glob(os.path.join(projects, "**", "*.jsonl"), recursive=True)
                  if os.path.getmtime(f) >= t0)


def fresh(t0: float, key: str = "") -> dict:
    return {"v": CACHE_VERSION, "key": key, "since": t0, "offsets": {}, "calls": 0, "lanes": {}, "prefilter": 0,
            "launches": [], "misses": [], "seen": [], "decide_s": 0.0}


def collect(st: dict, files: list, t1: float, decide, fleet: dict, prefilter: list, takes_cwd: bool = True) -> dict:
    """Read each transcript from its recorded offset; add every teammate Bash/Monitor call in [since, t1) to st.
    Only complete lines are consumed, so a line the lane is still writing is read next time."""
    cfg = {"gpu": {"guard": "warn"}}
    seen = set(st["seen"])
    lanes = Counter(st["lanes"])
    t0 = st["since"]
    for f in files:
        try:
            ino = os.stat(f).st_ino
        except OSError:
            continue
        prev = st["offsets"].get(f)
        off = prev[1] if prev and prev[0] == ino else 0
        with open(f, "rb") as fh:
            fh.seek(off)
            for raw in fh:
                if not raw.endswith(b"\n"):
                    break                          # partial line: the lane is still writing it
                off += len(raw)
                if b'"tool_use"' not in raw or (b'"Bash"' not in raw and b'"Monitor"' not in raw):
                    continue
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if r.get("type") != "assistant" or not r.get("agentName"):
                    continue                          # orchestrators/main sessions pass the guard by design
                try:
                    te = datetime.fromisoformat(r.get("timestamp", "").replace("Z", "+00:00")).timestamp()
                except (AttributeError, ValueError):
                    continue
                if not (t0 <= te < t1):
                    continue
                aid = f"{r['agentName']}@{r.get('teamName', '')}"
                for b in (r.get("message") or {}).get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use" or b.get("name") not in ("Bash", "Monitor"):
                        continue
                    if b.get("id") in seen:           # a resumed transcript can repeat lines
                        continue
                    seen.add(b.get("id"))
                    cmd = (b.get("input") or {}).get("command") or ""
                    if not cmd:
                        continue
                    st["calls"] += 1
                    lanes[r["agentName"]] += 1
                    payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": b["name"], "tool_input": b.get("input")})
                    pf = any(fnmatch.fnmatchcase(payload, p) for p in prefilter)
                    st["prefilter"] += pf
                    t_a = time.perf_counter()
                    res = decide(cmd, fleet, cfg, aid, te, cwd=r.get("cwd")) if takes_cwd else decide(cmd, fleet, cfg, aid, te)
                    st["decide_s"] += time.perf_counter() - t_a
                    if res["action"] == "allow":
                        continue
                    row = {"ts": te, "lane": r["agentName"], "cards": res["cards"], "host_any": res["host_any"],
                           "why": res["why"], "cmd": excerpt(cmd)}
                    (st["launches"] if pf else st["misses"]).append(row)
        st["offsets"][f] = [ino, off]
    st["launches"].sort(key=lambda x: x["ts"])
    st["misses"].sort(key=lambda x: x["ts"])
    st["seen"] = sorted(x for x in seen if x)
    st["lanes"] = dict(lanes)
    return st


def _hash_files(paths: list) -> str:
    h = hashlib.sha256()
    for p in paths:
        with contextlib.suppress(OSError):
            with open(p, "rb") as f:
                h.update(p.encode() + b"\0" + f.read())
    return h.hexdigest()[:16]


def cached(plugin: str, fleet: dict, decide, t0: float, projects: str, state: str) -> dict:
    """The board's replay: incremental, from the cache in the state dir (flocked; written atomically)."""
    lib = os.path.join(plugin, "scripts", "lib")
    key = _hash_files([os.path.join(lib, "gpu_detect.py"), os.path.join(lib, "gpu_fleet.py"),
                       os.path.join(plugin, "scripts", "gpu-guard.sh"), os.path.join(plugin, "gpu", "fleet.json"),
                       os.path.join(state, "claims.json")]) + f"@{t0:.0f}"
    os.makedirs(state, exist_ok=True)
    path = os.path.join(state, "replay-cache.json")
    with open(os.path.join(state, "replay-cache.lock"), "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        st = None
        with contextlib.suppress(OSError, ValueError):
            with open(path) as f:
                st = json.load(f)
        files = transcripts(projects, t0)
        if (not st or st.get("v") != CACHE_VERSION or st.get("key") != key
                or any(f in st["offsets"] and _shrunk(f, st["offsets"][f]) for f in files)):
            st = fresh(t0, key)                     # the day, the code, the claims or a transcript changed
        collect(st, files, time.time() + 60, decide, fleet, prefilter_of(plugin))
        tmp = path + f".tmp{os.getpid()}"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, path)
    return st


def _shrunk(f: str, rec: list) -> bool:
    try:
        s = os.stat(f)
    except OSError:
        return False
    return s.st_ino != rec[0] or s.st_size < rec[1]


def report(st: dict, since: str, until: str | None, files: int, plugin: str) -> str:
    launches, misses = st["launches"], st["misses"]
    out = [f"# GPU guard replay: {since} → {until or 'now'} ({time.strftime('%Y-%m-%d %H:%M %Z')})", "",
           f"- transcripts: {files} files modified since {since}; teammate Bash/Monitor calls in the window: **{st['calls']}**",
           "- per lane: " + ", ".join(f"{k} {v}" for k, v in Counter(st["lanes"]).most_common()),
           f"- passed the pre-filter: {st['prefilter']}; decided a GPU launch (would-block with no claims seeded): **{len(launches)}**",
           f"- launches the pre-filter would have LET THROUGH unchecked (guard misses): **{len(misses)}**",
           f"- plugin: {plugin} · decide() time: {1000 * st['decide_s'] / max(st['calls'], 1):.2f} ms mean per call"
           " (in-process; the hook adds python start-up)", ""]
    by_lane = defaultdict(list)
    for x in launches:
        by_lane[x["lane"]].append(x)
    for lane, xs in sorted(by_lane.items()):
        out.append(f"## {lane}: {len(xs)} would-block")
        for x in xs:
            tgt = ",".join(x["cards"] + [f"{h}:<any>" for h in x["host_any"]])
            out.append(f"- {time.strftime('%H:%M:%S', time.localtime(x['ts']))} [{tgt}] ({x['why']}) `{x['cmd']}`")
        out.append("")
    if misses:
        out.append("## Pre-filter misses (decide says launch, the fast path exits first)")
        for x in misses:
            out.append(f"- {time.strftime('%H:%M:%S', time.localtime(x['ts']))} {x['lane']} ({x['why']}) `{x['cmd']}`")
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dreamteam gpu replay")
    ap.add_argument("--since", default=time.strftime("%Y-%m-%d 00:00"))
    ap.add_argument("--until", default=None)
    ap.add_argument("--plugin", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--projects", default=os.environ.get("DREAMTEAM_GPU_PROJECTS") or os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--claims", action="store_true", help="decide against the real ledger (read-only) instead of an empty one")
    ap.add_argument("--out", default=None)
    ap.add_argument("--tsv", default=None, help="also write ts, lane, cards, why, command (one line each) for diffing")
    a = ap.parse_args(argv)
    t0 = local_epoch(a.since)
    t1 = local_epoch(a.until) if a.until else time.time() + 60

    tmp = None
    if not a.claims:
        tmp = tempfile.mkdtemp(prefix="replay-guard-", dir=os.environ.get("TMPDIR_REPLAY") or None)
        os.environ["DREAMTEAM_GPU_STATE"] = tmp      # empty ledger: the pre-seed state; nothing live is read
    sys.path.insert(0, os.path.join(a.plugin, "scripts", "lib"))
    for mod in ("gpu_fleet", "gpu_detect"):          # the plugin under test, not whichever copy is loaded
        sys.modules.pop(mod, None)
    import gpu_fleet as g
    fleet = json.load(open(os.path.join(a.plugin, "gpu", "fleet.json")))
    takes_cwd = "cwd" in g.decide.__code__.co_varnames[:g.decide.__code__.co_argcount]
    try:
        files = transcripts(a.projects, t0)
        st = collect(fresh(t0), files, t1, g.decide, fleet, prefilter_of(a.plugin), takes_cwd)
        if a.tsv:
            with open(a.tsv, "w") as f:
                for x in st["launches"] + st["misses"]:
                    tgt = ",".join(x["cards"] + [f"{h}:<any>" for h in x["host_any"]])
                    f.write(f"{x['ts']:.3f}\t{x['lane']}\t{tgt}\t{x['why']}\t{x['cmd'][:160]}\n")
        text = report(st, a.since, a.until, len(files), a.plugin)
        if a.out:
            with open(a.out, "w") as f:
                f.write(text)
        print(text)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
