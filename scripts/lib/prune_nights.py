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

Which clones. Inside a prunable night EVERY entry is judged the same way, whatever its name (a `.pruning-…` name
left by an interrupted run earns nothing). It is deleted only when ALL of this holds:
  1. It is a real directory (a symlink is never followed and never removed) with a plain `.git` directory whose
     storage is its own: `objects` and `refs` are real directories, `HEAD` and `config` are plain files, and there
     is no `commondir`, `objects/info/alternates`, `worktrees` or `modules`.
  2. Its config is one this tool can trust WITHOUT running anything from it. An agent worked in these clones, so
     the local config is read as data first (`git config --local --no-includes --list`) and every key must be on a
     short list: the keys a fresh clone has, branch tracking, user.name/email. Anything else (a filter, an ssh
     command, a helper, an include, a second remote, a partial-clone setting) keeps the clone. The one remote is
     `origin` and its URL is `https://github.com/<owner>/<name>[.git]`, nothing else.
  3. Nothing in it changed in the last DREAMTEAM_PRUNE_QUIET_HOURS hours (default 6), and no process has its
     working directory or an open file inside it.
  4. git answers FOR THAT DIRECTORY (its parent is the discovery ceiling) and every git call exits 0 within the
     timeout. Every call forbids all transports and lazy fetching: this tool never fetches, so nothing in the clone
     is changed by judging it and no local ref can be moved before it is compared.
  5. HEAD is on a branch; `git status --untracked-files=all` prints nothing; no index entry is marked
     assume-unchanged or skip-worktree (status cannot see changes to those); there is no stash.
  6. Every commit this clone holds in ANY way (all refs, tags included, and every reflog) is reachable from its
     remote-tracking branches (`rev-list --all --reflog --not --remotes` is empty).
  7. And those remote-tracking branches are true NOW: for each tip, the forge is asked, from outside the clone
     (`gh api …/compare/<tip>...<branch>`, run in `/`), whether that commit is still on the default branch or on
     the branch of the same name. A tip the forge does not confirm (branch deleted, history rewritten, a ref
     someone pointed at a local commit, or the forge unreachable) keeps the clone.
  6 and 7 together are the proof: every commit is under a tracking tip, and every tracking tip is on the remote.
What this keeps on purpose: a clone whose fix branch was squash-merged and deleted on the remote (its commits are
not on the remote any more); a clone whose history was amended or rebased (the reflog holds the old commits).
Ignored files (build output) are not looked at: these are the nightly's own fresh clones.

How a clone is deleted, and what that does and does not guarantee.
  - Every directory is opened O_NOFOLLOW and used by descriptor, never by a re-resolved path.
  - After the first judgment the clone is RENAMED inside its night to `.pruning-<name>-<random>`. From then on a
    user coming by path finds nothing under the old name.
  - The renamed directory is opened; it must be the inode that was judged. Then the process table is scanned for
    any working directory or open file inside it, it is JUDGED AGAIN in full (so a write that landed between the
    first judgment and the rename is seen), and scanned once more.
  - Only then are its contents removed, THROUGH THAT DESCRIPTOR (so what is emptied is the judged directory, not
    whatever now has its name), and the empty directory is removed only if the name still leads to that inode.
  - Whenever a step says no, the directory is renamed back if its name is free; otherwise it stays under the
    `.pruning-…` name and the next run judges it like any other entry.
  This is NOT a lock. Nothing else in the fleet takes a lock on a clone, so none can be shared. What remains
  possible: a process of ANOTHER user (invisible in /proc), or one that opens the renamed directory by listing the
  night between the last scan and the removal. The nightly allows one runner at a time, this runs inside it after
  FINISHED, and only nights before the previous one are candidates; those are the reasons this window is accepted.
  A night directory is removed only when it has become empty.

Output: one JSON object on stdout:
    {"tonight": "...", "protected": [...], "pruned": ["<night>/<name>", ...],
     "kept": [{"clone": "<night>/<name>", "why": "..."}], "ignored": ["<name>", ...], "dry_run": false}
With --dry-run nothing is renamed or removed (the forge is still asked: that reads only).
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
import urllib.parse

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1", LC_ALL="C")
for _k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
           "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_OBJECT_DIRECTORY"):
    ENV.pop(_k, None)
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
       "-c", "protocol.allow=never"]
# The local config keys a clone may have. Everything else keeps it (rule 2).
CONFIG_OK = re.compile(r"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)"
                       r"|remote\.origin\.(url|fetch)|branch\..+\.(remote|merge)|user\.(name|email))$")
REMOTE_URL = re.compile(r"^https://github\.com/([A-Za-z0-9][A-Za-z0-9._-]{0,99})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?$")
FETCH_DEFAULT = "+refs/heads/*:refs/remotes/origin/*"
SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")


def number(name, default, lo, hi):
    try:
        v = float(os.environ.get(name, default))
        return v if lo <= v <= hi else float(default)
    except ValueError:
        return float(default)


TIMEOUT = number("DREAMTEAM_PRUNE_GIT_TIMEOUT", "120", 1, 3600)
QUIET = number("DREAMTEAM_PRUNE_QUIET_HOURS", "6", 0, 24 * 365) * 3600
FORGE = {}                                             # (owner/name, tip, branch) → True/False/None, for this run


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


def forge_has(repo, tip, branch):
    """True when the forge says commit `tip` is on `branch` of `repo` now; False when it says no; None when it could
    not be asked. Run in `/` with this process's own gh login: nothing from any clone is involved."""
    key = (repo, tip, branch)
    if key in FORGE:
        return FORGE[key]
    url = f"repos/{repo}/compare/{tip}...{urllib.parse.quote(branch, safe='')}"
    try:
        p = subprocess.run(["gh", "api", url, "--jq", ".status"], cwd="/", env=ENV, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        FORGE[key] = None
        return None
    out = p.stdout.decode("utf-8", "replace").strip()
    if p.returncode == 0 and out in ("ahead", "identical"):
        ans = True                                     # the branch is at or ahead of the tip: the tip is on it
    elif p.returncode == 0 and out in ("behind", "diverged"):
        ans = False
    elif p.returncode != 0 and b"HTTP 404" in p.stderr:
        ans = False                                    # the branch (or the commit) is not there any more
    else:
        ans = None
    FORGE[key] = ans
    return ans


def default_branch(repo):
    key = (repo, "", "")
    if key not in FORGE:
        try:
            p = subprocess.run(["gh", "api", f"repos/{repo}", "--jq", ".default_branch"], cwd="/", env=ENV,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
            out = p.stdout.decode("utf-8", "replace").strip()
            FORGE[key] = out if p.returncode == 0 and re.match(r"^[A-Za-z0-9._/-]{1,200}$", out) and not out.startswith("-") else None
        except (OSError, subprocess.TimeoutExpired):
            FORGE[key] = None
    return FORGE[key]


def users_of(real, skip_pid):
    """A short text naming a process that has its working directory or an open file at or below `real`, else None.
    "" + text is a reason to keep. Entries we may not read belong to other users and are skipped (stated limit)."""
    prefix = real + "/"
    try:
        pids = [e for e in os.listdir("/proc") if e.isdigit() and int(e) != skip_pid]
    except OSError:
        return "the process table could not be read"
    for pid in pids:
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if cwd == real or cwd.startswith(prefix):
            return f"a process is working in it (pid {pid})"
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(f"/proc/{pid}/fd/{fd}")
            except OSError:
                continue
            if target == real or target.startswith(prefix):
                return f"a process has a file open in it (pid {pid})"
    return None


def newest_change(clone_fd):
    newest = os.fstat(clone_fd).st_mtime
    for rel in (".git", ".git/HEAD", ".git/index", ".git/logs/HEAD", ".git/config", ".git/refs", ".git/refs/heads"):
        try:
            newest = max(newest, os.stat(rel, dir_fd=clone_fd, follow_symlinks=False).st_mtime)
        except FileNotFoundError:
            continue
    return newest


def layout(clone_fd):
    """None when `.git` is a plain directory holding its own storage, else why not."""
    def kind(rel):
        try:
            return os.stat(rel, dir_fd=clone_fd, follow_symlinks=False).st_mode
        except FileNotFoundError:
            return None
    m = kind(".git")
    if m is None:
        return "not a git clone (no .git)"
    if not stat.S_ISDIR(m):
        return "its .git is not a directory (a worktree or submodule checkout, not a plain clone)"
    for rel in (".git/objects", ".git/refs"):
        m = kind(rel)
        if m is None or not stat.S_ISDIR(m):
            return f"its {rel} is not a plain directory"
    for rel in (".git/HEAD", ".git/config"):
        m = kind(rel)
        if m is None or not stat.S_ISREG(m):
            return f"its {rel} is not a plain file"
    for rel in (".git/commondir", ".git/objects/info/alternates", ".git/worktrees", ".git/modules"):
        if kind(rel) is not None:
            return f"its storage is not its own ({rel} exists)"
    return None


def judge(path, clone_fd, now, dry):
    """None when the clone may go, else the reason it stays. `path` is the real path of the directory behind clone_fd."""
    try:
        why = layout(clone_fd)
    except OSError:
        return "its .git could not be read"
    if why:
        return why
    try:
        # the clock is read at each judgment (the second one runs later than `now`), and a change stamped after
        # that reading is "just now", never a negative age
        age = max(0.0, max(now, time.time()) - newest_change(clone_fd))
    except OSError:
        return "its times could not be read"
    if age < QUIET:
        return f"changed {int(age // 60)} min ago (quiet period {QUIET / 3600:g} h)"
    busy = users_of(path, os.getpid())
    if busy:
        return busy

    # rule 2: the config, read as data, before any command that would act on it
    rc, out = git(path, "config", "--local", "--no-includes", "--null", "--list")
    if rc != 0:
        return "its config could not be read"
    conf = {}
    for item in out.split("\0"):
        if not item:
            continue
        k, _, v = item.partition("\n")
        if not CONFIG_OK.match(k):
            return f"a config key this tool does not trust ({k[:60]})" if re.match(r"^[A-Za-z0-9._-]+$", k[:60]) \
                else "a config key this tool does not trust"
        conf.setdefault(k, []).append(v)
    urls = conf.get("remote.origin.url", [])
    if not urls:
        return "no remote"
    m = REMOTE_URL.match(urls[0]) if len(urls) == 1 else None
    if not m or m.group(2) in (".", ".."):
        return "its remote is not one plain https://github.com/<owner>/<name> URL"
    if conf.get("remote.origin.fetch", []) != [FETCH_DEFAULT]:
        return "its fetch refspec is not the default one"
    repo = f"{m.group(1)}/{m.group(2)}"

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
    rc, out = git(path, "ls-files", "-v", "-z")
    if rc != 0:
        return "git could not list the index"
    for entry in out.split("\0"):
        if entry and (entry[0].islower() or entry[0] == "S"):
            return "index entries hidden from status (assume-unchanged or skip-worktree)"
    rc, _ = git(path, "rev-parse", "--verify", "-q", "refs/stash")
    if rc == 0:
        return "a stash"
    if rc != 1:
        return "git could not say whether there is a stash"
    rc, out = git(path, "rev-list", "--count", "--all", "--reflog", "--not", "--remotes")
    if rc != 0 or not out.strip().isdigit():
        return "git could not compare with the remote"
    if int(out.strip()) != 0:
        return f"{int(out.strip())} commit(s) its remote-tracking branches do not hold"
    # rule 7: the tracking branches themselves, against the forge as it is now
    rc, out = git(path, "for-each-ref", "--format=%(objectname) %(symref) %(refname)", "refs/remotes/")
    if rc != 0:
        return "git could not list the remote-tracking branches"
    tips = []
    for line in out.split("\n"):
        if not line:
            continue
        parts = line.split(" ")
        if len(parts) != 3 or not SHA.match(parts[0]) or not parts[2].startswith("refs/remotes/origin/"):
            return "a remote-tracking ref this tool cannot read"
        if parts[1]:                                   # origin/HEAD is a pointer to another tracking ref
            continue
        tips.append((parts[0], parts[2][len("refs/remotes/origin/"):]))
    if not tips:
        return "no remote-tracking branch"
    main = default_branch(repo)
    if main is None:
        return "the forge could not be asked"
    for tip, branch in tips:
        on_main = forge_has(repo, tip, main)
        if on_main is True:
            continue
        on_own = forge_has(repo, tip, branch) if branch != main else on_main
        if on_own is True:
            continue
        if on_main is None or on_own is None:
            return "the forge could not be asked"
        return f"origin/{branch[:60]} is not on the remote any more" if re.match(r"^[A-Za-z0-9._/-]+$", branch[:60]) \
            else "a remote-tracking branch is not on the remote any more"
    return None


def empty_through(fd):
    """Remove everything inside the directory behind `fd`, through the descriptor."""
    for entry in os.listdir(fd):
        st = os.stat(entry, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISDIR(st.st_mode):
            shutil.rmtree(entry, dir_fd=fd)
        else:
            os.unlink(entry, dir_fd=fd)


def put_back(night_fd, night_path, tomb, name):
    """After a refusal: the directory gets its name back when that name is free. Returns words for the report."""
    if tomb == name:
        return ""
    try:
        if os.path.lexists(os.path.join(night_path, name)):
            return f"; it stays as {tomb}: its name was taken meanwhile"
        os.rename(tomb, name, src_dir_fd=night_fd, dst_dir_fd=night_fd)
        return ""
    except OSError:
        return f"; it stays as {tomb}"


def consider(night_fd, night_path, night, name, now, dry, res):
    label = f"{night}/{name}"
    keep = lambda why: res["kept"].append({"clone": label, "why": why})   # noqa: E731
    try:
        st = os.stat(name, dir_fd=night_fd, follow_symlinks=False)
    except OSError:
        return keep("it could not be looked at")
    if stat.S_ISLNK(st.st_mode):
        return keep("a symlink (never followed, never removed)")
    if not stat.S_ISDIR(st.st_mode):
        return keep("not a directory")
    try:
        clone_fd = os.open(name, NOFOLLOW_DIR, dir_fd=night_fd)
    except OSError:
        return keep("it could not be opened")
    try:
        path = os.path.join(night_path, name)
        try:
            if not os.path.samestat(os.stat(path, follow_symlinks=False), os.fstat(clone_fd)):
                raise OSError("moved")
        except OSError:
            return keep("its path does not lead to it")
        why = judge(path, clone_fd, now, dry)
        if why is not None:
            return keep(why)
        if dry:
            res["pruned"].append(label)
            return None
        judged = os.fstat(clone_fd)
        if name.startswith(".pruning-"):
            tomb = name                                # already set aside by an earlier run; judged afresh above
        else:
            tomb = f".pruning-{name}-{secrets.token_hex(6)}"
            try:
                os.rename(name, tomb, src_dir_fd=night_fd, dst_dir_fd=night_fd)
            except OSError:
                return keep("it could not be set aside")
        tomb_path = os.path.join(night_path, tomb)
        try:
            tomb_fd = os.open(tomb, NOFOLLOW_DIR, dir_fd=night_fd)
        except OSError:
            return keep("it was replaced while being judged" + put_back(night_fd, night_path, tomb, name))
        try:
            if not os.path.samestat(os.fstat(tomb_fd), judged):
                return keep("it was replaced while being judged" + put_back(night_fd, night_path, tomb, name))
            # set aside: scan, judge again in full, scan again; any "no" puts it back
            why = users_of(tomb_path, os.getpid()) or judge(tomb_path, tomb_fd, now, dry) or users_of(tomb_path, os.getpid())
            if why is not None:
                return keep(why + " (found after it was set aside)" + put_back(night_fd, night_path, tomb, name))
            try:
                empty_through(tomb_fd)
            except OSError:
                return keep(f"removal did not finish; the rest is {tomb}")
            try:
                if os.path.samestat(os.stat(tomb, dir_fd=night_fd, follow_symlinks=False), judged):
                    os.rmdir(tomb, dir_fd=night_fd)
            except OSError:
                pass                                   # emptied; a directory of that name that is not ours stays
            res["pruned"].append(label)
        finally:
            os.close(tomb_fd)
    finally:
        os.close(clone_fd)
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
                consider(night_fd, os.path.join(base_real, night), night, name, now, dry, res)
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
