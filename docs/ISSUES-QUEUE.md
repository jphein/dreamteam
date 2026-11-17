# issues-queue.json — the fix machine's queue (contract with plan.realm.watch /hearth/issues)

Written by `scripts/issues-queue.py` (timer `issues-queue.timer`, 04:50, 10:50, 16:50, 21:50 + on boot) to `state/issues-queue.json`
and to `PLAN_DATA/issues-queue.json` (default `~/srv/plan.realm.watch/data`). Read-only on GitHub (REST, no search).

```json
{"generated": "2026-11-13T10:40:00-08:00", "complete": true, "failed_repos": [],
 "repos": [{"repo": "jphein/smol", "open": 77, "dream": 12, "blocked_on_jp": 3, "hardware": 9, "design": 20, "fleetwatch": 0,
            "lane": "none", "top": [{"number": 529, "title": "...", "labels": ["bug","dream"]}],
            "needs_jp": [{"number": 34, "title": "...", "labels": ["blocked-on-hardware"]}]}],
 "totals": {"open": 500, "dream": 150, "blocked_on_jp": 40, "fixed_last_night": 0},
 "next_sweep": {"at": "2026-11-13T23:30:00-08:00", "mode": "pilot"},
 "bad_rows": 0}
```
- `dream`: issues carrying the `dream` label (the overnight queue). `blocked_on_jp` = `needs_jp` list length (the whole list is exported; the plan clips what it shows): labels `needs-jp`, `blocked-on-hardware`, `jp`, `hands`.
- Scope: only repos whose owner is in `OWNERS` (`jphein`, `techempower-org`; case-insensitive) are read or exported, whatever else the token can see.
- `complete` is `false` when any repo's issues could not be read (an API error, a timeout, a page that is not JSON or not UTF-8, any malformed issue, exported or not); those repos are named in `failed_repos` and left out of `repos` and `totals`, and the run exits 1. `bad_rows` = failed repos + an unreadable `sweep-results.json`. Freshness and completeness are separate: read `complete` as well as `generated`.
- `design`: `epic`, `matrix`, `design`. `fleetwatch`: `fleetwatch-fix` rows (they close themselves).
- `lane`: from `config/lane-map.json` (repo → owning lane), `none` when no lane runs it.
- `fixed_last_night`: from `state/sweep-results.json` when its `night` is yesterday; the sweep writes that file (see `sweep-results.json` in the plan contract).
- `next_sweep`: `dreamteam-nightly-guarded.timer`'s next elapse with mode `guarded` when that timer is active (the 23:30 guarded sweep, docs/OVERNIGHT-GUARDED.md); else the retired 02:11 `dreamteam-nightly.timer` if still installed (mode `active` only when its service runs `launch-dreamteam.sh`); else tonight 23:30 in `pilot`.
- `sweep-results.json` (plan contract `{night, mode, armed_at, fleet, quota_guard: {skipped, reason}, fixed, reviewed_not_merged, too_large}`) is written by `scripts/overnight-guarded.sh`: at start (fleet = repos, nothing held back), on a held night (`skipped` = fixes held back + the reason), and filled from each coordinator's `SWEEP-RESULT` line when the run ends.

## Failure, deadlines and publication (#193)

- **Discovery failure publishes nothing.** When the repo list itself cannot be read (an API error, a timeout, an answer that is not pages of repo objects, or any repo record missing `full_name`, `archived`, `has_issues` or `open_issues_count`), the run exits 2 and both files keep the previous snapshot, so `generated` stays old and the plan's 26-hour staleness shows it.
- **A per-repo failure publishes a partial queue.** A run where discovery worked but some repos failed publishes a FRESH file with `complete: false` and exits 1. Its `repos` can even be empty. So `repos: []` means "no allowed repo has open issues" only when `complete` is `true`; an incomplete queue never proves the absence of work.
- **Deadlines.** Each `gh` call has `ISSUES_QUEUE_TIMEOUT` seconds (default 90) and each `systemctl` call `min(10, ISSUES_QUEUE_TIMEOUT)`. The subprocess time of the whole run stays inside `ISSUES_QUEUE_BUDGET` (default 420): `gh` calls stop early by a reserve sized for `next_sweep`'s worst case of four `systemctl` calls (4 × (10 + 1 s kill grace) = 44 s by default), and every deadline is clamped to what is left. Either variable set to something that is not a finite number (`nan`, `inf`, `abc`) is a configuration error: the run exits 2 before any call and publishes nothing. A call past its deadline has its whole process group killed: a `gh` call fails its repo (or discovery), and a `systemctl` call falls back to the `pilot` next-sweep guess. The service's `TimeoutStartSec=10min` is the backstop, so a stuck run cannot hold later timer activations.
- **Publication.** Each file is written to a uniquely named temp file in its own directory (`.issues-queue.json.<random>.tmp`), mode 0600, fsynced, then `os.replace`d. A manual run overlapping the timer cannot corrupt either file, and the issue titles are readable only by the owner (the plan server runs as the same user). The two files are published one after the other, not as one transaction: if the second write fails, the run exits non-zero and the two copies differ until the next run. A file left 0644 by an older version stays so until the next successful publication replaces it.

## Freshness (2026-11-13)

The producer runs at 04:50, 10:50, 16:50 and 21:50 (plus boot), so successful daytime refreshes are about six hours apart or less (seven overnight); a run whose discovery fails, or one that never runs, leaves the file older, so the stamp in `generated` is the truth, not the schedule (and `complete` says whether that fresh stamp covers every repo). Before assigning any item, confirm it is still open (`gh api repos/<owner>/<repo>/issues/<n> --jq .state` must print `open`; an API error is not a confirmation): on 2026-11-13 Sen assigned seven issues from the 10:35 file at 16:05 and every one had been closed that morning. `systemctl --user start issues-queue.service` refreshes the file on demand (about 20 s).
