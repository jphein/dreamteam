#!/usr/bin/env python3
"""issues-queue.py — the fix machine's queue file: open issues per repo, the `dream` queue,
what waits on JP, and the next sweep. Written by issues-queue.timer (04:50, 10:50, 16:50, 21:50, boot) and on demand.
Reads GitHub through `gh api` (REST only, no search endpoint: it rate-limits at 30/min), writes
state/issues-queue.json and, when the plan's data dir exists, PLAN_DATA/issues-queue.json.
Contract: docs/ISSUES-QUEUE.md. Nothing here changes GitHub.

Hardening (#193, post-merge xreview of #166):
- pagination decodes successive JSON documents (gh --paginate concatenates pages), never a string replace;
- only repos whose owner is in OWNERS are read or exported;
- a discovery failure publishes nothing (rc 2, previous snapshot kept); a repo that fails is listed in
  failed_repos with complete=false and the run exits 1;
- every subprocess has a deadline (its process group is killed), inside a whole-run budget;
- both files are written 0600 through a uniquely named temp file and os.replace.
"""
import json, math, os, re, signal, socket, subprocess, sys, datetime, pathlib, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / "state"
PLAN_DATA = pathlib.Path(os.environ.get("PLAN_DATA", str(pathlib.Path.home() / "srv/plan.realm.watch/data")))
OWNERS = {"jphein", "techempower-org"}          # an allowlist: no other owner's repo is read or exported
NEEDS_JP = {"needs-jp", "blocked-on-hardware", "jp", "hands"}
DESIGN = {"epic", "matrix", "design"}
FLEETWATCH = {"fleetwatch-fix"}
CONFIG_ERRORS = []

def _num(name, default):
    """A finite number from the environment; anything else is a configuration error (main exits 2)."""
    v = os.environ.get(name)
    if v is None:
        return default
    try:
        f = float(v)
    except ValueError:
        f = math.nan
    if not math.isfinite(f):
        CONFIG_ERRORS.append(f"{name}={v[:40]!r} is not a finite number")
        return default
    return f

TIMEOUT = _num("ISSUES_QUEUE_TIMEOUT", 90.0)    # one gh call, seconds
BUDGET = _num("ISSUES_QUEUE_BUDGET", 420.0)     # the whole run; the unit's TimeoutStartSec is 10 min
SYS_TIMEOUT = min(10.0, TIMEOUT)                # one systemctl call
GRACE = 1.0                                     # reaping after a group kill
SYS_CALLS = 4                                   # next_sweep's worst case: guarded is-active + elapse, pilot elapse + cat
# The run's subprocess time stays inside BUDGET: gh calls stop at BUDGET - RESERVE, which leaves the systemctl
# calls their whole deadlines; every call's deadline is also clamped to what is left, kill grace included.
RESERVE = SYS_CALLS * (SYS_TIMEOUT + GRACE)
_T0 = time.monotonic()

def _left(reserve=0.0):
    return BUDGET - reserve - (time.monotonic() - _T0) - GRACE

def _run(argv, timeout):
    """(rc, stdout bytes, stderr text); rc None when the deadline passed or the budget is spent. The child runs in
    its own session and on a timeout the whole process group is killed, so a grandchild holding the pipe cannot keep
    the run waiting."""
    if timeout <= 0:
        return None, b"", "run budget spent"
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return 127, b"", str(e)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=GRACE)
        except subprocess.TimeoutExpired:
            pass
        return None, b"", f"timed out after {timeout:g} s"
    return p.returncode, out, err.decode("utf-8", "replace")

def _sys(argv):
    """A bounded systemctl call: (rc, stdout text); never raises."""
    rc, out, _ = _run(argv, min(SYS_TIMEOUT, _left()))
    return rc, out.decode("utf-8", "replace")

def pages(text):
    """Every JSON document in text, in order (gh --paginate writes one per page, with or without whitespace)."""
    dec, i, n, docs = json.JSONDecoder(), 0, len(text), []
    while True:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            return docs
        doc, i = dec.raw_decode(text, i)
        docs.append(doc)

def gh(path):
    """A paginated REST list, flattened. Anything but pages of JSON objects is a failure (RuntimeError)."""
    rc, out, err = _run(["gh", "api", "--paginate", path], min(TIMEOUT, _left(RESERVE)))
    if rc != 0:
        raise RuntimeError(f"gh api {path}: {(err or '').strip()[:200] or f'rc {rc}'}")
    try:
        docs = pages(out.decode("utf-8"))
    except ValueError as e:   # UnicodeDecodeError is a ValueError; RecursionError (deep nesting) is a RuntimeError
        raise RuntimeError(f"gh api {path}: not JSON ({type(e).__name__})") from None
    if not docs or not all(isinstance(d, list) for d in docs):
        raise RuntimeError(f"gh api {path}: expected JSON array pages")
    items = [x for d in docs for x in d]
    if not all(isinstance(x, dict) for x in items):
        raise RuntimeError(f"gh api {path}: a page item is not an object")
    return items

def owner_ok(full):
    return isinstance(full, str) and full.count("/") == 1 and full.split("/", 1)[0].lower() in OWNERS

def _int(v, least=0):
    return isinstance(v, int) and not isinstance(v, bool) and v >= least

def check_repo(r):
    """A discovery record must carry every field the filter reads; a default must never drop a repo."""
    if not (isinstance(r.get("full_name"), str) and isinstance(r.get("archived"), bool)
            and isinstance(r.get("has_issues"), bool) and _int(r.get("open_issues_count"))):
        raise RuntimeError(f"discovery: malformed repo record {str(r.get('full_name'))[:80]!r}")

def check_issue(i):
    """Every issue is validated, exported or not: a malformed one fails its repo instead of skewing the counts."""
    labels = i.get("labels")
    if not (_int(i.get("number"), 1) and isinstance(i.get("title"), str) and isinstance(labels, list)
            and all(isinstance(l, dict) and isinstance(l.get("name"), str) for l in labels)):
        raise RuntimeError(f"malformed issue #{i.get('number')!r}")

def repos():
    """Every non-archived repo with open issues that the gh user owns or is an org member of, owner in OWNERS
    (user/repos with affiliation: the users/<login>/repos path lists only PUBLIC repos). Raises RuntimeError
    when discovery fails: an empty list must mean "none", never "could not look"."""
    found = []
    for r in gh("user/repos?per_page=100&affiliation=owner,organization_member"):
        check_repo(r)
        if r["archived"] or not r["has_issues"] or r["open_issues_count"] == 0:
            continue
        if owner_ok(r.get("full_name")):
            found.append(r["full_name"])
    return sorted(set(found))

def lane_map():
    p = ROOT / "config" / "lane-map.json"
    return json.loads(p.read_text()) if p.exists() else {}

def _next_elapse(unit):
    rc, out = _sys(["systemctl", "--user", "show", "-p", "NextElapseUSecRealtime", "--value", unit])
    v = out.strip()
    if rc != 0 or not v or v == "n/a":
        return None
    try:
        return datetime.datetime.strptime(v, "%a %Y-%m-%d %H:%M:%S %Z").astimezone()
    except ValueError:
        return None

def next_sweep(now):
    """(mode, at). Guarded wins when its timer is active: there is ONE nightly start (timers-ctl.sh retires
    the pilot pair on install), and the plan should name the one that will actually fire."""
    rc, out = _sys(["systemctl", "--user", "is-active", "dreamteam-nightly-guarded.timer"])
    if rc == 0 and out.strip() == "active":
        at = _next_elapse("dreamteam-nightly-guarded.timer")
        if at:
            return "guarded", at
    mode, at = "pilot", now.replace(hour=23, minute=30, second=0, microsecond=0)
    if at < now:
        at += datetime.timedelta(days=1)
    at = _next_elapse("dreamteam-nightly.timer") or at
    rc, out = _sys(["systemctl", "--user", "cat", "dreamteam-nightly.service"])
    if rc == 0 and "launch-dreamteam.sh" in out:
        mode = "active"
    return mode, at

def publish(path, text):
    """Atomic and private: a uniquely named 0600 temp file in the same dir, fsync, os.replace."""
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

CHECK_NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")     # the Watch's NAME (plan checks.py)
RUNS = ((4, 50), (10, 50), (16, 50), (21, 50))               # systemd/issues-queue.timer

def check_name(base):
    """<base> on familiar, <base>-<host> elsewhere (lower-cased, [a-z0-9-] only), as scripts/lib/check-line.sh."""
    host = re.sub(r"[^a-z0-9-]", "", (os.environ.get("DREAMTEAM_CHECK_HOST") or socket.gethostname()).lower()) or "unknown-host"
    return base if host == "familiar" else f"{base}-{host}"

def check_line(status, fact):
    """The one CHECK line (docs/CHECKS.md row issues-queue; same contract as scripts/lib/check-line.sh): exactly three
    segments, the fact's " · " → ", " and newlines → spaces, an unknown status published as fail, a name the Watch would
    not read never published, written through publish() (unique same-dir temp file, os.replace: a symlink at the
    destination is replaced, a directory there refused). Returns the line; never raises."""
    if status not in ("ok", "warn", "fail"):
        fact, status = f"unknown status {status!r}: {fact}", "fail"
    fact = re.sub(r"[\r\n]+", " ", str(fact))
    fact = fact.replace(" · ", ", ").replace("·", ",")   # no "·" left: none can form a separator at any edge
    now = datetime.datetime.now().astimezone()
    nxt = min(now.replace(hour=h, minute=m, second=0, microsecond=0) + datetime.timedelta(days=d)
              for d in (0, 1) for h, m in RUNS
              if now.replace(hour=h, minute=m, second=0, microsecond=0) + datetime.timedelta(days=d) > now)
    name = check_name("issues-queue")
    line = f"CHECK {name} {status} · {fact} · next {nxt:%H:%M}, owner Sen"
    print(line)
    if not CHECK_NAME_RE.fullmatch(name):
        print(f"issues-queue: check name {name!r} is not one the Watch reads; not published", file=sys.stderr)
        return line
    try:
        d = pathlib.Path(os.environ.get("DREAMTEAM_CHECKS_DIR") or pathlib.Path.home() / ".local/state/checks")
        d.mkdir(parents=True, exist_ok=True)
        publish(d / f"{name}.line", line + "\n")
    except OSError as e:
        print(f"issues-queue: could not publish the CHECK line: {e}", file=sys.stderr)
    return line

def main():
    now = datetime.datetime.now().astimezone()
    if CONFIG_ERRORS:
        print(f"issues-queue: bad configuration, nothing published: {'; '.join(CONFIG_ERRORS)}", file=sys.stderr)
        check_line("fail", f"bad configuration, nothing published: {'; '.join(CONFIG_ERRORS)}")
        return 2
    lanes = lane_map()
    try:
        names = repos()
    except RuntimeError as e:
        print(f"issues-queue: discovery failed, nothing published (previous snapshot kept): {e}", file=sys.stderr)
        check_line("fail", f"discovery failed, nothing published (previous snapshot kept): {str(e)[:120]}")
        return 2
    out_repos, failed, bad = [], [], 0
    tot = {"open": 0, "dream": 0, "blocked_on_jp": 0, "fixed_last_night": 0}
    def labels(i): return {l["name"].lower() for l in i.get("labels", [])}
    for full in names:
        try:
            issues = [i for i in gh(f"repos/{full}/issues?state=open&per_page=100") if "pull_request" not in i]
            for i in issues:
                check_issue(i)
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
                # the whole list: blocked_on_jp is its length (docs/ISSUES-QUEUE.md); the plan clips what it shows
                "needs_jp": [{"number": i["number"], "title": i["title"][:120], "labels": sorted(labels(i))} for i in needs],
            }
        except RuntimeError as e:   # check_issue() has vetted every field the row reads
            print(f"warn: {full}: {e}", file=sys.stderr); failed.append(full); continue
        out_repos.append(row)
        for k in ("open", "dream", "blocked_on_jp"): tot[k] += row[k]
    bad = len(failed)
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
    doc = {"generated": now.isoformat(timespec="seconds"), "complete": not failed, "failed_repos": failed,
           "repos": out_repos, "totals": tot,
           "next_sweep": {"at": at.isoformat(timespec="seconds"), "mode": mode}, "bad_rows": bad}
    text = json.dumps(doc, indent=1) + "\n"
    STATE.mkdir(exist_ok=True)
    publish(STATE / "issues-queue.json", text)
    if PLAN_DATA.is_dir():
        publish(PLAN_DATA / "issues-queue.json", text)
    print(f"issues-queue: {len(out_repos)} repos, open {tot['open']}, dream {tot['dream']}, on JP {tot['blocked_on_jp']}, next sweep {doc['next_sweep']['at']} [{mode}], bad rows {bad}"
          + (f", INCOMPLETE: {len(failed)} repo(s) failed: {' '.join(failed)}" if failed else ""))
    fact = f"{len(out_repos)} repos, open {tot['open']}, dream {tot['dream']}, on JP {tot['blocked_on_jp']}, bad rows {bad}"
    if failed:
        check_line("warn", f"{fact}, INCOMPLETE: {len(failed)} repo(s) failed: {' '.join(failed)[:160]}")
    else:
        check_line("ok" if bad == 0 else "warn", f"{fact}, complete")
    return 1 if failed else 0

if __name__ == "__main__":
    try:
        rc = main()
    except BaseException as e:      # a crash still says so on the Watch, then propagates
        if not isinstance(e, SystemExit):
            check_line("fail", f"crashed: {type(e).__name__}: {str(e)[:120]}")
        raise
    sys.exit(rc)
