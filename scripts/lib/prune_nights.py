#!/usr/bin/env python3
"""dreamteam — move the nightly's OLD per-night clones into a quarantine, then delete them from there by age (#250).

    prune_nights.py [--dry-run] --quarantine <dir> [--quarantine <dir> ...] [--keep-days 14] [--min-free-pct 10]
                    <wt_base> <tonight YYYY-MM-DD>

The nightly clones each repo into <wt_base>/<night>/<name> and never removed them (1.8 GB a night on a small root).
The design is MOVE-THEN-DELETE, RENAME ONLY (the lead, 2026-11-20, after four review rounds):
  1. In every quarantine dir, entries older than --keep-days are deleted (by the date in their name, never mtime).
  2. A quarantine dir whose filesystem has less than --min-free-pct free takes nothing; the result says so and the
     nightly puts it in its CHECK line. The reading is taken again before every single move.
  3. Each old clone the SELECTOR passes is moved, by ONE rename, to <quarantine>/<night>__<name>__q<YYYYMMDD> in
     the quarantine dir that lies on the SAME FILESYSTEM as the clone. There it stays whole for --keep-days.
     A clone whose filesystem has no quarantine dir is not moved at all: it stays, and is named in the result.
Nothing is ever copied, and nothing is deleted on the night it is selected: a rename is atomic, so a clone is in
its night or in the quarantine, never half in both, and a wrong selection can be undone by hand for two weeks.
What that costs, stated plainly: a quarantine on the clone's own filesystem frees no space on the night of the
move. The space comes back when the entry expires.
The selector below is therefore a SELECTOR, not a proof. It is kept as strict as the reviews made it, because the
stricter it is, the less often a clone someone still needs is moved at all.

Which nights. A night is a directory directly under <wt_base> whose name is a real calendar date earlier than
<tonight>. Tonight is never touched, nor is the newest earlier night (the previous night's clones are the ones a
person still reads in the morning). Names that are not a date, impossible dates (2026-00-99), dates that are not
earlier than tonight, symlinks and plain files are not nights: left alone and listed under "ignored".

Which clones. Inside a prunable night EVERY entry is judged the same way, whatever its name (a `.pruning-…` name
left by an interrupted run earns nothing). It is selected (moved to quarantine) only when ALL of this holds:
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
  6. Every commit reachable from any ref or reflog is reachable from its remote-tracking branches (`rev-list
     --all --reflog --not --remotes` is empty), AND every COMMIT and TAG OBJECT in the object store, referenced or
     not (a commit left dangling by a reset and an expired reflog is still in the store), is reachable from the
     remote-tracking branches or from a tag the forge has. History is read as it is: no grafts file, no shallow
     file, no replace refs, replacement processing off.
  7. And those remote-tracking branches are true NOW: for each tip, the forge is asked, from outside the clone
     (`gh api …/compare/<tip>...<branch>`, run in `/`), whether that commit is still on the default branch or on
     the branch of the same name; and every local tag must be a tag the forge lists with the same object. A tip or
     tag the forge does not confirm (deleted, rewritten, pointed at a local commit, or the forge unreachable)
     keeps the clone.
  6 and 7 together are the proof: every commit is under a tracking tip or a remote tag, and each of those is on
  the remote now.
  NOT covered, by decision: blobs and trees that no commit holds (content that was staged and then dropped). They
  are in no commit, `status` does not show them, and nothing short of keeping every clone would preserve them.
What this keeps on purpose: a clone whose fix branch was squash-merged and deleted on the remote (its commits are
not on the remote any more); a clone whose history was amended or rebased (the reflog holds the old commits).
Ignored files (build output) are not looked at: these are the nightly's own fresh clones.

How a selected clone is moved.
  - Every directory is opened O_NOFOLLOW and used by descriptor.
  - After the first judgment the clone is RENAMED inside its night to `.pruning-<name>-<random>`. The renamed
    directory must be the inode that was judged; the process table is scanned for a working directory, an open
    file or a mapped file inside it; it is JUDGED AGAIN in full; scanned once more; and the name is re-checked
    without following symlinks (still that directory, still inside the night that was opened).
  - The quarantine's free share is read again, and then ONE rename, relative to the two opened directories, takes
    it to its final name in the quarantine. If the kernel says the two are not on one filesystem after all, it is
    not moved. There is no other way a clone leaves its night.
  - Whenever a step says no, the directory is renamed back if its name is free; otherwise it stays under the
    `.pruning-…` name and the next run judges it like any other entry.
  This is not a lock (nothing else in the fleet locks a clone). A process of another user, or one of the owner's
  own that hides its state (non-dumpable: measured 2026-11-20, 15 of 284 on the server, among them the systemd
  user manager and ssh-agent), is invisible to the scans, and a process could open the set-aside directory
  between the last scan and the rename. The cost of that is a clone found whole in the quarantine instead of in
  its night, for 14 days; a process that had it open keeps working in it there.
  A quarantine dir: absolute, no symlink anywhere in its path, outside <wt_base>. Its path is checked BEFORE
  anything is created, and missing components are created one by one inside directories already opened without
  following links. Only entries named `<YYYY-MM-DD>__<name>__q<YYYYMMDD>` that are real directories are ever
  deleted from it, when the q-date is --keep-days or more before <tonight>. Anything else in it is left alone.
  A night directory is removed only when it has become empty.

Output: one JSON object on stdout:
    {"tonight": "...", "protected": [...], "moved": ["<night>/<name>", ...], "expired": ["<quarantine entry>", ...],
     "kept": [{"clone": "<night>/<name>", "why": "..."}], "ignored": ["<name>", ...], "dry_run": false,
     "no_quarantine": ["<night>/<name>", ...],        (clones on a filesystem that has no quarantine dir)
     "quarantine": [{"dir": "...", "free_pct": 37, "min_free_pct": 10, "keep_days": 14, "refused": false}, ...]}
With --dry-run nothing is renamed, moved or removed (the forge is still asked: that reads only); "moved" and
"expired" then list what would be.
Exit: 0 the object was printed · 2 <wt_base> or a quarantine is not a plain directory we can use · 22 bad arguments.
"""
import datetime
import errno
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
# Git reads ONLY the clone's own config, which the selector has checked key by key. The runner's global and system
# config and attributes are switched off: a filter defined there could be turned on by a clone's .gitattributes.
ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1",
           GIT_NO_REPLACE_OBJECTS="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_ATTR_NOSYSTEM="1",
           LC_ALL="C")
for _k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
           "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_OBJECT_DIRECTORY",
           "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_REPLACE_REF_BASE"):
    ENV.pop(_k, None)
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
       "-c", "protocol.allow=never", "-c", "core.useReplaceRefs=false", "-c", "core.attributesFile=/dev/null"]
GH_ENV = dict(os.environ)                              # the forge is asked with the runner's own environment and login
# The local config keys a clone may have. Everything else keeps it (rule 2).
CONFIG_OK = re.compile(r"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)"
                       r"|remote\.origin\.(url|fetch)|branch\..+\.(remote|merge)|user\.(name|email))$")
REMOTE_URL = re.compile(r"^https://github\.com/([A-Za-z0-9][A-Za-z0-9._-]{0,99})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?$")
FETCH_DEFAULT = "+refs/heads/*:refs/remotes/origin/*"
SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")
QNAME = re.compile(r"^(\d{4}-\d{2}-\d{2})__(.+)__q(\d{4})(\d{2})(\d{2})(?:-\d+)?$")


def number(name, default, lo, hi):
    try:
        v = float(os.environ.get(name, default))
        return v if lo <= v <= hi else float(default)
    except ValueError:
        return float(default)


TIMEOUT = number("DREAMTEAM_PRUNE_GIT_TIMEOUT", "120", 1, 3600)
QUIET = number("DREAMTEAM_PRUNE_QUIET_HOURS", "6", 0, 24 * 365) * 3600
READS = [0]                                            # how often the free share was read (test seam)
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
        p = subprocess.run(["gh", "api", url, "--jq", ".status"], cwd="/", env=GH_ENV, stdin=subprocess.DEVNULL,
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


def forge_tags(repo):
    """{tag name: object id} as the forge lists them now, or None when it could not be asked."""
    key = (repo, "tags", "")
    if key not in FORGE:
        ans = None
        try:
            p = subprocess.run(["gh", "api", "--paginate", f"repos/{repo}/git/matching-refs/tags/",
                                "--jq", '.[] | "\\(.ref) \\(.object.sha)"'], cwd="/", env=GH_ENV, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
            if p.returncode == 0:
                ans = {}
                for line in p.stdout.decode("utf-8", "surrogateescape").split("\n"):
                    if not line:
                        continue
                    ref, _, sha = line.rpartition(" ")
                    if not ref.startswith("refs/tags/") or not SHA.match(sha):
                        ans = None
                        break
                    ans[ref[len("refs/tags/"):]] = sha
        except (OSError, subprocess.TimeoutExpired):
            ans = None
        FORGE[key] = ans
    return FORGE[key]


def default_branch(repo):
    key = (repo, "", "")
    if key not in FORGE:
        try:
            p = subprocess.run(["gh", "api", f"repos/{repo}", "--jq", ".default_branch"], cwd="/", env=GH_ENV,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
            out = p.stdout.decode("utf-8", "replace").strip()
            FORGE[key] = out if p.returncode == 0 and re.match(r"^[A-Za-z0-9._/-]{1,200}$", out) and not out.startswith("-") else None
        except (OSError, subprocess.TimeoutExpired):
            FORGE[key] = None
    return FORGE[key]


def users_of(real, skip_pid):
    """A short text naming a process that has its working directory, an open file or a mapped file at or below
    `real`, else None. A process whose entries cannot be read (another user's, or one of ours that hides its state)
    is skipped: the header states that limit and why "keep on any such process" is not an option."""
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
        try:
            with open(f"/proc/{pid}/maps", encoding="utf-8", errors="surrogateescape") as mf:
                for line in mf:
                    at = line.find("/")
                    if at != -1 and line[at:].rstrip("\n").startswith(prefix):
                        return f"a process has a file of it mapped (pid {pid})"
        except OSError:
            continue
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
    # files that change what "parent" means: a graft can hang a local-only commit under a genuine remote tip
    for rel in (".git/info/grafts", ".git/shallow", ".git/refs/replace"):
        if kind(rel) is not None:
            return f"its history is not read as it is ({rel} exists)"
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
    # local tags: each must be a tag the forge lists, with the same object
    rc, out = git(path, "for-each-ref", "--format=%(objectname) %(refname)", "refs/tags/")
    if rc != 0:
        return "git could not list the tags"
    tag_ids = []
    if out.strip():
        there = forge_tags(repo)
        if there is None:
            return "the forge could not be asked"
        for line in out.split("\n"):
            if not line:
                continue
            sha, _, ref = line.partition(" ")
            if not SHA.match(sha) or not ref.startswith("refs/tags/"):
                return "a tag this tool cannot read"
            if there.get(ref[len("refs/tags/"):]) != sha:
                return "a tag the remote does not have"
            tag_ids.append(sha)
    # every commit and tag OBJECT in the store, referenced or not, must be under a tracking tip or a remote tag
    rc, out = git(path, "rev-list", "--remotes", *tag_ids)
    if rc != 0:
        return "git could not walk the remote's history"
    on_remote = set(out.split())
    on_remote.update(tag_ids)
    rc, out = git(path, "cat-file", "--batch-all-objects", "--unordered", "--batch-check=%(objecttype) %(objectname)")
    if rc != 0:
        return "git could not list the object store"
    loose = 0
    for line in out.split("\n"):
        if line.startswith("commit ") or line.startswith("tag "):
            if line.partition(" ")[2] not in on_remote:
                loose += 1
    if loose:
        return f"{loose} commit or tag object(s) in its store that the remote does not hold"
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


def to_quarantine(night_fd, tomb, q, label_night, name):
    """ONE rename from the night into the quarantine on the same filesystem. None when it is there; else why not
    (and then nothing has changed: a rename either happens whole or not at all)."""
    clean = name[len(".pruning-"):] if name.startswith(".pruning-") else name
    final = f"{label_night}__{clean}__q{q['stamp']}"
    n = 1
    while os.path.lexists(os.path.join(q["path"], final)):
        n += 1
        final = f"{label_night}__{clean}__q{q['stamp']}-{n}"
        if n > 50:
            return "the quarantine already holds 50 entries under its name"
    try:
        os.rename(tomb, final, src_dir_fd=night_fd, dst_dir_fd=q["fd"])
        return None
    except OSError as e:
        if e.errno == errno.EXDEV:
            return "its quarantine is not on its filesystem after all (nothing is ever copied)"
        return "it could not be moved to the quarantine"


def expire(q, tonight, keep_days, dry):
    """Quarantine entries of OUR name shape whose q-date is keep_days or more before tonight: removed, and named."""
    gone = []
    today = datetime.date.fromisoformat(tonight)
    for name in sorted(os.listdir(q["fd"])):
        m = QNAME.match(name)
        if not m or not real_date(m.group(1)):
            continue
        try:
            qd = datetime.date(int(m.group(3)), int(m.group(4)), int(m.group(5)))
            st = os.stat(name, dir_fd=q["fd"], follow_symlinks=False)
        except (ValueError, OSError):
            continue
        if not stat.S_ISDIR(st.st_mode) or (today - qd).days < keep_days:
            continue
        if not dry:
            try:
                shutil.rmtree(name, dir_fd=q["fd"])
            except OSError:
                continue
        gone.append(name)
    return gone


def free_pct(q):
    """Whole percent of the quarantine's filesystem that an ordinary user can still write, or None."""
    seq = os.environ.get("DREAMTEAM_PRUNE_FREE_PCT_SEQ", "")
    if seq:                                            # test seam: one reading per call, the last one repeats
        vals = seq.split(",")
        i = min(READS[0], len(vals) - 1)
        READS[0] += 1
        return int(vals[i]) if vals[i].isdigit() else None
    forced = os.environ.get("DREAMTEAM_PRUNE_FREE_PCT", "")
    if forced == "unreadable":
        return None                                    # test seam: a statvfs that does not answer
    if forced.isdigit() and int(forced) <= 100:
        return int(forced)                             # test seam: a disk cannot be filled in a test
    try:
        v = os.statvfs(q["fd"])
        return int(v.f_bavail * 100 // v.f_blocks) if v.f_blocks else None
    except OSError:
        return None


def still_there(night_fd, night_path, tomb, tomb_fd, judged):
    """True when the set-aside NAME is still the judged directory (not followed), inside the night that was opened,
    and both descriptors still live where they were opened. A move outside the night, or a symlink put at the
    name, makes this False."""
    try:
        st = os.stat(tomb, dir_fd=night_fd, follow_symlinks=False)
        if not stat.S_ISDIR(st.st_mode) or not os.path.samestat(st, judged):
            return False
        if not os.path.samestat(os.fstat(tomb_fd), judged):
            return False
        if os.readlink(f"/proc/self/fd/{tomb_fd}") != os.path.join(night_path, tomb):
            return False
        if os.readlink(f"/proc/self/fd/{night_fd}") != night_path:
            return False
        return os.path.samestat(os.stat(night_path, follow_symlinks=False), os.fstat(night_fd))
    except OSError:
        return False


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


def consider(night_fd, night_path, night, name, now, dry, res, qs):
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
        # its quarantine is the one on ITS filesystem (a rename cannot cross one, and nothing is ever copied)
        dev = os.fstat(clone_fd).st_dev
        q = next((x for x in qs if x["dev"] == dev), None)
        if q is None:
            res["no_quarantine"].append(label)
            return keep("no quarantine dir on its filesystem: not moved")
        if q["full"]:
            return keep("not looked at: its quarantine is under the free-space floor")
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
            res["moved"].append(label)
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
            moved = "it was moved or replaced after being set aside (left as it is)"
            if not still_there(night_fd, night_path, tomb, tomb_fd, judged):
                return keep(moved)
            # set aside: scan, judge again in full, scan again; any "no" puts it back
            why = users_of(tomb_path, os.getpid()) or judge(tomb_path, tomb_fd, now, dry) or users_of(tomb_path, os.getpid())
            if not still_there(night_fd, night_path, tomb, tomb_fd, judged):
                return keep(moved)                     # the judgment above may have followed a symlink: it counts for nothing
            if why is not None:
                return keep(why + " (found after it was set aside)" + put_back(night_fd, night_path, tomb, name))
            # the floor, read again before EVERY move: the moves before this one, or anything else, may have used
            # the room. Under it (or unreadable): this clone goes back, and no later one is even judged.
            pct = free_pct(q)
            q["report"]["free_pct"] = pct
            if pct is None or pct < q["min_free"]:
                q["report"]["refused"] = True
                q["full"] = True
                return keep("its quarantine went under the free-space floor" + put_back(night_fd, night_path, tomb, name))
            if not still_there(night_fd, night_path, tomb, tomb_fd, judged):
                return keep(moved)
            why = to_quarantine(night_fd, tomb, q, night, name)
            if why is not None:
                return keep(why + put_back(night_fd, night_path, tomb, name))
            res["moved"].append(label)
        finally:
            os.close(tomb_fd)
    finally:
        os.close(clone_fd)
    return None


def main(argv):
    usage = ("usage: prune_nights.py [--dry-run] --quarantine <absolute dir> [--quarantine ...] [--keep-days N] [--min-free-pct N] "
             "<absolute wt_base> <tonight YYYY-MM-DD>")
    args, dry, qdirs, keep_days, min_free = argv[1:], False, [], 14, 10
    try:
        while args and args[0].startswith("--"):
            opt = args.pop(0)
            if opt == "--dry-run":
                dry = True
            elif opt == "--quarantine":
                qdirs.append(args.pop(0))
            elif opt == "--keep-days":
                keep_days = int(args.pop(0))
            elif opt == "--min-free-pct":
                min_free = int(args.pop(0))
            else:
                raise ValueError(opt)
        if (len(args) != 2 or not os.path.isabs(args[0]) or not real_date(args[1]) or not qdirs
                or not all(os.path.isabs(d) for d in qdirs) or not 1 <= keep_days <= 3650 or not 0 <= min_free <= 99):
            raise ValueError("arguments")
    except (ValueError, IndexError):
        print(usage, file=sys.stderr)
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
    # the quarantines: each validated BEFORE anything is created, one per filesystem
    qs, seen_dev = [], set()
    inside = lambda a, b: a == b or a.startswith(b + "/")   # noqa: E731
    for qdir in qdirs:
        qnorm = os.path.normpath(qdir)
        try:
            # containment first, on the names alone: a refused path must not have been created on the way to refusal
            if inside(qnorm, base_real) or inside(base_real, qnorm) or inside(qnorm, os.path.normpath(base)):
                raise OSError("inside the base")
            # then component by component from the root, never through a symlink; a missing component is created
            # (not in a dry run) inside the directory already opened, so nothing can be made behind a link
            qfd = os.open("/", NOFOLLOW_DIR)
            for comp in [c for c in qnorm.split("/") if c]:
                try:
                    nxt = os.open(comp, NOFOLLOW_DIR, dir_fd=qfd)
                except FileNotFoundError:
                    if dry:
                        raise OSError("absent, and a dry run creates nothing") from None
                    os.mkdir(comp, mode=0o700, dir_fd=qfd)
                    nxt = os.open(comp, NOFOLLOW_DIR, dir_fd=qfd)
                os.close(qfd)
                qfd = nxt
            if os.path.realpath(qnorm) != qnorm or not os.path.samestat(os.stat(qnorm), os.fstat(qfd)):
                raise OSError("its path does not lead to it")
            dev = os.fstat(qfd).st_dev
            if dev in seen_dev:
                raise OSError("a second quarantine on one filesystem")
            seen_dev.add(dev)
        except OSError as e:
            print(f"prune_nights: the quarantine {qdir} cannot be used ({e}); nothing was moved", file=sys.stderr)
            return 2
        qs.append({"fd": qfd, "path": qnorm, "dev": dev, "stamp": tonight.replace("-", ""), "min_free": min_free, "full": False,
                   "report": {"dir": qnorm, "free_pct": None, "min_free_pct": min_free, "keep_days": keep_days, "refused": False}})

    res = {"tonight": tonight, "protected": [tonight], "moved": [], "expired": [], "kept": [], "ignored": [], "dry_run": dry,
           "no_quarantine": [], "quarantine": [q["report"] for q in qs]}
    for q in qs:
        res["expired"] += expire(q, tonight, keep_days, dry)   # first: it frees the space the floor is about
        pct = free_pct(q)
        q["report"]["free_pct"] = pct
        if pct is None or pct < min_free:
            q["report"]["refused"] = True                      # this quarantine takes nothing tonight
            q["full"] = True
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
                consider(night_fd, os.path.join(base_real, night), night, name, now, dry, res, qs)
            if not dry:
                try:
                    os.rmdir(night, dir_fd=base_fd)    # only an emptied night goes
                except OSError:
                    pass
        finally:
            os.close(night_fd)
    for q in qs:
        os.close(q["fd"])
    os.close(base_fd)
    print(json.dumps(res, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
