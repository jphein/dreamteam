---
description: Map EVERY agent on the host — all projects, all scopes, all tmux sockets (observer only).
argument-hint: "[--project <p> | --stale | --json]"
---

Run the fleet-wide observer (issue #18) and interpret its output:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fleet.sh" $ARGUMENTS
```

It assembles the full host map from three layers — `dreamteam-*.scope` cgroups
(recursive, anchor-excluded), every `claude` process, and panes across **all**
tmux sockets (PPid-chain matched) — and prints per agent: PID · project
(worktree-aware) · agent name · pane · scope · uptime · CPU · RSS · owner.

**Read the OWNER column before reasoning about any agent.** Rows marked
`NOT-YOURS` belong to another project's live fleet — they are NEVER orphans to
you, no matter how the scope math looks (the 2026-07-04 near-miss: 11 "unaccounted"
procs in the shared scope were techempower's and memorypalace's working fleets).

- `--stale` lists candidates (pane-less + old + idle CPU) for **human** review.
  The tool terminates nothing, by design and by test (test-fleet.sh tripwire).
- `--json` is the orchestrator contract: `{caller, scopes[], agents[]}`.
- Scope totals at the top are the true per-scope footprints (`memory.current`),
  including child processes — the same numbers containment enforces against.
