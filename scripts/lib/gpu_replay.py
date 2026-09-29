#!/usr/bin/env python3
"""dreamteam GPU fleet: replay the lanes' real Bash calls through the GPU guard, offline (`dreamteam gpu replay`).
Spec: docs/superpowers/specs/2026-09-29-gpu-fleet-design.md §5.3.

Why: plugin hooks load at session start, and every lane session alive on 2026-09-29 started before
gpu-guard reached main (09:40). So guard.log stays empty however many GPU launches happen, and a
"0 false positives" read from it is a zero from an instrument that cannot see. This replays what the
guard WOULD have decided on each teammate Bash/Monitor call in the transcripts: the same pre-filter
globs (on the JSON payload, as gpu-guard.sh matches it), then gpu_fleet.decide() with the lane's
identity and an EMPTY claims ledger (DREAMTEAM_GPU_STATE -> a temp dir), i.e. the pre-seed state.

Usage: dreamteam gpu replay [--since 'YYYY-MM-DD HH:MM'] [--until ...] [--out FILE] [--tsv FILE]
       python3 gpu_replay.py --plugin <another plugin checkout>   (compare two versions on the same window)
Read-only: it never touches the live ledger, guard.log, or any host (detect/decide are pure).
"""
import argparse, fnmatch, glob, json, os, re, shutil, sys, tempfile, time
from collections import Counter, defaultdict
from datetime import datetime, timezone

def prefilter_of(plugin: str) -> list:
    """The pass patterns of THIS plugin version's gpu-guard.sh (its `case "$INPUT" in` block)."""
    src = open(os.path.join(plugin, "scripts", "gpu-guard.sh")).read()
    block = src.split('case "$INPUT" in', 1)[1].split("esac", 1)[0]
    pats = []
    for line in block.splitlines():
        line = line.strip()
        if line.endswith(") ;;") and not line.startswith("*)"):
            pats += [p for p in line[:-len(") ;;")].split("|") if p]
    return pats
SECRETISH = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|[A-Za-z0-9+/=_-]{40,})")


def local_epoch(s: str) -> float:
    return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="dreamteam gpu replay")
    ap.add_argument("--since", default=time.strftime("%Y-%m-%d 00:00"))
    ap.add_argument("--until", default=None)
    ap.add_argument("--plugin", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--tsv", default=None, help="also write ts, lane, cards, why, command (one line each) for diffing")
    a = ap.parse_args(argv)
    t0 = local_epoch(a.since); t1 = local_epoch(a.until) if a.until else time.time() + 60

    tmp = tempfile.mkdtemp(prefix="replay-guard-", dir=os.environ.get("TMPDIR_REPLAY") or None)
    os.environ["DREAMTEAM_GPU_STATE"] = tmp          # empty ledger: the pre-seed state; nothing live is read
    sys.path.insert(0, os.path.join(a.plugin, "scripts", "lib"))
    for mod in ("gpu_fleet", "gpu_detect"):          # the plugin under test, not whichever copy is loaded
        sys.modules.pop(mod, None)
    import gpu_fleet as g
    fleet = json.load(open(os.path.join(a.plugin, "gpu", "fleet.json")))
    cfg = {"gpu": {"guard": "warn"}}
    PREFILTER = prefilter_of(a.plugin)
    takes_cwd = "cwd" in g.decide.__code__.co_varnames[:g.decide.__code__.co_argcount]
    spent = 0.0

    files = [f for f in glob.glob(os.path.join(a.projects, "**", "*.jsonl"), recursive=True)
             if os.path.getmtime(f) >= t0]
    calls = 0; lanes = Counter(); prefilter_pass = 0; launches = []; misses = []; seen = set()
    for f in files:
        with open(f, "rb") as fh:
            for raw in fh:
                if b'"tool_use"' not in raw or (b'"Bash"' not in raw and b'"Monitor"' not in raw):
                    continue
                try:
                    r = json.loads(raw)
                except ValueError:
                    continue
                if r.get("type") != "assistant" or not r.get("agentName"):
                    continue                          # orchestrators/main sessions pass the guard by design
                ts = r.get("timestamp")
                try:
                    te = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
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
                    calls += 1; lanes[r["agentName"]] += 1
                    payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": b["name"], "tool_input": b.get("input")})
                    pf = any(fnmatch.fnmatchcase(payload, p) for p in PREFILTER)
                    prefilter_pass += pf
                    t_a = time.perf_counter()
                    res = g.decide(cmd, fleet, cfg, aid, te, cwd=r.get("cwd")) if takes_cwd else g.decide(cmd, fleet, cfg, aid, te)
                    spent += time.perf_counter() - t_a
                    if not res["launch"] or res["via_run"]:
                        continue
                    row = {"ts": te, "lane": r["agentName"], "cards": res["cards"], "host_any": res["host_any"],
                           "why": res["why"], "action": res["action"], "prefilter": pf, "cmd": cmd}
                    (launches if pf else misses).append(row)
    launches.sort(key=lambda x: x["ts"]); misses.sort(key=lambda x: x["ts"])

    def excerpt(c: str, n: int = 220) -> str:
        c = SECRETISH.sub("<redacted>", " ".join(c.split()))
        return c[:n] + ("…" if len(c) > n else "")

    out = [f"# GPU guard replay: {a.since} → {a.until or 'now'} ({time.strftime('%Y-%m-%d %H:%M %Z')})", "",
           f"- transcripts: {len(files)} files modified since {a.since}; teammate Bash/Monitor calls in the window: **{calls}**",
           f"- per lane: " + ", ".join(f"{k} {v}" for k, v in lanes.most_common()),
           f"- passed the pre-filter: {prefilter_pass}; decided a GPU launch (would-block with no claims seeded): **{len(launches)}**",
           f"- launches the pre-filter would have LET THROUGH unchecked (guard misses): **{len(misses)}**",
           f"- plugin: {a.plugin} · decide() time: {1000 * spent / max(calls, 1):.2f} ms mean per call (in-process; the hook adds python start-up)", ""]
    by_lane = defaultdict(list)
    for x in launches:
        by_lane[x["lane"]].append(x)
    for lane, xs in sorted(by_lane.items()):
        out.append(f"## {lane}: {len(xs)} would-block")
        for x in xs:
            tgt = ",".join(x["cards"] + [f"{h}:<any>" for h in x["host_any"]])
            out.append(f"- {time.strftime('%H:%M:%S', time.localtime(x['ts']))} [{tgt}] ({x['why']}) `{excerpt(x['cmd'])}`")
        out.append("")
    if misses:
        out.append("## Pre-filter misses (decide says launch, the fast path exits first)")
        for x in misses:
            out.append(f"- {time.strftime('%H:%M:%S', time.localtime(x['ts']))} {x['lane']} ({x['why']}) `{excerpt(x['cmd'])}`")
    if a.tsv:
        with open(a.tsv, "w") as f:
            for x in launches + misses:
                tgt = ",".join(x["cards"] + [f"{h}:<any>" for h in x["host_any"]])
                f.write(f"{x['ts']:.3f}\t{x['lane']}\t{tgt}\t{x['why']}\t{excerpt(x['cmd'], 160)}\n")
    text = "\n".join(out) + "\n"
    if a.out:
        open(a.out, "w").write(text)
    print(text)
    shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
