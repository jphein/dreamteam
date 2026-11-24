"""dreamteam — io_probe: what does this disk feel like to an interactive process, right now?

For SECONDS it does what a session at a prompt does to a disk: one 4 KiB O_DIRECT read at a random offset of a
probe file per loop (a page that is not in the cache), and every 5th loop a 4 KiB append + fdatasync to a small
file (a transcript line). It prints one JSON object with the p50 / p99 / max of each, in milliseconds.

WHY a victim and not only PSI (Flow row 7e039111): pressure says somebody waited. On a quiet host one
sequential reader waiting on its own reads is "full" I/O pressure with nobody harmed, and a host can freeze a
person's typing at a pressure that looks modest. Measured on an NVMe (2026-11-21): alone fsync p99 4.5 ms;
beside 4 readers and 1 writer 453 ms; with io.cost latency targets and a 10:100 weight 7.7 ms.

  io_probe.py DIR SECONDS [SIZE_MIB]     DIR must be on the disk to judge; the probe file is made there once
Exit 0 with the JSON · 2 the probe could not run (reason on stderr; e.g. a filesystem without O_DIRECT).
The load it adds: about 400 reads and 80 small synced writes a second for SECONDS, one thread.
"""
import json
import mmap
import os
import random
import sys
import time


def q(v, p):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(len(v) * p))], 2) if v else None


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: io_probe.py DIR SECONDS [SIZE_MIB]", file=sys.stderr)
        return 22
    try:
        d, seconds = argv[0], float(argv[1])
        size_mib = int(argv[2]) if len(argv) == 3 else 64
        if not (0 < seconds <= 60 and 1 <= size_mib <= 4096):
            raise ValueError
    except ValueError:
        print("io_probe: SECONDS must be in (0, 60] and SIZE_MIB in 1..4096", file=sys.stderr)
        return 22
    path, log = os.path.join(d, "io-probe.bin"), os.path.join(d, "io-probe.log")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        want = size_mib * 1048576
        if not os.path.isfile(path) or os.path.getsize(path) != want:
            tmp = f"{path}.tmp.{os.getpid()}"
            with open(tmp, "wb") as fh:                      # real data: a hole would be read without the disk
                for _ in range(size_mib):
                    fh.write(os.urandom(1048576))
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, path)
        fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
        wfd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    except OSError as e:
        print(f"io_probe: {e}", file=sys.stderr)
        return 2
    buf, block = mmap.mmap(-1, 4096), b"x" * 4096
    blocks = os.fstat(fd).st_size // 4096
    reads, syncs, i, end = [], [], 0, time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            t = time.perf_counter()
            os.preadv(fd, [buf], random.randrange(blocks) * 4096)
            reads.append((time.perf_counter() - t) * 1000)
            i += 1
            if i % 5 == 0:
                t = time.perf_counter()
                os.write(wfd, block)
                os.fdatasync(wfd)
                syncs.append((time.perf_counter() - t) * 1000)
            time.sleep(0.002)
    except OSError as e:
        print(f"io_probe: {e}", file=sys.stderr)
        return 2
    finally:
        os.close(fd)
        os.close(wfd)
    if not reads or not syncs:
        print("io_probe: no complete operation in the time given", file=sys.stderr)
        return 2
    print(json.dumps({"reads": len(reads), "read_p50": q(reads, .5), "read_p99": q(reads, .99), "read_max": round(max(reads), 1),
                      "fsyncs": len(syncs), "fsync_p50": q(syncs, .5), "fsync_p99": q(syncs, .99), "fsync_max": round(max(syncs), 1)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
