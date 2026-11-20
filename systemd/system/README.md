# systemd/system: SYSTEM units kept here as the copy of record

The units in `systemd/` one level up are user units, linked from this checkout. The ones in this directory are
different: they are installed in `/etc/systemd/system` on the build server and run a script installed in
`/usr/local/bin`. They ran from no repository until 2026-11-20 (the 2026-11-17 timer audit found them); this
directory and `scripts/host/` now hold the text that is deployed.

| unit | installed at | runs | copy of record |
|---|---|---|---|
| `reap-fambuild-agents.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/bin/reap-fambuild-agents 2` as the login user, daily | here, and `scripts/host/reap-fambuild-agents` |

Nothing installs these from the repo yet. A change is made here first, then copied to the host with root and
`systemctl daemon-reload`.

What `tests/test-vendored-units.sh` does and does not hold:
- It pins the script and both unit files by sha256, so any edit here is red until the digest is changed in the same
  reviewed commit. It does not judge the script's behaviour.
- It runs `systemd-analyze verify` on temp copies of both units, with the copy's `ExecStart` pointed at `/bin/true`
  (the real path exists only on the host). That step is skipped, with a note, where the tool is missing.
- It cannot see the host. Whether the installed files still match these is a CHECK row's job (docs/CHECKS.md,
  `reap-fambuild-agents`), and that line is not written yet.
