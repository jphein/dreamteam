# The guarded nightly sweep

JP said "go" on 2026-11-14 06:40 to ask 4c77a5b8f3ef ("Activate the nightly fix sweep", the "Guarded nightly" choice).
The card promised a sweep that "runs 23:30 with the 70 % quota guard, PR-only in production repos, oracle review
before any merge; costs about 50 seat-points a night". This page is the contract for the code that keeps that promise.

| Piece | File |
|---|---|
| Timer, 23:30 daily, `Persistent=false`, `AccuracySec=2min`, no random delay | `systemd/dreamteam-nightly-guarded.timer` |
| Oneshot service (PATH with `~/.cargo/bin` for the teamclaude `claude` wrapper) | `systemd/dreamteam-nightly-guarded.service` |
| Guard, launcher and runner | `scripts/overnight-guarded.sh` |
| Per-repo loop (with `issues`, `prOnly` and `prGate` args) | `workflows/overnight.js` |
| Tunables, production list | `config.json` → `.overnight` |
| Install, status, uninstall (an install retires the 02:11 pilot pair, so only one nightly start exists); `retire-pilot` does that alone on any other host that ever had the pilot (katana kept it armed until 2026-11-17) | `scripts/timers-ctl.sh` |
| Tests | `tests/test-overnight-guarded.sh` (98 checks), `tests/test-overnight-workflow.sh` (13 checks) |

## What happens at 23:30

1. **Quota (the 70 % guard).** The guard reads `GET http://127.0.0.1:3456/teamclaude/quota`. The sweep starts only
   when both pools have room:
   - the 5-hour pool: `aggregate.fiveHour.remaining` must be ≥ `five_hour_min` (0.70). The sweep never starts into a
     5-hour pool below 70 %.
   - the 7-day pool: `aggregate.sevenDay.remaining` must be ≥ `seven_day_min` (0.30). This proxy reports `sevenDay`
     as null, so the guard reads `aggregate.weeklyShared.remaining` in its place.

   Before the quota is read, a pre-flight asks the proxy's `/teamclaude/status`: anything but HTTP 200 means no
   start. It fails closed: if the proxy doesn't answer, or answers without those two numbers, nothing starts. Since
   teamclaude #66 the `~/.cargo/bin/claude` wrapper exits 69 when the proxy is down (it used to fall back to
   familiar's own login, billing a seat outside the pool); a runner that meets exit 69 stops the night.
2. **Work.** The guard reads `state/issues-queue.json` (refreshed 21:50) and takes the repos with `dream > 0` from
   every owner, not only jphein/dreamteam. It drops `never_sweep` (plan.realm.watch), puts the least recently swept
   first (`state/overnight-rotation.json`), then the most dream issues. It re-reads each repo's open `dream` issues
   live over REST and drops pull requests. **Provenance:** an issue is worked only when its author AND the account
   that last added the `dream` label both hold write, maintain or admin on that repo (checked through the
   collaborators-permission API, cached per login; the label history is read across every page, and an unreadable
   history counts as untrusted). Every account that renamed the title must hold write access too. If the issue
   has comments, every commenter must hold write access too, and an
   unreadable comment list counts as untrusted. The vetted title and body (capped at 4,000 characters) are
   frozen into the plan at that moment, and the agents work from that snapshot. Nothing reads the issue live
   during the run, so a later retitle or comment cannot reach them. An outsider's issue on a public repo, or a label added by a
   read-only account, is skipped and logged, because issue text is input to an unattended agent. Limits: up to `max_repos` (3; the older key `max_repos_per_night` is still read) repos and `max_issues_per_repo`
   (5) issues each. If no work is left, the decision is `no-work`, exit 0, and nothing is spoken or published.
3. **PR-only in production.** Repos are matched by name, so an owner transfer doesn't matter.
   - A repo in `production_repos` is PR-only: the sweep opens PRs and the oracle reviews them, but it never merges.
   - A repo in `merge_repos` merges a PR only when all three hold: the `dreamteam:oracle` review (read-only by toolset)
     approves, `scripts/pr-gate.sh` exits 0 (a repo with no CI exits 4, which means no merge), and the merge is the
     only one in flight.
   - A repo in neither list is PR-only. Adding a repo to `merge_repos` is the deliberate act that lets the sweep
     merge there.
   - **Guardrails in PR-only repos (not a security boundary).** The coordinator's PATH starts with an ALLOWLIST
     `gh` shim, and every read is bound to a known number:
     - Every call is bound to this repo:
       - a `--repo`, `-R`, `--repo=` or `GH_REPO` naming another repo is refused;
       - every caller `--repo` is stripped once checked, and one `--repo github.com/<this repo>` is appended
         (`api` always gets `--hostname github.com`);
       - `GH_CONFIG_DIR` and `XDG_CONFIG_HOME` must be the values the shim was made under;
       - a `GH_HOST` other than github.com, a joined `-Rx` and `--` are refused, and the enterprise tokens are
         unset;
       - api `repos/{o}/{r}` must be this repo.
     - `pr create` runs from a branch of this repo only (a `--head owner:branch` in a fork is refused). The shim
       records a PR only when the create succeeded, the PR's actual `head.repo` (read back from
       `pulls/N`) is this repo, and the create's last output line is exactly
       this repo's PR URL. `--dry-run` and `--web` are refused.
     - `pr diff|checks|comment N` work only for a PR this run opened.
     - No `issue` command at all: the issue text is the planning-time snapshot in the prompt.
     - A bare `repo view` (run as `repo view github.com/<this repo>`), `auth status` and `label list` are allowed.
     - `api` is GET only, with an exact flag set (`-H`, `--jq`, `--paginate`, `-X GET`). Its endpoints must be:
       - `pulls/N/files|commits` for an own PR;
       - or the repo itself, `contents/<path>` (default branch only), `branches` or `labels`. Writer-controlled
         data only: Actions runs and logs, commits and check-run summaries can carry a non-writer's PR text,
         so they are refused. The CI state of an own PR comes from `pr checks N`.
       - No query strings and no `-f`/`-F` fields, because `?ref=refs/pull/N/head` would read a fork's files.

       `%`, `//`, `..` and other hosts are refused, and so is GraphQL.

     Listings (`pr list`, `issue list`, `pr view`, `pr status`) are refused, because they would hand the agent text a
     non-writer wrote. So is anything that names comments or reviews, every merge spelling, and every mutation
     other than `pr create` and `pr comment` on an own PR. The action word must come right after the subcommand,
     so the shim never guesses flag arity. The clone also gets a `pre-push` hook that refuses
the clone's real default branch (`origin/HEAD`) and main/master/trunk/production. Together they stop an agent that follows a misleading issue body ("merge it").
     They cannot stop a hostile one, which could call `/usr/bin/gh` or use `--no-verify`. The boundary is GitHub
     branch protection on those repos.
4. **One start a night.** The guard holds an flock while it runs. A night marker (`state/overnight-night`, keyed
   by the date 12 hours ago, so a 00:20 restart counts as the same night) is written only after a successful
   launch, so a failed launch can still be retried that night. A duplicate attempt only logs: it never overwrites
   the running night's guard record or sweep results. A start more than `max_hours` (7.5) before `stop_at` is
   refused as a daytime start, not clamped.
5. **Contained start.** One `systemd-run --user --scope` (MemoryHigh/Max/SwapMax from `.scope`, `RuntimeMaxSec` up to
   the earlier of `stop_at` 06:30 and `max_hours` 7.5) holds a detached tmux server on its own socket,
   `-L dreamteam-nightly`. A shared `-L dreamteam` server may already be running inside another team's scope, and a
   session created on it would escape this scope's caps. Positive control, 2026-11-14 06:53: the detached tmux
   server sat inside the scope with its MemoryMax applied, and RuntimeMaxSec stopped the whole scope ("Scope reached
   runtime time limit"). The runner reaches tmux as separate argv words (`env K=V … bash overnight-guarded.sh
   --runner DIR`). tmux 3.x execs a multi-word command directly, with no shell, so no path needs quoting. The same
   array is saved NUL-separated as `runner.argv`, and the test runs exactly that array.
   `Delegate=yes`, plus `DREAMTEAM_SCOPE_NAME` exported to the coordinators, means `scope-attach.sh` keeps any
   teammate they spawn in this scope. Without it, a spawned teammate would be re-homed into
   `dreamteam-<repo>.scope`, which has neither this night's cap nor its runtime limit.
   **The runner joins the scope itself (#225).** tmux 3.6, built with systemd support, starts every pane in its own
   `tmux-spawn-<uuid>.scope`. So only the tmux server stays in the night's scope; the runner, its coordinators and
   their teammates ran outside the caps (11-16: a tmux-spawn scope peaked at 3.3 G). The runner's first act is
   `AttachProcessesToUnit` of its own pid to `dreamteam-<rid>.scope` (allowed by `Delegate=yes`), and everything it
   starts after that inherits it. Measured on tmux 3.6, 2026-11-17: before the attach `tmux-spawn-….scope`, after it
   the night's scope, and a child too. If it cannot join, the night stops before any coordinator: every repo is
   recorded skipped with the reason, and FINISHED says "Stopped: the runner could not join the night's scope (#225)".
6. **Runner.** For each repo in turn, the runner checks the clock (it needs ≥ `min_repo_minutes` left) and makes a
   fresh clone under `~/srv/wt/overnight/<night>/<name>` (git never touches the synced `~/Projects`). Right before
   the coordinator starts, it recomputes the time left and re-reads the quota:
   - the night's first coordinator needs the full start guard (5-hour ≥ 0.70);
   - later ones need the continuation floor (5-hour ≥ `continue_five_hour_min` 0.40);
   - every coordinator needs 7-day ≥ 0.30.

   It then runs one headless `claude -p` under `timeout`. If `claude` exits 69 (the wrapper's "teamclaude proxy
   down", teamclaude #66), the night stops with no retry: that repo is `stopped` (proxy-down), the rest are
   `skipped`, and the aborted repo is not marked swept, so it goes first next time. While that coordinator runs, a watchdog re-reads the
   quota every 600 s and stops the coordinator if the pool drops below the floor. The prompt opts in to the workflow ("use a workflow"), points the Workflow tool at
   `workflows/overnight.js` with `{repo, issues, prOnly, prGate, maxHours}`, and states the merge rule, the stop time
   and "no speech, no asks". Before starting it, the runner exports the proxy env the wrapper uses
   (`HTTPS_PROXY`/`HTTP_PROXY`=127.0.0.1:3456, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`=`~/.config/teamclaude-ca.pem`, no
   `ANTHROPIC_BASE_URL`). No key is involved, because the proxy presents as API auth.
7. **Records.**
   - `state/overnight-guard.json` holds `{at, quota_remaining: {five_hour, seven_day}, decision, reason, issues,
     repos, run_id, runs}`. `decision` is one of `started`, `no-start`, `no-work` or `dry-run`. `runs` has one line per
     planned repo: `{repo, run_id "<run>/<name>", status started|finished|stopped|skipped, reason, started_at,
     finished_at, rc, prs_opened, prs_reviewed, merged}`. `prs_opened` needs creation evidence: the shim's
     verified ledger in a PR-only repo, or the coordinator's `opened` list in a merge repo. Reviewed PRs are kept
     apart in `prs_reviewed`. A repo the night never reached is `skipped`, with the reason the night stopped.
   - Every step is logged to `state/dreamteam.log`.
   - `state/overnight-pending.md` gets "STARTED <run_id> at <time>" with the issue list, and the runner appends
     "FINISHED <run_id> …".
   - `sweep-results.json` goes to `state/` and to the plan's data folder (the `/hearth/issues` contract):
     - a held night publishes `quota_guard.skipped` (the number of fixes held back) with the reason;
     - each coordinator's closing `SWEEP-RESULT {…}` line fills `fixed`, `reviewed_not_merged` and `too_large`.
   - The 07:03 `morning-briefing.sh` adds a "Nightly sweep" line with one clause per repo (status, PRs opened,
     merged, reason), and a started run counts as overnight activity.

## Old night clones (#250): move, then delete

Each night's clones live in `~/srv/wt/overnight/<night>/<name>` and were never removed (1.8 GB a night on a small
root). After the FINISHED line the runner calls `scripts/lib/prune_nights.py`; its header is the contract.

**Move-then-delete, rename only** (decided 2026-11-20, after four review rounds): a selected clone is moved by ONE
rename into a quarantine dir **on its own filesystem** and deleted from there 14 days later. Nothing is ever
copied, and nothing is destroyed on the night it is selected: a wrong selection costs a move that can be undone.

1. **Expire:** in every quarantine dir, entries named `<night>__<name>__q<YYYYMMDD>` whose q-date is 14 days or
   more before tonight are deleted (by the date in the name, never by mtime). Anything else there is left alone.
2. **Floor:** a quarantine whose filesystem has less than 10 % free takes nothing; the reading is taken again
   before every move. The line says `old clones NOT all moved: a quarantine disk has N% free (floor 10%)` (warn).
3. **Select and move:** in nights before the previous one (tonight and the newest earlier night are never
   touched), each clone the selector passes is renamed into the quarantine on its filesystem; the others stay,
   each with its reason. **A clone whose filesystem has no quarantine dir is never moved**; the line counts and
   names it (warn).

**What that means for disk space:** the move frees nothing on the night it happens (same filesystem). The space
comes back when the entry expires, 14 days later. In steady state the quarantine holds two weeks of old clones.

**Configure it per host** (paths are host data, so they go in that host's overlay, `config.<host>.json`): one
absolute path, or a list with one dir per filesystem that holds night clones.

```json
{ "overnight": { "prune_quarantine": "/absolute/dir/on/the/clones/filesystem", "prune_keep_days": 14, "prune_min_free_pct": 10 } }
```

With no `prune_quarantine` nothing is moved and the line says `old clones stay (no quarantine dir configured:
overnight.prune_quarantine)` without changing its status. A quarantine dir is created if absent; it must have no
symlink anywhere in its path and lie outside the clone base; two dirs on one filesystem are refused.

**The selector** passes a clone only when: it is a real directory with a plain `.git` holding its own storage; its
local config has only the keys a fresh clone has (read as data, never run, and git is given no global or system
config), with one remote, `origin`, at `https://github.com/<owner>/<name>`; it has been quiet for 6 hours with no
process working in it or holding or mapping a file of it; HEAD is on a branch; `status --untracked-files=all` is
empty; no index entry is hidden from status; no stash; no grafts, shallow file or replace refs; every commit and
tag object it holds is under a remote-tracking branch or a tag the forge has; and the forge confirms now, asked
from outside the clone, that each tracking tip is still on the remote. Nothing is fetched. So these STAY in their
night, named in the line: a clone whose fix branch was squash-merged and deleted on the remote, one whose history
was amended, any clone when the forge cannot be asked.

**Things it will not do** (each from a review finding, each tested): replace anything by a rename (all three
renames are `renameat2(RENAME_NOREPLACE)`; without that call nothing moves); walk into a mount (an old entry with
something mounted inside is not expired and is named; a clone with a mount inside is not selected; an unreadable
mount table counts as a mount); go on using a quarantine dir that was moved or replaced during the run (it is
re-checked before every move and every expiry); run git with anything inherited (its environment is built from a
fixed list, with no global or system config).

**Where it shows:** the guard record's `.prune` and the CHECK line: `…; old clones: moved N to quarantine, kept M
(first: <night>/<name>: <why>), expired E`, and when it applies `; K old clone(s) on a filesystem with no
quarantine dir (first: …)`, `; a quarantine dir was moved or replaced during the run`, `; N old quarantine entr(ies)
not expired: something is mounted inside` (each warn). A tool that fails is `old clones NOT moved (…)` (warn). A marker is written in the run
dir BEFORE the tool runs and removed once its result is recorded; if it is still there the line says `a prune
started and its result is not in the record` (warn). If the marker cannot be written, the tool is not run.

**By hand:** `DREAMTEAM_PRUNE_NIGHTS=0` turns it off. To see what would move:
`python3 -I scripts/lib/prune_nights.py --dry-run --quarantine <dir> ~/srv/wt/overnight $(date -d '12 hours ago' +%F)`.
To bring a clone back within the 14 days: `mv <quarantine>/<night>__<name>__q<date> ~/srv/wt/overnight/<night>/<name>`.

## The 2026-11-16 night, and the watch

The first guarded night (`nightly-20261116-233001`) died at 23:41, 11 minutes in, with one repo begun and no FINISHED
line. Three things lined up:

1. The mempalace coordinator started its Workflow in the background and ended its turn ("the harness will re-invoke
   me"). In `-p` mode nothing re-invokes it: print mode killed the workflow 10 minutes later and exited with no
   SWEEP-RESULT. The coordinator now runs with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, so it waits for its own
   workflow; `timeout` still ends it at the cap.
2. Its SessionEnd hook (`cleanup-marker.sh`) was given `DREAMTEAM_SCOPE_NAME=dreamteam-<run id>`, found no claude
   process in that scope, and stopped it. The scope was not empty: it held the night's tmux server. tmux 3.6 moves
   every new pane into its own `tmux-spawn-*.scope`, so no claude process ever lives in the night's scope. Stopping
   it killed the tmux server, and the runner died of SIGHUP before it could write anything. `cleanup-marker.sh` now
   never stops a `dreamteam-nightly-*` scope, nor one marked `DREAMTEAM_SCOPE_OWNED=1` (the runner sets both).
3. Nothing noticed until the 07:03 briefing re-read the line after the cap.

Now the runner traps HUP, TERM and INT: it stops the coordinator, records `runner killed (SIGx)` on its repo, and
writes FINISHED. That line is FAIL. `dreamteam-nightly-watch.timer` runs `--watch` every 5 minutes from 23:35 to
07:00. It republishes the line, and a started night whose tmux session is gone before its cap is FAIL at once (SIGKILL
cannot be trapped; this is the net for it). The first FAIL for a run is sent to the lead once (raven mail to sen).

## Running it by hand

```bash
DREAMTEAM_TEST=1 DRY_RUN=1 bash scripts/overnight-guarded.sh   # real quota + real gh; prints the launch, starts nothing
```

A dry run writes the guard record in `state/` and never publishes to the plan.

## Disarm

- **Soft:** leave no `dream` issues open. The guard then exits with `no-work`.
- **Hard:** `systemctl --user disable --now dreamteam-nightly-guarded.timer`, or `bash scripts/timers-ctl.sh uninstall`.
- **Stop a run in flight:** `systemctl --user stop 'dreamteam-nightly-*.scope'`.

## Known limits

- The coordinators run `claude -p --dangerously-skip-permissions`, because an unattended fixer needs Edit and Bash.
  The boundaries that make that acceptable are:
  - provenance (only trusted authors and labellers);
  - prompts that fence issue text as untrusted data;
  - the read-only oracle review;
  - PR-only by default, with the allowlist shim and the pre-push hook;
  - the memory and runtime caps (nominal under tmux 3.6, see below).

  Branch protection, or a token without merge rights on production repos, is still the real boundary. It is not
  checked by this code.

- **The memory and runtime caps are nominal (found 2026-11-17).** tmux 3.6 moves the runner's pane, and so every
  coordinator and teammate under it, into its own `tmux-spawn-*.scope`. The night's scope (MemoryHigh/Max/SwapMax,
  RuntimeMaxSec) then holds only the tmux server. The 11-16 run peaked at 3.3 GB outside it. The `timeout` cap per
  coordinator still holds. Tracked as its own issue.
- The seat-point cost per night is not measured yet. The continuation floor (0.40) and the three-repo cap bound it;
  the card's "about 50" is an estimate.
- A plan.realm.watch `MODES` entry for `guarded` is still needed for the "next sweep" chip to show the mode. Until
  then the chip shows the time with no mode word, and `sweep-results.json` uses mode `active`, which the plan
  already knows.
