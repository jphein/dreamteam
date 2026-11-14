# issues-queue.json — the fix machine's queue (contract with plan.realm.watch /hearth/issues)

Written by `scripts/issues-queue.py` (timer `issues-queue.timer`, 21:50 nightly + on boot) to `state/issues-queue.json`
and to `PLAN_DATA/issues-queue.json` (default `~/srv/plan.realm.watch/data`). Read-only on GitHub (REST, no search).

```json
{"generated": "2026-11-13T10:40:00-08:00",
 "repos": [{"repo": "jphein/smol", "open": 77, "dream": 12, "blocked_on_jp": 3, "hardware": 9, "design": 20, "fleetwatch": 0,
            "lane": "none", "top": [{"number": 529, "title": "...", "labels": ["bug","dream"]}],
            "needs_jp": [{"number": 34, "title": "...", "labels": ["blocked-on-hardware"]}]}],
 "totals": {"open": 500, "dream": 150, "blocked_on_jp": 40, "fixed_last_night": 0},
 "next_sweep": {"at": "2026-11-13T23:30:00-08:00", "mode": "pilot"},
 "bad_rows": 0}
```
- `dream`: issues carrying the `dream` label (the overnight queue). `blocked_on_jp` = `needs_jp` list length: labels `needs-jp`, `blocked-on-hardware`, `jp`, `hands`.
- `design`: `epic`, `matrix`, `design`. `fleetwatch`: `fleetwatch-fix` rows (they close themselves).
- `lane`: from `config/lane-map.json` (repo → owning lane), `none` when no lane runs it.
- `fixed_last_night`: from `state/sweep-results.json` when its `night` is yesterday; the sweep writes that file (see `sweep-results.json` in the plan contract).
- `next_sweep`: `dreamteam-nightly.timer`'s next elapse when installed (mode `active` only when the service runs `launch-dreamteam.sh`), else tonight 23:30 in `pilot`.

## Freshness (2026-11-13)

The producer runs at 04:50, 10:50, 16:50 and 21:50 (plus boot), so successful daytime refreshes are about six hours apart or less (seven overnight); a failed or skipped run leaves the file older, so the stamp in `generated` is the truth, not the schedule. Before assigning any item, confirm it is still open (`gh api repos/<owner>/<repo>/issues/<n> --jq .state` must print `open`; an API error is not a confirmation): on 2026-11-13 Sen assigned seven issues from the 10:35 file at 16:05 and every one had been closed that morning. `systemctl --user start issues-queue.service` refreshes the file on demand (about 20 s).
