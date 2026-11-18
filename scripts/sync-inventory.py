#!/usr/bin/env python3
"""dreamteam — phase 0 of the sync replacement: a READ-ONLY inventory of a synced projects folder.

Spec: docs/superpowers/specs/2026-11-17-sync-replacement-design.md §5, phase 0. Before any folder leaves the file
syncer, this answers per project: what would be stranded if this directory became a plain git clone?

    sync-inventory.py [--root ~/Projects] [--no-size] [--only NAME ...] > inventory.tsv

One TSV row per top-level directory (header first), then a `#` summary on stderr:

    name  kind  size_mb  branch  unpushed  dirty  untracked  kept_ignored  kept_ignored_mb  conflicts  note

    kind          git | plain (no .git: everything in it is unversioned)
    size_mb       du of the tree without .git (blank with --no-size, or when du could not read all of it)
    unpushed      commits on HEAD that no remote branch holds (all of them when the repo has no remote)
    dirty         tracked files that differ from HEAD
    untracked     untracked, not ignored entries (a directory counts once)
    kept_ignored  ignored entries that are NOT regenerable (so: .env files, scratch/, data, local state). Dependency
                  and build dirs (node_modules, venvs, caches, build output) are left out: a clone rebuilds them.
    conflicts     `*.sync-conflict-*` files, outside .git / node_modules / .stversions
    note          no-remote · no-commits · detached · has-filters · has-submodules · hidden-index-flags ·
                  partial-clone ·
                  walk-error · size-error · git-error:<what>

A number is printed only when it was measured. A git command that could not answer leaves its columns BLANK and
adds `git-error:<what>`; a walk that met an unreadable directory adds `walk-error` (the count is then a floor); a du
that did not exit 0 leaves the size blank and adds `size-error`. The summary says how many rows carry such a note.

Read-only, and what that covers: git runs with GIT_OPTIONAL_LOCKS=0 (no index refresh), fsmonitor off, hooks off, and
only rev-parse / symbolic-ref / remote / rev-list / status / config --get-regexp. One limit: `git status` may run
a repo's own configured clean/process FILTER (git-lfs, git-crypt) to compare contents. A repo with such a filter is
NOT given to `git status`: its dirty/untracked/kept columns stay blank and the note says `has-filters`.
Submodules are never entered (`--ignore-submodules=all`); a repo with `.gitmodules` says `has-submodules`. Files
flagged assume-unchanged or skip-worktree are invisible to status: such a repo says `hidden-index-flags`. The
repo's own `status.showUntrackedFiles` is overridden (`--untracked-files=normal`). A partial (promisor) clone is
not inspected past HEAD (`partial-clone`): git could fetch a missing object there.

Known limit (accepted, 2026-11-17): the filter and partial-clone checks read `.git/config` just before `git status`
does. A config edit landing between the two could still let a filter run. The trees this is for are the owner's own
repos and `.git` is never synced, so nothing but a local hand edit can change that file mid-run; a hostile repo
needs a sandbox, which this tool is not.

In a tree whose `.git` does not sync, `dirty` can be the refs lagging the files rather than real edits: align the
refs (housekeep → "Synced trees") before committing anything this lists. Heavy on a big tree: run it on a lane host
or under `ionice -c3 nice -n 15`.

Exit: 0 inventory written · 2 the root is not a readable directory · 22 bad arguments.
"""
import argparse
import os
import subprocess
import sys

REGENERABLE = {
    "node_modules", ".pnpm-store", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    "target", "build", "dist", ".gradle", ".next", ".nuxt", ".cache", ".tox", ".turbo", ".parcel-cache", ".stversions",
}
PRUNE = {".git", "node_modules", ".stversions"}
COLS = ["name", "kind", "size_mb", "branch", "unpushed", "dirty", "untracked", "kept_ignored", "kept_ignored_mb",
        "conflicts", "note"]
# GIT_NO_LAZY_FETCH: in a partial (promisor) clone a missing object would otherwise be FETCHED, which writes into
# .git and runs the configured transport. With it set, git reports the object as absent and the row gets git-error.
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C", GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1")
SAFE = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false"]


def git(repo, *args, timeout=120):
    """(rc, stdout) of a read-only git command in repo; rc 124 on timeout, 127 when git cannot be run."""
    try:
        p = subprocess.run(["git", "-C", repo, *SAFE, *args], capture_output=True, text=True, env=ENV,
                           timeout=timeout, errors="replace")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError:
        return 127, ""


def du_kb(path, exclude=(".git",)):
    """Size in KB by du (one process); None unless du exited 0 with a number (a partial read is not a size)."""
    cmd = ["du", "-sk"] + [f"--exclude={x}" for x in exclude] + ["--", path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        if p.returncode != 0:
            return None
        return int(p.stdout.split()[0])
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def conflicts(path):
    """(count, complete): complete is False when any directory could not be listed (the count is then a floor)."""
    n = 0
    errs = []
    for _dir, dirs, files in os.walk(path, onerror=errs.append):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        n += sum(1 for f in files if ".sync-conflict-" in f)
    return n, not errs


def regenerable(rel):
    return any(part in REGENERABLE for part in rel.rstrip("/").split("/"))


def inspect_git(repo, want_size):
    """Columns for one repo. A column is set only when its git command answered."""
    row = {"kind": "git", "note": []}
    note = row["note"].append

    rc, head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
    if rc == 1 and not head.strip():
        has_head = False
        note("no-commits")                      # -q exits 1, silently, exactly when HEAD names no commit
    elif rc == 0 and head.strip():
        has_head = True
    else:
        note("git-error:" + {124: "timeout", 127: "no-git"}.get(rc, "rev-parse"))
        return row                              # nothing below can be trusted

    # A partial (promisor) clone can FETCH a missing object on demand: that writes into .git and runs a transport.
    # GIT_NO_LAZY_FETCH stops it only on a git new enough to know the variable, so such a repo is not inspected
    # further on any version: its columns stay blank.
    rc, out = git(repo, "config", "--get-regexp", r"^(remote\..*\.promisor|extensions\.partialclone)$")
    if rc == 0 and out.strip():
        note("partial-clone")
        return row
    if rc not in (0, 1):                        # 1 = no such key; anything else = config unreadable
        note("git-error:config")
        return row

    rc, br = git(repo, "symbolic-ref", "-q", "--short", "HEAD")
    if rc == 0:
        row["branch"] = br.strip()
    elif rc == 1:                               # -q exits 1 exactly when HEAD is not a symbolic ref
        note("detached")
    else:
        note("git-error:symbolic-ref")

    rc, remotes = git(repo, "remote")
    if rc != 0:
        note("git-error:remote")
    elif not remotes.strip():
        note("no-remote")

    if has_head:
        rc, out = git(repo, "rev-list", "--count", "HEAD", "--not", "--remotes")
        if rc == 0 and out.strip().isdigit():
            row["unpushed"] = int(out.strip())
        else:
            note("git-error:rev-list")

    # A configured clean/process filter is an external program `git status` may run: do not run status there.
    rc, out = git(repo, "config", "--get-regexp", r"^filter\..*\.(clean|process)$")
    if rc == 0 and out.strip():
        note("has-filters")
        return row
    if rc not in (0, 1):                        # 1 = no such key; anything else = config unreadable
        note("git-error:config")
        return row

    # Index flags can hide a changed tracked file from status: say so, never print a clean zero over it.
    rc, out = git(repo, "ls-files", "-v", "-z", timeout=600)
    if rc != 0:
        note("git-error:ls-files")
        return row
    if any(e[:1].islower() or e[:1] == "S" for e in out.split("\0") if e):
        note("hidden-index-flags")              # assume-unchanged (lower case) or skip-worktree (S)

    # Submodules are never entered (their own filters could run): a repo with any is marked, not measured inside.
    if os.path.lexists(os.path.join(repo, ".gitmodules")):
        note("has-submodules")
    rc, out = git(repo, "status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal",
                  "--ignore-submodules=all", timeout=600)
    if rc != 0:
        note("git-error:status")
        return row
    dirty = untracked = kept = 0
    kept_kb = 0
    size_ok = True
    entries = out.split("\0")
    i = 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        xy, rel = e[:2], e[3:]
        if xy[0] in "RC":          # a rename/copy entry is followed by its source path
            i += 1
        if xy == "??":
            untracked += 1
        elif xy == "!!":
            if not regenerable(rel):
                kept += 1
                if want_size:
                    kb = du_kb(os.path.join(repo, rel), exclude=sorted(REGENERABLE))
                    if kb is None:
                        size_ok = False
                    else:
                        kept_kb += kb
        else:
            dirty += 1
    row.update(dirty=dirty, untracked=untracked, kept_ignored=kept)
    if want_size:
        if size_ok:
            row["kept_ignored_mb"] = round(kept_kb / 1024, 1)
        else:
            note("size-error")
    return row


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description="Read-only inventory of a synced projects folder.")
    ap.add_argument("--root", default=os.path.expanduser("~/Projects"))
    ap.add_argument("--no-size", action="store_true", help="skip du (much faster on a slow disk)")
    ap.add_argument("--only", nargs="+", default=None, help="inspect only these top-level names")
    try:
        ns = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 22
    root = ns.root
    if not os.path.isdir(root) or not os.access(root, os.R_OK | os.X_OK):
        print(f"sync-inventory: {root} is not a readable directory", file=sys.stderr)
        return 2
    names = sorted(n for n in os.listdir(root)
                   if os.path.isdir(os.path.join(root, n)) and not os.path.islink(os.path.join(root, n))
                   and n not in PRUNE)
    if ns.only:
        unknown = [n for n in ns.only if n not in names]
        if unknown:
            print(f"sync-inventory: not a directory under {root}: {', '.join(unknown)}", file=sys.stderr)
            return 22
        names = [n for n in names if n in ns.only]
    print("\t".join(COLS))
    tot = {"git": 0, "plain": 0, "unpushed": 0, "dirty": 0, "untracked": 0, "kept": 0, "conflicts": 0,
           "stranded": 0, "unmeasured": 0}
    for n in names:
        p = os.path.join(root, n)
        if os.path.lexists(os.path.join(p, ".git")):
            row = inspect_git(p, not ns.no_size)
        else:
            row = {"kind": "plain", "note": []}
        row["name"] = n
        count, complete = conflicts(p)
        row["conflicts"] = count
        if not complete:
            row["note"].append("walk-error")
        if not ns.no_size:
            kb = du_kb(p)
            if kb is None:
                if "size-error" not in row["note"]:
                    row["note"].append("size-error")
            else:
                row["size_mb"] = round(kb / 1024, 1)
        tot[row["kind"]] += 1
        for k, src in (("unpushed", "unpushed"), ("dirty", "dirty"), ("untracked", "untracked"),
                       ("kept", "kept_ignored"), ("conflicts", "conflicts")):
            v = row.get(src)
            tot[k] += v if isinstance(v, int) else 0
        unmeasured = any(x in ("walk-error", "size-error", "has-filters", "has-submodules", "hidden-index-flags",
                               "partial-clone")
                         or x.startswith("git-error")
                         for x in row["note"])
        tot["unmeasured"] += 1 if unmeasured else 0
        if row["kind"] == "plain" or unmeasured or "no-remote" in row["note"] \
                or any(isinstance(row.get(k), int) and row.get(k) > 0
                       for k in ("unpushed", "dirty", "untracked", "kept_ignored")):
            tot["stranded"] += 1                 # an unmeasured dir is never counted as safe to convert
        row["note"] = " ".join(row["note"])
        print("\t".join(str(row.get(c, "")).replace("\t", " ").replace("\n", " ") for c in COLS))
    floor = " (a floor: see the notes)" if tot["unmeasured"] else ""
    print(f"# {len(names)} dirs: {tot['git']} git, {tot['plain']} plain · unpushed commits {tot['unpushed']} · "
          f"dirty {tot['dirty']} · untracked {tot['untracked']} · kept ignored {tot['kept']} · "
          f"conflict copies {tot['conflicts']} · dirs with something a clone would not carry: {tot['stranded']} · "
          f"dirs not fully measured: {tot['unmeasured']}{floor}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
