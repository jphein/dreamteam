# systemd/system: SYSTEM units kept here as the copy of record

The units in `systemd/` one level up are user units, linked from this checkout. The ones in this directory are
different: they are installed in `/etc/systemd/system` on the build server and run a script installed in
`/usr/local/bin`. They ran from no repository until 2026-11-20 (the 2026-11-17 timer audit found them); this
directory and `scripts/host/` now hold the text that is deployed.

| unit | installed at | runs | copy of record |
|---|---|---|---|
| `reap-fambuild-agents.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/bin/reap-fambuild-agents 2` as the login user, daily | here, and `scripts/host/reap-fambuild-agents` |
| `dreamteam-io-shield.timer` / `.service` | `/etc/systemd/system/` | `/usr/local/sbin/dreamteam-io-shield apply` as root, at boot and every 5 min; does nothing without `/etc/dreamteam/io-shield.conf` AND the acceptance flag `/var/lib/dreamteam/io-shield.accepted` | here, and `scripts/host/io-shield` |
| `dreamteam-io-shield-accept` | `/usr/local/sbin/` | the supervised run; `throwaway` is the only writer of the acceptance flag | `scripts/host/io-shield-accept` |
| `sudoers.d/dreamteam-io-shield` | `/etc/sudoers.d/` (0440) | the one grant: the login user may run the helper's two read-only `status` forms as root | `sudoers.d/dreamteam-io-shield.in` (the user's name is put in at install) |
| `user@.service.d/20-delegate-io.conf` | `/etc/systemd/system/user@<uid>.service.d/` | hands the io controller to that user's manager (effective inside it from the next boot) | here |

The `reap-fambuild-agents` files are copied to the host by hand, with root and `systemctl daemon-reload`. The
io-shield files are installed by `scripts/host/io-shield-install` and by nothing else (below).

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

### Order on a host. The first three steps cannot be skipped: each later one checks for them

1. **Install, nothing enabled:** `sudo scripts/host/io-shield-install <user>`. It copies the helper and the
   acceptance script to `/usr/local/sbin`, the two units to `/etc/systemd/system`, and the sudoers file (after
   `visudo -cf` accepts it). The timer is not enabled; if it was, and the helper is not the accepted one, it is
   disabled.
2. **A throwaway unit first.** As the user: `systemd-run --user --scope --unit=lead-throwaway-a1 sleep 600 &`.
   As root, `/etc/dreamteam/io-shield-throwaway.conf` with one line, `oomprotect <uid> lead-throwaway-a1.scope -500`
   (that file can hold nothing else: no device, no unit, no real lead). Then
   `sudo dreamteam-io-shield-accept <uid> throwaway`. It runs a whole `apply` and a whole `off` on that unit
   with its own ledger, checks every named service before and after both, and only when all of it holds writes
   **the acceptance flag**, `/var/lib/dreamteam/io-shield.accepted`, with the sha256 of the helper it ran.
3. **The flag is the gate.** Without it, for exactly this helper: the helper's own production `apply` exits 3,
   `io-shield-install --enable` exits 3, and the service unit's `ConditionPathExists` keeps a timer enabled by
   hand from doing anything. An updated helper has another sha256 and must be accepted again.
4. `/etc/dreamteam/io-shield.conf` (host data, not in this repo). For example:

       device nvme0n1 rlat=2000 wlat=5000 min=25 max=100
       docker mempalace-db 20
       unit syncthing@jp.service 20
       oomprotect 1000 lead-spire.scope -500

   A `unit` line takes a `*.service` name only. A slice, a scope (a lane's, the lead's) and `user@<uid>.service`
   are refused by the shape of the name, before anything is done.
5. **The production trial:** `sudo dreamteam-io-shield-accept <uid> apply`, a person watching (next section).
6. **The timer:** `sudo scripts/host/io-shield-install <user> --enable`.
7. The drop-in: `/etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf`, `systemctl daemon-reload`. Nothing
   running is disturbed; the user manager uses the io controller from the next boot.

### What the helper changes, and how it takes it back

**One ledger for everything** (`/run/dreamteam-io-shield`, root only, gone at reboot). An OOM score, a unit's or
container's IOWeight, and io.cost on a device are each RECORDED FIRST, durably (written whole, fsync, rename,
fsync of the directory), with what was there before. `off` undoes only what is recorded, and puts back what was
there: the weight a unit had, the io.cost line a device had. A unit or device the config names but the ledger
does not is not written: an `off` with no `apply` before it writes the stamp and nothing else.

**Fail closed.** The ledger is read whole before any change. A half-written record, a record of an unknown
name, a symlink, a directory that others can write: exit 1, nothing written anywhere. A process, a record or a
`systemctl show` that cannot be read for any reason other than "it is gone" (EACCES, EIO): the record is kept
and the run stops before the next change. A failure is never read as absence.

**The lead's score.** `scripts/lead-watchdog.sh` launches the lead in `lead-<session>.scope` (with
`ManagedOOMPreference=avoid`, so systemd-oomd passes it over). An `oomprotect <uid> lead-<session>.scope -500`
line gives each process in exactly that cgroup whose score is not already negative the kernel OOM score.

- **The undo is narrower than the write.** A score is written back in ONE case: `off`, the same process (pid and
  start time), still holding the score we wrote, its cgroup still the lead unit named in its record.
- **A recorded process found anywhere else is not written.** Under `/system.slice` first of all. Its record is
  moved to `left/` and `status` lists it as "left the unit holding our score, NOT written". It keeps our score
  until it ends; anything else is a person's decision, made with the unit's own `OOMScoreAdjust` in hand.
- **A negative score the helper has no record of is never written to, anywhere.** (The rule is from 2026-11-23,
  when an earlier version reset three services' scores on serialhub.)
- **The placement is read again immediately before every write**, and once more after a new score. That is not
  an atomic check-and-write, and the helper's header says so: the kernel offers none, so a process moved by its
  owner between the last look and the write is written once, then shows as "left" and is never written again.
  Closing that window, like the fact that a same-uid process can put itself into the lead's cgroup, needs lanes
  under their own uid. No check in a script closes it.

**One lock.** `apply`, `off` and `on` hold `/run/dreamteam-io-shield.lock` for the whole run, the timer's run and
a run by hand alike. A run that cannot get it in time does nothing and exits 75.

**A root run cannot be steered.** As root the helper, the acceptance script and the installer drop every
`IO_SHIELD_*` variable and use a fixed `PATH`; the acceptance script runs the INSTALLED helper only. The sudoers
file grants the login user two commands: `dreamteam-io-shield status` and `dreamteam-io-shield --throwaway
status`, read-only, with the environment reset. `apply`, `off` and `on` are not granted to anyone by this change:
the timer runs `apply`, and an enabling or a rollback is a person's act with their own sudo.

### Acceptance on the host itself (nothing is accepted from another host's numbers)

`sudo dreamteam-io-shield-accept <uid> apply` at the first production enabling, and the same with `off` at every
rollback, a person watching, the output kept with the row. The acceptance list is IN the script, per host:

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

A host that is not in the table is refused (exit 2). After a `REJECT`: do not enable the timer; if a score
changed, put it back from the unit's `OOMScoreAdjust`.

Around the production trial, on the host being enabled, in this order:

1. **Before:** `scripts/host-io-check.sh` under the load that hurts (a gate plus the palace suite), three times.
   Note the gate's wall time.
2. **The trial:** `sudo dreamteam-io-shield-accept <uid> apply`, then `sudo dreamteam-io-shield status`.
3. **After, same load:** the check three times; the gate's wall time again. Accept only if the victim's fsync p99
   is back near its idle value AND the gate still finishes inside its deadline. If the gate is starved, raise
   `min=` or the latency targets and repeat; if nothing helps, `off` through the acceptance script.
4. **After the next boot:** the io controller is in use by the user manager only from then; until then only the
   system-side weights are in force.

What the script cannot see: whether oomd treats the lead's scope as avoided, and anything that happens over hours.

### Rollback (each line undoes one thing; all of it is safe to run twice)

    sudo dreamteam-io-shield-accept <uid> off   # runs `dreamteam-io-shield off` and proves what it did not touch:
                                                # every RECORDED weight and io.cost line back to what it was, each
                                                # recorded score whose process is still in its lead unit back to
                                                # what it was, and a stamp so the timer's apply does nothing until
                                                # `on` or a reboot
    sudo systemctl disable --now dreamteam-io-shield.timer
    sudo rm /etc/systemd/system/user@<uid>.service.d/20-delegate-io.conf && sudo systemctl daemon-reload

What `off` does not undo: a retired record's process keeps our score until it ends (`status` names it); the
delegation drop-in stays until the last line. Re-enabling: `sudo dreamteam-io-shield on`.

`tests/test-io-shield.sh` runs the helper, the acceptance script and the installer against fixture trees and
stub commands; it cannot see a host.
