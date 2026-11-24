# systemd/system: SYSTEM units kept here as the copy of record

The units in `systemd/` one level up are user units, linked from this checkout. The ones in this directory are
different: they are installed in `/etc/systemd/system` on the build server and run a script installed in
`/usr/local/bin`. They ran from no repository until 2026-11-20 (the 2026-11-17 timer audit found them); this
directory and `scripts/host/` now hold the text that is deployed.

| unit | installed at | runs | copy of record |
|---|---|---|---|
| `reap-fambuild-agents.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/bin/reap-fambuild-agents 2` as the login user, daily | here, and `scripts/host/reap-fambuild-agents` |
| `dreamteam-io-shield.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/sbin/dreamteam-io-shield apply` as root, at boot and every 5 min; does nothing without `/etc/dreamteam/io-shield.conf` | here, and `scripts/host/io-shield` |
| `user@.service.d/20-delegate-io.conf` | `/etc/systemd/system/user@<uid>.service.d/` | hands the io controller to that user's manager (effective inside it from the next boot) | here |

Nothing installs these from the repo yet. A change is made here first, then copied to the host with root and
`systemctl daemon-reload`.

What `tests/test-vendored-units.sh` does and does not hold:
- It pins the script and both unit files by sha256, so any edit here is red until the digest is changed in the same
  reviewed commit. It does not judge the script's behaviour.
- It runs `systemd-analyze verify` on temp copies of both units, with the copy's `ExecStart` pointed at `/bin/true`
  (the real path exists only on the host). That step is skipped, with a note, where the tool is missing.
- It cannot see the host. Whether the installed files still match these is a CHECK row's job (docs/CHECKS.md,
  `reap-fambuild-agents`), and that line is not written yet.

## io-shield and the lanes slice (Flow row 7e039111)

Order on a host, each step reversible:

1. `/etc/dreamteam/io-shield.conf` (host data, not in this repo). For example:

       device nvme0n1 rlat=2000 wlat=5000 min=25 max=100
       docker mempalace-db 20
       unit syncthing@jp.service 20
       oomprotect 1000 -500

2. Trial before anything persists: run `scripts/host-io-check.sh` (the before line), then
   `sudo scripts/host/io-shield apply`, then the check again under the same load. `sudo scripts/host/io-shield off`
   undoes it; a reboot does too. The latency targets are per drive: if the after line is worse, or the batch work
   becomes too slow, raise `rlat` / `wlat` or `min` and try again.
3. Install: copy `scripts/host/io-shield` to `/usr/local/sbin/dreamteam-io-shield` (root, 0755), the two
   `dreamteam-io-shield.*` units to `/etc/systemd/system/`, `systemctl daemon-reload`,
   `systemctl enable --now dreamteam-io-shield.timer`.
4. The drop-in: `/etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf`, `systemctl daemon-reload`. Nothing
   running is disturbed; the user manager uses the controller from the next boot.
5. As the user: `.lanes` in `config.<host>.json` (enabled, exclude, weights, memory), `scripts/lane-slice.sh install`,
   link and enable `dreamteam-lane-slice.timer` and `dreamteam-host-io.timer`.

The lead (Flow row f72945bc): `.lanes.lead` names the lead's tmux session; `lane-slice.sh attach` writes the
`user.oomd_avoid` mark on its pane's scope (systemd-oomd then passes it over), and the `oomprotect <uid> -500`
line makes root give every process in a marked scope that kernel OOM score. Lanes get neither.

`tests/test-io-shield.sh` runs the tool against fixture files and stub commands; it cannot see a host.
