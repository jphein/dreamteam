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

## The nightly gate (PILOT)

`dreamteam-nightly.timer` fires **~02:11 daily** and runs `scripts/overnight-launch.sh`, which
checks for open work:

```bash
gh issue list -R jphein/dreamteam --label dream --state open --json number,title
```

- **None** → one log line, exit 0 (silent when idle).
- **Some** → writes `state/overnight-pending.md` listing them + speaks one line. **PILOT mode:
  it does NOT auto-start a coordinator or spend tokens** — it only *surfaces* the queued work.

So the switch that queues a night's work is simply **whether any `dream`-labelled issue is
open** — label an issue `dream` to queue it; close/unlabel to skip.

**Full activation** (JP's explicit opt-in, after watching a dry cycle): swap `overnight-launch.sh`
for `launch-dreamteam.sh` in `dreamteam-nightly.service` so the timer actually starts the sweep.
Legitimate from a timer — a timer start is an out-of-session launch, so the nested-coordinator
guard (`/dreamteam`) doesn't apply.

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
bash scripts/timers-ctl.sh install     # link the units, enable --now the three timers
bash scripts/timers-ctl.sh status      # systemctl --user list-timers 'dreamteam-*' + unit state
```

## Disarm

Two levers:

1. **Stop queuing work** (soft) — ensure no open `dream`-labelled issues; the nightly timer
   still fires but overnight-launch.sh exits immediately (and stays inert in PILOT mode anyway).
2. **Stop the timers** (hard) — `systemctl --user disable --now dreamteam-nightly.timer`
   (and `dreamteam-briefing.timer` / `dreamteam-audit.timer`), or `bash scripts/timers-ctl.sh
   uninstall` to disable + unlink the whole pack.

> Workflow scale is **opt-in**: full activation authorizes the overnight sweep explicitly.
> A plain interactive session still needs "ultracode" / "use a workflow" before running one.
