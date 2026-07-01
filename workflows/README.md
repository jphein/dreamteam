# dreamteam workflows

Saved [Workflow](https://docs.claude.com/) scripts for the dreamteam plugin's recurring
orchestration patterns. A **workflow** is a deterministic JavaScript script that fans out
subagents through `agent()` / `parallel()` / `pipeline()` — control flow (loops,
conditionals, ordering) lives in the script, not in a model's head. Use a workflow when a
pattern is *structured and repeatable*; use the Agent()/SendMessage dreamteam when the work
is *long-lived and course-correctable*. (See the dreamteam skill, § "Workflow vs Agent()
dreamteam".)

> **Opt-in only.** The Workflow tool needs JP's explicit opt-in each session —
> "ultracode", "use a workflow", or naming a workflow directly. Overnight/full-auto
> authorizes *design* autonomy, **not** unprompted Workflow scale.

| Workflow | Phases | What it does |
|---|---|---|
| **merge-cascade** | Merge | Serialized, dependency-ordered merge of N PRs (rebase-next-on-demand) |
| **overnight** | Scout · Fix · Review · Ship | Budget-scaled autonomous sweep: find issues → fix each in a worktree → ultrareview → serially ship |
| **review-sweep** | Discover · Review · Synthesize | Parallel review of every open PR → one cross-PR report flagging conflicts |

---

## Invoking

Two ways. **`scriptPath` always works**; the `name` form works only if your Claude Code
build registers plugin-contributed workflows into the `Workflow({name})` registry (not all
do — if `name` 404s, fall back to `scriptPath`).

```js
// By path (reliable) — `${CLAUDE_PLUGIN_ROOT}` resolves to the plugin's source dir
// (/home/jp/Projects/dreamteam, a directory-based marketplace):
Workflow({
  scriptPath: `${CLAUDE_PLUGIN_ROOT}/workflows/merge-cascade.js`,
  args: { prs: [123, 124, 125], repo: "techempower-org/candela" }
})

// By name (if plugin workflows are registered):
Workflow({ name: "merge-cascade", args: { prs: [123, 124, 125], repo: "techempower-org/candela" } })
```

> **Path note.** Prefer `${CLAUDE_PLUGIN_ROOT}` over a literal path — it survives version
> bumps and machine moves. If a literal is unavoidable, the real cache copy lives at
> `~/.claude/plugins/cache/dreamteam/dreamteam/1.0.0/workflows/`.

**`args` is passed verbatim** — pass it as a real JSON object, **never** a JSON-encoded
string (a stringified object reaches the script as one string and `args.prs`/`args.map`
throw). Watch progress live with `/workflows`.

---

## merge-cascade.js

Lands a *dependency-ordered* stack of PRs one at a time. For each PR in `args.prs` order:
sync → rebase onto the freshly-merged main if stale → wait for the required check → squash-merge
→ confirm main settled → next. Only ever **one merge in flight**. If a PR fails to merge, the
cascade **halts** (everything downstream depends on it) and returns a ready-to-rerun PR list.

**args**

| key | required | default | meaning |
|---|---|---|---|
| `prs` | ✅ | — | PR numbers **pre-sorted into merge order**, e.g. `[123, 124, 125]` |
| `repo` | ✅ | — | `"owner/name"` |
| `strategy` | | `"squash"` | `squash` \| `merge` \| `rebase` |
| `requiredCheck` | | `"Build APK"` | the **only** check that gates the merge; advisory bots (CodeRabbit/DeepSource/Gemini/Copilot) are ignored |
| `ciTimeoutMin` | | `25` | minutes to wait for the required check before giving up on a PR |
| `deleteBranch` | | `true` | pass `false` to keep merged branches |

**returns** `{ merged: [...], mergedCount, total, haltedAt, remaining: [...], results: [...], summary }`
— on a halt, `summary` includes the exact `prs: [...]` to re-run with.

**Why a serial loop, not `pipeline()`** — `pipeline()` has **no barrier between items** (PR #2
could start while #1 is still merging). A cascade is the opposite: item N must rebase onto the
*result* of item N-1, a strict serialization (a fold). The correct primitive is an `await`
loop — the same idiom the Workflow docs use for loop-until-count. This also enforces JP's
**no-eager-merge** rule structurally. (Deliberate deviation from the "use pipeline()" brief —
documented because it's the technically correct call.)

---

## overnight.js

One budget-scaled autonomous sweep. Run it **repeatedly** across the night (the launching
orchestrator owns the wall-clock cap and the memory-pressure tiers — the script can't read
the clock; `Date.now()` is unavailable in workflows).

1. **Scout** (`parallel` barrier) — one scout per lens (bugs, tech-debt, perf, tests). Each
   reads real code and **files `gh` issues** (so findings survive context loss, per the
   track-requests-as-issues rule). Results are deduped by area+title and prioritized
   (severity, then effort).
2. **Fix** (`pipeline`, `isolation: 'worktree'`) — one agent per issue, each in its **own git
   worktree** (parallel file mutation), implements the smallest correct fix and opens a PR.
   Stops & reports instead of forcing it when a fix needs design/secrets/destructive judgement.
3. **Review** (`pipeline`) — every PR gets an **ultrareview**: 3 adversarial lenses
   (correctness, regression, scope) → `approve` / `revise` / `reject` (approve only on a clean
   sweep). Runs as soon as each fix's PR exists — issue A is reviewed while issue B is still
   being fixed.
4. **Ship** (barrier → **serial** merge) — per no-eager-merge, hold every merge until the whole
   wave is reviewed, then merge the approved+green PRs one at a time in severity order.

**Fleet scales to the budget** (`budget.remaining()`): ~2–5 scouts and a 3–18 issue cap,
proportional to remaining tokens; falls back to `maxHours` when no `+Nk` target is set.

**args**

| key | required | default | meaning |
|---|---|---|---|
| `repo` | ✅ | — | `"owner/name"` |
| `maxHours` | | `6` | fleet-size fallback when there's no token budget (script can't enforce wall-clock) |
| `focus` | | — | narrow scouting, e.g. `"wear module"` or `"playback"` |
| `requiredCheck` | | `"Build APK"` | gating check for the ship phase |
| `ciTimeoutMin` | | `25` | per-PR CI wait in the ship phase |

**returns** `{ scouted, attempted, prsOpened, approved, needsWork: [...], merged: [...], notMerged: [...], budget, summary }`

> **Worktree-isolation caveat.** This uses the **Workflow tool's** documented
> `opts.isolation: 'worktree'` — a *different* mechanism from the Agent/Task-team
> `isolation: "worktree"` that `feedback_worktree_isolation_broken.md` flags as silently
> ignored for in-process team agents. The Workflow path is the supported one; still, verify
> worktrees are actually created on the first real multi-fix run.

---

## review-sweep.js

A consolidated review pass over all open PRs.

1. **Discover** — `gh pr list` (honors `label`/`author`/`state`/`limit` filters) → the PR set.
2. **Review** (`parallel` barrier) — one reviewer per PR over its `gh pr diff`: correctness,
   regressions, security/secrets, scope creep, convention fit. Structured findings + verdict.
3. **Synthesize** (barrier — needs *all* reviews) — one agent produces the cross-PR view no
   single reviewer can see: **shared-file collisions**, contradictory/duplicate/stacked PRs, a
   safe **merge order**, high-risk PRs, and the clean-approval set. The barrier is correct here
   because synthesis genuinely references every other review.

**args**

| key | required | default | meaning |
|---|---|---|---|
| `repo` | ✅ | — | `"owner/name"` |
| `state` | | `"open"` | PR state filter |
| `label` | | — | only PRs with this label |
| `author` | | — | only PRs by this author |
| `limit` | | `30` | max PRs to pull |

**returns** `{ discovered, reviewed, reviews: [...], synthesis: { overview, mergeOrder, conflicts, highRisk, readyToMerge } }`

A natural pairing: **review-sweep → merge-cascade**. Feed `synthesis.mergeOrder` (after
dropping the high-risk ones) straight into merge-cascade's `prs`.

---

## Editing & syntax-checking these scripts

Workflow scripts are **plain JavaScript, not TypeScript** — no type annotations, no
interfaces/generics. `meta` must be a **pure literal** (no variables/calls/spreads). No
`Date.now()` / `Math.random()` / argless `new Date()` (they break resume — pass timestamps via
`args`, vary by index for uniqueness).

⚠️ **`node --check file.js` is NOT a reliable gate here.** Node's CJS/ESM auto-detection sees
the top-level `export const meta` and *silently passes* broken code (TS annotations, brace
imbalance) without error. The scripts also use top-level `await` and top-level `return`, which
`--input-type=module` rejects but the Workflow runtime allows (it wraps the body in an async
function). To check them the way the runtime sees them, wrap-then-check:

```bash
# Reliable syntax check — strip `export`, wrap the body in an async fn, vm-compile:
node -e '
  const {readFileSync}=require("fs"), vm=require("vm");
  const f=process.argv[1], s=readFileSync(f,"utf8").replace(/^\s*export\s+const\s+meta/m,"const meta");
  try { new vm.Script(`(async()=>{\n${s}\n})`,{filename:f}); console.log("OK  "+f); }
  catch(e){ console.error("FAIL "+f+"\n  "+e.message); process.exit(1); }
' merge-cascade.js
```

This catches the real errors (`node --check` misses them) while allowing the runtime's
top-level `await`/`return`. Best of all: dry-run the actual logic by stubbing the hooks
(`agent`/`parallel`/`pipeline`/`phase`/`log`/`budget`) and executing the body — that's how the
`await parallel(...).filter(...)` precedence bug (member access binds tighter than `await`;
needs `(await parallel(...)).filter(...)`) was caught here. Syntax-valid ≠ logically sound.
