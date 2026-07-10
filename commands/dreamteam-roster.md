---
description: Realtime agent roster — live names, panes, and pane-trusted status, plus reusable idle agents.
argument-hint: "<team-name> — REQUIRED; bare fails closed (exit 22) to avoid the smol-team bug"
---

The **realtime roster**: who is on the team, what pane each agent is in, and its
pane-trusted status (ACTIVE / IDLE / queued / stale-isActive / no-pane / dead) — read
from the LIVE pane, not a stale hook-stamp — joined to each agent's assignment
(issue / branch / task) from `scratch/<team>/roster.md`.

**`--team` is required.** Bare invocation would fall back to the most-recently-modified
team config — usually the *wrong* team in a multi-team session (the smol-team bug) — so
it instead **fails closed** (errors to stderr, exits 22) rather than feed a `--json`
consumer wrong-team data. Find your team name under `~/.claude/teams/` (e.g.
`session-xxxxxxxx`).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/roster-live.sh" --team "$ARGUMENTS"
```

- **Names** come from the harness team config (the authoritative membership).
- **Panes** are resolved by **pid-ancestry** (pane-peek #32's technique: all tmux
  sockets, PPid walk, closest-wins) — collision-resistant, unlike an `@handle`
  name-match that false-hits across duplicate window titles.
- **Status trusts the live pane** (agent-activity.sh #34): a spinner line = ACTIVE, a
  past-tense completion + bare prompt = IDLE; queued input is reported orthogonally, and
  a `⚠` flags where the config's `isActive` disagrees with the screen.
- **Assignments** (issue / branch / task) overlay from the human-maintained
  `scratch/<team>/roster.md`; the roster's core truth (name / pane / status) never
  depends on it.

Add `--json` for machine output (manager roles / dashboards), `--no-overlay` for
pane-truth only, or `--roster-md PATH` to point at a specific assignment file.

## Reuse before you spawn

Reusing an idle agent costs zero new RAM and keeps its context — always prefer it over a
fresh spawn (the reuse-gate hook enforces this). To rank idle agents by fit for a task:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/idle-agents.sh" --task "<task description>"
```

If the right idle agent exists, `SendMessage({to:"<name>", message:"<new task>"})`. Only
spawn fresh when the task needs an isolated worktree, is genuinely independent parallel
work, or no idle agent has usable context — then add `FRESH-SPAWN: <reason>` to the
spawn prompt so the reuse-gate lets it through.
