#!/usr/bin/env python3
"""dreamteam — kill-mine: stop the processes matching a pattern that run INSIDE one directory, and no others.

WHY (measured on serialhub, 2026-11-18 and 11-20, Flow row 62d79dae). Lanes restarted their own test suite with
    for p in $(ps -eo pid,args | grep -E "make test|python.* -m pytest" | …); do kill $p; done
A command line carries no owner: `make test` reads the same in every worktree, so that loop ended every lane's
suite on the host. Three times on 11-20 two lanes' 7-minute runs died in the same second, and `setsid nohup`
(the advised workaround) could not help, because the selector never looks at sessions. The boundary a lane
actually means is "the suite running in MY worktree", and the kernel keeps that: /proc/<pid>/cwd.

WHAT IT DOES
    kill-mine.py [--under DIR] [--signal TERM|INT|HUP|KILL] [--dry-run] PATTERN
  - PATTERN is a Python regular expression searched in the process's command line (arguments joined by spaces).
  - DIR defaults to the git top level of the current directory, else the current directory.
  - A process is taken when it is ours (same uid), matches PATTERN, and its working directory is DIR or below;
    also when it matches PATTERN and descends from a process taken that way (a test runner that chdir'ed into
    a temp dir under its `make`).
  - Never taken: this process and its own ancestors (the calling shell's command line holds the pattern).
  - A matching process anywhere else is left alone and COUNTED, so the report shows what a host-wide kill
    would have hit.
  - Each signal goes through a pidfd. After the pidfd is open the process is read again, and it is signalled
    only if its START TIME, command line and directory are the ones selected: a pid reused between the look
    and the signal belongs to a process that started later, whatever its command line, and is never signalled.

REFUSED (exit 2): DIR that is `/`, the home directory, or any ancestor of it (that is the whole host again).
EXIT: 0 at least one process signalled (or would be, with --dry-run) · 1 none matched under DIR · 2 refused ·
22 bad arguments. `scripts/wide-kill-guard.sh` blocks the host-wide forms and names this tool.
"""
import argparse
import os
import re
import signal
import subprocess
import sys

SIGNALS = {"TERM": signal.SIGTERM, "INT": signal.SIGINT, "HUP": signal.SIGHUP, "KILL": signal.SIGKILL}


def read_proc(pid):
    """(ppid, cmdline, cwd, start time in clock ticks since boot) of a live process of ours, or None.
    A zombie has no cmdline and is skipped."""
    base = f"/proc/{pid}"
    try:
        if os.stat(base).st_uid != os.getuid():
            return None
        with open(f"{base}/cmdline", "rb") as fh:
            raw = fh.read()
        if not raw:
            return None
        with open(f"{base}/stat", "rb") as fh:
            stat = fh.read()
        fields = stat[stat.rindex(b")") + 2:].split()      # after "pid (comm) ": state ppid … starttime(22nd)
        ppid, start = int(fields[1]), int(fields[19])
        cwd = os.readlink(f"{base}/cwd")
    except (OSError, ValueError, IndexError):
        return None
    if cwd.endswith(" (deleted)"):
        cwd = cwd[:-len(" (deleted)")]
    return ppid, raw.rstrip(b"\0").replace(b"\0", b" ").decode("utf-8", "replace"), cwd, start


def signal_one(pid, selected, sig, read=read_proc, opener=None, sender=None):
    """Signal `pid` only if it is still the process `selected` describes. True when the signal was sent.
    The pidfd is taken FIRST, so what is read after it is the process the signal will reach."""
    opener = opener or os.pidfd_open
    sender = sender or signal.pidfd_send_signal
    try:
        fd = opener(pid)
    except OSError:
        return False                       # gone already
    try:
        now = read(pid)
        if now is None or now[1:] != selected[1:]:      # command line, directory, start time
            return False
        sender(fd, sig)
        return True
    except OSError as e:
        print(f"kill-mine: {pid}: {e}", file=sys.stderr)
        return False
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def default_dir():
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
        if top.returncode == 0 and top.stdout.strip():
            return top.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.getcwd()


def main(argv):
    ap = argparse.ArgumentParser(prog="kill-mine.py", add_help=True)
    ap.add_argument("--under")
    ap.add_argument("--signal", default="TERM")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("pattern")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 22
    sig = SIGNALS.get(a.signal.upper().removeprefix("SIG"))
    if sig is None:
        print(f"kill-mine: unknown signal {a.signal!r} (TERM, INT, HUP or KILL)", file=sys.stderr)
        return 22
    if not a.pattern.strip():
        print("kill-mine: an empty pattern matches every process", file=sys.stderr)
        return 22
    try:
        rx = re.compile(a.pattern)
    except re.error as e:
        print(f"kill-mine: bad pattern: {e}", file=sys.stderr)
        return 22
    root = os.path.realpath(a.under or default_dir())
    if not os.path.isdir(root):
        print(f"kill-mine: {root} is not a directory", file=sys.stderr)
        return 22
    home = os.path.realpath(os.path.expanduser("~"))
    if root == "/" or under(home, root):
        print(f"kill-mine: refused: {root} holds the home directory, so it is every lane on this host. "
              f"Name the worktree: --under <dir>", file=sys.stderr)
        return 2

    procs = {}
    for name in os.listdir("/proc"):
        if name.isdigit():
            info = read_proc(int(name))
            if info:
                procs[int(name)] = info

    spared = set()                         # this process and every ancestor of it
    p = os.getpid()
    while p > 1 and p not in spared:
        spared.add(p)
        p = procs[p][0] if p in procs else 0

    matching = {pid for pid, info in procs.items() if pid not in spared and rx.search(info[1])}
    taken = {pid for pid in matching if under(procs[pid][2], root)}
    for pid in sorted(matching - taken):   # a matching descendant of a taken process, wherever it stands now
        up, seen = procs[pid][0], set()
        while up in procs and up not in seen:
            if up in taken:
                taken.add(pid)
                break
            seen.add(up)
            up = procs[up][0]
    elsewhere = matching - taken

    done = 0
    for pid in sorted(taken):
        cmd = procs[pid][1]
        if a.dry_run:
            print(f"would signal {pid}  {cmd[:100]}")
            done += 1
        elif signal_one(pid, procs[pid], sig):
            print(f"signalled {pid}  {cmd[:100]}")
            done += 1
    verb = "would be signalled" if a.dry_run else "signalled"
    print(f"kill-mine: {done} {verb} ({sig.name}) under {root}; "
          f"{len(elsewhere)} matching elsewhere left alone")
    return 0 if done else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
