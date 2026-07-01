# Postmortem — 2026-06-30 overnight OOM cascade (katana)

**Status:** reconstructed 2026-07-01 from the verified kernel OOM dump analysis whose
numbers were recorded in `config.json` `_notes`, `README.md`, and the dreamteam skill.
This file gives those scattered citations one home; it adds no new claims.

Host: katana — 32 GB RAM / 32 GB swap, Ubuntu, GNOME desktop, Ghostty (snap).

## 1. What happened

A 25-PR overnight merge cascade ran a dream team plus review agents — **~40 Claude
processes in the working set, 59 distinct Claude procs system-wide at OOM time**
(spanning multiple sessions; the per-team "~30 agent" cap was violated nearly 2×
because no single session could see the aggregate).

Baseline agents ran ~200–280 MB RSS each (live-active with context ~350–430 MB) —
**17.2 GB resident total**. Then **two agents ballooned simultaneously (3.7 GB +
3.4 GB)**. The 32 GB swap was driven to 0, the kernel OOM-killer thrashed for
**~30 minutes** (swap made dying slow instead of preventing death), and the whole
session — orchestrator, agents, terminal — was lost.

## 2. Root causes

1. **Count-only cap, no memory backing.** "~30 agents" was prose in a skill; nothing
   enforced it, nothing sized it to available RAM, and it was per-team while the
   damage was system-wide.
2. **One cgroup, one tmux server.** Everything ran in a single Ghostty snap cgroup on
   the single `default` tmux server — no memory ceiling, so one balloon consumed the
   host; no isolation, so one dead server took every session.
3. **No balloon headroom.** Planning assumed baseline RSS; two concurrent multi-GB
   balloons had no reserve to land in.
4. **Oversized swap.** 32 GB of swap turned a 2-second OOM kill into a 30-minute
   freeze — the kernel paged instead of killing.
5. **Waydroid victim-poisoning.** Android processes carry `oom_score_adj` 900+, so the
   kernel killed tiny Android procs repeatedly instead of the real hog.

## 3. What the plugin now enforces (prevention mapping)

| Root cause | Enforcement |
|---|---|
| Count-only cap | `mem-gate.sh` (PreToolUse) — live budget `(avail − host − balloon) / perAgent`, system-wide count via `lib.sh`, exit-2 blocks |
| Needless spawns | `reuse-gate.sh` — idle teammates are reassigned via SendMessage before any fresh ~300 MB process |
| One cgroup / one tmux server | `launch-dreamteam.sh` — `systemd-run --scope` MemoryHigh/Max/SwapMax + dedicated `tmux -L dreamteam` socket |
| No balloon headroom | `balloonReserveMB` in `config.json` (sized to the observed double-balloon; see `_notes` for the 2026-07-01 re-tuning rationale) |
| Blind recovery | `crash-audit.sh` (SessionStart) — stale `state/active` marker surfaces the recovery checklist + live roster |
| Roster amnesia | `roster.sh` (authoritative harness team config) injected at SessionStart, post-spawn, TeammateIdle/SubagentStop, and Pre/PostCompact |

## 4. OS-level companions (outside the plugin)

Referenced from README — these make any *future* OOM a clean ~2-second kill instead
of a 30-minute thrash:

1. **`systemd-oomd`** — PSI- and cgroup-aware killing. Fixes the Waydroid
   victim-poisoning (it evaluates cgroups, not per-process `oom_score_adj`), and
   pairs with `launch-dreamteam.sh`'s scope so the team cgroup is the natural victim.
2. **Re-tune `earlyoom`** — the ~10%-available SIGTERM line is the plugin dashboard's
   "Red" tier; keep the two aligned so the plugin degrades before earlyoom fires.
3. **Cut the 32 GB swap** (e.g. to 8 G) — bounded swap bounds the thrash window.
   `launch-dreamteam.sh` already bounds the *team's* share via `MemorySwapMax`.
4. **Stop Waydroid before large runs** — `waydroid session stop` (it both consumes
   RAM and poisons victim selection).

## 5. Incident #2 — 2026-07-01 16:06 (same host, plugin active)

The follow-up test nobody ordered. Two fleets (ep3fc research + a candela dream team)
ran ~30 admitted agents across sessions. `systemd-oomd` killed the shared Ghostty
scope at **16:06:04** — memory 26.5/33.6 GB and swap 6.0/8.6 GB crossing its 70%
policy (`journalctl -u systemd-oomd`, verified).

**What worked:** recovery took seconds, not 30 minutes — the swap cut (§4.3, done)
plus systemd-oomd's cgroup-level kill (§4.1, active by default) behaved exactly as
predicted. The admission gate blocked new spawns at the floor; sessions restarted
with recoverable state; the new lifecycle hooks logged real events to T-9s.

**What failed, and the fixes shipped the same day:**

1. *Post-admission growth is invisible to admission control.* candela agents spawn
   gradle/JVM daemons — child-process memory the claude-proc accounting never sees
   (~10 GB grew after the last admitted spawn). The morning's balloon-reserve cut
   (8→4 G) removed exactly the margin that absorbs this → **restored to 8 G**; the
   reserve's `_notes` now name child toolchains explicitly.
2. *The degradation tiers had no actor.* The quiesce/shed ladder was prose in the
   skill; no orchestrator was watching. → `team-events.sh` now appends a live
   ORANGE/RED tier warning to every TeammateIdle/SubagentStop injection, so every
   active orchestrator hears memory pressure in-context as it develops.
3. *No crash marker for plain sessions.* Only `launch-dreamteam.sh` wrote
   `state/active`, so crash-audit stayed silent after the kill. → `spawn-accounting.sh`
   now writes the marker on the first spawn of any session; SessionEnd clears it.
4. *Containment was opt-in, and nobody opted in.* The `MemoryMax` scope (§3) only
   protected fleets launched via `launch-dreamteam.sh` — both fleets ran in plain
   sessions sharing one Ghostty cgroup, so oomd's victim was everything at once.
   → **`scope-attach.sh` (shipped same day): containment is now automatic.** Every
   spawn (and every TeammateIdle sweep) attaches all live agent procs on the host
   into `dreamteam-agents.scope` (MemoryHigh/Max/SwapMax from config, `Delegate=yes`
   — required for `AttachProcessesToUnit`) via the systemd user manager. Orchestrators
   stay outside and survive a scope kill. Children spawned after attach (gradle/JVM
   daemons — the actual killers) inherit the cgroup; daemons already detached before
   attach are the one prospective-only gap. Live-verified 2026-07-01 16:26: 11 agents
   from two plain-session fleets attached, 24G cap active. `/dreamteam` + the launcher
   remain the belt-and-braces path (own tmux server, whole-session scope).

## 6. Numbers reference

| Metric | Value (verified from the OOM dump) |
|---|---|
| Claude procs at OOM time | 59 distinct (system-wide, multiple sessions) |
| Working-set agents in the cascade | ~40 |
| Baseline RSS / agent | ~200–280 MB (active-with-context ~350–430 MB) |
| Total resident at OOM | 17.2 GB |
| Concurrent balloons | 2 (3.7 GB + 3.4 GB) |
| Swap | 32 GB, driven to 0 |
| Thrash duration | ~30 min |
| Nominal agent cap at the time | ~30 (prose-only, violated ~2×) |
