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
       oomprotect 1000 lead-spire.scope -500

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

The lead (Flow row f72945bc). `scripts/lead-watchdog.sh` launches the lead in a unit it names and creates,
`lead-<session>.scope`, with `ManagedOOMPreference=avoid` set at creation (systemd-oomd then passes it over). The
`oomprotect <uid> lead-<session>.scope -500` line makes root give each process in exactly that cgroup whose score
is not already negative the kernel OOM score, and WRITE A RECORD of it first (`/run/dreamteam-io-shield/<pid>`:
start time, unit, the score written, the score it had). **The helper undoes only what it recorded**: a process it
scored that has left the unit gets its previous score back; `off` puts every recorded score back. **A negative
score it has no record of is never written to, anywhere**: not in a system service, not in a login session, not
elsewhere in the user's slice, not inside the lead's unit. (The rule is from 2026-11-23, when an earlier version
reset three services' scores on serialhub and the next version would still have reset a login session's.)
Nothing a lane can mark, name or configure earns the score. The limit that remains: the lead and the lanes are
one uid, and a same-uid process can put itself into that cgroup. That needs lanes under their own uid; no check
in a script closes it.

### Rollback (each line undoes one thing; all of it is safe to run twice)

    sudo dreamteam-io-shield off            # io.cost off, unit and container weights reset, every score THIS TOOL
                                            # recorded back to what it was (nothing else is written), and a stamp
                                            # so the timer's apply does nothing until `on` or a reboot
    sudo systemctl disable --now dreamteam-io-shield.timer
    scripts/lane-slice.sh uninstall         # lanes' processes moved out of the slice, lane scopes stopped, fleet
                                            # scope weights reset, slice + drop-ins removed, attach timer disabled
    systemctl --user disable --now dreamteam-host-io.timer
    sudo rm /etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf && sudo systemctl daemon-reload

What `off` and `uninstall` do not undo: a lane scope's processes stay in `out-<session>.scope` (a plain scope,
no limits) until they end; the delegation drop-in stays until the last line. Reinstalling: `lane-slice.sh install`
again reconciles (a unit dropped from `.lanes.units` loses its drop-in), then `sudo dreamteam-io-shield on`.

### Acceptance on the host itself (nothing above is accepted from another host's numbers)

Run on the host being enabled, in this order, and keep the output. Everything measured so far was measured on
serialhub; familiar's drive, memory and load are different.

1. **Before:** `scripts/host-io-check.sh` under the load that hurts (a gate plus the palace suite), three times.
   Note the gate's wall time.
2. **Overlay and memory:** `free -m`; the sum of `memory.current` for `system.slice`, the lead's scope and
   `session-*.scope`; then set `.lanes.memoryHigh` = MemTotal − 2048 MB − that sum, and `.lanes.perLane.memoryHigh`
   no lower than the lane maximum plus one balloon (4700M on familiar's 11-17 numbers). Two measured floors exist
   for ADMISSION (lane start 6800 MB available, nightly 5500 MB; both with 4096 MB swap free): they say when a
   lane may start, not what it may use, and they are not replaced by these limits.
3. **Trial, nothing persistent, WITH THE PROOF OF WHAT IT DID NOT TOUCH:**
   `sudo IO_SHIELD_BIN=scripts/host/io-shield scripts/host/io-shield-accept <uid> apply`, then `io-shield status`.
   `io-shield-accept` lists every negative OOM score of that user before the run, runs the helper, reads the same
   processes again (pid and start time) and must end in `ACCEPT`. It names these units one by one, and each must
   read `untouched` with its score on the host it lives on (an `absent` there is a finding too):
   - familiar: `palace-daemon.service` (-500), `qwen3-coder.service` (-500), `familiar-loadguard.service` (-800),
     `donkey-llm.service` (-100);
   - serialhub: `octoprint.service`, `ustreamer.service`, `ustreamer-builtin.service` (-900 each).
   A `REJECT` (exit 1) means the helper changed a score it did not write: put the scores back from the units'
   `OOMScoreAdjust`, do not enable the timer. The same script with `off` goes with every rollback.
4. **After, same load:** `scripts/host-io-check.sh` three times; the gate's wall time again. Accept only if the
   victim's fsync p99 is back near its idle value AND the gate still finishes inside its deadline. If the gate is
   starved, raise `min=` or the latency targets and repeat; if nothing helps, `io-shield off`.
5. **Placement:** `scripts/lane-slice.sh install`, `attach`, `status`: every lane in the slice, the lead and every
   excluded session outside it, fleet scopes counted. `io-shield status`: the lead's unit, its scores (which
   are the tool's own), and the ledger.
6. **Negative cases:** a throwaway scope with another name, and one that marks itself `user.oomd_avoid`, get no
   score after `apply` (`/home/jp/work/iotest/oomprotect-live.sh` on serialhub is the model).
7. **After the next boot:** `lane-slice.sh status` must say the io controller is in use by the user manager; until
   then IOWeight on lanes.slice does nothing and only the system-side weights (step 3) are in force.
8. **Repeat-install and rollback:** `install` twice, then the rollback block above, then `status` on both tools.

`tests/test-io-shield.sh` runs the tool against fixture files and stub commands; it cannot see a host.
