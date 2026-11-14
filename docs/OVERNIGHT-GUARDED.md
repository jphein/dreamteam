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
| Install, status, uninstall (an install retires the 02:11 pilot pair, so only one nightly start exists) | `scripts/timers-ctl.sh` |
| Tests | `tests/test-overnight-guarded.sh` (85 checks), `tests/test-overnight-workflow.sh` (12 checks) |

## What happens at 23:30

1. **Quota (the 70 % guard).** The guard reads `GET http://127.0.0.1:3456/teamclaude/quota`. The sweep starts only
   when both pools have room:
   - the 5-hour pool: `aggregate.fiveHour.remaining` must be ≥ `five_hour_min` (0.70). The sweep never starts into a
     5-hour pool below 70 %.
   - the 7-day pool: `aggregate.sevenDay.remaining` must be ≥ `seven_day_min` (0.30). This proxy reports `sevenDay`
     as null, so the guard reads `aggregate.weeklyShared.remaining` in its place.

   It fails closed: if the proxy doesn't answer, or answers without those two numbers, nothing starts. The
   `~/.cargo/bin/claude` wrapper silently falls back to familiar's own login when the proxy is down, so starting
   anyway would bill a seat outside the pool.
2. **Work.** The guard reads `state/issues-queue.json` (refreshed 21:50) and takes the repos with `dream > 0` from
   every owner, not only jphein/dreamteam. It drops `never_sweep` (plan.realm.watch), puts the least recently swept
   first (`state/overnight-rotation.json`), then the most dream issues. It re-reads each repo's open `dream` issues
   live over REST and drops pull requests. **Provenance:** an issue is worked only when its author AND the account
   that last added the `dream` label both hold write, maintain or admin on that repo (checked through the
   collaborators-permission API, cached per login; the label history is read across every page, and an unreadable
   history counts as untrusted). If the issue has comments, every commenter must hold write access too, and an
   unreadable comment list counts as untrusted. Agents are told to read the title and body only
   (`--json title,body`). An outsider's issue on a public repo, or a label added by a
   read-only account, is skipped and logged, because issue text is input to an unattended agent. Limits: up to `max_repos_per_night` (3) repos and `max_issues_per_repo`
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
     - `issue view N` works only for this night's vetted issues.
     - A bare `repo view` (run as `repo view github.com/<this repo>`), `auth status` and `label list` are allowed.
     - `api` is GET only, with an exact flag set (`-H`, `--jq`, `--paginate`, `-X GET`). Its endpoints must be:
       - `issues/N` for a vetted N;
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
6. **Runner.** For each repo in turn, the runner checks the clock (it needs ≥ `min_repo_minutes` left) and makes a
   fresh clone under `~/srv/wt/overnight/<night>/<name>` (git never touches the synced `~/Projects`). Right before
   the coordinator starts, it recomputes the time left and re-reads the quota:
   - the night's first coordinator needs the full start guard (5-hour ≥ 0.70);
   - later ones need the continuation floor (5-hour ≥ `continue_five_hour_min` 0.40);
   - every coordinator needs 7-day ≥ 0.30.

   It then runs one headless `claude -p` under `timeout`. While that coordinator runs, a watchdog re-reads the
   quota every 600 s and stops the coordinator if the pool drops below the floor. The prompt opts in to the workflow ("use a workflow"), points the Workflow tool at
   `workflows/overnight.js` with `{repo, issues, prOnly, prGate, maxHours}`, and states the merge rule, the stop time
   and "no speech, no asks". Before starting it, the runner exports the proxy env the wrapper uses
   (`HTTPS_PROXY`/`HTTP_PROXY`=127.0.0.1:3456, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`=`~/.config/teamclaude-ca.pem`, no
   `ANTHROPIC_BASE_URL`). No key is involved, because the proxy presents as API auth.
7. **Records.**
   - `state/overnight-guard.json` holds `{at, quota_remaining: {five_hour, seven_day}, decision, reason, issues,
     repos, run_id}`. `decision` is one of `started`, `no-start`, `no-work` or `dry-run`.
   - Every step is logged to `state/dreamteam.log`.
   - `state/overnight-pending.md` gets "STARTED <run_id> at <time>" with the issue list, and the runner appends
     "FINISHED <run_id> …".
   - `sweep-results.json` goes to `state/` and to the plan's data folder (the `/hearth/issues` contract):
     - a held night publishes `quota_guard.skipped` (the number of fixes held back) with the reason;
     - each coordinator's closing `SWEEP-RESULT {…}` line fills `fixed`, `reviewed_not_merged` and `too_large`.
   - The 07:03 `morning-briefing.sh` adds a "Nightly sweep" line, and a started run counts as overnight activity.

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
  - the memory and runtime caps.

  Branch protection, or a token without merge rights on production repos, is still the real boundary. It is not
  checked by this code.

- The seat-point cost per night is not measured yet. The continuation floor (0.40) and the three-repo cap bound it;
  the card's "about 50" is an estimate.
- A plan.realm.watch `MODES` entry for `guarded` is still needed for the "next sweep" chip to show the mode. Until
  then the chip shows the time with no mode word, and `sweep-results.json` uses mode `active`, which the plan
  already knows.
