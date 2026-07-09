# Manager Roles — Hypnos & Nyx (design spec)

- **Date:** 2026-07-09
- **Status:** approved-pending-JP-review
- **Scope:** dreamteam plugin (this repo). Guildmaster changes are referenced as follow-ups only.

## Problem

The coordinator (Sandman) is chronically busy while agents sit idle. JP's words
(2026-07-09): *"make sure you are delegating things so that you can respond to me.
right now you are almost always busy, often there are many agents idle."*

Today the plugin's hooks **enforce** (gates block bad spawns) and **signal**
(tier warnings inject into context), but every **action** — nudging idle agents,
verifying message delivery, acting the memory tier ladder, shedding load — burns
coordinator attention. The coordinator's scarce resource is JP-facing
responsiveness, not throughput.

Two aggravating facts, both observed:

1. **SendMessage is not always reliable** — delivery is sometimes delayed/batched,
   so an agent can sit on an undelivered assignment. A comms role must verify
   delivery and have a fallback channel.
2. **Forks are not peer-addressable** — a fork inherits the coordinator's full
   context, but teammates cannot SendMessage it back. A manager without a working
   inbox is broken by construction.

## Decisions (JP's calls, 2026-07-09)

| Question | Decision |
|---|---|
| One ops persona or two? | **Two** — comms (Hypnos) and resources (Nyx), separate blast radius |
| Scope | **Per-team** — every team gets the same manager roles; `/dreamteam-fleet` stays the host-wide *view* |
| Argus + Iona (overnight overseer/conductor) | **Folded into Hypnos**; rows deleted, Reeve + Hermes stay |
| Names | **Hypnos** (agent manager) + **Nyx** (resource manager) |
| Naming convention | `<dreamname>-<task-slug>` → **`<dreamname>-<role>`**, roster-wide |
| Spawn mechanics | Managers are **peer-addressable typed teammates, never forks** |

## Design

### 1. Two typed personas

New files `agents/hypnos.md` and `agents/nyx.md`, same format as the existing
five (frontmatter `name`/`description`/`color` + persona body with voice,
boundaries, comms rules).

#### Hypnos — agent manager (`hypnos-agent-manager`)

God of sleep, father of Morpheus and the Oneiroi — the manager of the dream
agents. Voice **Andrew**, quality `hd`, subtitle_color **cyan**.

Owns *communication and roster flow*:

- **Delivery verification.** After any SendMessage to a teammate, confirm the
  pane reacted (`tmux capture-pane` / `gm peek`). If the message hasn't landed
  in ~60s, re-deliver by typing into the agent's pane:
  `tmux send-keys -t <pane> "<msg>" Enter`. SendMessage stays primary (it lands
  in the transcript); tmux injection is the reliability fallback.
- **Roster flow.** Keep `roster.md` current (idle/busy/dead + acting role),
  match idle agents to queued work (`/dreamteam-roster` affinity), perform or
  propose reassignments so no agent idles while work queues.
- **Agent↔agent brokering** *(absorbed from Iona)*. Pair agents touching shared
  files, surface communication gaps, relay cross-teammate context.
- **Team-health audit** *(absorbed from Argus)*. Every 15 min; if Sandman is
  silent >5 min, escalate URGENT (SendMessage to Sandman, then JP-visible
  channels per the attention plumbing).
- **Doc steward.** Append operational lessons to `state/lessons-<date>.md` as
  they happen. Never live-edit the skill mid-session; at session end, turn
  generalizable lessons into a docs PR (lazily create a worktree for this one
  task) for dreamteam SKILL.md and flag guildmaster-side notes for JP.
- **Boundaries:** no feature work, no code edits, no worktree (except the lazy
  session-end docs worktree), **no kill authority**. `tmux send-keys` ONLY into
  panes mapped to the OWN team's roster — never `NOT-YOURS` panes (fleet owner
  rule).

Cadence: fast — event-driven plus a 1–2 min poll loop between events.

#### Nyx — resource manager (`nyx-resource-manager`)

Primordial Night, mother of Hypnos — the substrate everything runs on. Voice
**Ava**, quality `hd`, subtitle_color **magenta**.

Owns *memory, containment, and shedding* — the actions the tier ladder
currently assigns to the orchestrator:

- **Tier-ladder actor.** On hook-injected ORANGE/RED warnings (or its own poll):
  - Yellow → announce admission freeze to Sandman + Hypnos.
  - Orange → quiesce: checkpoint requests to agents (delivery via Hypnos).
  - Red → shed load down the escalation ladder: `shutdown_request` → wait ~60s →
    `TaskStop`; write the crash HANDOFF immediately.
- **Scope watch.** `MemoryCurrent` vs `MemoryHigh` (85% = scope-pressure),
  containment sweeps, verify scope-attach took effect for each new spawn.
- **Balloon forensics.** Identify the growing PID from the roster, investigate,
  report cause + recommendation to Sandman.
- **Admission input.** Compute `mem-budget.sh` MAX before each spawn wave and
  hand Sandman the number — Sandman stops doing budget math inline.
- **State hygiene.** Detect and clear stale per-team active markers (§6) whose
  processes are gone.
- **Sole kill authority below Sandman.** The chatty role (Hypnos) and the kill
  role (Nyx) are deliberately different agents.

Cadence: slower — 2–5 min poll plus event-driven on injected tier warnings.

### 2. Naming: `<dreamname>-<role>`

The `name` field convention changes from *task-slug* to *role*: the suffix says
what the agent **is**, not which ticket it holds — `lucid-debugger`, `luna-ui`,
`morpheus-architect`, `reeve-merge-warden`, `hypnos-agent-manager`,
`nyx-resource-manager`. Names now stay accurate across reuse/reassignment,
which the reuse-first workflow makes common.

- SKILL.md §Naming rules + spawn template + all inline examples updated.
- `scripts/spawn-standards.sh` teach text + comments updated (rule 1b's
  mechanical check — dream name + non-empty kebab suffix — is unchanged; roles
  are an open vocabulary).
- "Never reuse names within a session" stands; two debuggers = two dream names
  (`lucid-debugger`, `wisp-debugger`).
- **Hypnos** and **Nyx** become fixed-role names: Nyx is removed from the
  extended name pool in §Naming rules so she can't be handed to a worker agent.

### 3. Spawn mechanics — the fork rule

- Managers spawn as **typed teammates** (`dreamteam:hypnos`, `dreamteam:nyx`) —
  peer-addressable, two-way SendMessage. **Never forks**: forks inherit full
  context but teammates cannot message them back.
- **Context transfer, not inheritance:** managers boot by reading the briefing
  file (`state/briefing-<date>.md`, existing convention) + `roster.md` +
  `mempalace wake-up --wing <project>`. Forks stay legal for one-shot, no-inbox
  bursts — e.g. distilling the session into the briefing file that then warms
  the managers.
- **Promotion fallback.** Fresh typed spawn is the default (the persona arrives
  as a system prompt — promotion can't give that). When RAM is tight or an idle
  agent's warm context is valuable, an idle teammate may be *promoted* via a
  SendMessage promotion-prompt (new SKILL.md template); it keeps its birth name,
  and `roster.md`'s role column records the acting role.
- Manager fresh-spawns while idle agents exist need `FRESH-SPAWN: manager role
  requires typed persona system prompt` to pass the reuse-gate (template
  includes it). Gate code itself is untouched.

### 4. Startup sequence

New step after roster-write, before the working-agent wave: **if the planned
working-agent count ≥ `managers.minTeamSize` (default 3), spawn Hypnos and Nyx
first**, then the wave. Below the threshold, Sandman wears both hats (current
behavior). Tunable in `config.json`:

```json
"managers": { "minTeamSize": 3 }
```

- Managers get **no worktree at spawn** (Hypnos's session-end docs worktree in
  §1 is the one lazy exception) and count against the memory budget like any
  agent — a 3-worker team's true footprint is 5 agents (+~600 MB at the
  default `perAgentMB`). The skill's budget step says so explicitly.
- Requirement on the worktree-guard: manager roles may write **only** under the
  plugin `state/` dir (roster.md, lessons, briefings, HANDOFF); the guard's
  allowlist is the enforcement point.

### 5. Overnight mode changes

- **Argus and Iona rows deleted** from §Additional overnight roles; their
  duties live in Hypnos's persona (health audit, silence escalation,
  cross-teammate coordination). Names retire.
- Reeve (merge warden) and Hermes (release herald) stay overnight-only.
- §Self-sustaining triangle text updated: "Argus + Iona catch what the
  orchestrator drops" → Hypnos/Nyx.

### 6. Per-team active markers (adjacent bug fix)

Observed 2026-07-09: `state/active` is a single global file, so session B's
SessionStart sees session A's *live* team as a crash (smol's running team
false-flagged this session's startup).

- `state/active` → `state/active-<team>.json` (one per team).
- SessionStart crash check flags only markers whose team has **no live
  processes** (cross-check roster/pgrep before banner).
- SessionEnd removes its own team's marker; Nyx sweeps stale ones at runtime.
- Migration: a legacy bare `state/active` whose team is dead is removed; if
  alive, left for that session's SessionEnd (renamed form takes over from next
  team start).

### 7. Roster & docs touches

- `roster.md` gains a **role** column (assignment layer; records acting role,
  supports the promotion fallback).
- New SKILL.md section **"Manager roles (standing)"** — a small table like the
  overnight one — plus the promotion-prompt template and the fork rule.
- Dashboard/statusline: no changes; role-bearing names are self-documenting.

## Error handling

- **Manager dies:** TeammateIdle/SubagentStop injections already surface it;
  Sandman re-spawns (or promotes) a replacement. If Nyx is down during a RED
  tier, Sandman acts the ladder himself — the tier table remains in SKILL.md as
  the shared contract, not Nyx-private knowledge.
- **Unreachable agent** (no SendMessage reaction, pane gone): Hypnos marks it
  dead in roster.md and escalates to Sandman; it never guesses.
- **Kill discipline:** every Nyx kill follows polite-first (`shutdown_request`,
  ~60s grace) except RED-tier emergencies, and is logged to `state/events.log`.

## Testing

- `tests/test-gates.sh`: fixtures/assertions updated for role-style names and
  the FRESH-SPAWN manager reason; teach-text assertions follow the new wording.
- `tests/test-roster.sh`: role column tolerated/parsed; regression test for the
  per-team marker logic (live-team marker must NOT banner; dead-team marker
  must).
- New light check: `agents/hypnos.md` + `agents/nyx.md` frontmatter parses
  (name/description/color present), alongside the existing static checks.
- Static: `bash -n` all touched scripts; hooks.json still valid JSON.

## Out of scope / follow-ups

- **Fleet-level singleton managers** — JP chose per-team; `/dreamteam-fleet`
  remains the host-wide observer.
- **Guildmaster repo:** note in `guild.yaml` that per-team Hypnos is the
  dreamteam embodiment of the planned quartermaster control plane
  (guildmaster#9-11) and wields `gm peek` (#2, #22). Follow-up commit there,
  not part of this plan.
- **tokentelemetry budgets** (guildmaster#11) — future Nyx input, not now.
- Dashboard surfacing of manager presence — YAGNI until the roles prove out.

## Addendum — 2026-07-09, post-approval discoveries

1. **`scripts/poke.sh` already exists** (JP prototype, untracked at time of
   writing): immediate message delivery by typing into an agent's pane, resolved
   via its `@handle` pane footer. It names the SendMessage lag precisely
   ("queues until the target agent's next tool round"). Design updates:
   - Hypnos's re-delivery fallback **is `poke.sh`** — not a raw send-keys recipe.
   - poke reaches **forks** by name too (footer match), softening §3's fork
     limitation for short one-line nudges; the teammate rule stands for full
     two-way comms.
   - Implementation item: adopt/commit poke.sh (JP's call — his prototype).
2. **spawn-standards.sh roster list** must gain `hypnos` and `nyx` — confirmed
   live 2026-07-09: the gate correctly blocked the pilot `hypnos-agent-manager`
   spawn as a non-roster name (escape hatch `STANDARDS-EXEMPT:` used for the
   pilot).
3. **Pending input:** nebula-teamwork-research (spawned same day) will propose
   numbered spec deltas from human-team + multi-agent-AI effectiveness research;
   fold accepted deltas here before writing the implementation plan.
4. **Dedicated `manager` window (JP directive, same day):** each team's manager
   runs in its own tmux window named `manager` in the team's session — mirroring
   JP's fleet-coordinator prototype (rune:3). After spawning the manager, break
   its pane out (`tmux break-pane -d -s <pane> -n manager`) and retile `agents`.
   `pane-organizer.sh` already never reclaims a `manager`-named window (guard
   landed in 97c5612), so the convention is sweep-safe. §4's startup sequence
   gains this as a post-spawn step. Corollary from performing the move live:
   pane indexes shift as teammates join (Hypnos had drifted 2.2→2.4 within the
   hour) — resolve panes by `@handle` footer match at use time (`poke.sh
   --dry-run`); never store static pane indexes in the roster as truth.
