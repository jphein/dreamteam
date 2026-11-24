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

2026-11-21 (Sen, row 55bd0a23): after the 10:10 wall this resumed familiar's panes, and five lanes on serialhub
sat on the same notice for 3.5 h. Two reasons, both fixed by running THIS script on each lane host (the unit files
are in systemd/; the proxy's quota endpoint is local on every host that runs lanes):
- no timer ran on serialhub, so nothing looked at its panes;
- the script wrote no line anywhere, so a walled fleet was visible only to whoever opened a pane.
It now ends every run with one CHECK line (docs/CHECKS.md), named for the host, that NAMES the walled panes by
tmux session and says why each one was not resumed (waiting for the reset, typed text in its box, a dialog, no
seat can serve):
    CHECK quota-resume[-<host>] ok   · 9 panes read, 0 walled · every 2 min, owner Sen
    CHECK quota-resume[-<host>] warn · 9 panes read, 3 walled: luna-map (resumed), morpheus-roam (typed text in its box), nebula (waits 412 s for the reset) · every 2 min, owner Sen
    CHECK quota-resume[-<host>] fail · tmux cannot be read (<reason>) · every 2 min, owner Sen
THE FAILOVER TURN (rows daf22d99, 55bd0a23; measured 2026-11-23 from the lanes' transcripts). When no seat can
serve, the proxy answers a turn itself with a small local model and marks it:
    ● ⚠ FAILOVER: local qwen36-coder served this turn; no tools ran; treat as unavailable
That turn does nothing and ENDS, so the lane sits at its prompt with no error on screen. 19 such turns in six
days on serialhub, and each "pane hung" or "context emptied by a restart" report matches one to the minute
(Fri 14:40 and Sat 19:14/19:17 this lane, Sat 19:11 raven, four lanes Thu 02:04-02:06). No process had been
restarted. A pane whose LATEST output block starts with that mark is therefore treated like a walled one: after
120 s (exactly: the 30 s of grace belongs to a quota notice's own reset time), with nothing typed in its box
and a seat serving again, it is told to continue, at most 3 times an hour per pane (a proxy that keeps failing
over is not fed forever). The line names it "(failover turn …)".

BEFORE ANY KEY (xreview #283 r1): the seat check comes first, so with no seat the pane is not touched at all;
then the pane is captured AGAIN and must still show the same stall, an empty box, no dialog and no work (the first
capture is as old as the walk over every other pane); then Ctrl-U, the text and Enter are sent one by one and each
result is checked. A refused key stops the sequence and is reported in the line; it is never recorded as a resume.
The line names EVERY walled pane. With no tmux server it is ok (a host without lanes) unless claude processes of
this user run here: then it warns that the timer is looking at the wrong user or socket.

ROUND 2 of that review (7125633596):
- WORKING IS LOOKED FOR OVER THE WHOLE CAPTURE, AND ONLY THE FOOTER CAN UNWALL A PANE (ruling after round 3). A
  marker BELOW the input box, where Claude Code draws its footer ("esc to interrupt", the spinner's line), means
  the agent works: the pane is not walled. A marker anywhere ABOVE the box is transcript body: a quoted
  "esc to interrupt" in an answer reads exactly like a real one, so it never unwalls a pane. Such a pane stays
  walled and NAMED, "(a working marker is on screen above the input box: not typed into)", and gets no key.
- A TURN'S IDENTITY IS NOT ITS TEXT, AND NOT WHAT THE SCREEN SHOWS (ruling after round 3). The key is the pane,
  the stall block, and a DURABLE element read from the session's own transcript: the id of its last assistant
  record at the time of the sighting. Every turn the model (or the proxy's failover model) answers appends one
  such record with a new id, so a second failover turn with the very same answer is another turn whatever is or
  is not still on the screen (the earlier design hashed the visible lines around the stall, and a short pane that
  had scrolled our stamped message away read as the same turn for ever). The transcript is found from the pane:
  its shell's descendant named claude, that process's working directory and its `--resume`/`--session-id`
  argument → ~/.claude/projects/<directory, non-alphanumerics as dashes>/<session id>.jsonl.
  WHEN NO TRANSCRIPT CAN BE READ (a session started without an id on its command line, an unreadable file), the
  script says so in the line and falls back to time: a failover turn it resumed that is still stalled, not
  working, after another full wait counts as a new turn, under the same hourly allowance. It never holds a pane
  for ever on what a screen shows. The typed message still carries the time, for a person reading the pane.
- THE TMUX SOCKET IS EXPLICIT. Every tmux call is `tmux -S <socket>`: $QUOTA_RESUME_TMUX_SOCKET, else the default
  socket of this user (/tmp/tmux-<uid>/default). Nothing is left to what the calling environment happens to hold
  (TMUX, TMUX_TMPDIR): a user service and a login shell then reach the same server or the run says which socket
  had none. `quota-resume-ctl.sh install` finds the lanes' socket, writes it into a drop-in when it is not the
  default, and refuses to enable the timer unless a process started BY THE USER MANAGER lists the same panes.
  One timer watches one socket; lanes on a second server need a second instance.

Seams: QUOTA_RESUME_STATE_DIR (state and log; default beside this file), DREAMTEAM_CHECKS_DIR, DREAMTEAM_CHECK_HOST,
QUOTA_RESUME_TMUX_SOCKET.
A fixture pane is never typed into: the run goes through every decision and logs what it would have typed.
"""
import hashlib, json, os, re, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = socket.gethostname()
SDIR = os.environ.get("QUOTA_RESUME_STATE_DIR") or HERE
STATE = os.path.join(SDIR, f"quota_resume_state.{HOST}.json")   # host-suffixed: the dir may be mirrored
LOG = os.path.join(SDIR, f"quota_resume.{HOST}.log")
# The real error is one "●" output block; quoting it elsewhere never starts with the bullet.
ERR = re.compile(r"● API Error: .*?(Server is temporarily limiting requests|all \d+ accounts are at their quota)")
# A turn the proxy served from its local failover model: the mark is the first words of the block.
FAILOVER = re.compile(r"^● ⚠ FAILOVER: local \S+ served this turn")
FAILOVER_WAIT, FAILOVER_PER_HOUR = 120, 3
# "resets in 42s" (older notices) or "Quota resets in 1h 55m" / "in 7m" (teamclaude since 2026-11)
RESET = re.compile(r"resets in (?=\d)(?:(\d+)h\s*)?(?:(\d+)m\s*)?(?:(\d+)s)?")
# A working agent shows a spinner line like "✢ Wibbling… (3m 49s · ↓ 17.0k tokens)" or "esc to interrupt".
WORKING = re.compile(r"esc to interrupt|↓ [\d.]+k? tokens|^[✢✻✶✳✽]\s\S+…\s*\(")
SGR = re.compile(r"\x1b\[[0-9;]*m")
BLANKISH = re.compile(r"^[\s│─┃┆┊╎┊]*$")   # whitespace or leftover split borders only

TMUX_SOCKET = os.environ.get("QUOTA_RESUME_TMUX_SOCKET") or f"/tmp/tmux-{os.getuid()}/default"
TMUX = ["tmux", "-S", TMUX_SOCKET]        # the ONE way tmux is called here: always this socket, never a guess

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


def check_line(status, fact):
    """Publish the one CHECK line through scripts/lib/check-line.sh (the single writer: three segments, a fact
    that cannot hold a separator, an atomic replace). Never raises; a line that cannot be published is logged."""
    lib = os.path.join(HERE, "lib", "check-line.sh")
    try:
        r = subprocess.run(["bash", "-c", '. "$1" && check_line "$(check_name quota-resume)" "$2" "$3" "$4"', "_", lib, status, fact,
                            "every 2 min, owner Sen"], capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            log(f"check line not published: {r.stderr.strip()[:120]}")
        return r.stdout.strip()
    except Exception as e:
        log(f"check line not published ({type(e).__name__})")
        return ""


import os as _os
PARKED=set(_os.environ.get("PARKED_PANES","").split())
NAMES = {}          # pane id → tmux session name (a fixture: its file name)
NO_SERVER = False   # tmux answered "no server running": this user has no tmux server
PANE_PID = {}       # pane id → the pid of the pane's shell (from tmux)
PROJECTS = os.environ.get("QUOTA_RESUME_PROJECTS_DIR") or os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
PROCROOT = os.environ.get("QUOTA_RESUME_PROC") or "/proc"


def claude_running():
    """Does any process of this user named claude run on the host? (With no tmux server that means the timer is
    looking at the wrong user or socket: the silent miss this script was extended to end.)"""
    try:
        for n in os.listdir(PROCROOT):
            if n.isdigit():
                try:
                    if os.stat(f"{PROCROOT}/{n}").st_uid == os.getuid() and open(f"{PROCROOT}/{n}/comm").read().strip() == "claude":
                        return True
                except OSError:
                    pass
    except OSError:
        pass
    return False



def session_of(pane_pid):
    """(cwd, session id) of the claude process under a pane's shell, or None. Walks the process table once."""
    try:
        kids = {}
        for n in os.listdir(PROCROOT):
            if n.isdigit():
                try:
                    st = open(f"{PROCROOT}/{n}/stat").read()
                    kids.setdefault(st[st.rindex(")") + 2:].split()[1], []).append(n)
                except (OSError, ValueError, IndexError):
                    pass
        todo, seen = [str(pane_pid)], set()
        while todo:
            q = todo.pop(0)
            if q in seen:
                continue
            seen.add(q)
            try:
                if q != str(pane_pid) and open(f"{PROCROOT}/{q}/comm").read().strip() == "claude":
                    argv = open(f"{PROCROOT}/{q}/cmdline", "rb").read().decode("utf-8", "replace").split("\0")
                    sid = None
                    for i, a in enumerate(argv):
                        if a in ("--resume", "-r", "--session-id") and i + 1 < len(argv):
                            sid = argv[i + 1]
                        elif a.startswith("--resume=") or a.startswith("--session-id="):
                            sid = a.split("=", 1)[1]
                    if sid and re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", sid):
                        return os.readlink(f"{PROCROOT}/{q}/cwd"), sid
                    return None
            except OSError:
                pass
            todo.extend(kids.get(q, []))
    except OSError:
        pass
    return None


def turn_mark(pid):
    """The DURABLE identity of the pane's current turn: the uuid of the last assistant record in the session's
    transcript ('' when it cannot be read). A fixture's mark is the content of '<fixture>.turn' beside it."""
    if FIXTURES:
        f = next((x for x in FIXTURES if os.path.basename(x) == pid), None)
        try:
            return open(f + ".turn", encoding="utf-8").read().strip() if f else ""
        except OSError:
            return ""
    who = session_of(PANE_PID.get(pid, "")) if PANE_PID.get(pid) else None
    if not who:
        return ""
    cwd, sid = who
    path = os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 4_000_000))
            lines = f.read().split(b"\n")
        if size > 4_000_000:
            lines = lines[1:]                               # the first piece may be half a record
        for raw in reversed(lines):
            if b'"assistant"' not in raw:
                continue
            try:
                r = json.loads(raw)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get("type") == "assistant" and isinstance(r.get("uuid"), str) and r["uuid"]:
                return r["uuid"]
    except OSError:
        pass
    return ""


def panes():
    global NO_SERVER
    if FIXTURES:
        for f in FIXTURES:
            NAMES[os.path.basename(f)] = os.path.basename(f)
            yield os.path.basename(f), "fixture", open(f, encoding="utf-8", errors="replace").read()
        return
    try:
        r = subprocess.run([*TMUX, "list-panes", "-a", "-F", "#{pane_id} #{pane_pid} #{session_name} #{pane_current_command}"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"tmux: {type(e).__name__}")
    if r.returncode != 0:
        if "no server running" in r.stderr or "No such file or directory" in r.stderr:
            NO_SERVER = True
            return                                         # no tmux server for this user: no panes (judged below)
        raise RuntimeError(r.stderr.strip()[:80] or f"tmux exit {r.returncode}")
    for line in r.stdout.split("\n"):
        if line.split(" ",1)[0] in PARKED: continue
        if line.count(" ") >= 3:
            pid, ppid, sess, cmd = line.split(" ", 3)
            NAMES[pid] = sess
            PANE_PID[pid] = ppid
            yield pid, cmd, sh(*TMUX, "capture-pane", "-e", "-p", "-t", pid)



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

def look(raw):
    """What one capture of a pane shows. None when it is not a Claude Code pane at a prompt; else a dict:
    kind 'wall' | 'failover' | None (no stall) · working (a marker in the live area: the stall block after its
    first line, the box, and everything BELOW the box) · above (a marker anywhere above the stall: history, or a
    quote; not judged, so not typed into) · dialog · typed (text in the box) · collapsed (the latest output block
    as one line) · context (from the PREVIOUS output block down to the box, as one line: the turn's identity)."""
    raw_lines = raw.split("\n")
    plain_lines = [SGR.sub("", l) for l in raw_lines]
    keep = [i for i, l in enumerate(plain_lines) if not BLANKISH.match(l)]
    lines = [plain_lines[i] for i in keep]
    # the input box: the last line starting with ❯
    box = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].lstrip().startswith("❯")), None)
    if box is None or box < 2:
        return None
    text = "\n".join(lines)
    # the stall must be the LATEST output block: the last ● line before the box
    bullets = [i for i in range(box) if lines[i].lstrip().startswith("●")]
    block = lines[bullets[-1]:box] if bullets else []
    collapsed = " ".join(" ".join(block).split())
    start = bullets[-1] if bullets else box
    context = " ".join(" ".join(lines[(bullets[-2] if len(bullets) > 1 else 0):box]).split())
    kind = None
    if block and FAILOVER.search(collapsed):
        kind = "failover"
    elif block and ERR.search(collapsed):
        kind = "wall"
    return {"kind": kind, "collapsed": collapsed, "context": context,
            "working": any(WORKING.search(l) for l in lines[box + 1:]),      # the footer, below the box: the live UI
            "above": any(WORKING.search(l) for l in lines[:box]),          # anywhere in the transcript body: not judged
            "dialog": "Do you want" in text or "Enter to select" in text or "Enter to confirm" in text,
            "typed": typed_text(raw_lines[keep[box]])}


def capture(pid):
    """A fresh capture of one pane (a fixture: its file, read again)."""
    if FIXTURES:
        f = next((x for x in FIXTURES if os.path.basename(x) == pid), None)
        return open(f, encoding="utf-8", errors="replace").read() if f else ""
    return sh(*TMUX, "capture-pane", "-e", "-p", "-t", pid)


def keys(pid, *args):
    """One tmux send-keys; True only when tmux said it worked. A fixture is never typed into."""
    if FIXTURES:
        return True
    try:
        return subprocess.run([*TMUX, "send-keys", "-t", pid, *args], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


try:
    state = json.load(open(STATE))
except Exception:
    state = {}
now = time.time()
seen_now = set()
read = 0
walled = []          # (name, why it was or was not resumed), in pane order
unmarked = set()     # failover panes whose transcript could not be read: their turns are told apart by time
refused = 0          # sends that tmux refused: the resume itself could not be typed → the line is FAIL
try:
    all_panes = list(panes())
except RuntimeError as e:
    if DRY:
        print(f"tmux cannot be read ({e})")
    else:
        log(f"tmux cannot be read ({e})")
        check_line("fail", f"tmux cannot be read ({e})")
    sys.exit(0)
for pid, cmd, raw in all_panes:
    read += 1
    name = NAMES.get(pid, pid)
    v = look(raw)
    if v is None or v["kind"] is None:
        if DRY and v and v["dialog"]: print(f"skip {pid}: dialog on screen")
        continue
    failover = v["kind"] == "failover"
    kind = "failover turn, " if failover else ""
    if v["working"]:
        if DRY: print(f"skip {pid}: working again")
        continue   # the agent is already working again
    if v["above"]:
        if DRY: print(f"skip {pid}: a working marker above the input box")
        walled.append((name, kind + "a working marker is on screen above the input box: not typed into"))
        continue
    if v["dialog"]:
        if DRY: print(f"skip {pid}: dialog on screen")
        walled.append((name, kind + "a dialog is open"))
        continue
    if v["typed"]:
        if DRY:
            print(f"skip {pid}: typed input {v['typed'][:40]!r}")
        walled.append((name, kind + "typed text in its box"))
        continue
    collapsed = v["collapsed"]
    wait = None if failover else reset_wait(collapsed)
    # a quota notice names its own reset, and gets 30 s of grace on top; a failover turn names none: 120 s, exactly
    due = (FAILOVER_WAIT if failover else (300 if wait is None else wait) + 30)
    # THE TURN, not its text and not the screen: the pane, the stall block, and the id of the transcript's last
    # assistant record. Without a transcript (mark ""), the block alone, and time decides below.
    mark = turn_mark(pid)
    key = pid + ":" + hashlib.sha1((collapsed + "\x00" + mark).encode()).hexdigest()[:12]
    seen_now.add(key)
    first = state.get(key, {}).get("first", now)
    done = state.get(key, {}).get("done", False)
    done_at = state.get(key, {}).get("done_at")
    if done and failover and not mark and isinstance(done_at, (int, float)) and now >= done_at + due:
        # no transcript to tell turns apart: a failover turn we resumed, still stalled a full wait later, is
        # treated as a new one (the hourly allowance below still applies). Never held for ever on a screen.
        done, first = False, done_at
    state[key] = {"first": first, "done": done, "done_at": done_at}
    if failover and not mark:
        unmarked.add(name)
    if DRY:
        print(f"match {pid} ({cmd}): wait={due - (0 if failover else 30)}s done={done} due_in={int(first + due - now)}s serves={proxy_serves()}")
        continue
    if done:
        walled.append((name, kind + "resumed once already, still on the same turn"))
        continue
    if now < first + due:
        walled.append((name, kind + f"waits {int(first + due - now)} s" + ("" if failover else " for the reset")))
        continue
    fo_key = "_failover:" + pid
    recent = [t for t in state.get(fo_key, []) if isinstance(t, (int, float)) and t > now - 3600]
    if failover and len(recent) >= FAILOVER_PER_HOUR:
        state[fo_key] = recent
        walled.append((name, f"failover turn, {FAILOVER_PER_HOUR} resumes already this hour: held"))
        continue
    # 1. Can a seat serve? Asked BEFORE any key: with no seat, the pane is not touched at all.
    if not proxy_serves():
        log(f"hold {pid}: no seat can serve; no key sent")
        walled.append((name, kind + "no seat can serve"))
        continue
    # 2. Look at the pane AGAIN, now. The first capture is as old as the walk over every other pane and the quota
    #    call: someone may have typed, a dialog may have opened, the agent may be working. Only a pane that still
    #    shows the SAME stall, an empty box, no dialog and no work gets a key.
    again = look(capture(pid))
    if (again is None or again["kind"] != v["kind"] or again["collapsed"] != collapsed or again["context"] != v["context"]
            or again["working"] or again["above"] or again["dialog"] or again["typed"] or turn_mark(pid) != mark):
        log(f"skip {pid}: the pane changed between the first look and the send; no key sent")
        walled.append((name, kind + "changed while being looked at: left alone, looked at again next run"))
        continue
    # 3. The keys, each one checked. Ctrl-U (a prompt that looked empty), the text, Enter. A key tmux refused
    #    stops the sequence, is reported, and is NOT recorded as a resume.
    #    The message ends with the time: it is what makes the NEXT turn's context differ from this one's.
    message = ("continue (auto-resume: your last turn was served by the local failover model and did nothing; a seat serves again)"
               if failover else "continue (jp-ab auto-resume after quota reset)") + time.strftime(" [%H:%M:%S]", time.localtime(now))
    failed = None
    if not keys(pid, "C-u"):
        failed = "the clearing key was refused: nothing typed"
    elif not keys(pid, "-l", message):
        failed = "the text was refused: nothing sent"
    elif not keys(pid, "Enter"):
        failed = "the text is typed but Enter was refused: it sits in the box"
    if failed:
        log(f"send failed {pid}: {failed}")
        refused += 1
        walled.append((name, kind + "send failed (" + failed + ")"))
        continue
    if FIXTURES:
        log(f"would resume {pid} (a fixture is never typed into)")
    state[key]["done"] = True
    state[key]["done_at"] = now
    if failover:
        state[fo_key] = recent + [now]
    walled.append((name, kind + "resumed"))
    log(f"resumed {pid} ({cmd}) after {'a failover turn' if failover else 'quota error'}, waited {int(now-first)}s")
if DRY:
    print(f"dry-run: {read} panes read via {TMUX_SOCKET}" + (" (no server on that socket)" if NO_SERVER else ""))
if not DRY:
    state = {k: v for k, v in state.items() if k in seen_now or (k.startswith("_failover:") and any(t > now - 3600 for t in v))}
    json.dump(state, open(STATE, "w"))
    if walled:
        # EVERY walled pane is named, with its reason: the line exists so that none of them sits unseen
        note = f"; no transcript found for {', '.join(sorted(unmarked))}: turns told apart by time" if unmarked else ""
        # a key tmux REFUSED means this script cannot do its one job on that pane: fail, with every pane still named
        check_line("fail" if refused else "warn", f"{read} panes read, {len(walled)} walled: " + ", ".join(f"{n} ({why})" for n, why in walled) + note)
    elif read == 0 and NO_SERVER and claude_running():
        check_line("warn", f"no tmux server for this user at {TMUX_SOCKET}, yet claude processes run here: this timer runs as the wrong user or on the wrong socket, and sees no lane (quota-resume-ctl.sh install sets the socket)")
    else:
        check_line("ok", f"{read} panes read, 0 walled")
