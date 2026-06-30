---
description: Show reusable idle agents (and, for a task, the best context-affinity match).
argument-hint: "[task description] — optional; ranks idle agents by fit"
---

Before spawning anything, check who's already idle and warm. Reusing an idle agent
costs zero new RAM and keeps its existing context — always prefer it over a fresh spawn
(the reuse-gate hook enforces this; this command is the manual view).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/idle-agents.sh" --task "$ARGUMENTS"
```

- With no argument: lists all reusable idle agents in the current team.
- With a task: ranks them by context affinity (same cwd = strong, shared task keywords =
  weak) so you assign the best-fit agent via `SendMessage` instead of spawning.

If the right idle agent exists, `SendMessage({to:"<name>", message:"<new task>"})`. Only
spawn fresh when the task needs an isolated worktree, is genuinely independent parallel
work, or no idle agent has usable context — and then add `FRESH-SPAWN: <reason>` to the
spawn prompt so the reuse-gate lets it through.
