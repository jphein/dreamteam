# Agent-coordination lessons — 2026-07-18 (smol firmware wave)

Captured by the Hypnos (agent-manager) role during a long multi-lane smol firmware session
(net-stack surgery #89, OTA finalize-ack #157, channel_hint #155, OTA display #161, ETX #164,
HA notify #160, + viz #159/#177). Distilled from `state/lessons-2026-07-18.md`. These are
**generalizable coordination lessons** for anyone running or managing a dream team — not
smol-specific facts.

The throughline: **verify by the tree, not by the status message or the instruction.** Every
incident below was caught (or made harmless) by reading git / `/proc` / panes as ground truth
instead of trusting an ACK, a pane spinner, or an orchestrator's mental model.

---

## 1. The build HOST is part of the gate — "green on the wrong host" is an invalid gate
A firmware crate pinned to a specific toolchain (rust-toolchain.toml) builds cleanly only on the
host with that toolchain. Building it elsewhere (a different default rustc) can spurious-lint
**untouched** files or fail on unrelated code — so a "clippy/release green" from the wrong host
is an INVALID gate that reads as pass/fail incorrectly. Seen three ways in one night: spurious
lints on untouched files, an `esp-wifi-sys` type error, and a `BUILD_NUMBER=0`/no-`.git`
`absurd_extreme_comparisons`.
**Manager move:** when validating a "build green" claim, verify the **host + toolchain**, not just
the exit code. Relay the build-host rule to every affected lane; a lane's task text ("build on
$WRONGHOST") is a place the divergence hides — watch it get corrected.

## 2. Verify progress by the tree, not the ACK or the pane spinner
An agent's confident ACK ("done / rebased / clean") and even its live "thinking…" spinner do not
prove state. Only `git status` / `git log` / `git merge-base` / file mtimes do. Corollary
(**mailbox lag**): a busy agent in a long single turn reads its inbox only at turn-end, so relays
sit unread while it keeps working on a stale premise — invisible from messaging alone, visible in
the tree. When an agent says "your info is lagging," it is often right about its OWN state:
re-check YOUR method (right dir? right pane? right branch?) before doubling down.

## 3. `git merge-tree` is a no-write manager's conflict preview
To predict whether a lane's rebase will conflict WITHOUT running rebase/checkout (which a
non-writing manager must not do):
```
git merge-tree --write-tree --messages <branch> origin/main
```
Exit 0 + valid tree oid + zero `<<<<<<<` markers = clean; exit 1 = real conflict (output shows the
hunks). Uses the true merge-base as ancestor, so for a single-commit lane it models the rebase
faithfully. Used live to prove two lanes that "both touched the same files" were actually disjoint —
correcting the team's expectation with evidence, not opinion. **Always check the exit code /
stderr**: a silently-errored merge-tree looks identical to "clean" (empty output).

## 4. Eager small merges shift the base under every rebasing lane — freeze, then batch
During an active rebase window, each merge to main (even a trivial one) re-shifts the base and
forces another round of rebase relays + merge-base re-verification. **Fix:** freeze main until the
big lane lands, then batch the small non-HW-gated PRs together. The manager flags any eager merge
that lands mid-wave.

## 5. A gated PR is the perfect window for a bounded adversarial self-review
When a lane finishes early and its PR is HW/canary-gated, the author's context is warm and there's
idle time — offer a SCOPED self-audit (canary checks + named edge cases), not make-work; reserve if
nothing concrete. In this session that pass found + fixed a real latent bug (an MQTT SUBSCRIBE
packet-id collision that violated spec) **before** canary.

## 6. `/proc/<pid>/cwd` is NOT a worktree-collision detector
Dream-team agents keep their process cwd in the MAIN tree (their launch dir) and edit worktrees via
**absolute paths**. So `/proc/cwd` never points into a worktree — even for the agent actively
editing it — and a "did cwd leave the shared worktree?" check ALWAYS passes and detects nothing.
The real single-writer signal is **who WRITES the worktree's paths**: watch each agent's pane for
Edit/Write/build tool calls on that worktree's absolute paths, and correlate the worktree's
dirty-state / file mtimes with which agent is active. Related: two agents "sharing" a branch is a
shared *checkout* (git allows one worktree per branch), so the collision rule is "stay out of the
DIRECTORY," not just "don't commit to the branch" — a shared checkout clobbers files live, worse
than a merge conflict.

## 7. Ground-truth beats the orchestrator's instruction — surface evidence, enforce the safe path
The marquee incident: task ownership flipped five times because the orchestrator misattributed a
worktree's live WIP to the wrong agent. What kept the churn from costing anything:
1. **Verify by tree, not by the instruction** — the disputed WIP was already a committed, durable
   commit whose message matched the true author's own description, and the "idle" agent's pane
   showed it actively editing.
2. **Enforce a contested call along the reversible / no-data-loss path** — have the agent commit +
   dump its design to the plan doc BEFORE any stop, so no work is lost whichever way the call goes.
3. **Treat a peer agent's read-only corroboration as first-class evidence** (it checked `git status`
   from `~` with no cd-in and confirmed it wrote zero source).
4. **Reverse your OWN enforcement instantly when the orchestrator corrects** — a stop-poke racing
   toward a productive agent must be countermanded immediately (poke first).
Obeying an instruction over the evidence is right ONLY when the safe path is preserved underneath
it. And on ANY orchestrator reversal, proactively **supersede your own prior relays** to the
affected agents ("this replaces my last") — don't make them reconcile new-vs-old.

## 8. `git merge-base --is-ancestor` is unreliable for merged-ness after squash / force-push
A squash-merge creates a NEW commit; a force-push-after-merge diverges the branch tip from the
merged commit. In both cases the branch is genuinely merged, but `merge-base --is-ancestor <tip>
origin/main` returns false ("UNMERGED"). Do NOT gate a worktree-prune on that check — it will make
the wrong call. Verify merged-ness via the PR state (`gh pr view`), `git cherry`, or patch-id, and
leave prune decisions to a careful `/housekeep` pass, not a wind-down reflex.

---

### Meta
No work was lost across the whole session despite a build-host trap, repeated base-shifts, a
five-flip ownership saga, and a misattribution — because every enforcement action was chosen along
the path that stays recoverable if the call is wrong, and because durable state (committed +
pushed increments, plan docs) was treated as the source of truth over any message.
