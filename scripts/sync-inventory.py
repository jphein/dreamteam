#!/usr/bin/env python3
"""dreamteam — phase 0 of the sync replacement: a READ-ONLY inventory of a synced projects folder.

Spec: docs/superpowers/specs/2026-11-17-sync-replacement-design.md §5, phase 0. Before any folder leaves the file
syncer, this answers per project: what would be stranded if this directory became a plain git clone?

    sync-inventory.py [--root ~/Projects] [--no-size] [--only NAME ...] > inventory.tsv

One TSV row per top-level directory (header first), then a `#` summary on stderr:

    name  kind  size_mb  branch  unpushed  dirty  untracked  kept_ignored  kept_ignored_mb  conflicts  note

    kind          git | plain (no .git: everything in it is unversioned)
    size_mb       du of the tree without .git (blank with --no-size)
    unpushed      commits on HEAD that no remote branch holds (all of them when the repo has no remote)
    dirty         tracked files that differ from HEAD
    untracked     untracked, not ignored entries (a directory counts once)
    kept_ignored  ignored entries that are NOT regenerable (so: .env files, scratch/, data, local state). Dependency
                  and build dirs (node_modules, venvs, caches, build output) are left out: a clone rebuilds them.
    conflicts     `*.sync-conflict-*` files, outside .git / node_modules / .stversions
    note          no-remote · no-commits · detached · refs-may-lag · git-error:<what>

It never writes: git runs with GIT_OPTIONAL_LOCKS=0 (no index refresh) and only status / rev-list / rev-parse /
remote. In a tree whose `.git` does not sync, `dirty` can be the refs lagging the files rather than real edits; the
row then says `refs-may-lag` (HEAD's commit is older than the newest tracked file change by more than a day) so
nobody commits a phantom diff. Heavy on a big tree: run it on a lane host or under `ionice -c3 nice -n 15`.

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
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")


def git(repo, *args, timeout=120):
    """(rc, stdout) of a read-only git command in repo; rc 124 on timeout, 127 when git is absent."""
    try:
        p = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, env=ENV, timeout=timeout,
                           errors="replace")
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 124, ""
    except OSError:
        return 127, ""


def du_mb(path, exclude_git=True):
    """Size in MB by du (fast, one process); None when du cannot read it."""
    cmd = ["du", "-sk"] + (["--exclude=.git"] if exclude_git else []) + ["--", path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        return round(int(p.stdout.split()[0]) / 1024, 1)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def conflicts(path):
    n = 0
    for _dir, dirs, files in os.walk(path, onerror=lambda e: None):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        n += sum(1 for f in files if ".sync-conflict-" in f)
    return n


def regenerable(rel):
    return any(part in REGENERABLE for part in rel.rstrip("/").split("/"))


def inspect_git(repo, want_size):
    row = {"kind": "git", "note": []}
    rc, head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
    if rc in (124, 127):
        row["note"].append("git-error:" + ("timeout" if rc == 124 else "no-git"))
        return row
    if rc != 0:
        row["note"].append("no-commits")
    rc, br = git(repo, "symbolic-ref", "-q", "--short", "HEAD")
    row["branch"] = br.strip() if rc == 0 else ""
    if rc != 0 and head.strip():
        row["note"].append("detached")
    rc, remotes = git(repo, "remote")
    has_remote = rc == 0 and bool(remotes.strip())
    if not has_remote:
        row["note"].append("no-remote")
    if head.strip():
        rc, out = git(repo, "rev-list", "--count", "HEAD", "--not", "--remotes")
        row["unpushed"] = int(out.strip()) if rc == 0 and out.strip().isdigit() else ""
        if rc != 0:
            row["note"].append("git-error:rev-list")
    rc, out = git(repo, "status", "--porcelain=v1", "-z", "--ignored", timeout=600)
    if rc != 0:
        row["note"].append("git-error:status")
        return row
    dirty = untracked = kept = 0
    kept_kb = 0
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
                    mb = du_mb(os.path.join(repo, rel), exclude_git=False)
                    kept_kb += int((mb or 0) * 1024)
        else:
            dirty += 1
    row.update(dirty=dirty, untracked=untracked, kept_ignored=kept)
    if want_size:
        row["kept_ignored_mb"] = round(kept_kb / 1024, 1)
    if dirty and head.strip():
        rc, out = git(repo, "log", "-1", "--format=%ct", "HEAD")
        try:
            newest = max(os.lstat(os.path.join(repo, f)).st_mtime
                         for f in os.listdir(repo) if f != ".git")
            if rc == 0 and newest - int(out.strip()) > 86400:
                row["note"].append("refs-may-lag")
        except (OSError, ValueError):
            pass
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
    tot = {"git": 0, "plain": 0, "unpushed": 0, "dirty": 0, "untracked": 0, "kept": 0, "conflicts": 0, "stranded": 0}
    for n in names:
        p = os.path.join(root, n)
        if os.path.exists(os.path.join(p, ".git")):
            row = inspect_git(p, not ns.no_size)
        else:
            row = {"kind": "plain", "note": []}
        row["name"] = n
        row["conflicts"] = conflicts(p)
        if not ns.no_size:
            mb = du_mb(p)
            row["size_mb"] = "" if mb is None else mb
        tot[row["kind"]] += 1
        for k, src in (("unpushed", "unpushed"), ("dirty", "dirty"), ("untracked", "untracked"),
                       ("kept", "kept_ignored"), ("conflicts", "conflicts")):
            v = row.get(src)
            tot[k] += v if isinstance(v, int) else 0
        if row["kind"] == "plain" or any(isinstance(row.get(k), int) and row.get(k) > 0
                                         for k in ("unpushed", "dirty", "untracked", "kept_ignored")) \
                or "no-remote" in row["note"]:
            tot["stranded"] += 1
        row["note"] = " ".join(row["note"])
        print("\t".join(str(row.get(c, "")).replace("\t", " ").replace("\n", " ") for c in COLS))
    print(f"# {len(names)} dirs: {tot['git']} git, {tot['plain']} plain · unpushed commits {tot['unpushed']} · "
          f"dirty {tot['dirty']} · untracked {tot['untracked']} · kept ignored {tot['kept']} · "
          f"conflict copies {tot['conflicts']} · dirs with something a clone would not carry: {tot['stranded']}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
