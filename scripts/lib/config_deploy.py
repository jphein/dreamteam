#!/usr/bin/env python3
"""dreamteam — the file-replacement core of scripts/config-pull.sh (sync replacement, phase 2).

    python3 -I config_deploy.py <bare-git-dir> <head-sha> <live-dir> <backup-dir> <skip-prefix>

Prints one line:  RESULT total=<T> updated=<U> edits=<E> skipped=<S> displaced=<D>
Exit 0 when the pass completed (whatever it found), 2 when it could not measure (git or the live root unusable).

The one rule: a live file is replaced only when nothing can be lost by it: it is absent, or its exact bytes are a
version of THAT SAME PATH recorded by a commit reachable from the head. Anything else is a local edit: left alone
and counted. Nothing the head does not track is touched; nothing is ever removed.

How it stays safe against the tree changing underneath it:
- Every directory on the way to a file is opened one component at a time with O_NOFOLLOW and then PINNED by its file
  descriptor; all later operations on the file (stat, read, link, rename) are relative to that descriptor. A parent
  directory that is swapped for a symlink mid-pass cannot redirect a write: the descriptor still names the original
  directory. A symlinked component is never entered: the path is counted as an edit.
- New bytes are written to a uniquely named temp file in that same directory (O_CREAT|O_EXCL).
- An absent file is published with link(2), which never replaces: a file that appears meanwhile survives.
- A present file is first hard-linked into the backup directory. That link shares the live file's inode, so it is a
  witness: it is judged, the temp file is renamed over the live name, and the witness is judged AGAIN. If the hard
  link cannot be made (another filesystem), the file is NOT replaced: a copy would not be a witness.
- An in-place write that lands after the witness was judged is NOT put back automatically: its bytes are in the
  witness (kept in the backup directory) and the pass reports "displaced".
- Not excluded: an editor that REPLACES the live file (by rename, i.e. a new inode) between our witness link and our
  rename. That interval covers reading the witness and, the first time a path is judged, one `git log` for it: short,
  but not just two system calls. Such a replacement would be lost; the job says so and does not claim otherwise.
"""
import hashlib
import os
import secrets
import stat
import subprocess
import sys

NOFOLLOW_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Unmeasured(Exception):
    """git or the live root could not be read: the pass must not report a result."""


def git(gitdir, *args):
    p = subprocess.run(["git", "--git-dir", gitdir, "--literal-pathspecs", *args], capture_output=True)
    if p.returncode != 0:
        raise Unmeasured("git " + args[0])
    return p.stdout


def blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class Deployer:
    def __init__(self, gitdir, head, live, backup, skip):
        self.gitdir, self.head, self.live, self.backup, self.skip = gitdir, head, live, backup, skip
        self.history = {}
        self.total = self.updated = self.edits = self.skipped = self.displaced = 0

    def versions(self, path):
        """Every blob id a commit reachable from the head recorded at exactly this path (whole output consumed)."""
        if path not in self.history:
            out = git(self.gitdir, "log", "-m", "--format=", "--raw", "--no-abbrev", "--no-renames", self.head, "--", path)
            ids = set()
            for line in out.decode("ascii", "replace").splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[0].startswith(":"):
                    ids.update(parts[2:4])
            ids.discard("0" * 40)
            self.history[path] = ids
        return self.history[path]

    def lossless(self, path, data):
        return blob_id(data) in self.versions(path)

    def open_parent(self, rootfd, path):
        """A pinned descriptor for the directory holding <path>, or None when a component is a symlink or not a
        directory. Missing directories are created (they hold nothing, so nothing can be lost)."""
        fd = os.dup(rootfd)
        try:
            for comp in path.split("/")[:-1]:
                try:
                    nxt = os.open(comp, NOFOLLOW_DIR, dir_fd=fd)
                except FileNotFoundError:
                    try:
                        os.mkdir(comp, 0o755, dir_fd=fd)
                    except FileExistsError:
                        pass
                    try:
                        nxt = os.open(comp, NOFOLLOW_DIR, dir_fd=fd)
                    except OSError:
                        os.close(fd)
                        return None
                except OSError:           # ELOOP (a symlink), ENOTDIR, EACCES: never entered
                    os.close(fd)
                    return None
                os.close(fd)
                fd = nxt
            return fd
        except BaseException:
            os.close(fd)
            raise

    @staticmethod
    def read_at(dfd, name):
        """Bytes of a REGULAR file <name> in the pinned directory, or None (absent) / False (not a regular file)."""
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=dfd)
        except FileNotFoundError:
            return None
        except OSError:
            return False
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return False
            chunks = []
            while True:
                b = os.read(fd, 1 << 20)
                if not b:
                    break
                chunks.append(b)
            return b"".join(chunks)
        finally:
            os.close(fd)

    @staticmethod
    def ensure_exec(dfd, name):
        """Make a regular file executable through a descriptor opened with O_NOFOLLOW (never through a path that
        could have become a symlink). True when it is executable afterwards."""
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=dfd)
        except OSError:
            return False
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                return False
            if not st.st_mode & 0o100:
                os.fchmod(fd, (st.st_mode | 0o111) & 0o777)
            return True
        except OSError:
            return False
        finally:
            os.close(fd)

    @staticmethod
    def write_temp(dfd, data, mode):
        """A uniquely named file with <data> in the pinned directory; returns its name."""
        for _ in range(20):
            name = ".config-pull." + secrets.token_hex(6)
            try:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=dfd)
            except FileExistsError:
                continue
            try:
                view = memoryview(data)
                while view:
                    n = os.write(fd, view)
                    view = view[n:]
                os.fchmod(fd, mode)
                os.fsync(fd)
            finally:
                os.close(fd)
            return name
        raise OSError("no free temp name")

    @staticmethod
    def unlink_quiet(name, dfd=None):
        try:
            os.unlink(name, dir_fd=dfd)
        except OSError:
            pass

    def one(self, rootfd, mode, blob, path):
        self.total += 1
        fmode = 0o755 if mode == "100755" else 0o644
        dfd = self.open_parent(rootfd, path)
        if dfd is None:
            self.edits += 1
            return
        name = path.rsplit("/", 1)[-1]
        try:
            cur = self.read_at(dfd, name)
            if cur is False:                       # a symlink, a directory, a device: never written
                self.edits += 1
                return
            if cur is not None and blob_id(cur) == blob:
                if fmode == 0o755 and not self.ensure_exec(dfd, name):
                    self.edits += 1            # the repo wants it executable and that could not be made so
                return
            new = git(self.gitdir, "cat-file", "blob", blob)
            if blob_id(new) != blob:
                raise Unmeasured("cat-file returned other bytes")
            tmp = self.write_temp(dfd, new, fmode)
            try:
                if cur is None:
                    try:
                        os.link(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)   # never replaces
                        self.updated += 1
                    except OSError:
                        self.edits += 1
                    return
                # the witness: a hard link to the live file's inode, in the backup directory (ours)
                bak = os.path.join(self.backup, path)
                os.makedirs(os.path.dirname(bak), mode=0o700, exist_ok=True)
                self.unlink_quiet(bak)
                try:
                    os.link(name, bak, src_dir_fd=dfd, follow_symlinks=False)
                except OSError:
                    self.edits += 1             # no witness (another filesystem, or the file went away): not replaced
                    return
                bfd = os.open(os.path.dirname(bak), NOFOLLOW_DIR)
                try:
                    witness = self.read_at(bfd, os.path.basename(bak))
                    if not isinstance(witness, bytes) or not self.lossless(path, witness):
                        self.unlink_quiet(os.path.basename(bak), bfd)
                        self.edits += 1
                        return
                    os.rename(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
                    tmp = None
                    again = self.read_at(bfd, os.path.basename(bak))
                    if not isinstance(again, bytes) or not self.lossless(path, again):
                        # An editor wrote into the old file after it was judged. Its bytes are IN the witness, which
                        # stays in the backup directory. Nothing is put back automatically: a second rename could
                        # itself displace something newer. The pass reports it; a person or a lane restores it.
                        self.displaced += 1
                        return
                    self.updated += 1
                finally:
                    os.close(bfd)
            finally:
                if tmp is not None:
                    self.unlink_quiet(tmp, dfd)
        finally:
            os.close(dfd)

    def run(self):
        try:
            rootfd = os.open(self.live, NOFOLLOW_DIR)
        except OSError:
            raise Unmeasured("live dir")
        try:
            tree = git(self.gitdir, "ls-tree", "-r", "-z", "--full-tree", self.head)
            for rec in tree.split(b"\0"):
                if not rec:
                    continue
                meta, _, raw = rec.partition(b"\t")
                try:
                    path = raw.decode("utf-8")
                    mode, typ, blob = meta.decode("ascii").split(" ")
                except ValueError:
                    self.skipped += 1
                    continue
                if path.startswith(self.skip):
                    continue
                parts = path.split("/")
                if typ != "blob" or mode not in ("100644", "100755") or any(p in ("", ".", "..") for p in parts) or "\n" in path:
                    self.skipped += 1          # submodules, tracked symlinks, odd names: never written
                    continue
                self.one(rootfd, mode, blob, path)
        finally:
            os.close(rootfd)


def main(argv):
    if len(argv) != 5:
        print("usage: config_deploy.py <git-dir> <head> <live-dir> <backup-dir> <skip-prefix>", file=sys.stderr)
        return 22
    gitdir, head, live, backup, skip = argv
    if not (os.path.isabs(gitdir) and os.path.isabs(live) and os.path.isabs(backup)) or not skip.endswith("/"):
        print("config_deploy: absolute paths and a skip prefix ending in / are required", file=sys.stderr)
        return 22
    d = Deployer(gitdir, head, live, backup, skip)
    try:
        d.run()
    except Unmeasured as e:
        print(f"config_deploy: could not measure ({e})", file=sys.stderr)
        return 2
    print(f"RESULT total={d.total} updated={d.updated} edits={d.edits} skipped={d.skipped} displaced={d.displaced}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
