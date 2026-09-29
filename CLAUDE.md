# dreamteam

Claude Code plugin for memory-gated parallel agent orchestration. Spawns named dream agents in isolated worktrees, coordinated via SendMessage, with admission control, reuse routing, and crash recovery.

## Structure

- `plugin.json` — manifest (name, version, description)
- `config.json` — tunables (perAgentMB, balloonReserveMB, hostReserveMB, maxAgents)
- `hooks/hooks.json` — PreToolUse gates (reuse → mem-gate chain; `Bash|Monitor` → no-poll-guard, then gpu-guard), PostToolUse accounting, TeammateIdle/SubagentStop roster injection + `idle-assign.sh` (the freed agent's held context — recorded from its spawn prompt / last SendMessage by PostToolUse[Agent|SendMessage] — and the best-fit open item from `scratch/dreamteam/backlog.md` or `~/.claude/state/dreamteam-backlog.md`; `idle-assign.sh backlog add|list|done`), Pre/PostCompact HANDOFF guard, sync WorktreeCreate provision adapter (returns the worktree path, #26) + async Task*/WorktreeRemove event log, SessionStart/End lifecycle
- `scripts/` — gate scripts, budget calculator, scope-attach (automatic cgroup containment), dashboard data generator, statusline (wired via user settings `statusLine`), local-model lane seam (optional ollama, `local-model.sh`), shared lib (`lib.sh`; `lib/pane-resolve.sh` = the canonical agent→pane resolver poke/pane-peek/fleet source, #53; `lib/agent-id.sh` = the canonical "which teammate am I?" /proc walk, shared by worktree-guard + no-poll-guard), PR tooling (`pr-gate.sh` / `pr-merge.sh` / `cascade.sh` — REST-only, no polling)
- **GPU fleet** (spec `docs/superpowers/specs/2026-09-29-gpu-fleet-design.md`):
  - `gpu/fleet.json`: every host and card with measured sizes, capabilities and the host's admission rules.
  - `bin/dreamteam` → `scripts/gpu.sh` → `scripts/lib/gpu_fleet.py`: `dreamteam gpu board|inventory|claim|release|window|admit|run`. The claims ledger is at `~/.claude/state/dreamteam/gpu/claims.json` (flock).
  - `scripts/gpu/`: the three launch forms promoted from GEMS, `safe_run.sh` (familiar), `guest_run.sh` (katana, game) and `remote_run.sh` (gpu0, gpu1; a system scope, because those hosts do not linger). `test_guest_run.sh` is the on-host control for guest_run.
  - `scripts/gpu-guard.sh`: PreToolUse Bash; a lane cannot launch on a card it does not hold. `config.json gpu.guard`: warn (the rollout default), enforce, or off.
  - `scripts/gpu/callwatch.sh` + `systemd/dreamteam-gpu-callwatch.service`: katana's call watcher. It pauses GPU work only while a non-OBS process reads the virtual camera.
- `scripts/org-lookup.sh` + `scripts/lib/org_lookup.py` — optional org map: agent name → department / human owner / escalation chain, read from lexicon `catalog/agents.yaml` (`config.json .org`). Read-only; no catalog = no-op
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

- `tests/test-idle-assign.sh` — idle-assign: announce + held context (gate preamble stripped) + ranking follows context + per-stretch dedupe + re-arm on new assignment + lead never announced + empty backlog still announces.
- `tests/test-gates.sh` — mem-gate (RAM-floor block, count-cap block, non-Agent passthrough, **local-lane reserve #37** — armed lane subtracts `.local.reserveMB`, matched off/armed pair) + reuse-gate (block on live idle teammate, allow on FRESH-SPAWN / no team). Includes negative controls proving the block-paths aren't vacuous.
- `tests/test-roster.sh` — roster.sh status classification (lead/idle/dead) against a fixture, the **spawn-accounting line-21 crash regression** (restricted `ps` must not crash the hook), and a **defaults-agreement guard** (dashboard-data.sh vs mem-budget.sh fallback defaults must match — catches the 600/4000 drift class; also `.local.reserveMB` across mem-gate/mem-budget/dashboard-data, #37).
- `tests/test-dashboard.sh` — dashboard-data.sh `--json` output contract (every key dashboard.html reads) + `--inject` render + template standalone sanity.
- `tests/test-pane-resolve.sh` — the canonical resolver lib (`lib/pane-resolve.sh`, #53): pane sweep, `pr_pane_of` closest-wins PPid walk, and the **structural @handle footer-rule table** (#61 — rejects a pane merely DISPLAYING `@name`, e.g. a command or roster line), re-run through agent-activity.sh's mirrored Python regex so the two implementations can't drift.
- `tests/test-no-poll-guard.sh` — the CI-polling gate: positive controls (the measured incident
  command verbatim, a `while` loop, a `statusCheckRollup` poll, a Monitor watch, a sleep-separated
  repeat) AND negative controls proving the block is not vacuous (the same loop from a
  non-teammate is allowed — the lead's cascade must never be blocked; a one-shot check; an
  unrelated loop; the sanctioned REST route; the kill switch; malformed stdin). A missing config
  file must still ENFORCE — an absent kill switch is not a disabled guard. `gh pr checks --watch`
  is pinned separately: it is a poller with no loop keyword, so a space-delimited " watch " pattern
  misses the single most dangerous form.
- `tests/test-pr-tools.sh` — `pr-gate.sh` / `pr-merge.sh` / `cascade.sh` against a stubbed `gh`
  (fixture JSON piped through the real `jq` with the caller's real `--jq` filter, mutating calls
  logged so the tests assert what the tools DID). Pins the two traps: **a blank conclusion is a
  RUNNING check**, and **the verdict is the exit code, which a pipe throws away** (so it must also
  reach stderr). Also pins distinct exit codes for not-green / unreadable / no-CI, the default
  keep-the-branch behaviour, and the cascade's stop-and-ping-the-lane protocol. Also: an EMPTY
  `DREAMTEAM_GATE_IGNORE` means "ignore nothing" (`${VAR:-default}` would silently restore the
  defaults — the strictest request becoming the most permissive); a `null` `behind_by` must STOP
  rather than read as "up to date"; `--allow-no-ci <note>` covers the absence of checks and never
  a failing one; and `--gated-sha` re-gates when the head moved (the force-push race).
- `tests/test-org-map.sh` — the OPTIONAL org map (`scripts/lib/org_lookup.py`, `scripts/org-lookup.sh`): resolution order (exact id / current_name / lane glob / dream prefix), escalation chain to the human + channel (three-channel for `.org.threeChannelOwners`), silent no-ops (missing / `off` / malformed catalog, unknown name, entry without org fields), and **backward compatibility** — `roster-live.sh` / `idle-agents.sh` output is byte-identical with no catalog, and org keys are purely additive when one resolves.
- `tests/test-gpu.sh` — the GPU fleet, tested against the real `gpu/fleet.json` with a temp ledger and a stub ssh that serves canned probes:
  - **admission, on the 2026-09-28 incident numbers:** the ×1.2/×1.5 caps; the pair rule on RAW peaks against idle MemAvailable (gpu1's 46-band pair fits and a 5.23 GiB pair is refused; a gpu0 DEM3 pair shares its one card); katana's summed guest budget; familiar's one heavy job; VRAM beside resident services, split into physics (never overridden) and the 1 GiB margin (policy); the B60 compute block; estimate needs `--solo`; midnight-crossing windows;
  - **v1.1 claims:** sharing, `--exclusive`, scheduled `--from` handoffs (the guard blocks before a claim's start and allows after), `--override` recorded;
  - **v1.2:** a growing job's VRAM counts ×1.5 (rule 3: a growing 4.4 GiB job fits familiar:0 and 4.5 does not); katana's desktop is a resident; docker `--gpus`/`--runtime=nvidia` launches are detected, through the wrapper's pre-filter too; on a call a container holding ≥ 1 GiB of VRAM is killed, not paused; below 512 MiB free the biggest GPU container is killed; the board labels a process by its program, since Chromium reports its whole command line to nvidia-smi;
  - **v1.3 detection (`scripts/lib/gpu_detect.py`): a launch is where a shell RUNS it, never where it is mentioned.**
    - The regression corpus is one test per false-positive class from the 09-29 replay, using fictional paths. It covers cat, sed and grep of launchers, heredocs written to files, commit messages, python edit scripts, `ps | grep`, `until ssh … test`, CPU raster jobs under `safe_run.sh CAP`, `bash -n`, `--help`, and a wrapped no-op. It also covers the CPU markers `CUDA_VISIBLE_DEVICES=` and `--device cpu`, and `--gpus` after the image.
    - The real launch forms are tested too: detached guest_run queues, a GPU index before a remote queue script, a bench script written by heredoc and run by the same command, a chain script followed two levels, a script scp'd and run behind `queue_after.sh`, and a script written, scp'd and run in one call, which is not yet on disk at hook time.
    - A pinned known limit: an unreadable remote script with no GPU evidence is not a launch.
    - Every detect check is replayed through the real `gpu-guard.sh`, so the pre-filter must stay a superset.
    - Each new rule has its own red perturbation.
  - **device kinds and the fleet.json guard classes:**
    - `--device xpu` is the B60, and a CUDA index or CPU marker does not move an XPU job;
    - named GPU wrappers count when unreadable (chain45.sh, b60_bench.sh as XPU), and CPU programs never count;
    - `--device` on a launcher or an unread script names the card; `safe_run --protected` defers to its wrapped command;
    - a no-op is found past `env` and the wrappers;
  - **the Oracle's 09-29 findings:**
    - a positive control for each rule it could not turn red: the fail-open net at 3000 nested `$( )`, `bash -c`, `$( )`/`<( )`, a heredoc or here-string to a shell, a tee-written script, `env -S`, `flock -c`;
    - extensionless local scripts (`./gpujob`, `source gpujob`), through the real wrapper's pre-filter too;
    - tmux new-session/send-keys, screen, `su -c`, xargs, eval, and `bash -c "$c"`;
    - printf-written scripts, a symlinked launcher, and a 4-deep chain;
    - indices the host does not have, and reads (`git status`) are not launches;
    - the replay's copy of the pre-filter honours bash quoting;
  - **the Oracle's delta review (#112):**
    - `--protected` over a CPU program or a CPU-marked command is no training run;
    - an XPU script on a CUDA-only host fails open;
    - an explicit `--device` beats a CPU name;
    - `command` runs its argument (`-v` is a lookup);
    - an XPU index beats the CUDA CPU marker;
  - **the board's guard section:**
    - unguarded = a lane session started before the hook's reflog arrival; an orchestrator is no lane, and an unknown arrival counts every lane unguarded;
    - the incremental replay cache: a new line is read once, a line still being written waits, the offset stops at the last complete line, and a replaced transcript rebuilds;
    - `hook_arrival` is tested on a real temp git reflog;
  - **the call watcher:** a stand-in camera. OBS alone is not a call; the stand-in OBS is ONE process with comm `obs` via prctl, because a copy of multi-call `sleep` named `obs` exits at once, which made this negative vacuous. A second reader pauses; only the GPU container is docker-paused; the calm period holds; after it only our pause file is removed and only our containers are unpaused; a foreign pause file is never touched;
  - **the ledger:** granters only; one holder per card; expiry; the holder releases;
  - **the guard's `detect`:** positive controls for each launcher, the `CUDA_VISIBLE_DEVICES` form and python over ssh; negative controls for reads and CPU jobs; an unresolved ssh host fails open;
  - **the guard's modes:** warn, enforce and off; a missing config is warn;
  - **the wrapper's exit codes;**
  - **`run --dry-run`** for all three forms, plus the live-VRAM refusal;
  - **safe_run and remote_run** with PATH stubs (meminfo refusals; the exact scope, sleep lock and card of a remote launch).
- `tests/test-worktree-create.sh` — the #26 WorktreeCreate hook adapter (`worktree-create-hook.sh`): asserts **stdout is exactly the worktree path** (the command-hook contract that was missing), cwd-independence, branch-off-HEAD, opt-in git-ignored-input copy (`.claude/worktree-copy`), name sanitization, and a clean **non-zero exit on failure** (no phantom "succeeded but no path").

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
  Measured 2026-09-17: every gate runs in 108-208 ms, so the budget is a target
  rather than a description; `scripts/no-poll-guard.sh` and `worktree-guard.sh`
  sit at the top of that range because of the /proc ancestry walk.
- **`timeout` in `hooks/hooks.json` is in SECONDS, not milliseconds.** Every
  value in that file was once written ms-style (`3000`, `30000`), which meant
  50 minutes to 8 hours — so the ceiling those numbers looked like never
  existed. If you add a hook, write `4`, not `4000`. The same mistake was live
  in `~/.claude/settings.json` (14 entries, one at `130000` ≈ 36 hours) and in
  the first draft of the mempalace#497 pre-mutation hook, whose README argued
  the non-existent ceiling was a safety backstop.
- The dream-name roster is a DERIVED artifact. Source of truth: lexicon's `vocabularies/dreams.yaml` (`dreams.roster`). Add names there, then regenerate the `ROSTER=` regex in `scripts/spawn-standards.sh` with the command in the comment above it — `tests/test-standards.sh` fails on drift. New names must be single lowercase tokens (the gate splits the agent name on the FIRST hyphen) and must not collide with JP's tmux session names.
