export const meta = {
  name: 'review-sweep',
  description: 'Parallel code review across every open PR in a repo: discover the open PRs → one reviewer agent per PR (reads the diff + context, returns structured findings) → synthesize one cross-PR report that flags conflicts, shared-file collisions, and contradictory changes.',
  whenToUse: 'When several PRs are open at once and you want one consolidated review pass — before a merge wave, during an overnight run, or to triage a backlog. For merging PRs in order use merge-cascade; this only reviews.',
  phases: [
    { title: 'Discover', detail: 'gh pr list → the set of open PRs to review (optional author/label/limit filters)' },
    { title: 'Review', detail: 'parallel — one reviewer per PR over its diff; structured findings + verdict' },
    { title: 'Synthesize', detail: 'barrier — one agent merges reviews, flags cross-PR conflicts + shared-file collisions, ranks by risk' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────
// Review is a BARRIER (parallel): synthesis genuinely needs ALL reviews at
// once to spot cross-PR conflicts (two PRs editing the same file, or making
// contradictory changes). That is the textbook case where a barrier is
// correct — stage N references "the other findings".
// ─────────────────────────────────────────────────────────────────────────

const A = (args && typeof args === 'object') ? args : {}
const REPO = A.repo || ''
const STATE = A.state || 'open'
const LABEL = A.label || ''     // optional filter
const AUTHOR = A.author || ''   // optional filter
const LIMIT = A.limit || 30

if (!REPO) {
  return { error: 'review-sweep needs args: { repo: "owner/name", label?, author?, state?, limit? }' }
}

const PR_LIST_SCHEMA = {
  type: 'object', required: ['prs'],
  properties: {
    prs: { type: 'array', items: {
      type: 'object', required: ['number', 'title'],
      properties: {
        number: { type: 'number' },
        title: { type: 'string' },
        author: { type: 'string' },
        headRefName: { type: 'string' },
        baseRefName: { type: 'string' },
        additions: { type: 'number' },
        deletions: { type: 'number' },
        changedFiles: { type: 'number' },
        isDraft: { type: 'boolean' },
        mergeable: { type: 'string' },
      },
    }},
  },
}
const REVIEW_SCHEMA = {
  type: 'object', required: ['pr', 'verdict', 'summary', 'files'],
  properties: {
    pr: { type: 'number' },
    verdict: { enum: ['approve', 'comment', 'request-changes'] },
    risk: { enum: ['low', 'medium', 'high'] },
    summary: { type: 'string' },
    files: { type: 'array', items: { type: 'string' }, description: 'paths the PR touches (for collision detection)' },
    findings: { type: 'array', items: {
      type: 'object', required: ['severity', 'detail'],
      properties: {
        severity: { enum: ['blocker', 'major', 'minor', 'nit'] },
        detail: { type: 'string' },
        location: { type: 'string' },
      },
    }},
  },
}
const SYNTH_SCHEMA = {
  type: 'object', required: ['overview', 'mergeOrder', 'conflicts'],
  properties: {
    overview: { type: 'string', description: '3-5 sentence state-of-the-PRs summary' },
    mergeOrder: { type: 'array', items: { type: 'number' }, description: 'suggested safe merge order by PR number' },
    conflicts: { type: 'array', items: {
      type: 'object', required: ['prs', 'kind', 'detail'],
      properties: {
        prs: { type: 'array', items: { type: 'number' } },
        kind: { enum: ['shared-file', 'contradictory', 'duplicate', 'stacked-dependency'] },
        detail: { type: 'string' },
      },
    }},
    highRisk: { type: 'array', items: { type: 'number' }, description: 'PR numbers needing the closest look' },
    readyToMerge: { type: 'array', items: { type: 'number' } },
  },
}

// ════════════════ Phase 1: Discover ════════════════
phase('Discover')
const filters = [`--state ${STATE}`, `--limit ${LIMIT}`, LABEL && `--label "${LABEL}"`, AUTHOR && `--author "${AUTHOR}"`].filter(Boolean).join(' ')
const listing = await agent(`## PR discovery on ${REPO}

Run:
\`gh pr list --repo ${REPO} ${filters} --json number,title,author,headRefName,baseRefName,additions,deletions,changedFiles,isDraft,mergeable\`

Return the PRs as-is (author is the \`.author.login\`). Skip nothing — include drafts (mark isDraft). READ-ONLY.`,
  { label: 'discover', phase: 'Discover', schema: PR_LIST_SCHEMA })

const prs = (listing && listing.prs) || []
if (!prs.length) {
  return { repo: REPO, reviewed: 0, message: `No ${STATE} PRs${LABEL ? ` with label "${LABEL}"` : ''}${AUTHOR ? ` by ${AUTHOR}` : ''}.` }
}
log(`Discovered ${prs.length} PR(s): ${prs.map(p => '#' + p.number).join(', ')}`)

// ════════════════ Phase 2: Review (parallel, one per PR) ════════════════
phase('Review')
const reviews = (await parallel(prs.map(pr => () =>
  agent(`## PR reviewer — #${pr.number}: ${pr.title}

Repo: \`${REPO}\`. Author: ${pr.author || '?'} · branch ${pr.headRefName || '?'} → ${pr.baseRefName || 'main'} · ~${pr.changedFiles || '?'} files (+${pr.additions || 0}/-${pr.deletions || 0})${pr.isDraft ? ' · DRAFT' : ''}.

Read the change and review it:
\`gh pr diff ${pr.number} --repo ${REPO}\`  (open changed files for surrounding context where it matters; check the PR description for intent.)

Review for: correctness bugs, regressions / broken contracts for callers, security or secrets, scope creep / debug artifacts, and project-convention fit. Be specific — cite file:line where you can. READ-ONLY: do NOT edit, push, or comment on GitHub.

Return: pr (${pr.number}), verdict (approve | comment | request-changes), risk (low/medium/high), a 1-3 sentence summary, the list of files it touches (for collision detection), and findings[] (severity blocker/major/minor/nit · detail · location).`,
    { label: `review:#${pr.number}`, phase: 'Review', schema: REVIEW_SCHEMA })
))).filter(Boolean)

log(`Reviewed ${reviews.length}/${prs.length}. Verdicts: ${reviews.filter(r => r.verdict === 'approve').length} approve · ${reviews.filter(r => r.verdict === 'comment').length} comment · ${reviews.filter(r => r.verdict === 'request-changes').length} request-changes.`)

if (!reviews.length) {
  return { repo: REPO, discovered: prs.length, reviewed: 0, message: 'All reviewer agents failed or were skipped.' }
}

// ════════════════ Phase 3: Synthesize (barrier — needs all reviews) ════════════════
phase('Synthesize')
const block = reviews.map(r =>
  `### PR #${r.pr} — ${r.verdict} (risk: ${r.risk || '?'})\n` +
  `${r.summary}\n` +
  `Files: ${(r.files || []).join(', ') || '(none reported)'}\n` +
  (r.findings && r.findings.length
    ? r.findings.map(f => `  - [${f.severity}] ${f.detail}${f.location ? ` (${f.location})` : ''}`).join('\n')
    : '  - (no findings)')
).join('\n\n')

const synthesis = await agent(`## Cross-PR synthesis — ${REPO}

${reviews.length} PRs were reviewed independently. Produce ONE consolidated report. The key value here is cross-PR analysis no single reviewer could see:

1. **overview** — 3-5 sentences on the overall state of the open PRs.
2. **conflicts** — find PRs that touch the SAME files (shared-file), make CONTRADICTORY changes, are DUPLICATES of each other, or are STACKED (one depends on another's branch). Use the per-PR file lists below.
3. **mergeOrder** — a safe merge order (PR numbers): lowest-risk / smallest-touch-set first, dependencies before dependents, so each merge dirties the rest as little as possible (the no-eager-merge principle).
4. **highRisk** — PRs needing the closest human look.
5. **readyToMerge** — PRs that are clean approvals with no conflicts.

## Per-PR reviews
${block}

Structured output only.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA })

return {
  repo: REPO,
  discovered: prs.length,
  reviewed: reviews.length,
  reviews: reviews.map(r => ({ pr: r.pr, verdict: r.verdict, risk: r.risk, summary: r.summary, blockers: (r.findings || []).filter(f => f.severity === 'blocker' || f.severity === 'major').length })),
  synthesis: synthesis || { note: 'synthesis step failed; per-PR reviews still returned above' },
}
