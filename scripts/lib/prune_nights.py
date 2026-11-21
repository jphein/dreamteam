#!/usr/bin/env python3
"""dreamteam — remove the nightly's OLD per-night clones, and only the ones nothing can be lost with (#250).

    prune_nights.py [--dry-run] <wt_base> <tonight YYYY-MM-DD>

The nightly clones each repo into <wt_base>/<night>/<name> and never removed them (1.8 GB a night on a small root).
This deletes directories, so every rule below is a reason to KEEP: a clone goes only when every check answered,
and answered "nothing here exists only here". Anything unclear is kept and named.

Which nights. A night is a directory directly under <wt_base> whose name is a real calendar date earlier than
<tonight>. Tonight is never touched, nor is the newest earlier night (the previous night's clones are the ones a
person still reads in the morning). Names that are not a date, impossible dates (2026-00-99), dates that are not
earlier than tonight, symlinks and plain files are not nights: left alone and listed under "ignored".

Which clones. Inside a prunable night, an entry is deleted only when ALL of this holds:
  - it is a real directory (a symlink is never followed and never removed) holding a `.git` directory;
  - nothing in it changed in the last DREAMTEAM_PRUNE_QUIET_HOURS hours (default 6: the clone dir, .git, HEAD,
    index, the HEAD reflog), and no process has its working directory inside it;
  - git answers FOR THAT DIRECTORY (its parent is the discovery ceiling, so a broken clone cannot be judged as an
    enclosing repository) and every git call exits 0 within the timeout. A call that fails or stalls means keep;
  - HEAD is on a branch (a detached HEAD may hold commits no branch names);
  - `git status --untracked-files=all` (the flag wins over the clone's own status.showUntrackedFiles) prints nothing;
  - there is no stash;
  - it has a remote, EVERY remote was fetched successfully just now (`fetch --prune`: the remote's present state,
    not this clone's memory of it), and after that no commit reachable from HEAD or any local branch is missing
    from the remote-tracking branches.
What that last rule keeps on purpose: a clone whose fix branch was squash-merged and deleted on the remote still
has commits the remote does not hold, so it is kept and named. Nothing here asks the forge whether a pull request
was merged. Ignored files (build output) are not looked at: these are the nightly's own fresh clones.

How a clone is deleted. Every path is walked with directory descriptors opened O_NOFOLLOW, never by a re-resolved
path. The clone is first RENAMED inside its night directory to `.pruning-<name>-<random>`; the renamed directory
must be the same inode that was judged, and still have no process working in it; only then is it removed with
shutil.rmtree(dir_fd=...) (which does not follow symlinks). A directory swapped for another between judgment and
deletion is put back and kept. A `.pruning-*` directory left by an interrupted run was judged by that run and is
removed. A night directory is removed only when it has become empty.

There is NO lock shared with whoever might use a clone: nothing else takes one. What stands in for it: only nights
before the previous one are candidates; the nightly allows one runner at a time and this runs inside it, after
FINISHED; the quiet period; the working-directory scan before and after the rename; and the rename itself, after
which a late user finds the path gone rather than half-deleted. Processes of other users are invisible to the scan.

Output: one JSON object on stdout:
    {"tonight": "...", "protected": [...], "pruned": ["<night>/<name>", ...],
     "kept": [{"clone": "<night>/<name>", "why": "..."}], "ignored": ["<name>", ...], "dry_run": false}
With --dry-run nothing is renamed, fetched or removed; "pruned" lists what would go on the local evidence alone.
Exit: 0 the object was printed · 2 <wt_base> is not a plain directory we can open · 22 bad arguments.
"""
import datetime
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import time

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
for _k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_DISCOVERY_ACROSS_FILESYSTEM"):
    ENV.pop(_k, None)
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
       "-c", "fetch.recurseSubmodules=false"]


def number(name, default, lo, hi):
    try:
        v = float(os.environ.get(name, default))
        return v if lo <= v <= hi else float(default)
    except ValueError:
        return float(default)


TIMEOUT = number("DREAMTEAM_PRUNE_GIT_TIMEOUT", "120", 1, 3600)
QUIET = number("DREAMTEAM_PRUNE_QUIET_HOURS", "6", 0, 24 * 365) * 3600


def real_date(name):
    if not DATE.match(name):
        return False
    try:
        datetime.date.fromisoformat(name)
        return True
    except ValueError:
        return False


def git(path, *args):
    """(exit status, stdout) of one git call that may only answer for `path` itself; (None, "") when it did not finish."""
    env = dict(ENV, GIT_CEILING_DIRECTORIES=os.path.dirname(path))
    try:
        p = subprocess.run(GIT + ["-C", path] + list(args), env=env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout.decode("utf-8", "surrogateescape")


def busy_pid(real):
    """A pid whose working directory is `real` or below it, else None. Unreadable entries are other users' processes."""
    prefix = real + "/"
    try:
        pids = [e for e in os.listdir("/proc") if e.isdigit()]
    except OSError:
        return -1                                      # cannot look: treated as busy by the caller
    for pid in pids:
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if cwd == real or cwd.startswith(prefix):
            return int(pid)
    return None


def newest_change(clone_fd):
    newest = os.fstat(clone_fd).st_mtime
    for rel in (".git", ".git/HEAD", ".git/index", ".git/logs/HEAD", ".git/FETCH_HEAD"):
        try:
            newest = max(newest, os.stat(rel, dir_fd=clone_fd, follow_symlinks=False).st_mtime)
        except FileNotFoundError:
            continue
    return newest


def judge(path, clone_fd, now, dry):
    """None when the clone may go, else the reason it stays. `path` is the real path of the directory behind clone_fd."""
    try:
        st = os.stat(".git", dir_fd=clone_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "not a git clone (no .git)"
    except OSError:
        return "its .git could not be read"
    if not stat.S_ISDIR(st.st_mode):
        return "its .git is not a directory (a worktree or submodule checkout, not a plain clone)"
    try:
        age = now - newest_change(clone_fd)
    except OSError:
        return "its times could not be read"
    if age < QUIET:
        return f"changed {int(age // 60)} min ago (quiet period {QUIET / 3600:g} h)"
    pid = busy_pid(path)
    if pid is not None:
        return "the process table could not be read" if pid == -1 else f"a process is working in it (pid {pid})"

    rc, top = git(path, "rev-parse", "--show-toplevel")
    if rc != 0:
        return "git could not answer for this directory"
    top = top[:-1] if top.endswith("\n") else top
    try:
        same = os.path.samestat(os.stat(top), os.fstat(clone_fd))
    except OSError:
        same = False
    if not same:
        return "git answered for a different directory"
    rc, _ = git(path, "symbolic-ref", "-q", "HEAD")
    if rc == 1:
        return "a detached HEAD"
    if rc != 0:
        return "git could not say what HEAD is"
    rc, out = git(path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none")
    if rc != 0:
        return "git status did not finish"
    if out:
        return "uncommitted or untracked files"
    rc, _ = git(path, "rev-parse", "--verify", "-q", "refs/stash")
    if rc == 0:
        return "a stash"
    if rc != 1:
        return "git could not say whether there is a stash"
    rc, remotes = git(path, "remote")
    if rc != 0:
        return "git could not list the remotes"
    names = [r for r in remotes.split("\n") if r]
    if not names:
        return "no remote"
    if not dry:
        for r in names:
            if r.startswith("-"):
                return "a remote with an option-like name"
            rc, _ = git(path, "fetch", "--prune", "--no-tags", "--quiet", "--", r)
            if rc != 0:
                return "the remote could not be refreshed just now"
    rc, out = git(path, "rev-list", "--count", "HEAD", "--branches", "--not", "--remotes")
    if rc != 0 or not out.strip().isdigit():
        return "git could not compare with the remote"
    if int(out.strip()) != 0:
        return f"{int(out.strip())} commit(s) the remote does not hold"
    return None


def main(argv):
    args = argv[1:]
    dry = False
    if args and args[0] == "--dry-run":
        dry, args = True, args[1:]
    if len(args) != 2 or not os.path.isabs(args[0]) or not real_date(args[1]):
        print("usage: prune_nights.py [--dry-run] <absolute wt_base> <tonight YYYY-MM-DD>", file=sys.stderr)
        return 22
    base, tonight = args
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
        print("prune_nights: no symlink-safe rmtree on this platform; nothing is removed", file=sys.stderr)
        return 2
    try:
        base_fd = os.open(base, NOFOLLOW_DIR)
        base_real = os.path.realpath(base)
        if not os.path.samestat(os.stat(base_real), os.fstat(base_fd)):
            raise OSError("moved")
    except OSError:
        print(f"prune_nights: {base} is not a plain directory that can be opened", file=sys.stderr)
        return 2

    res = {"tonight": tonight, "protected": [tonight], "pruned": [], "kept": [], "ignored": [], "dry_run": dry}
    nights = []
    for name in sorted(os.listdir(base_fd)):
        try:
            st = os.stat(name, dir_fd=base_fd, follow_symlinks=False)
        except OSError:
            res["ignored"].append(name)
            continue
        if name == tonight and stat.S_ISDIR(st.st_mode):
            continue
        if real_date(name) and name < tonight and stat.S_ISDIR(st.st_mode):
            nights.append(name)
        else:
            res["ignored"].append(name)
    if nights:
        res["protected"].append(nights[-1])            # the newest earlier night stays whole
    now = time.time()
    for night in nights[:-1]:
        try:
            night_fd = os.open(night, NOFOLLOW_DIR, dir_fd=base_fd)
        except OSError:
            res["kept"].append({"clone": night, "why": "the night directory could not be opened"})
            continue
        try:
            for name in sorted(os.listdir(night_fd)):
                label = f"{night}/{name}"
                try:
                    st = os.stat(name, dir_fd=night_fd, follow_symlinks=False)
                except OSError:
                    res["kept"].append({"clone": label, "why": "it could not be looked at"})
                    continue
                if stat.S_ISLNK(st.st_mode):
                    res["kept"].append({"clone": label, "why": "a symlink (never followed, never removed)"})
                    continue
                if not stat.S_ISDIR(st.st_mode):
                    res["kept"].append({"clone": label, "why": "not a directory"})
                    continue
                if name.startswith(".pruning-"):
                    # judged and renamed by a run that did not finish: finish it
                    if not dry:
                        try:
                            shutil.rmtree(name, dir_fd=night_fd)
                        except OSError:
                            res["kept"].append({"clone": label, "why": "an unfinished prune that could not be completed"})
                            continue
                    res["pruned"].append(label)
                    continue
                try:
                    clone_fd = os.open(name, NOFOLLOW_DIR, dir_fd=night_fd)
                except OSError:
                    res["kept"].append({"clone": label, "why": "it could not be opened"})
                    continue
                try:
                    path = os.path.join(base_real, night, name)
                    try:
                        if not os.path.samestat(os.stat(path, follow_symlinks=False), os.fstat(clone_fd)):
                            raise OSError("moved")
                    except OSError:
                        res["kept"].append({"clone": label, "why": "its path does not lead to it"})
                        continue
                    why = judge(path, clone_fd, now, dry)
                    if why is not None:
                        res["kept"].append({"clone": label, "why": why})
                        continue
                    if dry:
                        res["pruned"].append(label)
                        continue
                    judged = os.fstat(clone_fd)
                    tomb = f".pruning-{name}-{secrets.token_hex(6)}"
                    try:
                        os.rename(name, tomb, src_dir_fd=night_fd, dst_dir_fd=night_fd)
                    except OSError:
                        res["kept"].append({"clone": label, "why": "it could not be set aside"})
                        continue
                    try:
                        moved = os.stat(tomb, dir_fd=night_fd, follow_symlinks=False)
                        same = stat.S_ISDIR(moved.st_mode) and os.path.samestat(moved, judged)
                    except OSError:
                        same = False
                    busy = busy_pid(os.path.join(base_real, night, tomb)) if same else None
                    if not same or busy is not None:
                        # not the directory that was judged, or someone arrived: put it back under its name
                        back = "it was put back"
                        try:
                            # the rename back must not replace a directory that took the name meanwhile
                            if os.path.lexists(os.path.join(base_real, night, name)):
                                back = f"it stays as {tomb}: its name was taken meanwhile"
                            else:
                                os.rename(tomb, name, src_dir_fd=night_fd, dst_dir_fd=night_fd)
                        except OSError:
                            back = f"it stays as {tomb}"
                        res["kept"].append({"clone": label, "why": ("it was replaced while being judged" if not same
                                                                    else "a process began working in it") + f"; {back}"})
                        continue
                    try:
                        shutil.rmtree(tomb, dir_fd=night_fd)
                    except OSError:
                        res["kept"].append({"clone": label, "why": f"removal did not finish; the rest is {tomb}"})
                        continue
                    res["pruned"].append(label)
                finally:
                    os.close(clone_fd)
            if not dry:
                try:
                    os.rmdir(night, dir_fd=base_fd)    # only an emptied night goes
                except OSError:
                    pass
        finally:
            os.close(night_fd)
    os.close(base_fd)
    print(json.dumps(res, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
