#!/usr/bin/env python3
"""Auto-resume Claude panes stalled on teamclaude's "all N accounts are at their quota" error (JP 2026-09-29).

A systemd user timer runs this every 2 min. For each tmux pane running claude:
- the latest output block (the last "●" line before the input box) is the API Error,
- no spinner / "esc to interrupt" line follows it (the agent is not working),
- the reset time has passed (first sighting + "resets in Ns" + 30 s), and
- the ❯ input box holds no TYPED text (Claude Code's dim ghost-text suggestions don't count),
then type "continue (jp-ab auto-resume after quota reset)" and press Enter, at most once per error sighting.
Everything is logged to quota_resume.log. It never touches a pane that has typed input or a dialog open.

2026-10-05 (jp-main) — three misses measured on familiar, all fixed here:
- ghost-text in the ❯ box (rendered dim, SGR 2) was read as typed input → the pane was skipped;
- stale "│" split-border residue counted as non-blank lines, pushing a wrapped error out of the 6-line window;
- any pane that merely QUOTED the error text (a reviewer, a dry-run command) matched → anchored on the "●" bullet.
Options: --dry-run (print decisions, type nothing); --fixture FILE... (treat saved `capture-pane -e -p` files as panes).
"""
import hashlib, json, os, re, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = socket.gethostname()
STATE = os.path.join(HERE, f"quota_resume_state.{HOST}.json")   # host-suffixed: the dir may be mirrored
LOG = os.path.join(HERE, f"quota_resume.{HOST}.log")
# The real error is one "●" output block; quoting it elsewhere never starts with the bullet.
ERR = re.compile(r"● API Error: .*?(Server is temporarily limiting requests|all \d+ accounts are at their quota)")
# "resets in 42s" (older notices) or "Quota resets in 1h 55m" / "in 7m" (teamclaude since 2026-11)
RESET = re.compile(r"resets in (?=\d)(?:(\d+)h\s*)?(?:(\d+)m\s*)?(?:(\d+)s)?")
# A working agent shows a spinner line like "✢ Wibbling… (3m 49s · ↓ 17.0k tokens)" or "esc to interrupt".
WORKING = re.compile(r"esc to interrupt|↓ [\d.]+k? tokens|^[✢✻✶✳✽]\s\S+…\s*\(")
SGR = re.compile(r"\x1b\[[0-9;]*m")
BLANKISH = re.compile(r"^[\s│─┃┆┊╎┊]*$")   # whitespace or leftover split borders only

DRY = "--dry-run" in sys.argv
FIXTURES = sys.argv[sys.argv.index("--fixture") + 1:] if "--fixture" in sys.argv else []


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


def log(msg):
    if DRY:
        print(msg)
        return
    with open(LOG, "a") as f:
        f.write(time.strftime("%F %T ") + msg + "\n")


def typed_text(raw_line):
    """Text after ❯ that is NOT dim. Ghost-text suggestions render as SGR 2 (dim); typed input does not."""
    out, dim = [], False
    for tok in re.split(r"(\x1b\[[0-9;]*m)", raw_line):
        if tok.startswith("\x1b["):
            params = tok[2:-1].split(";") if len(tok) > 3 else ["0"]
            if "2" in params:
                dim = True
            if "0" in params or "22" in params or params == [""]:
                dim = False
        elif not dim:
            out.append(tok)
    plain = "".join(out).lstrip()
    return plain[1:].strip() if plain.startswith("❯") else plain.strip()


import os as _os
PARKED=set(_os.environ.get("PARKED_PANES","").split())
def panes():
    if FIXTURES:
        for f in FIXTURES:
            yield os.path.basename(f), "fixture", open(f, encoding="utf-8", errors="replace").read()
        return
    for line in sh("tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_current_command}").split("\n"):
        if line.split(" ",1)[0] in PARKED: continue
        if line.strip():
            pid, cmd = line.split(" ", 1)
            yield pid, cmd, sh("tmux", "capture-pane", "-e", "-p", "-t", pid)



def seats_serving(q):
    """How many seats the proxy can route to now; 0 on any doubt (a dead fleet → don't type).

    The proxy's own `live_seats` is the answer: it is the routing predicate itself (throttles, switch thresholds,
    family buckets). 2026-11-21 (Sen, row seat-walls): the old test here counted any seat with a sliver of 5h and week
    left, so it typed "continue" 146 times into two walls (10:10-12:01, 14:05-17:00) while the proxy refused every
    request; and a seat whose fiveHour bucket is null raised AttributeError 254 times. Without `live_seats` (an older
    proxy) a seat counts only when it is active, its week is under 98 % and its 5h under 97 % (the proxy's rules)."""
    live = q.get("live_seats")
    if isinstance(live, int) and not isinstance(live, bool):
        return max(live, 0)
    n = 0
    for a in q.get("accounts") or []:
        if not isinstance(a, dict) or a.get("disabled") or a.get("status") != "active":
            continue
        b = a.get("buckets") or {}
        fh, wk = b.get("fiveHour") or {}, b.get("weeklyShared") or {}
        fu, wu = fh.get("utilization"), wk.get("utilization")
        if isinstance(wu, (int, float)) and wu < 0.98 and (fu is None or (isinstance(fu, (int, float)) and fu < 0.97)):
            n += 1
    return n


def proxy_serves():
    """True when the proxy says a seat can serve; False on any doubt (dead fleet → don't type)."""
    try:
        import urllib.request, json as _j
        src = os.environ.get("QUOTA_RESUME_QUOTA_FILE")   # tests read a file instead of the endpoint
        if src:
            q = _j.load(open(src))
        else:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # loopback, never via a proxy
            with opener.open("http://127.0.0.1:3456/teamclaude/quota", timeout=5) as r:
                q = _j.load(r)
        return seats_serving(q) > 0
    except Exception as e:
        log(f"proxy quota unreadable ({type(e).__name__}); not resuming")
        return False


def reset_wait(text):
    """Seconds the notice says to wait: 'resets in 42s' or teamclaude's 'Quota resets in 1h 55m'; None if it names none."""
    m = RESET.search(text)
    if not m or not any(m.groups()):
        return None
    h, mi, s = (int(x) if x else 0 for x in m.groups())
    return h * 3600 + mi * 60 + s

try:
    state = json.load(open(STATE))
except Exception:
    state = {}
now = time.time()
seen_now = set()
for pid, cmd, raw in panes():
    raw_lines = raw.split("\n")
    plain_lines = [SGR.sub("", l) for l in raw_lines]
    keep = [i for i, l in enumerate(plain_lines) if not BLANKISH.match(l)]
    lines = [plain_lines[i] for i in keep]
    # locate the input box: the last line starting with ❯
    box = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].lstrip().startswith("❯")), None)
    if box is None or box < 2:
        continue
    text = "\n".join(lines)
    if "Do you want" in text or "Enter to select" in text or "Enter to confirm" in text:
        if DRY: print(f"skip {pid}: dialog on screen")
        continue
    # the error must be the LATEST output block: the last ● line before the box
    bullets = [i for i in range(box) if lines[i].lstrip().startswith("●")]
    if not bullets:
        continue
    block = lines[bullets[-1]:box]
    collapsed = " ".join(" ".join(block).split())
    if not ERR.search(collapsed):
        continue
    if any(WORKING.search(l) for l in block[1:]):
        if DRY: print(f"skip {pid}: working again")
        continue   # the agent is already working again
    typed = typed_text(raw_lines[keep[box]])
    if typed:
        if DRY:
            print(f"skip {pid}: typed input {typed[:40]!r}")
        continue
    wait = reset_wait(collapsed)
    wait = 300 if wait is None else wait
    key = pid + ":" + hashlib.sha1(collapsed.encode()).hexdigest()[:12]
    seen_now.add(key)
    first = state.get(key, {}).get("first", now)
    done = state.get(key, {}).get("done", False)
    state[key] = {"first": first, "done": done}
    if DRY:
        print(f"match {pid} ({cmd}): wait={wait}s done={done} due_in={int(first + wait + 30 - now)}s serves={proxy_serves()}")
        continue
    if done or now < first + wait + 30:
        continue
    subprocess.run(["tmux", "send-keys", "-t", pid, "C-u"])
    if not proxy_serves():
        log(f"hold {pid}: no seat can serve; not typing continue")
        continue
    subprocess.run(["tmux", "send-keys", "-t", pid, "-l", "continue (jp-ab auto-resume after quota reset)"])
    subprocess.run(["tmux", "send-keys", "-t", pid, "Enter"])
    state[key]["done"] = True
    log(f"resumed {pid} ({cmd}) after quota error, waited {int(now-first)}s")
if not DRY:
    state = {k: v for k, v in state.items() if k in seen_now}
    json.dump(state, open(STATE, "w"))
