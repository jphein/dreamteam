---
description: Arm (or explain) the nightly autonomous dreamteam sweep — gated on open `dream`-labelled issues.
argument-hint: "[repo-path] — default this repo"
---

The **overnight autonomous sweep**: scout the repo for high-value issues → fix each in an
isolated worktree (one PR per fix) → **oracle** read-only review → serially ship the clean,
green, approved ones. Fleet scales to the token budget. This command is the human-facing
explanation + arming doc; the actual loop is `workflows/overnight.js`, and the nightly trigger
is a **systemd user timer** (`dreamteam-nightly.timer`) — durable across sessions and reboots,
unlike the session-only CronCreate it replaces.

## The nightly sweep (GUARDED, armed by JP 2026-11-14)

`dreamteam-nightly-guarded.timer` fires **23:30 daily** (`Persistent=false`: a missed night is
missed, never started late) and runs `scripts/overnight-guarded.sh`. Contract and every number:
`docs/OVERNIGHT-GUARDED.md`. In short:

- **70 % quota guard**: starts only if the teamclaude proxy reports the 5-hour pool ≥ 70 % and the
  7-day pool ≥ 30 %; a proxy that does not answer = no start (fail closed). Re-checked before each
  repo (floor 40 %).
- **Work**: open `dream`-labelled issues across every repo in `state/issues-queue.json`, confirmed
  live; none → silent exit. Up to 3 repos × 5 issues a night, least recently swept first.
- **PR-only in production** (`config.json .overnight.production_repos`; unlisted = PR-only too);
  in `merge_repos` a PR merges only after the read-only oracle approves and `pr-gate.sh` is green,
  one at a time.
- **Contained**: one memory-capped `systemd-run --user --scope` with `RuntimeMaxSec` to 06:30, its own
  `tmux -L dreamteam-nightly` server, one headless `claude -p` per repo in a fresh clone under
  `~/srv/wt/overnight/`.
- **Reported**: `state/overnight-guard.json`, `state/overnight-pending.md` (STARTED/FINISHED), the
  plan's `/hearth/issues` (`sweep-results.json`), and the 07:03 briefing's "Nightly sweep" line.

So the switch that queues a night's work is still **whether any `dream`-labelled issue is open**.

The 02:11 PILOT pair (`dreamteam-nightly.*` → `overnight-launch.sh`, surface-only) stays in the
repo but is no longer installed: `timers-ctl.sh install` retires it so there is ONE nightly start.

## Safety posture (all on by default)

- **Memory admission** — the mem-gate blocks spawns with no RAM headroom; the count cap and
  balloon reserve are enforced from `config.json` (see `/dreamteam-status`).
- **Automatic containment** — every agent proc is attached to the capped
  `dreamteam-agents.scope`; a runaway is OOM-killed inside its cgroup, the orchestrator
  survives (see the skill § Containment).
- **Oracle verify** — the review stage runs as `dreamteam:oracle`, a verifier with **no
  Edit/Write in its toolset** (harness-enforced) — read-only by construction, not by prompt.
- **No-eager-merge** — every PR in a wave is reviewed before any merge; approved+green PRs
  merge one at a time in severity order.
- **Surfaces, doesn't guess** — design/product judgement, secrets/keystore, and
  destructive/irreversible changes are reported (`too-large`), never forced.

## Companion timers

Installed as systemd user units (source of truth in `systemd/`, installed via
`scripts/timers-ctl.sh install`):

- **`dreamteam-briefing.timer`** (~07:03 daily) — `scripts/morning-briefing.sh` speaks + files a
  briefing of what the night did (silent if nothing ran).
- **`dreamteam-audit.timer`** (Sun ~03:07) — `scripts/self-audit.sh` runs the suite, checks
  statusline/palace health, prunes logs; failures become follow-up issues.

Install / inspect the pack:

```bash
bash scripts/timers-ctl.sh install     # link the units, enable --now the three timers (retires the pilot)
bash scripts/timers-ctl.sh status      # systemctl --user list-timers 'dreamteam-*' + unit state
```

## Disarm

Two levers:

1. **Stop queuing work** (soft) — ensure no open `dream`-labelled issues; the nightly timer
   still fires but overnight-guarded.sh exits with decision `no-work`.
2. **Stop the timers** (hard) — `systemctl --user disable --now dreamteam-nightly-guarded.timer`
   (and `dreamteam-briefing.timer` / `dreamteam-audit.timer`), or `bash scripts/timers-ctl.sh
   uninstall` to disable + unlink the whole pack.

> Workflow scale is **opt-in**: full activation authorizes the overnight sweep explicitly.
> A plain interactive session still needs "ultracode" / "use a workflow" before running one.
