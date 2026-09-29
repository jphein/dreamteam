# The GPU fleet: inventory, claims, one launcher, a launch guard (design spec)

- **Date:** 2026-09-29 (drafted 09:2x–09:4x PDT by cirrus-scry, a Morpheus lane)
- **Status:** v1 is live (dreamteam #101, f55fbd2). v1.1 (#102, #103) added shared and scheduled claims, the raw-peak pair rule keyed to idle MemAvailable, and katana's call watcher. v1.2 (10:3x) adds morpheus-gems's rules 3 and 6 as refined (VRAM growth; kill a VRAM-heavy container on a call, or when free VRAM is low), docker GPU launch detection, and katana's desktop as a VRAM resident. v1.3 (11:5x) makes the guard's detection precise: a launch is where a shell runs it, never where it is mentioned (§5.1; 109 of v1.2's 125 would-blocks were false, and it missed 18 real launches). It also records that no lane session alive today runs the hook (§5.3). The guard stays in `warn` through today's GEMS window; the lead seeds and flips it tonight (§5.3).
- **Asked by:** JP, 08:5x, relayed by team-lead: *"we need a gpu part for dreamteam plugin pls"*.
- **Domain sources:**
  - `money/scratch/contests/gems/FAMILIAR-RULES.md` (the lead, Lucid, Drift and Morpheus-gems, 2026-09-28);
  - `tools/safe_run.sh` (Lucid, promoted by morpheus-gems);
  - `tools/guest_run.sh` with `tools/test_guest_run.sh` (morpheus-gems);
  - `lanes/drift/gpu1_launch.sh` (drift-gems).
- **Scope:** this repo. The GEMS copies of the three launchers are not touched. Switching them to the
  plugin is morpheus-gems's call (§7).

**Legend.**
- **[measured]**: read with an instrument on 2026-09-29 09:1x: `nvidia-smi`, `free`, `swapon` and `df` over ssh.
- **[rule]**: a GEMS rule, quoted from FAMILIAR-RULES.md or a launcher, with the incident it encodes.
- **[proposed]**: a new default in this spec.

## 0. Decisions at a glance

| # | Decision |
|---|---|
| D1 | **Inventory is data:** `gpu/fleet.json`, which lists every host and card with measured sizes, capabilities and the host's admission rules. Code reads it; no host is hard-coded in a script again. |
| D2 | **One claims ledger:** `~/.claude/state/dreamteam/gpu/claims.json`, written under `flock`. A claim records the lane, the purpose, `from`/`until`, and the job's **measured** peaks: host RAM, VRAM, and whether it grows with run length. **v1.1:** claims **share** a card while its VRAM and the host budget hold (GEMS runs two lanes on gpu0's one card). A claim may **start later** (`--from`, for the schedule's handoffs). `--exclusive` keeps co-tenants off (a bench). A granter's `--override REASON` passes a soft refusal, is recorded, and never passes VRAM or a compute block. |
| D3 | **Only granters write claims and windows.** A granter is an orchestrator session, identified by having no `--agent-id` (the lead, or JP's own shells), or a name matching `gpu.granters` in config (default `nyx*` and `morpheus-gems`). A lane asks its lead by SendMessage. |
| D4 | **One admission library** (`scripts/lib/gpu_fleet.py`), used by `claim`, `run` and `admit`. The cap is measured peak × 1.2, or × 1.5 when the job grows with run length. Host rules come from `fleet.json` (§3). |
| D5 | **`dreamteam gpu run` is the single launcher.** It checks the caller holds the card, computes the cap, admits, and runs the host's form: familiar the `safe_run` form, katana and game the `guest_run` form, gpu0 and gpu1 the detached sleep-locked form. The three scripts are promoted into `scripts/gpu/` with their budgets read from `fleet.json`. |
| D6 | **A PreToolUse Bash guard** (`gpu-guard.sh`) detects a GPU launch and checks the caller holds that card. It runs in `warn` mode first, then `enforce` once the current holdings are seeded (§5.3). It fails open on unknown identity, like every guard in this plugin. |
| D7 | **`dreamteam gpu board`** shows, per card: the holder, the claim's end, the window, and live VRAM and processes. Per host: available RAM, swap use, root free space and the pause file. It reads over ssh, in parallel, with a 5 s timeout; a sleeping host shows as `asleep` and is **never woken** by the board. |
| D8 | **Windows:** `gpu window <card> <HH:MM-HH:MM|always|never>` sets when a card may be used, for example katana's GPU while JP is away from the desk. A claim or run outside its card's window is refused. |
| D9 | **katana's call watcher** (`scripts/gpu/callwatch.sh`, a user service). JP's OBS holds the virtual camera all day, so OBS is not a call. While a **non-OBS** process reads `/dev/video9`, it writes `~/.gems-pause` (which guest-form GPU jobs obey) and `docker pause`s GPU containers. It undoes only its own actions after 60 s of calm (§3b). |

## 1. The inventory (`gpu/fleet.json`)

Measured 2026-09-29 09:1x PDT, all five hosts awake:

| host | card(s) [measured] | arch, compute cap | host RAM, swap [measured] | root free [measured] | desktop |
|---|---|---|---|---|---|
| **katana** | `katana:0` RTX 2080 Ti, 11264 MiB | Turing, 7.5: tensor cores, fp16 fast, **no bf16** | 32003 MB, swap 20993 MB | 111 G of 938 G | **yes** (JP's workstation; the card drives the desktop) |
| **familiar** | `familiar:0` P102-100, 10240 MiB; `familiar:xpu0` Arc Pro B60 (PCI 09:00.0, `e211`) | Pascal, 6.1: **no bf16**, fp16 slow, no tensor cores. The B60 is Battlemage (XPU) | 31995 MB, **zram** 15.6 G | 34 G of 234 G | no |
| **game** | `game:0` GTX 1650, 4096 MiB | Turing TU117, 7.5: **no tensor cores**, no bf16 | 15978 MB, swapfile 8 G | 11 G of 234 G | **yes** (an active graphical session) |
| **gpu0** | `gpu0:0` GTX 1050 Ti, 4096 MiB | Pascal, 6.1 | 11941 MB, **no swap** | 58 G of 108 G | no |
| **gpu1** | `gpu1:0`, `gpu1:1` P102-100, 10240 MiB each | Pascal, 6.1 | 10938 MB, **no swap** | 73 G of 115 G | no |

Per-card fields:
- `vram_mib`, `arch`, `compute_cap`;
- `caps`: `cuda`, `bf16`, `fp16` (`fast`, `slow` or `none`), `tensor_cores`, `xpu`, `vulkan`;
- `compute_ok`, with a `blocked_by` note;
- `notes`.

The B60 is listed with **`compute_ok: false`**, blocked by BIOS Resizable BAR (memory
`familiar-b60-needs-rebar`: torch xpu fails until ReBAR is on; Vulkan works). `run` and `claim` refuse a
card whose `compute_ok` is false, unless given `--vulkan`.

Per-host fields:
- `ram_mb`, `swap` (`{kind: zram|file|none, mb}`), `cores`, `desktop`;
- `disk_floors` (the path and the minimum free GB);
- `pause_file`;
- `launch_form` (`familiar`, `guest` or `remote`);
- a `budget` block (§3).

`dreamteam gpu inventory --check` re-measures a host and reports drift from `fleet.json`, the same idea
as `realm vlans verify`.

## 2. Claims and windows

A **claim** is `{card, lane, purpose, from, until, peak_ram_mb, peak_vram_mib, grows, protected, exclusive, override}`,
keyed `card#lane#from`. Rules (v1.1, after morpheus-gems's holdings showed two lanes on gpu0's one card and
handoffs through the day):
- **Sharing:** claims that overlap in time on one card must fit its VRAM together: Σ peak VRAM ≤ vram − 1 GiB −
  resident services (familiar:0 carries 3.4 GiB of llama-servers). The host budget (§3) counts every overlapping
  claim on the host. A lane re-claiming a card replaces its own overlapping claim.
- **Exclusive:** `--exclusive` refuses any overlapping co-tenant, and an exclusive holder refuses newcomers. The
  refusal names the holder and the span.
- **Schedules:** `--from T` starts a claim later, so the gpu1 card 0 handoff (morpheus's bench until 10:15, then
  nebula's lindep) is two claims. A claim is live only between `from` and `until`: before its start, the guard
  treats the lane as holding nothing. HH:MM means the next occurrence, so `--from 22:00 --until 06:00` is overnight.
- **Override:** a granter's `--override REASON` passes a window, exclusivity, solo or host-budget refusal, and the
  reason is kept in the ledger (for example, the lead's B60 bench beside vesper's protected run). Nothing overrides
  the physics: VRAM beyond the card's total less its resident services, or a compute-blocked card. The 1 GiB VRAM margin is policy, so it can be overridden (vesper's 6.5 GB beside familiar:0's 3.4 GiB of services runs at 97%).
- **Peaks must be measured.** `--peak-ram` and `--peak-vram` are required. `--estimate` is accepted only
  together with `--solo`, which makes the claim exclusive on its host until a measurement replaces the
  estimate. That is the "46 bands: unmeasured; run it solo first" rule, in code [rule].
- `until` is required, as a time or a duration. An expired claim reads as free on the board. Its record
  stays, marked `expired`, so the history survives.
- A claim is refused when the host's budget (§3) would not hold it beside the claims already on that host.

A **window** is `{card, spec: "HH:MM-HH:MM" | "always" | "never", note}`, set by a granter. The default is
**`always` on every card**, katana included. On katana the protection is the guest form's desktop-first
freezer and the pause file, and the lead's caps (23:2x) already allow guest jobs there. GPU stutter against
the compositor is not detected (guest_run's own note), so JP or the lead can narrow katana with a window
at any time [proposed]. A window that crosses midnight is allowed (`01:00-07:00`, `22:00-06:00`).

## 3. Admission math (one library; every number has an incident)

**The cap.** `cap = peak × 1.2` for fixed-shape jobs, and `peak × 1.5` when `grows` is set. The ×1.5 comes
from two OOM kills on 2026-09-28 [rule]:
- Canary-1B: a 2-clip sample, 4.75 GB + 20% = 6 GB, grew past 6.26 GB on the full run;
- the lidar build: GDAL's per-worker cache grew across blocks.

Every job prints its measured peak, and the claim is updated from it.

**familiar** [rule 1–3], `launch_form: familiar`:
- **Regenerable** (the default): admit when `MemAvailable ≥ cap + 2 GB`. Runs under `MemorySwapMax=0`,
  `oom_score_adj +500`, `nice 19`.
- **Protected** (`--protected`, for training): admit when `MemAvailable ≥ 6 GB` **and** swap (zram) is under
  50%. Every PID in the scope gets `oom_score_adj −300`, twice, to close the fork race.
- **One heavy job at a time** on familiar: refuse if another GEMS python process over 1 GB is resident. This
  is safe_run's guard, kept.
- The zram is RAM, which is why `MemorySwapMax=0` makes the cap real.

**gpu0 and gpu1**, `launch_form: remote`, no swap:
- The pair rule, on **raw measured full-run peaks** (×1.5 when the job grows): `Σ peaks + 1.5 GiB ≤ the host's limit`.
  The ×1.2 cap is the per-job MemoryMax, not the pair sum. STAGE3 00:27: "2 × peak + 1.5 ≤ 10.2, no margin
  needed" [rule].
- The limit is keyed to the host's measured **idle MemAvailable**, not its total (drift-gems, 09-29): gpu1 10.2 GiB
  (10444 MiB); gpu0 about 9.5 GB. gpu0 has 11941 MB, but services hold about 2.4 GB.
- STAGE3's measured full-run VmHWM: 26 bands 3.2 GiB, 32 bands 3.43, 34 bands 3.53, 46 bands 4.22. The 46-band pair
  is 2 × 4.22 + 1.5 = 9.94, so it fits.
- The evidence: a 26-band pair on gpu1 was kernel-OOM-killed at 19:29:47 on 09-28 at 5.23 GiB each. The
  pad-once loader's 2.81 GiB made pairs fit (2 × 2.81 + 1.5 = 7.1).

**katana and game**, `launch_form: guest` [guest_run.sh, the lead's caps 23:2x]:
- The host budget bounds the **sum** of all running guest caps: katana 12 GB RAM and 9 GiB GPU; game 8 GB and
  3.5 GiB. The incident: reverie stacked 6 G + 8 G + 4 G on katana at 23:53, each admitted alone.
- Admission: `MemAvailable ≥ cap + headroom` (katana 4 GB, game 2 GB), and GPU free ≥ GPU cap + 1 GiB.
- On game, root free ≥ 8 GB + `--disk-need`.
- No pause file (`~/.gems-pause`).
- **Desktop first:** the job's scope is **frozen** while the desktop session's CPU PSI avg10 is over 10 or its
  memory PSI avg10 is over 5, or while the pause file exists, or on game when root free falls under 8 GB.
  It thaws after 60 s calm, with hysteresis. It is never left frozen: the launcher's TERM handler thaws it.
- The GPU watchdog TERMs, then KILLs after 30 s, a job whose processes hold more VRAM than their cap.

**Every card.** `Σ claimed VRAM on the card ≤ vram − 1 GiB − resident services`, where a growing job's VRAM counts ×1.5.
That growth factor is also the job's headroom, so no 1 GiB margin is stacked on top (morpheus-gems rule 3: familiar:0
takes a growing job only at ≤ 4.4 GiB, since ×1.5 ≤ 6.6). katana:0's desktop is a resident, at about 2.7 GiB. At launch, `run` also checks
the card's **live** free VRAM (another process may hold it) and names what does. A card whose `compute_ok` is false
is refused.

### 3b. katana's call watcher (the lead's correction, 2026-09-29)
- **The premise that was wrong:** "no heavy CUDA on katana while OBS's virtual camera is live". OBS runs all day in
  the tray with the virtual camera on (the Kiyo-Call profile), holding `/dev/video9`, so that rule meant never
  (memory `obs-virtualcam-not-a-call`).
- **The rule:** a live call is a **second, non-OBS** process reading `/dev/video9`.
- **The watcher:** `scripts/gpu/callwatch.sh`, run by `systemd/dreamteam-gpu-callwatch.service`, polls every 5 s with
  one `find /proc/*/fd -lname` pass (~50 ms). This mirrors `guest_run.sh`'s own call guard, which refuses and freezes
  guest GPU jobs during a call.
- **On a call:** it writes `~/.gems-pause` with a `callwatch` marker, unless a pause file already exists that it did not
  write (set on JP's word: left alone). GPU containers are stopped by name, because a container runs outside a user
  scope, so freezing the launcher does not reach it. They are found by `DeviceRequests`, and by mapping nvidia-smi's
  compute pids to docker scopes. A container holding ≥ 1 GiB of VRAM is **killed**, because a paused one keeps its
  VRAM. A smaller one is paused and unpaused after the call (morpheus-gems rule 6, refined).
- **At any time:** if katana's free VRAM falls below 512 MiB, the GPU container holding the most VRAM is killed, one per
  tick. JP's desktop comes first, as in luna-refurb's `docker_guard.sh`, whose low-VRAM kill fired twice on 09-29.
- **After 60 s of calm:** it removes only its own pause file, and unpauses only the containers it paused.
- **Controls:**
  - In `tests/test-gpu.sh`, a stand-in device, never the real camera. The "OBS alone" negative uses one process with
    comm `obs` (via `prctl`). A copy of `sleep` named `obs` dies at once on this coreutils ("unknown program"), which
    made that negative vacuous until perturbed.
  - A live control on katana's real `/dev/video9` (09:58): OBS alone, no pause; ffmpeg as a second reader, the pause
    file appeared naming ffmpeg; after calm, it was removed.

**Every host.** Each `disk_floors` entry holds: familiar's run outputs never on the nvme root [rule 5],
enforced as root free ≥ 10 GB [proposed]. A refusal exits **75** (EX_TEMPFAIL, retry later), the
code all three launchers already use.

## 4. The launcher: `dreamteam gpu run`

```
dreamteam gpu run --card <host:idx> [--protected] [--grows] [--peak-ram MB] [--gpu-mem GB]
                  [--disk-need GB] [--log PATH] [--name NAME] -- CMD...
```

1. **Identity and claim.** The caller must hold the claim on `--card` (lane = `dt_agent_id` without its
   `@team`). An orchestrator may run on a card it has claimed for itself. Otherwise the exit is 77 (EX_NOPERM).
2. **Window.** The card's window must be open now. Otherwise the exit is 75.
3. **Cap.** Taken from the claim's peaks unless `--peak-ram` overrides them. An override above the claim's
   peak re-runs the host budget check first.
4. **Form.** The host's `launch_form` decides:
   - **familiar:** `scripts/gpu/safe_run.sh [--protected] CAP CMD`, run on familiar over ssh.
     `~/Projects/dreamteam` is Syncthing-mirrored there, so the same file runs. Detached with
     `setsid nohup` and a log, because a training run outlives an ssh session.
   - **katana, game:** `scripts/gpu/guest_run.sh --mem CAP --gpu-mem G --disk-need D -- CMD`. katana runs it
     locally. On game it is **installed** first to `~/.local/lib/dreamteam-gpu/`, checksum-verified, because game
     does not sync `~/Projects`, then run detached.
   - **gpu0, gpu1:** `scripts/gpu/remote_run.sh`, drift's gpu1_launch made generic:
     - `CUDA_VISIBLE_DEVICES=<idx>` and a `systemd-inhibit --what=sleep` lock for the life of the run, so a stray
       `realm wol sleep` is refused [rule];
     - `setsid nohup`, and the log under the run directory;
     - an `nvidia-smi -i <idx>` preflight (the lib/module mismatch trap; exit 5) and a run-exists check (exit 17);
     - `MemoryMax=CAP`, `MemorySwapMax=0` in a user scope, which gpu1_launch lacked; the pair rule used to be a
       comment and is now admitted in code.

     GEMS's `--threads 1` injection and the `g0-`/`g1-` name prefixes are GEMS conventions, so they stay in
     GEMS's own wrapper.
5. **Report.** Print the host, card, unit or pid, log path and cap. The claim gains a `jobs[]` entry. `release`
   refuses while a job of that claim is still running, unless given `--force`.

`dreamteam gpu admit --card … --peak-ram …` runs steps 1–3 as a dry run and prints the arithmetic.

## 5. The launch guard (`scripts/gpu-guard.sh`, PreToolUse Bash)

### 5.1 What counts as a GPU launch (v1.3: where a shell RUNS it, never where it is mentioned)
v1.2 scanned the command's tokens: any launcher name or `CUDA_VISIBLE_DEVICES=` anywhere was a launch, and so was
any python over ssh to gpu0, gpu1 or game. Replayed over 3600 lane Bash calls from 2026-09-29 00:00 to 11:30
(`dreamteam gpu replay`, `scripts/lib/gpu_replay.py`), it flagged 125 would-blocks:
- **109 were false.** They were `cat`, `sed`, `grep`, `scp` and `diff` of launcher scripts, heredocs written to files,
  commit messages, python edit scripts, `ps | grep` status checks, and nebula's all-day CPU raster builds on gpu0.
- **It missed 18 real launches.** They were chained through scripts: reverie's `after_queue.sh` and
  `night_chain.sh` queues, vesper's `chain-nh.sh → gpu1_run.sh` (the gpu1:1 train.py of 11:04), luna-refurb's
  verify script, and drift's DINO inference, scp'd to gpu0 and queued behind `queue_after.sh`.

v1.3 (`scripts/lib/gpu_detect.py`) parses the command as a shell does. It honours quotes, escapes, heredocs,
`$(…)`, `<(…)` and `;`/`&&`/`||`/`|`/`&`/newlines, and looks only at the program word of each simple command,
after `NAME=value` prefixes and wrappers. The wrappers are nohup, setsid, env, timeout, nice, ionice, stdbuf,
chrt, taskset, flock, sudo, time, watch, systemd-run (its `-E` sets the environment), systemd-inhibit, GEMS's
`queue_after.sh`, and `safe_run.sh CAP` without `--protected`. A simple command launches GPU work when:
- it is a launcher: `gpu1_launch.sh [N]` (host from `HOST=`, else gpu1), `run_exp.sh`, `remote_run.sh`,
  `guest_run.sh` unless `--gpu-mem 0`, or `safe_run.sh --protected`. Not with `--help`, and not wrapping a no-op
  (`safe_run.sh --protected 64M true` is an admission smoke test);
- a GPU index is set on it: `CUDA_VISIBLE_DEVICES=N` or `ZE_AFFINITY_MASK=N` as a prefix, through `env`, or
  exported earlier. An explicit prefix makes any program a launch (except a read such as `nvidia-smi` or
  `echo`). An exported index counts only for python and for scripts that cannot be followed. A variable value
  (`=$GPU`) means some card of that host;
- it is python with GPU evidence: an index as above, `--device cuda[:N]`/`xpu:N`, `-m torch.distributed.run`, or
  a script whose basename matches `fleet.json guard.gpu_programs` (stage2_train, dino_features, train.py,
  finetune);
- it is `torchrun`, `deepspeed`, `accelerate launch` or `ollama run`;
- it is `docker`/`podman run|create` with `--gpus`, `--runtime=nvidia` or `--device /dev/nvidia*` before the image;
- it runs a script that is **followed**. The detector reads the script and applies the same rules inside it,
  with the environment the script inherits. Three kinds are followed:
  - a script this command writes with a heredoc (`cat > bench.sh <<EOF … bash bench.sh`);
  - a script this command `scp`s to a host and then runs there (the heredoc body wins over the disk, because the
    hook runs BEFORE the command);
  - a script on this machine, up to three levels deep (chain.sh → gpu1_run.sh → the ssh).

  `bash X` is treated as `X` for launchers and wrappers.

The ssh remote command, a heredoc fed to a remote shell (`ssh gpu1 bash -s <<EOF`), and `bash -c STRING` are
parsed the same way, on their host. An ssh to an unresolvable host (`ssh "$H"`) fails open.

**Device kinds and the GEMS classes (#110, morpheus-gems 12:1x).**
- A CUDA job gets a CUDA card and an XPU job an XPU card (`caps.cuda` / `caps.xpu` in fleet.json).
  - `--device xpu` with no index on familiar is the B60, `familiar:xpu0`, never the P102.
  - Only a kind's own variable indexes it, so a CUDA index or the CUDA CPU marker does not move an XPU job.
- `fleet.json guard` holds three classes:
  - `gpu_programs`: python scripts, a string for CUDA or `{"match", "kind"}`.
  - `gpu_scripts`: GEMS wrappers whose child is stage2_train (chain45.sh, queue_dem3_seeds.sh,
    queue_stack_seeds.sh, pipeline_1m.sh) and drift's b60_bench.sh (kind xpu). They count by name when their text
    cannot be read, for example when run on gpu0 over ssh.
  - `cpu_programs`: ens_eval.py, score_sweep.py, make_candidate.py, build_stacks.py, build_dem_features.py and
    tip1e.py. These are never a launch, whatever the environment says.
- `--device cuda|xpu[:N]` on a launcher's or an unread script's command line names the kind and the card.
  drift's b60_bench.sh passes `--device xpu` through `safe_run --protected` to run_exp_xpu.sh.
- `safe_run --protected` defers to its capped command. The protected run is the evidence only when that command
  reveals nothing, and a no-op is found past `env` and the wrappers.
- On the morning window this gives 36 would-blocks, all real. That's 34 plus nebula's two `queue_after.sh … bash
  chain45.sh` chains on gpu0 and gpu1, which v1.3 missed. drift's B60 bench moves to `familiar:xpu0`.

**The Oracle's review (a1d17af, 09-29 12:3x): SHIP-AS-IS, 0 must-fix.** Its findings are fixed in #111:
- **Pre-filter:** an extensionless local script (`./gpujob`, `bash gpujob`, `. ./gpujob`, `source gpujob`) was a
  launch to detect, but the pre-filter let it through unchecked. The pre-filter now also passes `./`, `sh `,
  `source `, `. /`, `. ~`, tmux, screen, xargs, `eval ` and `su `. That lifts the replay's pass rate from 58% to
  72%, about 64 ms added per lane call on average.
- **Tests:** seven rules had no test that could go red. Each now has a positive control and a red perturbation:
  - the fail-open net (3000 nested `$( )` → "parse error, fail open (RecursionError)");
  - `bash -c`, `$( )`/`<( )`, a heredoc or here-string fed to a shell, a tee-written script, `env -S` and
    `flock -c`.
- **Forms it now scans** (they were never claimed):
  - `tmux new-session` and the other runner subcommands, and `tmux send-keys`: tmux is the fleet's own runner;
  - `screen -dmS`, `su -c`, `xargs`, and `eval`;
  - `bash -c "$c"` and `eval "$c"` of a variable the command set;
  - printf- and echo-written scripts;
  - a launcher symlinked under another name (judged by its realpath);
  - a 4-deep local chain (MAX_DEPTH 4).
- **Cards that don't exist:** an index the host does not have is dropped, because the process sees no GPU. So
  `CUDA_VISIBLE_DEVICES=1` on katana, or `--gpus device=1` there, is not a launch.
- **Reads:** git, less, rg, stat, ps, systemctl and their kin are reads.

**The Oracle's delta review of #110 (6740ce7): FIX-BEFORE-ENFORCE (1). Fixed in #112:**
- **The blocker:** the `safe_run --protected` fallback treated a capped CPU command as a training run
  (`--protected 20G python build_stacks.py`, `--protected 6G env CUDA_VISIBLE_DEVICES= make`). The scan now counts
  CPU verdicts (a CPU program, a CPU marker, `--device cpu`), and the fallback applies only when the capped command
  was neither judged CPU nor named a card.
- **An XPU job on a host with no XPU,** or a CUDA job with no CUDA card, fails open. It never falls back to the other
  kind's cards: `b60_bench.sh` run on gpu1 is not a gpu1 launch.
- **An explicit `--device cuda|xpu` beats a CPU program's name.** An index in the environment does not: morpheus-gems's
  classes say "whatever the environment says". A renamed GPU job still shows on the board.
- **`command X` runs X** (a wrapper); `command -v X` is a lookup.
- **In env-only evidence, a variable naming a device beats another variable's CPU marker:**
  `CUDA_VISIBLE_DEVICES= ZE_AFFINITY_MASK=0` is an XPU job.

**Not launches:** every argument and every quoted string, heredoc data (`cat > f`, `git commit -F -`, `jq`),
reads, `bash -n`, `--help`, python without GPU evidence (CPU jobs), and the CPU markers:
`CUDA_VISIBLE_DEVICES=` (empty), `-1`, and `--device cpu`. drift's 09:09 `dino_features.py --device cpu` smoke is
a CPU job.

**Precision over recall, on purpose.** A false block bricks a lane in `enforce`, while a missed launch still
shows on `dreamteam gpu board` as `IN USE, NO CLAIM` within minutes. So an unreadable remote script with no GPU
evidence is not a launch, and that known limit is pinned by a test. The replay of the same window gives 34
would-blocks, each one reviewed as a real launch: v1.2's 16, plus the 18 it missed. The pre-filter in
`gpu-guard.sh` is a superset of these triggers. It passes python, `.sh`, the GPU variables, the launchers, the
GPU runners and docker/podman. The tests replay every detect check through the real wrapper, so a trigger
missing from the pre-filter goes red. It costs about 10 ms for a command the pre-filter skips and about 85 ms for
one it passes; in the replay it passed 58% of lane calls, against 14% in v1.2.

### 5.2 The decision
- Identity: `dt_agent_id` from `lib/agent-id.sh`. Empty identity is an orchestrator or JP, and is allowed
  (fail open, the plugin's rule).
- It is allowed if the lane holds an unexpired claim on C, or the command goes through `gpu run`.
- Otherwise: in `enforce` mode, exit 2 with the holder, the end time and the way to ask ("SendMessage your
  lead: `dreamteam gpu claim C --lane <you> …`"). In `warn` mode, allow, and write one line to
  `~/.claude/state/dreamteam/gpu/guard.log` plus stderr.

### 5.3 Rollout (warn → seed → enforce)
The guard fires on every lane's Bash calls, and the GEMS lanes launch jobs today with no claims on record, so
enforcing on day one would stop GEMS mid-run. Hence:
1. Ship in `warn`. The log is a live positive control: the would-block lines must name real GEMS launches and
   nothing else.
2. morpheus-gems, the window-granter in FAMILIAR-RULES, supplied the holdings (09:18). The v1.1 model (shared,
   scheduled) can express them. They are seeded as claims by a granter (the lead or morpheus-gems) from
   `money/scratch/gpu-fleet/seed-2026-09-29.sh`, which should be dry-run first.
3. Flip `gpu.guard` to `enforce` in `config.json`, a one-line reversible change, once a day of warn lines shows
   no false positives.

**The warn log cannot see yet (found 11:2x, 09-29).** Plugin hooks load at session start. All 13 lane sessions
alive at 11:20 started before the guard reached main (09:40), so no lane runs `gpu-guard.sh`, and `guard.log`
did not exist. This was proven two ways. First, a would-block command in such a session logged nothing. Second,
the same payload piped to the hook script logged a warn. So an empty `guard.log` is a zero from an instrument
that cannot see. The warn-phase review uses the replay instead:
`dreamteam gpu replay --since '<date> 00:00'`. To compare two plugin versions on the same window, run
`python3 scripts/lib/gpu_replay.py --plugin <other checkout> --tsv <file>` from each.
Enforcement also reaches only sessions started after 09:40: a lane is guarded once it is respawned.

## 6. `dreamteam gpu board`

It prints one line per card:
- the holder, the claim's end, and the window (open or closed now);
- VRAM used over total, and the compute processes (pid, VRAM, and command where the host allows);
- the host's available RAM, swap used %, root free, the pause file (on or off), and `asleep` for an
  unreachable host.

It reads over ssh, in parallel, `ConnectTimeout=5` and a 12 s wall clock. **The board never wakes a host.**
`--json` has the same content. `claim`, `release`, `window` and `admit` print the board line they changed.

**The guard section** (the lead, 12:1x 09-29) comes last:
- the mode, and when the hook reached this checkout (`hook_arrival`: the first reflog entry whose HEAD contains
  the commit that added `gpu-guard` to hooks.json; 09:40:47 on katana);
- the live lane sessions still unguarded, meaning Claude processes with `--agent-id` that started before then.
  An unknown arrival counts every lane as unguarded, never as all guarded. Orchestrators always pass;
- the would-blocks since local midnight, from the replay against the claims live at each command's time. It shows
  the last 10; `--guard` shows all. Pre-filter misses are printed too.

The replay behind it is incremental. `replay-cache.json` in the state dir keeps each transcript's offset, the
rows found so far, and the ids already seen. It reads only complete lines, so a line being written waits. The
cache is rebuilt when the day, the detection code, fleet.json, the pre-filter or the claims change, or when a
transcript is replaced or shrinks. Cold, it takes 4.7 s over 83 transcripts (800 MB) and runs beside the host
probes; warm, 0.3 s. The ids already seen make a re-read harmless.

## 7. What is not changing, and the migration
- The GEMS copies (`tools/safe_run.sh`, `tools/guest_run.sh`, `lanes/drift/gpu1_launch.sh`) stay exactly as
  they are. GEMS is mid-competition, and those copies are what its lanes and records cite.
- Replacing them with shims that exec `dreamteam gpu run` is morpheus-gems's call, after claims are seeded.
  Until then, the guard's warn log is the only effect on GEMS.
- `earlyoom`, zram and the palace are untouched. The zram decision (jp-ab, 20:47) stands.

## 8. Tests (`tests/test-gpu.sh`, in `tests/run.sh`)
- **Admission library** (pure, no hosts):
  - the ×1.2 and ×1.5 caps;
  - the gpu1 pair rule: a 2.81 GiB pair is admitted and a 5.23 GiB pair refused, the 09-28 incident's
    numbers;
  - the katana budget sum: 6 + 8 + 4 G is refused at the third job, reverie's stack;
  - familiar's protected and regenerable forms;
  - VRAM Σ;
  - the B60 refused and allowed with `--vulkan`;
  - windows across midnight;
  - an estimate needs `--solo`.
- **Ledger:** one holder per card; granters only (a lane is refused, an orchestrator and `nyx-*` allowed); expiry;
  `release` refuses while a job runs.
- **Guard:** positive controls (each launcher, the `CUDA_VISIBLE_DEVICES` form, `ssh gpu1 python …`) and negative
  controls (`nvidia-smi`, a log tail, `board`, an unrelated `python`). Warn allows and logs; enforce blocks.
  Orchestrator identity passes. A missing config still defaults to `warn`, never off.
- **Launchers:** `safe_run.sh` refuses (75) on stubbed `/proc/meminfo` values. `remote_run.sh` builds the
  exact ssh command (a stubbed `ssh` records it). `guest_run.sh` keeps its own on-host controls
  (`scripts/gpu/test_guest_run.sh`, run on katana).
- **Perturbation for the PR:** disabling the pair rule turns the suite red.

## 9. Open
- Answered: morpheus-gems (the holdings; the rules since 23:5x; the peaks ledger in STAGE3.md) and drift-gems (the
  pair rule keyed to idle MemAvailable; the traps). GEMS-wrapper traps (absolute holdouts, `--threads 1` ordering)
  stay in GEMS's wrapper. The detachment trap (every remote fd redirected) and the inhibitor's lifetime are covered:
  the live control on gpu1 showed ssh returning at once, and the inhibitor held, then gone after the run.
- v2: `host:cpu` claims for CPU jobs (today they pass safe_run's live admission only), and B60 live VRAM (it needs
  xpu-smi).
- JP's floor: nothing here spends money, signs or needs his hands. katana's GPU window is `always`, protected by
  the desktop-first freezer and the pause file; JP or the lead can narrow it with one `gpu window` call.
