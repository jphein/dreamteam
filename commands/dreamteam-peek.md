---
description: Peek at a teammate's live tmux pane — see what a non-responding agent is actually doing.
argument-hint: "<agent-name> [--lines N] — the teammate to inspect (observer-only)"
---

When a teammate goes quiet on a `SendMessage`, you can't tell *stuck* from *mid-tool-chain*
from the roster alone (SendMessage delivery queues until the target's next tool round). This
joins the roster to the agent's live tmux pane and dumps the tail — the ground truth.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pane-peek.sh" $ARGUMENTS
```

- Resolves the pane by **pid-ancestry** first (`roster.sh --json` name→pid, then walk the
  pid's PPid chain to the owning pane across *every* tmux socket), falling back to the
  **`@handle` footer** when there's no pid (e.g. the lead) or the walk finds no pane.
- Prints the agent's status + cwd + resolved pane, then the last N lines (`--lines`, default 50).
- **Observer-only:** it only reads panes — it never types into or terminates one. To *act*
  on a stuck agent (nudge/unblock), use `scripts/poke.sh`; to peek, use this.
- Add `--json` for machine output (the contract `gm peek` consumes).

Exit codes: `0` pane found · `3` no live pane (dead / not in tmux / unknown agent) · `22` usage.

If peek shows a permission prompt or a crash, that's your root cause. If it shows an active
tool run, the agent is fine — just mid-chain; wait or `poke` a status request.
