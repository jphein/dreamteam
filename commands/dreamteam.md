---
description: Launch (or resume) a memory-guarded dream team in an isolated, capped scope.
argument-hint: "[team-name] — e.g. /dreamteam candela-wear"
---

Bootstrap a dream team with the OOM guardrails in place. This wraps the dreamteam
skill's startup sequence with the plugin's reuse, memory, and isolation guardrails.

**Pre-flight (do these first, in order):**

1. **Budget check** — never skip:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/mem-budget.sh"
   ```
   The reported MAX is your hard wave size. The PreToolUse gate enforces it too, but
   knowing it up front lets you batch instead of hitting blocks.

2. **Isolated launch** (if not already inside an isolated dream session) — runs the
   team in its own systemd memory-capped scope + its own tmux server socket so a
   runaway can't take down the host or JP's main session:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/launch-dreamteam.sh" "$ARGUMENTS" "$(pwd)"
   ```
   (This also writes the crash-recovery active-marker.)

3. Then follow the **dreamteam skill** for scope → spec → worktrees → spawn → roster →
   orchestrate. The skill auto-loads on the trigger phrases; re-read it for the
   anti-collision worktree rules.

   Reuse before spawning: `/dreamteam-roster "<task>"` shows idle teammates ranked by
   context fit — assign one via SendMessage instead of a fresh spawn (the reuse-gate
   enforces this; a deliberate fresh spawn needs `FRESH-SPAWN: <reason>` in the prompt).

**On clean finish:** cleanup runs via the SessionEnd hook (clears the marker). If you
tore the team down mid-session, `rm "${CLAUDE_PLUGIN_ROOT}/state/active"` so the next
session doesn't false-flag a crash.
