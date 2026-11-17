# CHECKS: dreamteam's durable checks (systemd user timers on familiar and katana)

This file follows the fleet rule (Sen 11/14, the shape money and realmwatch use). Each timer's job ends by writing ONE
fixed-shape line:

    CHECK <name> <ok|warn|fail> · <fact, number, time> · <next/owner>

- **Where it goes:** to `~/.local/state/checks/<name>.line` on the host that ran it, and to stdout.
- **How it is written:** as `.tmp`, then renamed, so a reader never sees half a line.
- **How it is read:** Hearth › Checks reads each line with its mtime, and turns it amber once it is older than its
  cadence plus half.
- **Unknown is never ok:** a check that could not measure prints `fail` with the reason.

Written 2026-11-17 by nebula, from the live units (`systemctl --user cat` / `show` / `journalctl` on familiar and katana,
09:4x). **None of the seven timers writes a `.line` today.** Every row below is a spec: "Mechanism: none yet
(2026-11-17)". The owner of every row is **Sen**. The rows were found by the weekly no-CHECKS pass
(`~/.claude/projects/-home-jp/scratch/loose-ends-2026-11-17/no-checks.md`).

| name | host | timer | cadence | measures | line shape (spec) | lands at | owner | mechanism |
|---|---|---|---|---|---|---|---|---|
| dreamteam-audit | familiar | dreamteam-audit.timer → `scripts/self-audit.sh` | weekly Sun 03:07 | the full suite (`tests/run.sh`), statusline and palace health, log prune. **Last run, Sun 11-15: `FAILED: 1/39 suites — test-standards.sh`**, seen only in the journal | `CHECK dreamteam-audit <ok\|fail> · suites <pass>/<total>[, failing <name,…>] · statusline <ok\|bad> · palace <ok\|bad> (run <MM-DD HH:MM>) · <next Sun 03:07 \| fix <suite>, owner Sen>` | familiar `~/.local/state/checks/dreamteam-audit.line` | Sen | none yet (2026-11-17) |
| dreamteam-audit-katana | katana | dreamteam-audit.timer → `scripts/self-audit.sh` | weekly Sun 03:07 | the same audit on katana (last ran 11-15 03:10; its journal holds no result line) | same shape, name `dreamteam-audit-katana` | katana `~/.local/state/checks/dreamteam-audit-katana.line` | Sen | none yet (2026-11-17) |
| dreamteam-briefing | familiar | dreamteam-briefing.timer → `scripts/morning-briefing.sh` | daily 07:03 | the morning briefing file exists for today and includes the "Nightly sweep" line (journal: `briefing written: state/briefing-<date>.md`) | `CHECK dreamteam-briefing <ok\|fail> · state/briefing-<YYYY-MM-DD>.md written <HH:MM>, <n> lines, nightly-sweep line <present\|missing> · <next 07:03, owner Sen>` | familiar `…/dreamteam-briefing.line` | Sen | none yet (2026-11-17) |
| dreamteam-briefing-katana | katana | dreamteam-briefing.timer | daily 07:03 | the same, on katana (it wrote `briefing-2026-11-17.md` at 07:03). **Two hosts write one synced `state/` file:** the line names the host so a clobber is visible | same shape, name `dreamteam-briefing-katana` | katana `…/dreamteam-briefing-katana.line` | Sen | none yet (2026-11-17) |
| nightly-guarded | familiar | dreamteam-nightly-guarded.timer → `scripts/overnight-guarded.sh` | daily 23:30 | the 70 % quota guard's decision and the sweep outcome per repo (`SWEEP-RESULT` and the guard record, docs/OVERNIGHT-GUARDED.md) | `CHECK nightly-guarded <ok\|warn\|fail> · night <MM-DD>: guard <ran\|skipped: quota NN %\|skipped: no dream issues>, repos <n>, PRs opened <n>, fixed <n>, too large <n> · <next 23:30, owner Sen>` | familiar `…/nightly-guarded.line` | Sen | none yet (2026-11-17) |
| dreamteam-nightly-pilot | katana | dreamteam-nightly.timer → `scripts/overnight-launch.sh` | daily 02:11 | the 02:11 PILOT gate ("records pending, does not auto-start"). **Still enabled on katana (last ran 11-17 02:11)**, although OVERNIGHT-GUARDED.md says installing the guarded timer retires the pilot pair "so only one nightly start exists". The check exists to make that drift visible until the pilot is retired | `CHECK dreamteam-nightly-pilot <warn\|ok> · pilot timer <enabled\|absent> on katana; guarded timer <enabled\|absent> on familiar · <retire the pilot pair (scripts/timers-ctl.sh), owner Sen>` (ok only when the pilot is absent) | katana `…/dreamteam-nightly-pilot.line` | Sen | none yet (2026-11-17) |
| issues-queue | familiar | issues-queue.timer → `scripts/issues-queue.py` | daily 04:50, 10:50, 16:50, 21:50 | the fix machine's queue file (docs/ISSUES-QUEUE.md): repos read, open issues, the dream queue, what waits on JP, `complete`, `failed_repos`. **Today it prints a summary line to the journal** (`issues-queue: 67 repos, open 527, dream 114, on JP 5, next sweep … [guarded], bad rows 0`), not in the fleet shape, and not to a state file | `CHECK issues-queue <ok\|warn\|fail> · <n> repos, open <n>, dream <n>, on JP <n>, complete <true\|false>[, failed <repo,…>], bad rows <n> (read HH:MM) · <next HH:50, owner Sen>` (warn on `complete: false`, fail on exit 2) | familiar `…/issues-queue.line` | Sen | none yet (2026-11-17); the journal line is the producer |

## Adding the lines (the follow-up)

- **One helper**, `scripts/lib/check-line.sh`, used by all three shell jobs: write `.tmp`, rename, echo.
  `issues-queue.py` gets the same behaviour inline.
- **Tests** in `tests/`, run on fixtures: the shape regex; `fail` when the measure is missing; and that no line is ever
  half-written.
- **Each timer** gets its row's mechanism changed from "none yet" to the commit that wired it.
- **The katana rows** need the line written on katana. Hearth › Checks reads familiar's directory, so either katana pushes
  its line over raven or ssh, or familiar reads it over ssh. Pick one in the same PR.
