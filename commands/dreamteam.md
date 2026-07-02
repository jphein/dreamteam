---
description: Launch (or resume) a memory-guarded dream team — containment is automatic.
argument-hint: "[team-name] — e.g. /dreamteam candela-wear"
---

Bootstrap a dream team with the OOM guardrails in place. This wraps the dreamteam
skill's startup sequence with the plugin's reuse, memory, and containment guardrails.

**⛔ Do NOT run `launch-dreamteam.sh` from this session.** It starts a NEW session —
a coordinator running it spawns a second coordinator in a new terminal window
(observed candela 2026-07-01). It exists for JP to start a dedicated overnight
server from a plain terminal, and only JP launches it. Containment no longer needs
it: every agent proc is auto-attached to the memory-capped `dreamteam-agents.scope`
at spawn (scope-attach.sh), in any session.

**Pre-flight (do these first, in order):**

1. **Budget check** — never skip:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/mem-budget.sh"
   ```
   The reported MAX is your hard wave size; the `team scope` line is the true live
   footprint (incl. build daemons). The PreToolUse gates enforce all of this too,
   but knowing it up front lets you batch instead of hitting blocks.

2. **tmux check** — `echo "${TMUX:-NOT-IN-TMUX}"`. If NOT-IN-TMUX, stop and have JP
   relaunch the session inside tmux (the spawn-standards gate blocks teammate
   spawns outside tmux — teammates would open GUI windows and die with them).

3. Then follow the **dreamteam skill** for scope → spec → worktrees → spawn → roster →
   orchestrate. The skill auto-loads on the trigger phrases; re-read it for the
   anti-collision worktree rules. Spawn conventions are enforced: names are
   `<dreamname>-<task-slug>`, typed personas use their `dreamteam:*` type.

   Reuse before spawning: `/dreamteam-roster "<task>"` shows idle teammates ranked by
   context fit — assign one via SendMessage instead of a fresh spawn (the reuse-gate
   enforces this; a deliberate fresh spawn needs `FRESH-SPAWN: <reason>` in the prompt).

**On clean finish:** cleanup runs via the SessionEnd hook (clears the crash marker,
stops the containment scope when empty). If you tore the team down mid-session,
`rm "${CLAUDE_PLUGIN_ROOT}/state/active"` so the next session doesn't false-flag a crash.
