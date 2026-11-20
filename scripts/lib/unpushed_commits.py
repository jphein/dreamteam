#!/usr/bin/env python3
"""dreamteam — the measuring half of CHECK unpushed-commits (scripts/unpushed-commits-check.sh, docs/CHECKS.md).

    unpushed_commits.py <now-epoch> <min-age-seconds> <root> [<root> ...]

For every top-level directory of each root that is a git repository, answer two questions:
  - has it commits on HEAD that NO remote-tracking branch holds, the oldest of them at least <min-age> old?  → ahead
  - has it commits and no remote at all?                                                                   → no-remote
Both mean: this history exists on this disk (and its file-synced copies) only. 2026-11-18: one repo had 14 such
commits for 16 days and another had no remote; nobody was told.

Output, one TSV line per finding, then exactly one RESULT line:
    ahead      <root>/<name>  <commits>  <oldest epoch>
    no-remote  <root>/<name>  <commits>  <oldest epoch>
    error      <root>/<name>  0          0                 (git could not answer: counted, never read as clean)
    RESULT repos=<git repos looked at> ahead=<a> noremote=<n> errors=<e> young=<y> empty=<m>
young = ahead, but the oldest such commit is younger than <min-age> (work in progress, not reported).
empty = a repository with no commit yet.

What "ahead" means here, and its limits (say them in the report, do not paper over them):
  - Only HEAD is asked about. A local branch that is not checked out is not looked at: after a squash merge the
    local feature branch keeps commits no remote holds, and listing those would bury the real cases.
  - "No remote-tracking branch holds it" is this clone's last knowledge of its remotes. Nothing is fetched (a check
    must not write into a repository), so a commit that reached the remote by another road still reads as ahead.
  - Age is the committer date of the oldest such commit. A rebase renews it.
Read-only: git runs with GIT_OPTIONAL_LOCKS=0, no hooks, no fsmonitor, no prompt, every transport forbidden
(`protocol.allow=never`) and lazy fetching off (GIT_NO_LAZY_FETCH, git 2.45+), and only `config --get-regexp`,
`symbolic-ref`, `show-ref`, `rev-parse`, `remote` and `rev-list`, each under one timeout. A PARTIAL clone (promisor
remote) is not inspected at all and counts as an error: on a git older than 2.45 a missing object there could
start a fetch, which writes. A HEAD that exists but cannot be resolved to a commit is an error, never "empty".
A directory whose name holds a control character (tab, newline, ...) is not inspected: it is an error, listed
with each such character shown as "?". A directory that cannot be looked into is an error too, never skipped.
Exit: 0 RESULT printed · 2 a root is not a readable directory (nothing after it is trusted) · 22 bad arguments.
"""
import os
import subprocess
import sys

ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")
for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    ENV.pop(k, None)
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never"]
try:
    TIMEOUT = float(os.environ.get("DREAMTEAM_UNPUSHED_GIT_TIMEOUT", "120"))
    if not 0 < TIMEOUT <= 3600:
        raise ValueError
except ValueError:
    TIMEOUT = 120.0


def run(repo, *args):
    """(exit status, stdout text) of ONE git call under the timeout; (None, "") when it could not run or finish."""
    try:
        p = subprocess.run(GIT + ["-C", repo] + list(args), env=ENV, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "replace")


def git(repo, *args):
    """stdout text, or None when git did not exit 0 in time."""
    rc, out = run(repo, *args)
    return out if rc == 0 else None


def plain(name):
    """A directory name as one printable TSV field: every control character becomes "?"."""
    return "".join("?" if (ord(c) < 32 or ord(c) == 127) else c for c in name)


def stamps(text):
    """rev-list --timestamp output → list of epochs; None when a line is not `<epoch> <sha>`."""
    out = []
    for line in text.splitlines():
        head = line.split(" ", 1)[0]
        if not head.isdigit():
            return None
        out.append(int(head))
    return out


def look(repo):
    """→ (kind, commits, oldest) with kind in clean | empty | ahead-candidate | no-remote | error."""
    # A partial clone is not inspected: `config --get-regexp` exits 1 for "no such key", 0 when one is set.
    rc, _ = run(repo, "config", "--get-regexp", r"^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$")
    if rc != 1:
        return ("error", 0, 0)
    rc, _ = run(repo, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    if rc is None:
        return ("error", 0, 0)
    if rc != 0:
        # "empty" only for a truly unborn branch: HEAD names a branch and that branch ref does not exist. A HEAD
        # whose ref exists but whose object is missing or not a commit also fails --verify, and that is an error.
        rc_s, ref = run(repo, "symbolic-ref", "-q", "HEAD")
        ref = ref.strip()
        if rc_s != 0 or not ref.startswith("refs/heads/"):
            return ("error", 0, 0)
        rc_r, _ = run(repo, "show-ref", "--verify", "-q", ref)
        return ("empty", 0, 0) if rc_r == 1 else ("error", 0, 0)
    remotes = git(repo, "remote")
    if remotes is None:
        return ("error", 0, 0)
    if not remotes.strip():
        text = git(repo, "rev-list", "--timestamp", "HEAD")
        ts = stamps(text) if text is not None else None
        if not ts:
            return ("error", 0, 0)
        return ("no-remote", len(ts), min(ts))
    text = git(repo, "rev-list", "--timestamp", "HEAD", "--not", "--remotes")
    ts = stamps(text) if text is not None else None
    if ts is None:
        return ("error", 0, 0)
    if not ts:
        return ("clean", 0, 0)
    return ("ahead-candidate", len(ts), min(ts))


def main(argv):
    if len(argv) < 4 or not argv[1].isdigit() or not argv[2].isdigit():
        print("usage: unpushed_commits.py <now-epoch> <min-age-seconds> <root> [<root> ...]", file=sys.stderr)
        return 22
    now, min_age, roots = int(argv[1]), int(argv[2]), argv[3:]
    tot = dict(repos=0, ahead=0, noremote=0, errors=0, young=0, empty=0)
    for root in roots:
        if not os.path.isabs(root) or not os.path.isdir(root):
            print(f"unpushed_commits: not a readable directory: {root}", file=sys.stderr)
            return 2
        try:
            names = sorted(os.listdir(root))
        except OSError:
            print(f"unpushed_commits: cannot list {root}", file=sys.stderr)
            return 2
        for name in names:
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isdir(path):
                continue
            # Is it a repository? Only "there is no .git here" makes it not one. A directory we may not look into
            # (or any other failure to ask) is a repository we could not measure, never a directory we may skip.
            try:
                os.lstat(os.path.join(path, ".git"))
            except FileNotFoundError:
                continue
            except OSError:
                tot["repos"] += 1
                tot["errors"] += 1
                print(f"error\t{root}/{plain(name)}\t0\t0")
                continue
            tot["repos"] += 1
            if plain(name) != name:
                # A name with a control character cannot be written as one TSV field. It is not inspected and is
                # an error under its name with each such character shown as "?": stable from run to run, and
                # never a finding, so it has no owner and no memory of its own.
                tot["errors"] += 1
                print(f"error\t{root}/{plain(name)}\t0\t0")
                continue
            shown = path
            kind, n, oldest = look(path)
            if kind == "error":
                tot["errors"] += 1
                print(f"error\t{shown}\t0\t0")
            elif kind == "empty":
                tot["empty"] += 1
            elif kind == "no-remote":
                tot["noremote"] += 1
                print(f"no-remote\t{shown}\t{n}\t{oldest}")
            elif kind == "ahead-candidate":
                if now - oldest >= min_age:
                    tot["ahead"] += 1
                    print(f"ahead\t{shown}\t{n}\t{oldest}")
                else:
                    tot["young"] += 1
    print("RESULT " + " ".join(f"{k}={v}" for k, v in tot.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
