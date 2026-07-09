# dreamteam (plugin)

Converts the dreamteam **skill** into a full **plugin** so the OOM-prevention logic is
*enforced by the harness*, not just *described in prose the model can talk past*.

Born from the [2026-06-30 postmortem](docs/postmortem-2026-06-30.md): a 25-PR overnight merge cascade ran ~40 Claude
agents in one Ghostty cgroup; one ballooned to 3.7 GB; 32 GB swap hit 0; the kernel
OOM-killer thrashed for ~30 min and the whole session was lost. The old `~30 agent`
cap was a *count* with no memory backing — and ~40 were running.

## What's a hook vs. what's a script (read this first)

Claude Code hooks are **event-driven only** — there is **no "post-crash" hook event**.
So the guardrails map to the harness like this:

| Guardrail | Real mechanism | Why |
|---|---|---|
| Reuse-before-spawn | **`PreToolUse` hook** (matcher `Agent\|Task`), `exit 2` blocks | Reuse an idle teammate (zero new RAM) before creating a new agent |
| Pre-spawn memory gate | **`PreToolUse` hook** (matcher `Agent\|Task`), `exit 2` blocks | Agent spawns are tool calls; a true, deterministic admission gate |
| Post-crash recovery | **`SessionStart` hook** detecting crash *residue* (stale marker) | No "crash" event fires; we detect that SessionEnd never cleared the marker |

**No polling watchdog** (JP's call): a mid-flight balloon is contained *structurally* by
the systemd-scope `MemoryMax` cap (see `launch-dreamteam.sh`) — the team's own cgroup
hard-kills a runaway at its ceiling, so the host survives without a poller. `PostToolUse`
logs the cumulative footprint to `state/dreamteam.log` for visibility.

## File tree

```
dreamteam/
├── plugin.json                    manifest (name, version, description)
├── .claude-plugin/marketplace.json  directory-marketplace metadata
├── hooks/hooks.json               wires the 4 hook events → scripts
├── config.json                    tunables (per-agent MB, reserves, reuse enforce, scope caps)
├── scripts/
│   ├── mem-gate.sh                ★ PreToolUse gate — blocks a spawn with no headroom
│   ├── reuse-gate.sh              ★ PreToolUse gate — blocks a spawn when an idle teammate fits
│   ├── roster.sh                  authoritative team roster + liveness (--json contract)
│   ├── idle-agents.sh             idle-agent oracle + context-affinity scorer (--json contract)
│   ├── crash-audit.sh             SessionStart — surfaces the recovery checklist
│   ├── spawn-accounting.sh        PostToolUse — cumulative footprint log
│   ├── cleanup-marker.sh          SessionEnd — clears the active marker (clean exit)
│   ├── mem-budget.sh              shared budget calculator (also /dreamteam-status)
│   ├── launch-dreamteam.sh        systemd-scope + tmux -L isolated launcher
│   └── tmux-layout.sh             move agent panes into their own window
├── commands/
│   ├── dreamteam.md               /dreamteam — guarded launch
│   ├── dreamteam-status.md        /dreamteam-status — budget + footprint snapshot
│   └── dreamteam-roster.md        /dreamteam-roster — idle agents ranked by context fit
├── agents/                        named dream-agent types (luna, morpheus, lucid, nebula)
├── workflows/                     saved Workflow scripts (merge-cascade, overnight, review-sweep)
├── templates/                     Artifact dashboard HTML template
├── skills/dreamteam/SKILL.md      the existing skill (moved here verbatim + §3 prose adds)
└── state/                         runtime: active marker, HANDOFF.md, dreamteam.log
```

## Defense in depth

1. **Reuse** (`reuse-gate.sh`): assign an idle teammate (zero new RAM, warm context) before
   spawning. The cheapest lever — last night's kill was 59 procs; every spawn avoided helps.
2. **Admission** (`mem-gate.sh`): can't spawn past the live memory budget. Prevents the cause.
3. **Containment** (`launch-dreamteam.sh`): team runs in a `MemoryMax`-capped cgroup on its
   own tmux server → a runaway is hard-capped within the team; host + JP's session survive.
4. **Recovery** (`crash-audit.sh`): next session auto-surfaces "check worktrees for
   uncommitted work, reconcile the merge cascade, resume from item N."

## Team-state JSON contract

`roster.sh --json` and `idle-agents.sh --json` are the **public team-state oracle** —
external tools (guildmaster, dashboards) shell out to them and parse the result. That
JSON shape is a **frozen, versioned contract**, not an internal detail free to drift:
see [`docs/json-contract.md`](docs/json-contract.md) for every field, type, enum, and
the empty/exit-code guarantees — locked against drift by `tests/test-json-contract.sh`.

## Install (after review — these hooks BLOCK spawns and can KILL processes)

This is a **directory-based marketplace plugin** — the source dir *is* the plugin, so there's
nothing to copy. Register it once in `~/.claude/settings.json`:

- `extraKnownMarketplaces.dreamteam` → `{ "source": { "source": "directory", "path": "/home/jp/Projects/dreamteam" } }`
- `enabledPlugins["dreamteam@dreamteam"]` → `true`

```bash
chmod +x scripts/*.sh   # gate + lifecycle scripts must be executable
```

Restart Claude Code so the hooks load. Edits to the source dir take effect on the next session
start — no reinstall. (A cache copy at `~/.claude/plugins/cache/dreamteam/dreamteam/1.0.0` is
kept as an uninstall safety net, refreshed by `scripts/sync-plugin.sh`; it's not needed for
development.)

OS-level companions (see [postmortem §4](docs/postmortem-2026-06-30.md)): configure `systemd-oomd` (PSI+cgroup-aware,
fixes the Waydroid victim-poisoning), re-tune `earlyoom`, and cut the 32 GB swap. Those
make any future OOM a clean 2-second kill instead of a 30-min thrash.
