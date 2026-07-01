# dreamteam

Claude Code plugin for memory-gated parallel agent orchestration. Spawns named dream agents in isolated worktrees, coordinated via SendMessage, with admission control, reuse routing, and crash recovery.

## Structure

- `plugin.json` — manifest (name, version, description)
- `config.json` — tunables (perAgentMB, balloonReserveMB, hostReserveMB, maxAgents)
- `hooks/hooks.json` — PreToolUse gates (reuse → mem-gate chain), PostToolUse accounting, SessionStart/End lifecycle
- `scripts/` — gate scripts, budget calculator, dashboard data generator, shared lib
- `skills/dreamteam/SKILL.md` — full orchestration skill (~900 lines)
- `agents/` — custom agent type definitions (luna, morpheus, lucid, nebula)
- `commands/` — slash commands (dreamteam, dreamteam-status, dreamteam-roster)
- `workflows/` — Workflow templates (merge-cascade, overnight, review-sweep)
- `templates/` — Artifact dashboard HTML template
- `state/` — runtime state (active markers, HANDOFF.md)

## Development

Edit source files here, then sync to the plugin cache:
```bash
scripts/sync-plugin.sh
```

Plugin cache (real copy, safe to uninstall): `~/.claude/plugins/cache/dreamteam/dreamteam/1.0.0`
Registered as `dreamteam@dreamteam` marketplace (modeled after mempalace).
Marketplace metadata: `.claude-plugin/marketplace.json`.
Changes take effect after sync + next Claude Code session start.

## Testing

```bash
# Validate all scripts
for f in scripts/*.sh; do bash -n "$f" && echo "OK: $f"; done

# Check hook config
python3 -c "import json; json.load(open('hooks/hooks.json')); print('hooks OK')"

# Verify budget calculation
scripts/mem-budget.sh
```

## Key constraints

- In-process team agents (`team_name`) share the parent's CWD — `isolation: "worktree"` is silently ignored for them. Manual worktree creation before spawn is MANDATORY.
- Out-of-process `Agent()` subagents DO support `isolation: "worktree"` at spawn time.
- `EnterWorktree` is blocked for spawned subagents — it's a solo-session tool only.
- Gate scripts run on every Agent/Task tool call — keep them fast (<100ms).
