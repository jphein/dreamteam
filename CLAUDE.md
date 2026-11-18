# dreamteam

Claude Code plugin for memory-gated parallel agent orchestration. Spawns named dream agents in isolated worktrees, coordinated via SendMessage, with admission control, reuse routing, and crash recovery.

## Structure

- `plugin.json` — manifest (name, version, description)
- `config.json` — tunables (perAgentMB, balloonReserveMB, hostReserveMB, maxAgents)
- `hooks/hooks.json` — PreToolUse gates (reuse → mem-gate chain; `Bash|Monitor` → no-poll-guard, then gpu-guard), PostToolUse accounting, TeammateIdle/SubagentStop roster injection + `idle-assign.sh` (the freed agent's held context — recorded from its spawn prompt / last SendMessage by PostToolUse[Agent|SendMessage] — and the best-fit open item from `scratch/dreamteam/backlog.md` or `~/.claude/state/dreamteam-backlog.md`; `idle-assign.sh backlog add|list|done`), Pre/PostCompact HANDOFF guard, sync WorktreeCreate provision adapter (returns the worktree path, #26) + async Task*/WorktreeRemove event log, SessionStart/End lifecycle
- `scripts/` — gate scripts, budget calculator, scope-attach (automatic cgroup containment), dashboard data generator, statusline (wired via user settings `statusLine`), local-model lane seam (optional ollama, `local-model.sh`), shared lib (`lib.sh`; `lib/pane-resolve.sh` = the canonical agent→pane resolver poke/pane-peek/fleet source, #53; `lib/agent-id.sh` = the canonical "which teammate am I?" /proc walk, shared by worktree-guard + no-poll-guard; `lib/nopoll_text.py` = the no-poll guard's heredoc-data reader, #191), PR tooling (`pr-gate.sh` / `pr-merge.sh` / `cascade.sh` — REST-only, no polling)
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
  **Heredoc data (#191):** `scripts/lib/nopoll_text.py` removes a heredoc body from the judged text only
  when every path its text can take ends as data (a sink such as cat/gh/git/read, a python program that
  names no process API, no pipe/`$( )`/`<( )`/file/variable reaching a non-sink later). Allow controls:
  the 11-14 incident (a python edit of overnight.js quoting its checks loop), an issue body posted with
  `-F body=@file`, a PR body in `"$(cat <<'EOF' … EOF)"`, a commit message, a variable passed only to gh.
  Deny controls: bash/ssh/sh owners, a pipe into sh, a script written then run (`bash f`, `./f`, `. f`),
  read/`$( )`/variables into eval or `bash -c`, `source <( )`, an unquoted body's `$( )`, a group piped to
  bash, `done <<EOF`, a python body using os.system, `gh alias set --shell`, and python3 failing (the
  block stays). Each rule has a red perturbation (listed in PR #215's body).
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
  - **v1.2:** a growing job's VRAM counts ×1.5 (rule 3: a growing 4.4 GiB job fits familiar:0 and 4.5 does not); katana's desktop is a resident; docker `--gpus`/`--runtime=nvidia` launches are detected, through the wrapper's pre-filter too; on a call a container holding ≥ 1 GiB of VRAM is killed, not paused; below 1 GiB free the biggest GPU container is killed (800 MiB kills, 1100 does not); the board labels a process by its program, since Chromium reports its whole command line to nvidia-smi;
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
  - **the final review (#113):**
    - a CPU decoy beside an unjudged program keeps the protected run;
    - `. gpujob` goes through the pre-filter;
    - tmux if-shell/pipe-pane and `screen -X stuff` are scanned;
    - export/declare variables are tracked;
  - **#114:**
    - utilities (mv, mkdir, rm), builtins (cd, `[[`) and GDAL/PDAL CLIs are no runs, so a CPU pipeline under `--protected` stays CPU;
    - `uv run`, `conda run -n` and the other runners run their command;
  - **#118:**
    - runner global options (`uv --directory DIR run`, `uv -q run`) are skipped, so the command is seen and a CPU program behind them stays CPU;
    - `uvx` runs its command;
    - an unknown runner verb fails closed;
  - **post-flip follow-ups (#122):**
    - uv global options after `run` are skipped (no false block);
    - hatch env run, hatch test;
    - a sourced unread script is a leaf;
    - find -exec, trap (its command scanned, not just counted), tar --to-command, and path-named reads;
    - uv run -m, uv run x.py, pushd;
    - the pre-filter passes runners and `.py`;
    - cuda13 caps in the inventory;
    - katana's resident is the desktop's TYPICAL 2700 MiB (its 3.7 GB peak is guarded live), so a ~6.5 GB official-image verify is claimable without an override, and putting the peak back goes red;
  - **#124:**
    - a protected find -exec or tar --to-command of an unjudged program is a training run, and of a read it stays CPU;
    - `trap -- CMD` and `tar -xI CMD` are scanned;
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
- `tests/test-lessons.sh` — the 14 Fleet lessons (SKILL.md § Fleet lessons, 2026-09-29/30, incl. three adopted from gstack v1.91). Every lesson check is scoped to the SECTION (a phrase that also lives in the spawn template cannot keep a deleted lesson green), plus numbered lessons 1–14, placement between REACHING JP and Org map, all four report fields + red-before-green in the spawn template, Oracle's coverage-before-verdict order, and README/CONTRIBUTING pointers. Targeted perturbations for the section scope, the spawn template and the Oracle shape (fixture writes checked, so a failed write cannot pass as a detection); placement and README/CONTRIBUTING are plain greps.
- `tests/test-roster-watch.sh` — `scripts/roster-watch.sh` (#81, the #79 watcher contract's reference implementation) against a stub roster serving one fixture per poll: debounce threshold and flicker reset, SELF never flagged (plus the negative control that it fires when not SELF, and SELF derived from the agent id), baseline seed vs a late idle, the pane-peek verify line, re-arm, dead/membership/poll-error once each, team pinned after the first poll, `--polls`/`--until` end with `WATCH-END`, bad arguments exit 22.
- `tests/test-headless-chrome.sh` — `scripts/headless-chrome` against a stub browser: the three flags it adds, the caller's `--headless`/`--user-data-dir` winning (`--disable-extensions` still added), the fresh profile under `$XDG_RUNTIME_DIR` (else `~/.cache`) existing during the run and removed after, exit-status passthrough, TERM forwarded to the browser (a broken forward fails instead of hanging), `HEADLESS_CHROME_BIN`, and exit 127 with no browser.
- `tests/test-overnight-guarded.sh` — the GUARDED nightly (`scripts/overnight-guarded.sh`, docs/OVERNIGHT-GUARDED.md) with stub curl/gh/git/claude: the 70 % 5-hour and 30 % 7-day guard (0.69 holds; a null 7-day pool, a dead proxy and a garbage answer all fail closed), silent no-work (also when the queue is stale), never_sweep, PRs dropped from the issue list, PR-only for production AND unlisted repos, the merge rule in the prompt, the proxy env and fresh-clone cwd of each `claude -p`, STARTED/FINISHED records, the plan's sweep-results (held-back count), the 06:30 / max_hours caps, the 40 % continuation floor, DRY_RUN's contained launch line (and that it never publishes), one start per night, the briefing line and issues-queue's `guarded` mode; units checked with `systemd-analyze --user verify`.
- `tests/test-issues-queue.sh` — `scripts/issues-queue.py` (docs/ISSUES-QUEUE.md) with stub gh/systemctl and the script copied into a temp root: pages decoded as successive JSON documents (a `][` title survives, whitespace-separated pages, discovery pages, a non-JSON page fails its repo); a discovery failure (error, `{}`, an error object, scalars, `[{}]`, a record missing `open_issues_count`, non-UTF-8 bytes, a hang) exits 2 and keeps both previous snapshots; a failed or malformed repo (`[{}]`, a sixth dream issue with no title, issue number 0, non-UTF-8, 100 000-deep nesting) gives `complete=false` + `failed_repos` and rc 1; OWNERS is an allowlist (case-insensitive) and an outside repo is never read; both files 0600; `blocked_on_jp` = `needs_jp` length; a hung gh, discovery or systemctl has its child killed too (PIDs checked), hung gh plus hung systemctl stay inside the run budget, the systemctl reserve covers the four calls counted from a run, a hung systemctl falls back; a non-finite timeout or budget (`nan`, `inf`, `abc`) exits 2 before any call; `TimeoutStartSec` bounded; a stale `*.tmp` cannot block publication, the state file gets a new inode, and a white-box check pins publish() to one same-dir `os.replace` of the whole text with unique temp names (overlapping runs are a smoke check). Each rule has a red perturbation (#193).
- `tests/test-overnight-workflow.sh` — `workflows/overnight.js` under stubbed Workflow globals: `issues` skips Scout and fixes exactly the given list, `prOnly` never runs a merge agent, `prGate` makes the warden gate on pr-gate.sh (exit 4 = no merge), and no args keeps the old Scout → Ship behaviour.
- `tests/test-check-line.sh` — `scripts/lib/check-line.sh`, the one CHECK line every dreamteam timer writes (docs/CHECKS.md): each line is parsed back with the Watch's own `LINE` and `NAME` regexes (read from the plan checkout, else pinned copies), so the fact is exactly one segment (` · ` → `, `, newline → space); an unknown status is published as fail; a name the Watch would not read is never published; `check_name` adds `-<host>` off familiar (lower-cased, `[a-z0-9-]` only); a symlink at the destination is replaced, a directory refused, predictable temp names unused.
- `tests/test-briefing-line.sh` — the morning briefing's line (real script, temp HOME/state/checks, stub gh and notify-send, `--quiet`): a run with a nightly record → ok naming the decision; no record → warn; an OOM kill → warn, also from a REAL quiet-night run (stub journalctl: the OOM is measured before the quiet-night exit and named in that briefing); an unreadable journal (a non-zero exit, or exit 0 with the "not seeing messages from other users and the system" hint) is "OOM unmeasured" (warn), never "no OOM", in the briefing, the line and the spoken sentence of an active night; with the guard record MISSING on the timer's host, reconciliation turns a stale nightly ok into fail; the script runs from a private fixture root, so a lost `DREAMTEAM_STATE` falls back into the fixture; `--check-only` with no briefing → fail and state untouched, on an existing briefing → ok with the file byte-identical and its mtime kept; a briefing the run could not write → fail, also when a valid older briefing is on disk (success is the write's own result, not an mtime); katana's name carries the host; the briefing reconciles a dead night after the cap (nightly-guarded → fail with no hand `--check-line`), on the production `auto` path too (a stub systemctl: it asks for `dreamteam-nightly-guarded.timer`; enabled → the "running" ok becomes fail, not enabled → the line stays byte-identical); `--check-only` never reconciles (no nightly line, no lock file). The nightly line's cases (`guard_line`: dead runner after its cap → fail, held → warn, finished → ok, old record → warn, no readable plan.json → fail even when every repo reads finished, a plan whose repos are not unique owner/name strings (`[{}]`, duplicates) → fail, results counted once per PLANNED repo (its last), an unwritable guard record → fail, one snapshot under a REQUIRED lock (held elsewhere → nothing published, free again → published; a record-write failure is published under it too; `--check-line` prints exactly what it published, nothing when another publisher held the lock and replaced the file), the guard record's temp file is exclusive (planted symlinks untouched), malformed plans (non-object, no repos, not owner/name, deadline 0/-5/"x"/1.5/1e20/5000000000/4102444800) → fail while in-range forms (1000000019.5, 1e9) are accepted and floored (pinned: 1000000019.5 reads as :19's minute, not the next), a record whose `at` is not a full `date -Iseconds` string (missing, null, garbage, a number, date-only, "ISO +1 day") → fail (GNU date would read "" as today's midnight), `--check-line` runs nothing) are in `test-overnight-guarded.sh`; issues-queue's (each exit's line, and `check_line()` called directly: sanitizing, unknown status, refused names, host case) in `test-issues-queue.sh`; the retired pilot's (host-suffixed name) in `test-timers.sh`; `run.sh`'s isolation (one private dir holding HOME, the XDG dirs and the checks dir; inherited values replaced and DECOYS with sentinels untouched; no suite run when it cannot be made, proven by an invocation sentinel; the live roster check reads the real team config via `DREAMTEAM_REAL_HOME`, read-only) in `test-self-audit.sh`. No test may name a real state path (2026-11-17: a mutant runner kept an inherited real checks dir and its cleanup deleted familiar's `~/.local/state/checks`).
- `tests/test-self-audit.sh` — `scripts/self-audit.sh` against a fake root with a stubbed `tests/run.sh`, HOME, state and checks dir in a temp dir: the weekly audit writes ONE fleet-shape line to `~/.local/state/checks/dreamteam-audit.line` (also on stdout): `ok · suites n/n` on green, `warn` when the suites are green but the palace is down or unmeasured or the statusline drifted, `fail · suites k/n, failing <names>` naming the suite to fix, and `fail · suites unreadable` for every summary it cannot trust (no run.sh, no summary, a pass string not on the LAST line, inconsistent or zero counts, a pass summary with a non-zero exit, a FAILED summary that does not name exactly k `test-*.sh` suites); the failing suite's own section survives into the journal even with 80 lines after it (the 2026-11-15 run kept only the last 40, which cut its FAIL line); publication is a unique same-dir temp file plus `mv -T`, so a symlink at the destination is replaced and never followed, a directory there is refused, symlinks planted at the predictable temp names are never followed, overlapping runs leave one whole line (a smoke check), counts are decimal (`1/09` is 8/9, never a shell octal abort), and a check name that is not a plain basename publishes nothing; an unwritable checks dir still exits 0 with the line on stdout; and `tests/run.sh` gives every suite the timer's environment (`TMUX` unset), so interactive and timer runs agree (the 11-15 failure was `test-standards.sh` reading the caller's tmux).
- `tests/test-timers.sh` (retire-pilot part) — `timers-ctl.sh retire-pilot` and `install` against a stub `systemctl`: the 02:11 pilot pair is retired by asking systemd (`is-enabled`), so a dangling link or a unit loaded from outside the user dir is still disabled `--now` and its link removed; both pilot units and only those are touched (the call log must equal the expected four calls per pilot unit: is-enabled, disable --now, then is-active + is-enabled at the final gate; an unrelated enabled unit and its link survive); a final gate verifies BOTH units before any outcome (retired, reported, absent), so a not-found but still-running unit blocks a retirement claim, and a leftover link alone is removed with retirement claimed only after both units pass the final gate; an absent pilot is a no-op; `disable`'s exit code decides nothing: the final gate's answer does (`is-active` not in an active state: active/activating/reloading/deactivating/refreshing; `is-enabled` not-found/disabled; a queued job behind an inactive unit is NOT inspected), so a `disable` that exits 1 after the unit is gone (katana 2026-11-17, a linked unit) counts as retired, and a failed OR "successful" disable that leaves the unit enabled or running is rc 3 with no line; `--retired-on` also refuses while a pilot unit is still running; `--retired-on <date>` records an operator-reported earlier retirement of a pilot verified absent ("retirement reported as <date> … date given by the operator"; a real calendar date, not in the future: 2024-02-29 yes, 2025-02-29 / 2026-02-30 / 2026-13-01 / 2999-01-01 no → rc 22, no line); any other argument shape (`--retired-on=…`, extra words, unknown options, a missing date) → rc 22 before any systemctl call; a query systemd cannot answer (no user bus: empty stdout) fails instead of reading as absence, and a path it cannot remove fails instead of reporting "unlinked", and in both cases install stops before linking anything; install retires before it links. 21 red perturbations in the PR body.
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

## Stack choices (STACK-CHOICES rule)

- **Local model lane: Ollama + `qwen3.5:9b-q4_K_M` on the desktop 2080 Ti** (2026-11-12). Ollama because `local-model.sh` speaks its API (config change only, no adapter). That model because it is the newest that fits an 11 GiB Turing card entirely in VRAM with headroom left for the desktop and NVENC. The stronger MoE models (qwen3.6-35B-A3B) need their experts in the desktop's RAM and CPU, so they stay on the server GPU. Shortlist, sources and limits: `docs/BACKENDS.md`. Host and address live in a private per-host overlay, never in this public repo.

## Per-host overlays

`config.<host>.json` beside `config.json` is deep-merged over it by `scripts/lib/config_merge.py` (every reader). Overlays are **host data**: this repo is public, so they are gitignored and live only in the Syncthing'd tree (each host reads only its own). A host's floors and how they were derived go in `scratch/memory-floors-*.md`. Mechanism: `.gitignore` `/config.*.json` and the test-roster check "no per-host overlay is tracked".
