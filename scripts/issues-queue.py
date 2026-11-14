#!/usr/bin/env python3
"""issues-queue.py — the fix machine's queue file: open issues per repo, the `dream` queue,
what waits on JP, and the next sweep. Written nightly (issues-queue.timer, 21:50) and on demand.
Reads GitHub through `gh api` (REST only, no search endpoint: it rate-limits at 30/min), writes
state/issues-queue.json and, when the plan's data dir exists, PLAN_DATA/issues-queue.json.
Contract: docs/ISSUES-QUEUE.md. Nothing here changes GitHub.
"""
import json, os, subprocess, sys, datetime, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / "state"
PLAN_DATA = pathlib.Path(os.environ.get("PLAN_DATA", str(pathlib.Path.home() / "srv/plan.realm.watch/data")))
OWNERS = ["jphein", "techempower-org"]
NEEDS_JP = {"needs-jp", "blocked-on-hardware", "jp", "hands"}
DESIGN = {"epic", "matrix", "design"}
FLEETWATCH = {"fleetwatch-fix"}

def gh(path):
    r = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"gh api {path}: {r.stderr.strip()[:200]}")
    out = r.stdout.strip()
    # --paginate concatenates JSON arrays; join them
    if out.startswith("["):
        parts = out.replace("][", ",")
        return json.loads(parts)
    return json.loads(out)

def repos():
    """Every non-archived repo with open issues that the gh user owns or is an org member of
    (user/repos with affiliation: the users/<login>/repos path lists only PUBLIC repos)."""
    found = []
    try:
        for r in gh("user/repos?per_page=100&affiliation=owner,organization_member"):
            if r.get("archived") or not r.get("has_issues"):
                continue
            if (r.get("open_issues_count") or 0) == 0:
                continue
            found.append(r["full_name"])
    except RuntimeError as e:
        print(f"warn: {e}", file=sys.stderr)
    return sorted(set(found))

def lane_map():
    p = ROOT / "config" / "lane-map.json"
    return json.loads(p.read_text()) if p.exists() else {}

def _next_elapse(unit):
    r = subprocess.run(["systemctl", "--user", "show", "-p", "NextElapseUSecRealtime", "--value", unit], capture_output=True, text=True)
    v = r.stdout.strip()
    if r.returncode != 0 or not v or v == "n/a":
        return None
    try:
        return datetime.datetime.strptime(v, "%a %Y-%m-%d %H:%M:%S %Z").astimezone()
    except ValueError:
        return None

def next_sweep(now):
    """(mode, at). Guarded wins when its timer is active: there is ONE nightly start (timers-ctl.sh retires
    the pilot pair on install), and the plan should name the one that will actually fire."""
    g = subprocess.run(["systemctl", "--user", "is-active", "dreamteam-nightly-guarded.timer"], capture_output=True, text=True)
    if g.returncode == 0 and g.stdout.strip() == "active":
        at = _next_elapse("dreamteam-nightly-guarded.timer")
        if at:
            return "guarded", at
    mode, at = "pilot", now.replace(hour=23, minute=30, second=0, microsecond=0)
    if at < now:
        at += datetime.timedelta(days=1)
    at = _next_elapse("dreamteam-nightly.timer") or at
    svc = subprocess.run(["systemctl", "--user", "cat", "dreamteam-nightly.service"], capture_output=True, text=True)
    if svc.returncode == 0 and "launch-dreamteam.sh" in svc.stdout:
        mode = "active"
    return mode, at

def main():
    now = datetime.datetime.now().astimezone()
    lanes = lane_map()
    out_repos, bad = [], 0
    tot = {"open": 0, "dream": 0, "blocked_on_jp": 0, "fixed_last_night": 0}
    for full in repos():
        try:
            issues = [i for i in gh(f"repos/{full}/issues?state=open&per_page=100") if "pull_request" not in i]
        except RuntimeError as e:
            print(f"warn: {e}", file=sys.stderr); bad += 1; continue
        def labels(i): return {l["name"].lower() for l in i.get("labels", [])}
        dream = [i for i in issues if "dream" in labels(i)]
        needs = [i for i in issues if labels(i) & NEEDS_JP]
        row = {
            "repo": full, "open": len(issues), "dream": len(dream),
            "blocked_on_jp": len(needs),
            "hardware": sum(1 for i in issues if "blocked-on-hardware" in labels(i)),
            "design": sum(1 for i in issues if labels(i) & DESIGN),
            "fleetwatch": sum(1 for i in issues if labels(i) & FLEETWATCH),
            "lane": lanes.get(full, lanes.get(full.split("/",1)[1], "none")),
            "top": [{"number": i["number"], "title": i["title"][:120], "labels": sorted(labels(i))} for i in dream[:5]],
            "needs_jp": [{"number": i["number"], "title": i["title"][:120], "labels": sorted(labels(i))} for i in needs[:20]],
        }
        out_repos.append(row)
        for k in ("open", "dream", "blocked_on_jp"): tot[k] += row[k]
    # last night's sweep, if any
    sw = STATE / "sweep-results.json"
    if sw.exists():
        try:
            s = json.loads(sw.read_text())
            if s.get("night") == (now.date() - datetime.timedelta(days=1)).isoformat():
                tot["fixed_last_night"] = len(s.get("fixed", []))
        except Exception:
            bad += 1
    # next sweep: the GUARDED 23:30 timer when active (mode "guarded"), else the old 02:11 PILOT timer
    # (mode "active" only if its service runs launch-dreamteam.sh), else tonight 23:30 "pilot".
    mode, at = next_sweep(now)
    doc = {"generated": now.isoformat(timespec="seconds"), "repos": out_repos, "totals": tot,
           "next_sweep": {"at": at.isoformat(timespec="seconds"), "mode": mode}, "bad_rows": bad}
    STATE.mkdir(exist_ok=True)
    (STATE / "issues-queue.json").write_text(json.dumps(doc, indent=1) + "\n")
    if PLAN_DATA.is_dir():
        tmp = PLAN_DATA / "issues-queue.json.tmp"
        tmp.write_text(json.dumps(doc, indent=1) + "\n"); os.replace(tmp, PLAN_DATA / "issues-queue.json")
    print(f"issues-queue: {len(out_repos)} repos, open {tot['open']}, dream {tot['dream']}, on JP {tot['blocked_on_jp']}, next sweep {doc['next_sweep']['at']} [{mode}], bad rows {bad}")

if __name__ == "__main__":
    main()
