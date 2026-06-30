export const meta = {
  name: 'merge-cascade',
  description: 'Serialized, dependency-ordered merge of N PRs: for each PR in order — rebase onto the new main, wait for the required check to go green, squash-merge, let main settle — then move to the next. Honors the no-eager-merge rule (one merge in flight, rebase-next-on-demand).',
  whenToUse: 'When several PRs must land in a specific order and each merge dirties the next (overlapping files, stacked branches). Pass the PRs already sorted into dependency/merge order. For independent PRs that just need reviewing, use review-sweep instead.',
  phases: [
    { title: 'Merge', detail: 'one PR per step, in args.prs order; rebase the next onto the freshly-merged main before its turn' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────
// DESIGN NOTE — why a sequential for-loop and NOT pipeline()
//
// pipeline() runs items through stages with NO barrier between items: PR #2
// could start its CI-wait while PR #1 is still merging. A real cascade is the
// opposite — PR N+1 must rebase onto the RESULT of merging PR N, then build,
// then merge. That is a strict fold/serialization (item N depends on item
// N-1's *completion*, which is stronger than a barrier), so the correct
// primitive is an `await` loop — the same idiom the Workflow docs use for
// loop-until-count. Using pipeline() here would race the cascade and re-dirty
// branches, the exact failure the no-eager-merge rule exists to prevent.
//
// Only ONE merge is ever in flight. If a PR fails to merge, the chain halts —
// everything downstream depends on it, so blindly merging on would corrupt the
// order. The unmerged tail is reported so the orchestrator can intervene.
// ─────────────────────────────────────────────────────────────────────────

const MERGE_RESULT_SCHEMA = {
  type: 'object',
  required: ['pr', 'merged', 'action'],
  properties: {
    pr: { type: 'number' },
    title: { type: 'string' },
    merged: { type: 'boolean' },
    action: { enum: ['merged', 'rebased-then-merged', 'blocked', 'conflict', 'ci-red', 'ci-timeout', 'already-merged', 'error'] },
    requiredCheck: { type: 'string', description: 'name + state of the gating check, e.g. "Build APK: SUCCESS"' },
    mergeCommit: { type: 'string' },
    rebased: { type: 'boolean', description: 'true if the branch was rebased+force-pushed before merging' },
    notes: { type: 'string' },
  },
}

// args: { prs: [123, 124, 125], repo: "owner/name",
//         strategy?: "squash"|"merge"|"rebase" (default squash),
//         requiredCheck?: "Build APK" (the only check that gates; bots are advisory),
//         ciTimeoutMin?: 25, deleteBranch?: true }
const A = (args && typeof args === 'object') ? args : {}
const PRS = Array.isArray(A.prs) ? A.prs : []
const REPO = A.repo || ''
const STRATEGY = A.strategy || 'squash'
const REQUIRED = A.requiredCheck || 'Build APK'
const CI_TIMEOUT = A.ciTimeoutMin || 25
const DELETE_BRANCH = A.deleteBranch !== false

if (!PRS.length || !REPO) {
  return { error: 'merge-cascade needs args: { prs: [123,124,...], repo: "owner/name" }. PRs must be pre-sorted into merge order.' }
}

const flag = STRATEGY === 'merge' ? '--merge' : STRATEGY === 'rebase' ? '--rebase' : '--squash'

const MERGE_PROMPT = (pr, idx, total, isFirst) => `## Merge warden — PR #${pr}  (cascade step ${idx + 1}/${total})

Repo: \`${REPO}\`. You are merging exactly ONE pull request, then stopping. You have full shell + the \`gh\` CLI. NEVER force-push to main; only ever force-push the PR's own feature branch with \`--force-with-lease\`.

### 1. Sync + check mergeability
\`\`\`
gh pr view ${pr} --repo ${REPO} --json number,title,state,mergeable,mergeStateStatus,headRefName,baseRefName
\`\`\`
- If \`state\` is already MERGED → return action:"already-merged", merged:true. Done.
${isFirst ? '- This is the FIRST PR in the cascade; main has not moved for it yet.' : `- Earlier cascade steps have moved main. Treat this branch as potentially stale.`}

### 2. Rebase onto current main if needed
If \`mergeable\` is CONFLICTING/UNKNOWN, or \`mergeStateStatus\` is BEHIND/DIRTY, OR no CI run appears for the head SHA (a missing Android run usually means the branch conflicts main — see the candela "no-CI-run = merge conflict" rule):
\`\`\`
git fetch origin
git checkout <headRefName> && git rebase origin/${'${baseRefName:-main}'}
# resolve trivial conflicts only; if a real semantic conflict needs judgement, STOP and report action:"conflict"
git push --force-with-lease
\`\`\`
Set rebased:true if you did this. A force-push re-triggers CI — you must then wait for it in step 3.

### 3. Wait for the required check to go GREEN
The ONLY check that gates this merge is **${REQUIRED}**. Advisory review bots (CodeRabbit, DeepSource, Gemini, Copilot) do NOT block — ignore their state for the merge decision. Poll up to ~${CI_TIMEOUT} min:
\`\`\`
until gh pr checks ${pr} --repo ${REPO} 2>/dev/null | grep -qiE '${REQUIRED}.*(pass|success)'; do
  # bail out if the required check has clearly FAILED, not just pending
  gh pr checks ${pr} --repo ${REPO} | grep -qiE '${REQUIRED}.*(fail|error)' && break
  sleep 30
done
\`\`\`
- Required check FAILED → return action:"ci-red", merged:false, notes=the failing job/log excerpt. Do NOT merge.
- Still pending after ~${CI_TIMEOUT} min → return action:"ci-timeout", merged:false. Do NOT merge.

### 4. Merge
Only if mergeable AND ${REQUIRED} is green:
\`\`\`
gh pr merge ${pr} --repo ${REPO} ${flag}${DELETE_BRANCH ? ' --delete-branch' : ''}
\`\`\`

### 5. Confirm main settled
\`\`\`
git fetch origin && gh pr view ${pr} --repo ${REPO} --json state,mergeCommit
\`\`\`
Confirm state==MERGED and capture the merge commit SHA.

### Return (structured)
pr, title, merged, action (merged | rebased-then-merged | blocked | conflict | ci-red | ci-timeout | already-merged | error), requiredCheck ("${REQUIRED}: <state>"), mergeCommit, rebased, notes. If anything blocks the merge, merged:false with a precise reason — the cascade halts on a non-merge because every later PR depends on this one landing.`

phase('Merge')
log(`Cascade: ${PRS.length} PR(s) in order [${PRS.join(' → ')}] on ${REPO} (gate: "${REQUIRED}", strategy: ${STRATEGY})`)

const results = []
let halted = null
for (let i = 0; i < PRS.length; i++) {
  const pr = PRS[i]
  const res = await agent(MERGE_PROMPT(pr, i, PRS.length, i === 0), {
    label: `merge:#${pr}`,
    phase: 'Merge',
    schema: MERGE_RESULT_SCHEMA,
  })

  if (!res) {
    // null = user-skipped this agent or it died after retries. The cascade
    // cannot safely continue past an unknown outcome — halt and report.
    results.push({ pr, merged: false, action: 'error', notes: 'agent returned null (skipped or terminal error)' })
    halted = pr
    log(`#${pr}: no result — halting cascade (downstream PRs depend on it).`)
    break
  }

  results.push(res)
  const done = results.filter(r => r.merged).length
  if (res.merged) {
    log(`Merged ${done}/${PRS.length}: #${pr} — ${res.title || ''}${res.rebased ? '  (rebased first)' : ''}`)
  } else {
    halted = pr
    log(`#${pr} did NOT merge — ${res.action}: ${res.notes || ''}. Halting cascade; ${PRS.length - i - 1} PR(s) downstream left untouched.`)
    break
  }
}

const merged = results.filter(r => r.merged).map(r => r.pr)
const remaining = PRS.slice(results.length)
return {
  repo: REPO,
  order: PRS,
  strategy: STRATEGY,
  requiredCheck: REQUIRED,
  mergedCount: merged.length,
  total: PRS.length,
  merged,
  haltedAt: halted,
  remaining,
  results,
  summary: halted
    ? `Merged ${merged.length}/${PRS.length}; HALTED at #${halted}. Remaining (depend on the halt): [${remaining.join(', ')}]. Resolve #${halted} then re-run merge-cascade with prs: [${[halted, ...remaining].join(', ')}].`
    : `Merged all ${merged.length}/${PRS.length} in order.`,
}
