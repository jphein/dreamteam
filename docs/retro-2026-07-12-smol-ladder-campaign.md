# Retro — 2026-07-12 smol overnight ladder campaign (manager-side)

**Status:** written at session-end by the agent manager (Hypnos role) of dreamteam
session `session-596d190f`. A success retro, not an incident postmortem — it distills
the *reusable orchestration patterns* that carried the run, as candidates to fold into
the dreamteam skill. Companion to the running log `state/lessons-2026-07-11.md`
(untracked runtime notes; this doc is the committed, generalized synthesis).

## Context

Overnight "finish all issues" campaign on project **smol** (public ESP32-C3 Rust fw +
HA integration). One orchestrator (Sandman/team-lead), one standing agent-manager
(Hypnos), one read-only verifier (oracle), ~10 worker agents. Result: **~21 PRs merged,
zero regressions merged**, through a mid-run quota outage and an API-blip wave, with as
many as 4 feature branches live on one hot file (`net/mode.rs`). Every remaining open
issue was honestly boundary-parked (hardware / spike / epic / JP-editorial).

The manager holds no kill authority and ships no feature code; its leverage is the
**build gate**, the **merge sequencing**, and **delivery verification**. These patterns
are what turned that leverage into a zero-regression night.

## Reusable patterns

### 1. Merge-ladder: rebase-then-gate, serial
When N PRs touch the same hot files, merge them as a **ladder**: each rung rebases onto
the *prior rung's merge* before its gate, so every conflict is resolved against real
merged code — never a stale base, never an N-way pileup at the end. The data dependency
(rung N rebases onto rung N-1's merge) also *forces* seriality, so there's no build
contention to guard against separately. Order the ladder to land the **invariant-clearing
rung first** (here: a lint/0-warning-restore PR), so downstream builds inherit a clean base.

### 2. Build-gate: strict-serial is an OOM guard, not a style choice
Parallel release builds ballooned a cgroup's page cache into a whole-scope OOM kill in a
prior session (`docs/postmortem-2026-06-30.md`). So: **only one `cargo` build fleet-wide
at a time.** Agents *code* in parallel (separate worktrees — git-isolated, always
FS-safe) but must **request a build window**; the manager grants one, pgrep-verifies the
slot is clear first, and runs a scoped guard that emits `BUILD-DONE`. Coding-parallel +
build-serial + merge-serial is the shape.

### 3. Two-merge-lane parallelism
Work that shares neither the build slot nor files runs as an **independent lane**. Here
the HA lane (yaml/python, no compile) gated + merged *concurrently* with the fw-serial
build ladder — don't queue no-build PRs behind the OOM-serial gate.

### 4. Rebase traps on shared files (flag the shared-namespace up front)
git's line-based 3-way merge is dangerous on **shared tables/namespaces**:
- **Shared-const auto-merge miscount:** two features each grew `CFG_APPLY_KEYS` and
  appended a key → auto-merge kept *both* elements (7 in the body) but resolved the
  length annotation `[u8; N]` to one side's `6`. Silent off-by-one. → Name the shared
  const as a conflict surface in the rebase cue; have the builder count elements vs len.
- **pid / key / bit collisions:** two features independently claimed subscribe pid-14,
  or a plugin-mask bit, or a CFG key. → Reassign one + assert "pids/keys/bits used exactly
  once." Flag the shared namespace *before* the rebase, not after.

### 5. Independent adversarial gate — match depth to failure mode
Every rung passed a **read-only verifier (oracle)** that re-ran the actual gate invariant
rather than trusting the builder's report. The gate's *depth* must match the *failure
mode*, not the diff size:
- lint/logic PR → compile + clippy;
- **IRAM/perf-placement PR → LINK** (region overflow is link-time; clippy/check miss it —
  run full builds);
- **flagship distributed-consensus PR → correctness review** (exactly-one-holder /
  split-brain / migration-atomicity / orphan-election-convergence) — invisible to compile,
  so weight the review there.
Adversarial verifiers add the most value attacking the *why* (e.g. a caller-audit proving
"no non-espnow caller can exist" beats a wifi-profile clippy that only shows "compiles today").

### 6. Contract-first across a boundary (fw ↔ HA)
When firmware emits a wire format a separate HA parser consumes, **pin the contract before
coding** — keys, units, field order. A worker here *held* its code+build until the HA
owner pinned the deployed parser's contract, internalizing an earlier guess→full-rework
lesson. Even "obvious" fields carry units (rtt ms vs µs; rx/tx cumulative-counts vs
per-second rates) that silently break the consumer. Verify emitted keys/units against the
*deployed* parser at the gate.

### 7. Capacity-split at a verified boundary
When an agent is deep in context and the next chunk is large/invasive, **bank the verified
increment and hand the remainder to fresh context** — don't gamble the whole feature on a
tiring agent. Ship stage-1 as a partial PR, keep the parent issue open, write a handoff
doc. Splitting at a *verified* boundary is strictly safer than pushing through.

### 8. Boundary-park (honest deferral)
A feature that can't be *validated* tonight (needs hardware, a walk-test, a purchase) is
not worth a build slot — it buys an inert, unverifiable artifact while blocking
validatable work. Instead: post a **precise, ready-to-build spec + a `*-gated` label,
keep the issue OPEN.** Converts "vague-blocked" into a clean short pickup when the gate
opens. `log()` what was deferred so the board stays honest.

### 9. Spike-before-build on unproven external APIs
A read-only feasibility dig caught that a crate's *safe* API was enum-mis-mapped (a
contiguous Rust enum vs a holey C enum → the obvious call silently set the wrong value).
Building on it would have burned a headless hardware-debug cycle. A cheap source dig
before committing a build slot is insurance on any unproven dependency.

### 10. Base-ref discipline
Always **`git fetch && git rebase origin/main`** — the remote-tracking ref — never the
local `main` branch, which lags after GitHub merges. Reading `git log main` reports the
stale local ref; report bases from `git rev-parse origin/main` after a fetch. A builder
caught the manager briefing a stale base; the no-op rebase proved the branch was already
on the true tip.

### 11. Delivery verification (the manager's core duty)
SendMessage *queues* until the target's next tool round — an idle agent may never process
it. So: relay ends with `reply ACK <task>`, escalate on a **missing ACK** (not on pane
reaction), and re-deliver via `poke.sh` (types into the pane with a settle). Resolve panes
by **`@handle` footer at use time** — indices drift as members join (they re-shuffled when
a new agent spawned mid-run). A one-shot background probe (`sleep N; check active/building`)
is a clean way to implement missing-ACK escalation without busy-polling.

### 12. Tooling footguns (each cost a wasted cycle before the fix)
- **`pgrep -f 'cargo build'` self-matches** the very shell running it (its argv contains
  the string) → phantom "BUSY". Detect real builds by binary name: **`pgrep -x rustc` /
  `pgrep -x cargo`**.
- **`pkill -f 'guard.sh X'` SIGTERMs the pkill's own shell** too → use the bracket trick
  `'[g]uard.sh X'` so the pattern can't match itself.
- **Empty-diff false-clean:** a hygiene grep over a stale/empty diff finds nothing → false
  "CLEAN". Scan via **`gh pr diff <n>`** (authoritative, server-side); never sign off on an
  empty diff — empty = "scanned nothing," not "clean."
- **SendMessage `summary` hard-caps at 200 chars** — keep it ≤~150, put detail in the body.

### 13. Morning canary — verification-phase patterns

The overnight campaign *merged* features; the morning consolidated canary *validated* them
on hardware (JP re-plugged boards, the orchestrator drove all flashing/OTA/MQTT, the manager
kept watchers engaged and routed each observation → verifier → orchestrator). The validation
phase has its own reusable patterns, distinct from the merge patterns above:

- **Pre-register a falsification rubric per claim, before observations arrive.** A verifier
  structurally blind to the hardware (read-only, no MQTT/flash) turned the canary from
  "watch and hope" into "match against these" by writing a per-PR *contradiction-signature*
  (the exact RED conditions) up front. When it later ruled a degraded observation GREEN, it
  *named the falsifier* (an all-boards-current re-check) rather than hand-waving — so
  "expected-degraded" couldn't decay into a lazy dismissal of a real bug.
- **Score a falsifier by the DIRECT quantity, not a derived summary.** An online-flap alarm:
  a flap-*count* script read "persists → widen the timeout," but the real test was
  publish-cadence-vs-timeout. The direct cadence (max 35 s « the 90 s threshold = 2.6×
  margin, confirmed across two independent windows) was dispositive *and*
  threshold-independent; the "flaps" were one correlated gateway-restart blip miscounted as
  many. Derived metrics over-count correlated events and false-RED on legit transients —
  trust the ground-truth measurement, distrust the lossy rollup.
- **Build the observability surface early; it becomes the canary's own instrument.** Reboot
  counters, OTA slot/confirmed flags, and on-wire channel fields (shipped as a diagnostics
  record earlier in the campaign) let each feature *prove itself*: "boot 2→3 = exactly one
  reset," "slot=1 / ota=confirmed = a real OTA," "channel field=1 = the mesh config on the
  wire." The instrument you ship is the instrument you verify with.
- **Ground-truth beats retained MQTT, live.** Boards read a stale build number on the broker
  (a retained ghost from a prior gateway's ungated cache) while actually running the new
  image (confirmed at the serial slot). A flip to a *new* value is trustworthy; persistence
  proves nothing — read the board/serial, not the retained topic.
- **Hardware surfaces operational truths code review can't.** Transient command topics
  (reset/scan) needed MQTT **QoS 1** — the gateway's burst-only session silently drops
  unqueued QoS 0 (~5% reliable). Invisible in review; only ~15 QoS-0 attempts all missing on
  real hardware exposed it.
- **Manager guardrail during a canary: watchers are strictly READ-ONLY.** The orchestrator
  owns all flashing + MQTT; watchers only observe and route. When a watcher deployed a fix
  (reversible, config-side, post-settle), the right move was to surface its *provenance* to
  the canary-owner for a keep-vs-rollback call — neither let it ride silently nor kill it
  reflexively.
- **Human eyes are a legitimate gate for what no probe can prove.** The flagship
  showpiece — a stateful entity migrating from an unplugged board to its neighbor — was
  validated by JP watching the screen ("same creature, surviving board"), against a
  pre-agreed discriminator (survivor claims the *same* identity within N seconds; the
  re-joining board adopts rather than spawning a duplicate). Not everything reduces to a
  metric; pre-register what the human should see.

## Guildmaster notes for JP (skill-fold candidates)

These are worth promoting from this retro into the dreamteam skill itself:
- The **build-gate protocol** (§2) and **merge-ladder** (§1) deserve a first-class section —
  they're the manager's highest-leverage tools and were reinvented ad-hoc this run.
- The **tooling footguns** (§12) are cheap to encode as a one-liner each (or a small
  `roster`/`poke` wrapper that uses `pgrep -x` + the bracket trick + validates summary len).
- **Gate-depth-matches-failure-mode** (§5) is the single most reusable review principle —
  a checklist keyed by change class (logic / link / consensus / contract) would help any
  verifier.
- The **canary verification patterns** (§13) — pre-registered falsifier rubrics,
  score-by-direct-quantity, and observability-as-its-own-instrument — deserve a
  "validation" companion to the build-gate/merge-ladder sections: the manager's playbook
  should cover proving the merges as first-class alongside making them.

*No code or process was changed by this doc — it's a synthesis for review.*
