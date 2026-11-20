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
Read-only: git runs with GIT_OPTIONAL_LOCKS=0, no hooks, no fsmonitor, no prompt, and only `rev-parse`, `remote`
and `rev-list`. Directory names with a tab or newline are reported as errors by position, never printed raw.
Exit: 0 RESULT printed · 2 a root is not a readable directory (nothing after it is trusted) · 22 bad arguments.
"""
import os
import subprocess
import sys

ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
    ENV.pop(k, None)
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]


def git(repo, *args):
    """stdout text, or None when git did not exit 0 in time."""
    try:
        p = subprocess.run(GIT + ["-C", repo] + list(args), env=ENV, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


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
    head = subprocess.run(GIT + ["-C", repo, "rev-parse", "--verify", "-q", "HEAD^{commit}"], env=ENV,
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if head.returncode == 1:
        # rc 1 from --verify -q is "no such commit": a repository with nothing committed. Anything else is a failure.
        inside = git(repo, "rev-parse", "--git-dir")
        return ("empty", 0, 0) if inside is not None else ("error", 0, 0)
    if head.returncode != 0:
        return ("error", 0, 0)
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
        for i, name in enumerate(names):
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isdir(path):
                continue
            if not os.path.lexists(os.path.join(path, ".git")):
                continue
            tot["repos"] += 1
            shown = path if not any(c in name for c in "\t\n\r") else f"{root}/<entry {i} with an odd name>"
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
