<!-- contract-version: 1.0.0 -->
# dreamteam team-state JSON contract

**Contract version:** 1.0.0 &nbsp;·&nbsp; **Frozen:** 2026-07-09 &nbsp;·&nbsp; **Locked by:** [`tests/test-json-contract.sh`](../tests/test-json-contract.sh)

`scripts/roster.sh --json` and `scripts/idle-agents.sh --json` are the **public
team-state oracle** for dreamteam. External consumers — guildmaster, dashboards,
reuse routing — shell out to them and parse the result. This document **freezes**
that JSON as a versioned contract: the field names, types, enums, empty-payload
shapes, and exit-code behaviour below are a stability promise, not an
implementation detail free to drift on refactor.

Internal consumers today: `scripts/reuse-gate.sh`, `scripts/team-events.sh`,
`scripts/dashboard-data.sh`. External consumers are next — hence the freeze.

---

## Stability & versioning

The shape is versioned with **semver** (see the marker at the top of this file):

| Bump      | Triggered by                                                                                                  |
|-----------|---------------------------------------------------------------------------------------------------------------|
| **MAJOR** | Any breaking change: rename/remove a key, change a field's type, redefine an enum value, flip the sort direction, or introduce a non-zero exit code. |
| **MINOR** | Backward-compatible additions: a new key, or a new enum value that old consumers can treat as "unknown".       |
| **PATCH** | Doc-only clarifications with no change to the emitted bytes.                                                    |

**Consumer rules of engagement**

1. **Parse the payload as JSON.** Whitespace, indentation, and key *order* are
   **not** part of the contract. (`roster.sh` pretty-prints with 2-space indent;
   `idle-agents.sh` prints compact — do not depend on either.)
2. **Ignore unknown keys.** A MINOR bump may add fields; forward-compatible
   consumers must not choke on them.
3. **Branch on payload contents, never on exit status** — see *Exit codes*.
4. **Pin to the major version.** A MAJOR bump means the shape changed on purpose.

Any change to the emitted shape fails `tests/test-json-contract.sh` until this
doc **and** the `contract-version` marker are updated in the same commit. The
wire, the doc, and the test move together — by construction.

---

## Exit codes

Both scripts **always exit `0`** — including when there is no team at all:

- `roster.sh --json` with no team → `{"team": null, "counts": {…all 0…}, "agents": []}`, exit `0`.
- `idle-agents.sh --json` with no reusable agent → `[]`, exit `0`.

> **⚠️ Consumers MUST key off payload contents** (empty `agents` / empty array),
> **not** exit status. "No team" and "team present but everyone busy" are both
> exit `0`. Introducing a distinct exit code to disambiguate would be a **MAJOR**
> version bump.

---

## Team selection & wrong-team detection

Both scripts accept `--team <name>` and read team configs from
`$DREAMTEAM_TEAMS_DIR` (default `~/.claude/teams`):

| Invocation      | Resolves to                                                                                                          |
|-----------------|----------------------------------------------------------------------------------------------------------------------|
| `--team <name>` | **Exactly** that team. No such config → **empty payload, never a fallback** (roster `{ "team": null, …, "agents": [] }`; idle `[]`). |
| *(no `--team`)* | The **most-recently-modified** team config under `$DREAMTEAM_TEAMS_DIR`. Convenience for interactive use only.        |

> **⚠️ Programmatic consumers must pass `--team <name>`.** The bare call resolves
> to whichever team's config was touched last — which may **silently be a
> different team** than you meant (e.g. another project spun up a team after
> yours). Explicit `--team` is safe: a wrong or missing name returns an *empty*
> payload, never another team's data.

**Detecting a wrong-team answer**

- **`roster.sh`** echoes the resolved team in its top-level **`team`** field. A
  consumer that requested `--team X` should assert `payload.team == "X"`, and
  treat `payload.team == null` as "no such team". This is the intended guard.
- **`idle-agents.sh`** is a **bare array with no team identifier** — it cannot
  self-report which team answered. Pass `--team`, and if you need positive
  confirmation of the current team, cross-check `roster.sh`'s `team` field. An
  empty `[]` is ambiguous: either "no such team" **or** "team present, no
  reusable idle agent".

---

## `roster.sh --json`

The complete, authoritative roster of a harness team with live status.

```
roster.sh [--team NAME] [--json]     # default: newest team, human text
```

**Top-level object**

| Field    | Type              | Notes                                                                                 |
|----------|-------------------|---------------------------------------------------------------------------------------|
| `team`   | `string \| null`  | Team name (basename of the resolved config dir); **echoes which team answered** — see *Team selection & wrong-team detection*. `null` when no team resolved. |
| `counts` | `object`          | Always present; always carries **all four** integer keys below. `Σ == agents.length`. |
| `agents` | `array`           | Possibly empty. One object per team member (see below).                               |

**`counts` object** — every key always present, integer ≥ 0:

| Field    | Type      |
|----------|-----------|
| `lead`   | `integer` |
| `active` | `integer` |
| `idle`   | `integer` |
| `dead`   | `integer` |

**`agents[]` element**

| Field       | Type                | Notes                                                                                     |
|-------------|---------------------|-------------------------------------------------------------------------------------------|
| `name`      | `string`            | Member name. **Never null** — falls back to `agentId`, then `"?"`, if unnamed.            |
| `status`    | `string` (enum)     | One of `lead` · `active` · `idle` · `dead`. See semantics below.                           |
| `agentId`   | `string \| null`    | Harness agent id. `null` when the member carries none (e.g. some leads).                  |
| `cwd`       | `string \| null`    | Member working directory. `null` when unset.                                              |
| `agentType` | `string \| null`    | e.g. `team-lead`, `nebula`, `morpheus`. `null` when unset.                                |
| `pid`       | `integer \| null`   | OS pid of the live process. **`null` for `lead` and `dead`; `integer` for `active`/`idle`.** |

**`status` semantics**

- **`lead`** — `agentType == "team-lead"`. Classified by type; liveness is *not*
  consulted, so `pid` is always `null`.
- **`active`** — `isActive: true` **and** a live process matches its `agentId`.
- **`idle`** — alive **and** `isActive: false`. **Reusable** — assign it via
  SendMessage instead of spawning a fresh process.
- **`dead`** — no live process matches its `agentId`. Not reusable.

**Example — populated**

```json
{
  "team": "nightly-sweep",
  "counts": { "lead": 1, "active": 2, "idle": 1, "dead": 0 },
  "agents": [
    { "name": "nightly-sweep-lead", "status": "lead",   "agentId": null,               "cwd": "/home/jp/Projects/dreamteam",              "agentType": "team-lead", "pid": null   },
    { "name": "morpheus-refactor",  "status": "active", "agentId": "a3f1@session-8c2d", "cwd": "…/worktrees/morpheus-12-refactor",         "agentType": "morpheus",  "pid": 481923 },
    { "name": "nebula-audit",       "status": "active", "agentId": "b7e2@session-8c2d", "cwd": "…/worktrees/nebula-14-audit",              "agentType": "nebula",    "pid": 481944 },
    { "name": "luna-ui",            "status": "idle",   "agentId": "c9d3@session-8c2d", "cwd": "…/worktrees/luna-9-ui",                    "agentType": "luna",      "pid": 482010 }
  ]
}
```

**Example — no team** (exit `0`)

```json
{ "team": null, "counts": { "lead": 0, "active": 0, "idle": 0, "dead": 0 }, "agents": [] }
```

---

## `idle-agents.sh --json`

Reusable idle agents, ranked by context affinity to an optional task.

```
idle-agents.sh [--team NAME] [--task "text"] [--json]
```

**Top-level: a JSON `array`** (not an object), possibly empty `[]`. It contains
**only idle + alive** members — team-lead, `active`, and `dead` members are
excluded — **sorted by descending `score`**. The array carries **no team
identifier** — see *Team selection & wrong-team detection* before consuming it
programmatically.

**Element**

| Field      | Type              | Notes                                                                                                   |
|------------|-------------------|---------------------------------------------------------------------------------------------------------|
| `name`     | `string \| null`  | Member name. May be `null` if the member is unnamed. *(Note: unlike `roster.sh`, there is no fallback.)* |
| `agentId`  | `string`          | Harness agent id. **Always a non-empty string** — members without one are filtered out.                 |
| `cwd`      | `string`          | Member working directory. **Empty string `""`** when unset. *(Note: `""`, not `null` — differs from `roster.sh`.)* |
| `score`    | `integer`         | Context-affinity score for the `--task` (`0` when no task or no affinity). Higher = warmer context.     |
| `why`      | `string`          | Human-readable affinity breakdown (e.g. `"same cwd; kw:compose,navigation"`). Empty string when `score` is `0`. |
| `context`  | `string`          | One-line summary derived from the member's prompt (≤ 90 chars). May be empty.                           |

**Sort order:** descending by `score`. Ties preserve input order (stable sort).

**Example — populated** (invoked with a `--task`)

```json
[
  { "name": "luna-ui",     "agentId": "c9d3@session-8c2d", "cwd": "…/worktrees/luna-9-ui",    "score": 55, "why": "same cwd; kw:compose,navigation", "context": "own the settings screen redesign" },
  { "name": "lucid-probe", "agentId": "d1a4@session-8c2d", "cwd": "…/worktrees/lucid-3-probe", "score": 10, "why": "kw:latency,probe",                 "context": "diagnose the latency spike in the prober" }
]
```

**Example — no reusable idle agent** (exit `0`)

```json
[]
```

---

## Cross-script nuances (read before consuming both)

`roster.sh` and `idle-agents.sh` overlap in fields but **do not agree on
nullability** — this is intentional and part of the frozen contract:

| Field     | `roster.sh`                         | `idle-agents.sh`                       |
|-----------|-------------------------------------|----------------------------------------|
| `name`    | never `null` (fallback to id/`"?"`) | `string \| null`                       |
| `cwd`     | `string \| null`                    | `string` (empty `""`, never `null`)    |
| `agentId` | `string \| null`                    | `string` (never `null`, never empty)   |

A consumer that reads both must handle each script's nullability on its own
terms; do not assume symmetry.
