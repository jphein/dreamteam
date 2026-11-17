# Dream Team Enhancements Spec

- **Status:** Draft
- **Date:** 2026-06-29
- **Author:** Nebula (dream agent, team palace-recovery-dreamteam)
- **Target:** `~/.claude/skills/dreamteam/SKILL.md`
- **Related:**
  - `~/.claude/skills/dreamteam/SKILL.md` — the skill these enhancements modify
  - [`palace-context-recovery.md`](../../../../Projects/memorypalace/docs/specs/palace-context-recovery.md) — the spec-structure template (Enhancement 1)
  - `~/.claude/skills/agent-orchestration.md` — voice/speech/comms patterns the skill cross-references
  - `~/.claude/skills/palace-search.md` — palace search pipeline backing Enhancement 2
  - palace-daemon `POST /silent-save` — the diary-write endpoint (Enhancement 2.3)

## Problem

The dreamteam skill spawns named agents that work in parallel worktrees, coordinated by SendMessage. That core works. But three gaps limit how well it scales to non-trivial, architectural work:

1. **No shared design contract.** Agents work from issue descriptions or inline prompts. When work is multi-file or multi-agent with shared surfaces, each agent invents its own interpretation. There is no single artifact that says "here is the whole design, here is your slice, here is how your slice meets the next agent's slice." Integration drift and rework follow.

2. **Zero palace awareness.** Dream agents and the orchestrator have no connection to MemPalace's 410K+ drawers of verbatim history. The orchestrator scopes work without prior-decision context; agents hit unfamiliar code and guess instead of recalling "why was this done this way?"; and when a team's roster file *and* tmux reconstruction both fail, there is no third recovery tier.

3. **One orchestration primitive for every phase.** Everything runs through `Agent()` — discovery, implementation, verification, review. `Agent()` is ideal for interactive, named, course-correctable implementation, but a poor fit for systematic deterministic phases (fan-out discovery, compile/test-every-worktree verification, adversarial multi-lens review) where structured output and reproducible control flow matter more than voice and persistence. The orchestrator also reasons at the same depth for every decision — whether writing a roster row or designing a merge order across hot files.

## Solution Overview

Three enhancements, each independently valuable, that compound into one flow: **deep reasoning → design → implementation → context → verification.**

| # | Enhancement | Skill change | Effect |
|---|-------------|--------------|--------|
| 1 | Spec-Driven Development | New `## Spec-Driven Development` section + `1.5 Spec gate` startup step + spawn-template spec block | Non-trivial work gets a `docs/specs/<feature>.md` contract; agents read their assigned section first |
| 2 | MemPalace Integration | New `## MemPalace Integration` section + `0.3 Palace recall` startup step + agent prompt nudge + post-completion `/silent-save` + roster recovery tier 3 | Orchestrator scopes with history; agents recall on demand; team work is queryable; roster recoverable from palace |
| 3 | Ultrathink & Ultracode | New `## Ultrathink & Ultracode Integration` section + `0.6 Discovery` / verification Workflow steps | Deep reasoning for decision phases; Workflow for deterministic fan-out/verify/review; Agent() for interactive implementation |

The compounding flow across the startup sequence:

```
ultrathink (reason) → palace recall (context) → discovery Workflow (map)
  → spec (design, ultrathink) → dreamteam Agent() (implement)
  → verification Workflow (prove) → review Workflow (challenge)
  → ship (orchestrator, sequential) → palace save (capture)
```

These changes are **additive and read-only** with respect to the existing worktree / anti-collision model. Nothing about manual worktree creation, the tmux pre-flight, or the STOP-and-escalate rules changes.

## 1. Spec-Driven Development

### Decision point

Insert a **spec gate** in the startup sequence between Scope and TeamCreate. The orchestrator evaluates complexity and branches: write a spec, or proceed directly.

**Write a spec when ANY of these hold:**

- Work spans multiple files OR multiple agents touch a shared surface (schema, API, config, shared module).
- Architectural change: new module, migration, new API surface, cross-cutting refactor.
- One agent's output is another agent's input (a contract exists between slices).
- 3+ agents on one coherent feature (vs. N fully independent one-file fixes).

**Skip the spec when:**

- Single-file or trivial change.
- Mechanical bulk edit.
- Issues are fully independent with no shared surface (each agent self-contained) — a one-line-per-issue scope note in the roster suffices.

The gate is a **branch, not a mandate**. Trivial work skips it; the cost of a spec is only paid where coordination risk is real.

### Where specs live

`docs/specs/<feature-name>.md` in the **target project repo** (not the skill dir). This is already the established pattern — canonical example: `~/Projects/memorypalace/docs/specs/palace-context-recovery.md`.

### Spec structure (template)

Mirror the palace-context-recovery spec:

```markdown
# <Feature> Spec

- **Status:** Draft
- **Date:** <YYYY-MM-DD>
- **Related:** <linked specs, files, PRs>

## Problem
<numbered, concrete failures or goals>

## Solution Overview
| # | Change | File | Owner | Effect |   ← Owner column = dream agent name

## 1. <Change>   ...   ## N. <Change>
### Location — exact file path(s)
### Design — prose + code blocks
### Testing — real commands the agent can run

## Rollout
<numbered, ordered steps; include merge order if sections depend on each other>

## Non-goals
<bulleted, bold lead-in — what we explicitly are NOT doing>
```

The **Owner column** is the dreamteam-specific addition: it maps each numbered section to a dream agent, so the Solution Overview table doubles as the agent-assignment plan.

### How agents consume the spec

Each agent prompt embeds:

- The spec's **absolute path** in the main checkout (e.g. `/home/jp/Projects/memorypalace/docs/specs/foo.md`).
- The agent's **section number** ("you own § 2").

The agent's **first action after `cd`-ing to its worktree** (before any edit) is to read its section of the spec.

**Why absolute path, not the worktree copy:** worktrees are created off `origin/main`. A freshly written spec is uncommitted (or committed only locally), so it will not exist inside a worktree branched off `origin/main`. Reading the spec via its absolute path in the main checkout sidesteps any commit-ordering dependency — the file is on disk and readable from anywhere. (If you want the spec versioned into each worktree too, commit it to `main` with a `docs:` commit and branch the worktrees off local `main`; the absolute-path read is the zero-dependency default and is what the spawn template uses.)

**Spec is the contract:** if an agent finds reality contradicts the spec, it STOPs and SendMessages Sandman rather than silently diverging — the same escalation philosophy as the unexpected-branch-state rule.

## 2. MemPalace Integration

> Backing facts (verified 2026-06-29 against the live CLI + daemon OpenAPI):
> the search verb is `mempalace search <query> [--wing W] [--limit N] [--format {table,compact,full,json}] [--mode {auto,fast,hybrid}]`;
> `mempalace wake-up --wing W` returns ~600-900 tokens of L0+L1 context;
> `mempalace tunnels --wing W` returns cross-wing connections.
> **There is no `mempalace diary` subcommand** — the diary write is the daemon endpoint `POST /silent-save`.

### 2.1 Orchestrator palace recall (startup step 0.3, before Scope)

Before scoping, Sandman queries the palace for prior context so scoping *and* the spec are informed by history:

```bash
mempalace search "<project> <issue keywords>" --limit 5 --format compact
mempalace wake-up --wing <project>          # ~600-900 tokens of L0+L1 context
mempalace tunnels --wing <project>          # cross-wing connections, if relevant
```

Findings feed the spec's Problem / Related sections ("we already decided X in a prior session — don't re-litigate it").

**Slumber-Ward note:** familiar is sleepable; the CLI's `auto_wake` wakes it and retries (~20s). A slow first search is the host waking, not a failure — don't abort the run over it.

### 2.2 Agent palace queries (prompt nudge)

Each agent prompt includes a palace nudge — when the agent hits unfamiliar code, a prior decision, or a "why was this done this way?" question, it searches before guessing:

```bash
mempalace search "<specific question>" --wing <project-wing> --limit 3
```

Read-only, doesn't touch the worktree, safe to run any time. The nudge belongs in the prompt template so every agent inherits it.

### 2.3 Post-completion palace save (after PRs created)

The stop hook already auto-saves transcripts. The orchestrator additionally writes one **structured, queryable index-card** diary entry summarizing the team's work — this is what makes roster recovery (2.4) possible and what a future session finds when searching the team name.

**Mechanism — there is no `mempalace diary` CLI subcommand.** The diary write goes through the palace-daemon `POST /silent-save` endpoint (fields: `entry` required, plus optional `wing`, `topic`, `agent_name`):

```bash
source ~/.config/palace-daemon/env   # exports PALACE_API_KEY, PALACE_DAEMON_URL
SUMMARY="palace-recovery-dreamteam shipped: Vesper #214 search-only MCP mode (PR #N), \
Morpheus #215 PostCompact+SessionStart handlers (PR #M), Wisp #216 hooks.json wiring (PR #K). \
Spec: docs/specs/palace-context-recovery.md. Key decision: search-only over full-MCP (300 vs 9k tokens)."
curl -s -X POST "$PALACE_DAEMON_URL/silent-save" \
  -H "X-API-Key: $PALACE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 - "$SUMMARY" "memorypalace" <<'PY'
import json, sys
print(json.dumps({
    "entry": sys.argv[1],
    "wing": sys.argv[2],
    "agent_name": "Sandman",
    "topic": "dreamteam",
}))
PY
)"
```

The `entry` should record: **team name, each agent + assignment, issues/PRs shipped, spec path, key decisions.** Short and structured — it is an index card, not a transcript.

### 2.4 Roster recovery from palace (recovery tier 3)

Extend the existing recovery chain in Step 6.5:

1. Read `scratch/<team>/roster.md` (primary).
2. Reconstruct from tmux pane processes (fallback).
3. **NEW:** `mempalace search "<team-name>" --limit 5` — returns the 2.3 diary entry + stop-hook checkpoints describing team creation (agent names, assignments, worktree paths).

2.3's save is what makes tier 3 work — without the explicit index-card entry, the team name may appear only inside long transcript drawers that rank poorly.

## 3. Ultrathink & Ultracode Integration

### 3.1 Ultrathink — deep reasoning for decision phases

Engage ultrathink (deep extended reasoning) for the orchestrator's **decision-heavy** phases; use normal reasoning for mechanical phases. Depth costs latency and tokens — spend it where a wrong call cascades across the whole team, not on bookkeeping.

| Engage ultrathink | Normal reasoning |
|---|---|
| Spec writing (always — deep analysis of the problem space before assignment) | Worktree creation |
| Scoping work touching >5 files or >2 subsystems | Roster writing / updates |
| Designing agent assignments with dependency chains | Polling, relaying SendMessages |
| Architectural decisions: merge order, hot-file conflict resolution, collision salvage | Cleanup |

### 3.2 Ultracode (Workflow) vs Agent() dreamteam — complementary, not competing

| | Agent() dreamteam | Workflow (ultracode) |
|---|---|---|
| Shape | Named, interactive, persistent in tmux, voice, SendMessage | Deterministic control flow, pipeline/parallel, structured schemas, resume |
| Best for | Implementation — long-lived, conversational, course-correctable | Systematic phases — fan-out discovery, compile/test verify, adversarial review |
| JP visibility | Live tmux panes, voice by name | Progress tree via `/workflows` |
| State | Persists across turns; reattachable | One run; resumable by `runId` |

**Opt-in gate:** Workflow requires JP's explicit opt-in ("ultracode", or an explicit "use a workflow" ask). Don't fire one unprompted. If not opted in, the orchestrator does discovery/verification inline or via `Agent()` spawns. (Overnight/full-auto authorizes *design* autonomy, not the token scale of unprompted Workflow fan-outs.)

### 3.3 The hybrid pattern

| Phase | Tool | Why |
|-------|------|-----|
| Discovery | Workflow | Structured fan-out to map work items, deps, hot files |
| Spec writing | Orchestrator + ultrathink | Deep reasoning for design decisions |
| Implementation | Agent() dreamteam | Named agents, interactive, tmux panes |
| Verification | Workflow | Deterministic compile/test across all worktrees |
| Review | Workflow | Adversarial multi-lens review with structured verdicts |
| Ship | Orchestrator | Sequential merge with dependency ordering |

Discovery feeds the spec; the spec feeds the dreamteam; palace recall feeds both; verification/review Workflows replace the trust-the-summary step in *After Agents Finish*; the orchestrator ships sequentially and saves to the palace.

### 3.4 Example Workflow scripts

**Discovery — map work items, dependencies, and hot files before spec-writing:**

```javascript
export const meta = {
  name: 'dreamteam-discovery',
  description: 'Map work items, dependencies, and hot files before spec-writing',
  phases: [{ title: 'Scan' }, { title: 'Synthesize' }],
}

const ISSUES = args.issues   // e.g. ["#262","#261","#266"] passed via Workflow args

const WORK_ITEM = {
  type: "object",
  properties: {
    issue: { type: "string" },
    files: { type: "array", items: { type: "string" } },
    subsystems: { type: "array", items: { type: "string" } },
    risk: { type: "string", enum: ["low", "medium", "high"] },
    depends_on: { type: "array", items: { type: "string" } },
    summary: { type: "string" },
  },
  required: ["issue", "files", "risk", "summary"],
}

phase('Scan')
const scans = await parallel(ISSUES.map(issue => () =>
  agent(`Read issue ${issue} (gh issue view ${issue}) and the code it touches.
Identify which files change, which subsystems, risk level, and any issues it depends on.
Return a work-item record.`, { label: `scan:${issue}`, schema: WORK_ITEM })
))

phase('Synthesize')
const map = await agent(`Here are the work items:
${JSON.stringify(scans.filter(Boolean), null, 2)}
Identify HOT FILES (touched by 2+ items — these need serialization or careful merge order)
and a dependency-ordered build sequence.`, {
  schema: {
    type: "object",
    properties: {
      hot_files: { type: "array", items: {
        type: "object",
        properties: { file: { type: "string" }, touched_by: { type: "array", items: { type: "string" } } },
      } },
      build_order: { type: "array", items: { type: "string" } },
      notes: { type: "string" },
    },
    required: ["hot_files", "build_order"],
  },
})

return { work_items: scans.filter(Boolean), ...map }
```

**Verification — compile + test every agent worktree, return per-worktree verdicts:**

```javascript
export const meta = {
  name: 'dreamteam-verify',
  description: 'Compile + test every agent worktree, return per-worktree verdicts',
  phases: [{ title: 'Verify' }],
}

const WORKTREES = args.worktrees   // [{agent, path, branch, test_cmd}, ...]

const VERDICT = {
  type: "object",
  properties: {
    agent: { type: "string" },
    branch: { type: "string" },
    clean_tree: { type: "boolean" },
    compiles: { type: "boolean" },
    tests_pass: { type: "boolean" },
    failures: { type: "array", items: { type: "string" } },
    verdict: { type: "string", enum: ["green", "red"] },
  },
  required: ["agent", "verdict"],
}

phase('Verify')
const verdicts = await parallel(WORKTREES.map(wt => () =>
  agent(`cd ${wt.path}
Run: git status --porcelain (must be empty), then: ${wt.test_cmd}
Report whether the tree is clean, it compiles, and tests pass. List any failures verbatim.
This is READ-ONLY verification — do NOT edit or fix anything.`,
    { label: `verify:${wt.agent}`, schema: VERDICT })
))

const red = verdicts.filter(Boolean).filter(v => v.verdict === 'red')
log(`${verdicts.length} worktrees: ${verdicts.length - red.length} green, ${red.length} red`)
return { verdicts: verdicts.filter(Boolean), red }
```

Notes on the scripts:

- Plain JS — no TypeScript annotations, no `Date.now()` / `Math.random()` (both throw in Workflow scripts).
- `meta` is a pure literal (required).
- Verification agents are told explicitly **not to edit** — the default workflow subagent has all tools, so the read-only constraint must be in the prompt.
- Each verify agent `cd`s to its own worktree path; CWD does not persist between agents, so the `cd` is the first line every time.

## Testing / Validation

This is a skill-doc change, not code. "Testing" = verifying the documented commands are real and the skill stays internally consistent:

```bash
# Enhancement 2 commands are real:
mempalace search "test" --limit 3 --format compact            # exits 0, returns hits
mempalace wake-up --wing memorypalace                          # exits 0
curl -s http://familiar:8085/openapi.json | grep -o '/silent-save'   # endpoint exists

# Enhancement 1: the template spec exists and is the structure we mirror:
test -f ~/Projects/memorypalace/docs/specs/palace-context-recovery.md

# Enhancement 3: Workflow example scripts parse as JS (manual review):
#   - meta is a pure literal, no Date.now/Math.random, no TS syntax

# Skill internal consistency: every section reference resolves to a real heading:
grep -nE '## (Spec-Driven Development|MemPalace Integration|Ultrathink & Ultracode)' \
  ~/.claude/skills/dreamteam/SKILL.md
```

## Rollout

1. Write this spec (done).
2. Edit `SKILL.md`: insert decimal startup steps `0.3 Palace recall`, `0.6 Discovery`, `1.5 Spec gate`; weave spec/palace refs into the spawn template; extend roster recovery with tier 3.
3. Append three new sections after the Startup Sequence: `## Spec-Driven Development`, `## MemPalace Integration`, `## Ultrathink & Ultracode Integration`.
4. Add the post-completion `/silent-save` step to `## After Agents Finish`.
5. Verify with the Testing commands above.

## Non-goals

- **Forcing specs for trivial work.** The spec gate is a branch, not a mandate — one-file fixes skip it.
- **Restoring MCP diary tools.** The `/silent-save` HTTP path is deliberate; MCP tools stay retired (`mcp_mode: cli-only`).
- **Replacing Agent() with Workflow.** They are complementary; implementation stays on named interactive agents. Workflow is opt-in and scoped to systematic phases.
- **Auto-engaging ultrathink.** It is a deliberate per-phase orchestrator choice, not a global default — mechanical phases stay cheap.
- **Changing the worktree / anti-collision model.** All existing mandatory worktree rules are unchanged; specs and palace queries are read-only additions.
