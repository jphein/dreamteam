# systemd/system: SYSTEM units kept here as the copy of record

The units in `systemd/` one level up are user units, linked from this checkout. The ones in this directory are
different: they are installed in `/etc/systemd/system` on the build server and run a script installed in
`/usr/local/bin`. They ran from no repository until 2026-11-20 (the 2026-11-17 timer audit found them); this
directory and `scripts/host/` now hold the text that is deployed.

| unit | installed at | runs | copy of record |
|---|---|---|---|
| `reap-fambuild-agents.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/bin/reap-fambuild-agents 2` as the login user, daily | here, and `scripts/host/reap-fambuild-agents` |
| `dreamteam-io-shield.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/sbin/dreamteam-io-shield apply` as root, at boot and every 5 min; does nothing without `/etc/dreamteam/io-shield.conf` | here, and `scripts/host/io-shield` (its acceptance run: `scripts/host/io-shield-accept`) |
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

## io-shield (Flow rows 7e039111, f72945bc)

The root half of the I/O work. The user half (the lanes slice, its budgets and CHECK `<host>-io`) is a separate
change with no root helper (`scripts/lane-slice.sh`, `scripts/host-io-check.sh`, PR #288); where a step below
names one of those and the host does not have it yet, the step waits for it.

Order on a host, each step reversible:

1. `/etc/dreamteam/io-shield.conf` (host data, not in this repo). For example:

       device nvme0n1 rlat=2000 wlat=5000 min=25 max=100
       docker mempalace-db 20
       unit syncthing@jp.service 20
       oomprotect 1000 lead-spire.scope -500

2. Trial before anything persists, through the acceptance script (next section), never the bare helper.
   `sudo scripts/host/io-shield off` undoes it; a reboot does too. The latency targets are per drive: if the
   numbers after are worse, or the batch work becomes too slow, raise `rlat` / `wlat` or `min` and try again.
3. Install: copy `scripts/host/io-shield` to `/usr/local/sbin/dreamteam-io-shield` (root, 0755), the two
   `dreamteam-io-shield.*` units to `/etc/systemd/system/`, `systemctl daemon-reload`,
   `systemctl enable --now dreamteam-io-shield.timer`.
4. The drop-in: `/etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf`, `systemctl daemon-reload`. Nothing
   running is disturbed; the user manager uses the controller from the next boot.

### What the helper writes, and the one case in which it writes back

The lead: `scripts/lead-watchdog.sh` launches it in a unit it names and creates, `lead-<session>.scope`, with
`ManagedOOMPreference=avoid` set at creation (systemd-oomd then passes it over). An
`oomprotect <uid> lead-<session>.scope -500` line makes root give each process in exactly that cgroup whose score
is not already negative the kernel OOM score, and WRITE A RECORD of it first (`/run/dreamteam-io-shield/<pid>`:
start time, unit, the score written, the score it had).

- **The undo is narrower than the write.** A score is written back in ONE case: `off`, the same process (pid and
  start time), still holding the score we wrote, its cgroup still the lead unit named in its record (a
  `lead-<name>.scope` under that user's `app.slice`, a real directory).
- **A recorded process found anywhere else is never written.** Under `/system.slice` first of all: a process we
  scored that a service manager later adopted is the service's now. Its record is moved to
  `/run/dreamteam-io-shield/left/` and `status` lists it as "left the unit holding our score, NOT written". It
  keeps our score until it ends; putting anything else there is a person's decision, made with the unit's own
  `OOMScoreAdjust` in hand.
- **A negative score the helper has no record of is never written to, anywhere**: not in a system service, not in
  a login session, not elsewhere in the user's slice, not inside the lead's unit. (The rule is from 2026-11-23,
  when an earlier version reset three services' scores on serialhub and the next version would still have reset a
  login session's.)
- **One lock.** `apply`, `off` and `on` hold `/run/dreamteam-io-shield.lock` for the whole run, the timer's run
  and a run by hand alike, so no run reads a record another is writing. A run that cannot get it in time does
  nothing and exits 75.

Nothing a lane can mark, name or configure earns the score. The limit that remains: the lead and the lanes are
one uid, and a same-uid process can put itself into that cgroup. That needs lanes under their own uid; no check
in a script closes it.

### Acceptance on the host itself (nothing is accepted from another host's numbers)

`scripts/host/io-shield-accept <uid> apply` at the first enabling, and the same with `off` at every rollback, a
person watching, the output kept with the row. The acceptance list is IN the script, per host:

| host | unit | score its own unit file gives it |
|---|---|---|
| familiar | `palace-daemon.service` | -500 |
| familiar | `qwen3-coder.service` | -500 |
| familiar | `familiar-loadguard.service` | -800 |
| familiar | `donkey-llm.service` | -100 |
| serialhub | `octoprint.service` | -900 |
| serialhub | `ustreamer.service` | -900 |
| serialhub | `ustreamer-builtin.service` | -900 |

It ends in `ACCEPT` (exit 0) only when all of this holds, and in `REJECT` (exit 1) at the first thing that does not:

- **Before the run:** every named unit has a process of that user holding exactly its listed score. A unit that
  is ABSENT, or at another score, is a REJECT and the helper is not run: there is no baseline to accept against.
- **After the run:** every named process is the same process (pid and start time), in the same cgroup, at the
  same score. A restart during the run is a REJECT. Every other negative score the helper had no record of is
  unchanged.
- **Leads:** after `apply`, each `oomprotect` unit of that user holds at least one process with the configured
  score and a ledger record. ZERO protected leads is a REJECT, as is a config with no `oomprotect` line for that
  user. After `off`, no recorded score is left in a lead unit.

A host that is not in the table is refused (exit 2) unless `IO_SHIELD_MUST_STAY="unit=score …"` names its own
list; there is no host on which the script accepts with nothing named. After a `REJECT`: do not enable the
timer; if a score changed, put it back from the unit's `OOMScoreAdjust`.

Around it, on the host being enabled, in this order:

1. **Before:** `scripts/host-io-check.sh` under the load that hurts (a gate plus the palace suite), three times.
   Note the gate's wall time.
2. **The trial:** `sudo IO_SHIELD_BIN=scripts/host/io-shield scripts/host/io-shield-accept <uid> apply`, then
   `io-shield status`.
3. **After, same load:** the check three times; the gate's wall time again. Accept only if the victim's fsync p99
   is back near its idle value AND the gate still finishes inside its deadline. If the gate is starved, raise
   `min=` or the latency targets and repeat; if nothing helps, `io-shield off` through the acceptance script.
4. **Negative cases:** a throwaway scope with another name, and one that marks itself `user.oomd_avoid`, get no
   score after `apply`.
5. **After the next boot:** the io controller is in use by the user manager only from then; until then only the
   system-side weights are in force.

What the script cannot see: whether oomd treats the lead's scope as avoided, and anything that happens over hours.

### Rollback (each line undoes one thing; all of it is safe to run twice)

    sudo io-shield-accept <uid> off         # runs `dreamteam-io-shield off` and proves what it did not touch:
                                            # io.cost off, unit and container weights reset, each score THIS TOOL
                                            # recorded whose process is still in its lead unit back to what it
                                            # was, and a stamp so the timer's apply does nothing until `on` or a
                                            # reboot
    sudo systemctl disable --now dreamteam-io-shield.timer
    sudo rm /etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf && sudo systemctl daemon-reload

What `off` does not undo: a retired record's process keeps our score until it ends (`status` names it); the
delegation drop-in stays until the last line. Re-enabling: `sudo dreamteam-io-shield on`.

`tests/test-io-shield.sh` runs both scripts against fixture trees and stub commands; it cannot see a host.
