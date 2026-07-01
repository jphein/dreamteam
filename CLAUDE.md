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

Edit files directly here — Claude Code resolves `CLAUDE_PLUGIN_ROOT` to this source
directory (directory-based marketplace), so changes take effect on next session start
without syncing. A cache copy exists at `~/.claude/plugins/cache/dreamteam/dreamteam/1.0.0`
as an uninstall safety net; `scripts/sync-plugin.sh` updates it but is not required for
development.

Marketplace metadata: `.claude-plugin/marketplace.json`.
Registered as `dreamteam@dreamteam` in `~/.claude/settings.json` `extraKnownMarketplaces`.

## Testing

Full regression suite (each `tests/test-*.sh` is standalone and self-isolating —
PATH-stubbed `free`/`ps`/`pgrep` + fixture team configs + temp state via the scripts'
`DREAMTEAM_*` env seams, so no production script is touched):

```bash
bash tests/run.sh          # runs every suite, exits non-zero on any failure
```

- `tests/test-gates.sh` — mem-gate (RAM-floor block, count-cap block, non-Agent passthrough) + reuse-gate (block on live idle teammate, allow on FRESH-SPAWN / no team). Includes negative controls proving the block-paths aren't vacuous.
- `tests/test-roster.sh` — roster.sh status classification (lead/idle/dead) against a fixture, the **spawn-accounting line-21 crash regression** (restricted `ps` must not crash the hook), and a **defaults-agreement guard** (dashboard-data.sh vs mem-budget.sh fallback defaults must match — catches the 600/4000 drift class).
- `tests/test-dashboard.sh` — dashboard-data.sh `--json` output contract (every key dashboard.html reads) + `--inject` render + template standalone sanity.

Quick static checks:

```bash
for f in scripts/*.sh; do bash -n "$f" && echo "OK: $f"; done
python3 -c "import json; json.load(open('hooks/hooks.json')); print('hooks OK')"
CLAUDE_PLUGIN_ROOT=$PWD scripts/mem-budget.sh   # set CLAUDE_PLUGIN_ROOT so it reads config.json, not baked-in defaults
```

## Key constraints

- In-process team agents (`team_name`) share the parent's CWD — `isolation: "worktree"` is silently ignored for them. Manual worktree creation before spawn is MANDATORY.
- Out-of-process `Agent()` subagents DO support `isolation: "worktree"` at spawn time.
- `EnterWorktree` is blocked for spawned subagents — it's a solo-session tool only.
- Gate scripts run on every Agent/Task tool call — keep them fast (<100ms).
