export const meta = {
  name: 'overnight',
  description: 'Full overnight autonomous loop: scout the repo for high-value issues → fix each in an isolated worktree (one PR per fix) → ultrareview every PR with adversarial lenses → serially ship the clean, green, approved ones (no-eager-merge). Fleet size scales to the token budget.',
  whenToUse: '"overnight mode" / "dream until morning" / "keep rolling" / "full auto" for a long unattended run, AND JP has opted into Workflow/ultracode scale. Surfaces design/secrets/destructive decisions instead of guessing; ships everything else autonomously.',
  phases: [
    { title: 'Scout', detail: 'parallel scouts, one lens each (bugs, tech-debt, perf, tests); file gh issues; dedup + prioritize' },
    { title: 'Fix', detail: 'pipeline — one worktree-isolated agent per issue: implement, commit, push, open PR' },
    { title: 'Review', detail: 'pipeline — ultrareview each PR with 3 adversarial lenses → approve/revise/reject' },
    { title: 'Ship', detail: 'barrier then SERIAL merge of approved+green PRs in safe order (no-eager-merge)' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────
// Fleet scales to the token budget (budget.remaining()), falling back to
// maxHours when no "+Nk" target was set. Scripts can't read wall-clock
// (Date.now() is unavailable), so the LAUNCHING orchestrator owns the hard
// time cap and the memory-pressure tiers; this workflow owns one budget-scaled
// scout→fix→review→ship sweep. Run it repeatedly across the night.
//
// Fix runs in pipeline() (issues are INDEPENDENT — A can be in review while B
// is still being fixed) with isolation:'worktree' (parallel file mutation).
// Ship is a BARRIER + sequential merge: the no-eager-merge rule says hold every
// merge until the whole wave is reviewed, then merge serially in one ordered
// pass so each merge dirties the next as little as possible.
// ─────────────────────────────────────────────────────────────────────────

const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, Math.floor(n)))

const A = (args && typeof args === 'object') ? args : {}
const REPO = A.repo || ''
const MAX_HOURS = A.maxHours || 6
const REQUIRED = A.requiredCheck || 'Build APK'
const CI_TIMEOUT = A.ciTimeoutMin || 25
const FOCUS = A.focus || '' // optional: narrow scouting, e.g. "wear module" or "playback"

if (!REPO) {
  return { error: 'overnight needs args: { repo: "owner/name", maxHours?: 6, focus?: "..." }' }
}

// Budget primary, maxHours fallback. ~150k tokens per scout, ~120k per fix+review chain.
const SCOUTS = budget.total ? clamp(budget.remaining() / 150000, 2, 5) : clamp(MAX_HOURS, 2, 5)
const ISSUE_CAP = budget.total ? clamp(budget.remaining() / 120000, 3, 18) : clamp(MAX_HOURS * 3, 3, 15)

const LENSES = [
  { key: 'bugs', brief: 'Correctness bugs, crashes, null/lifecycle/coroutine hazards, race conditions, swallowed errors.' },
  { key: 'tech-debt', brief: 'Tech debt: dead code, duplication, leaky abstractions, missing error handling, fragile patterns worth refactoring.' },
  { key: 'perf', brief: 'Performance: needless recomposition/allocation, main-thread/IO-on-wrong-dispatcher work, N+1 queries, slow startup paths.' },
  { key: 'tests', brief: 'Test gaps + small UX/a11y defects: untested decision logic, missing content descriptions, broken edge cases.' },
].slice(0, SCOUTS)

// ─── Schemas ───
const SCOUT_SCHEMA = {
  type: 'object', required: ['issues'],
  properties: {
    issues: { type: 'array', maxItems: 8, items: {
      type: 'object', required: ['title', 'area', 'severity', 'rationale'],
      properties: {
        title: { type: 'string' },
        area: { type: 'string', description: 'module/file/subsystem' },
        severity: { enum: ['critical', 'high', 'medium', 'low'] },
        type: { enum: ['bug', 'tech-debt', 'perf', 'test', 'a11y', 'ux'] },
        rationale: { type: 'string' },
        files: { type: 'array', items: { type: 'string' } },
        issueNumber: { type: 'number', description: 'gh issue # if one was filed' },
        effort: { enum: ['small', 'medium', 'large'] },
      },
    }},
  },
}
const FIX_SCHEMA = {
  type: 'object', required: ['ok', 'action'],
  properties: {
    ok: { type: 'boolean' },
    action: { enum: ['pr-opened', 'no-change-needed', 'too-large', 'build-failed', 'error'] },
    prNumber: { type: 'number' },
    branch: { type: 'string' },
    summary: { type: 'string' },
    filesTouched: { type: 'array', items: { type: 'string' } },
  },
}
const REVIEW_SCHEMA = {
  type: 'object', required: ['verdict', 'rationale'],
  properties: {
    verdict: { enum: ['approve', 'revise', 'reject'] },
    rationale: { type: 'string' },
    blocking: { type: 'array', items: { type: 'string' }, description: 'issues that MUST be fixed before merge' },
    nits: { type: 'array', items: { type: 'string' } },
  },
}
const MERGE_SCHEMA = {
  type: 'object', required: ['pr', 'merged', 'action'],
  properties: {
    pr: { type: 'number' }, merged: { type: 'boolean' },
    action: { enum: ['merged', 'rebased-then-merged', 'ci-red', 'ci-timeout', 'conflict', 'blocked', 'error'] },
    mergeCommit: { type: 'string' }, notes: { type: 'string' },
  },
}

const slug = s => (s || 'issue').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32)

// ════════════════ Phase 1: Scout ════════════════
phase('Scout')
log(`Overnight on ${REPO} — ${LENSES.length} scout(s), issue cap ${ISSUE_CAP}, gate "${REQUIRED}"${FOCUS ? `, focus: ${FOCUS}` : ''}. Budget: ${budget.total ? Math.round(budget.remaining() / 1000) + 'k left' : 'no target (maxHours=' + MAX_HOURS + ')'}.`)

const scoutResults = (await parallel(LENSES.map(lens => () =>
  agent(`## Overnight scout — lens: ${lens.key}

Repo: \`${REPO}\` (work in the local checkout). ${FOCUS ? `Focus area: **${FOCUS}**.` : ''} You have full shell, \`gh\`, and the codebase.

Hunt for the highest-value **${lens.key}** problems: ${lens.brief}
Read real code (grep, open files, skim recent diffs / open issues to avoid dupes). Quality over quantity — surface 3-6 concrete, actionable items a single focused PR could fix. Skip anything sprawling or speculative.

For each item worth fixing, FILE a GitHub issue so it survives context loss (per the track-requests-as-issues rule):
\`gh issue create --repo ${REPO} --title "<title>" --body "<rationale + files + suggested approach>" --label overnight\`
(If \`--label overnight\` errors because the label is absent, retry without it.) Capture the returned issue number.

Return each as: title, area, severity, type, rationale, files[], issueNumber (if filed), effort. READ + file issues only — do NOT edit code in this phase.`,
    { label: `scout:${lens.key}`, phase: 'Scout', schema: SCOUT_SCHEMA })
))).filter(Boolean)

// Dedup across scouts by (area + normalized title); prioritize critical/high, small effort first.
const sevRank = { critical: 0, high: 1, medium: 2, low: 3 }
const effRank = { small: 0, medium: 1, large: 2 }
const seen = new Set()
const allIssues = scoutResults.flatMap(r => r.issues || [])
  .filter(it => { const k = slug(it.area) + '|' + slug(it.title); if (seen.has(k)) return false; seen.add(k); return true })
  .sort((a, b) => (sevRank[a.severity] - sevRank[b.severity]) || (effRank[a.effort || 'medium'] - effRank[b.effort || 'medium']))

const issues = allIssues.slice(0, ISSUE_CAP).map((it, i) => ({ ...it, slug: slug(it.title), rank: i }))
log(`Scouted ${allIssues.length} distinct issue(s); taking top ${issues.length}: ${issues.map(i => '#' + (i.issueNumber || '?') + ' ' + i.title).slice(0, 6).join(' · ')}${issues.length > 6 ? ' …' : ''}`)

if (!issues.length) {
  return { repo: REPO, phase: 'scout', scouted: 0, message: 'No actionable issues found this sweep.', scouts: LENSES.map(l => l.key) }
}

// ════════════════ Phase 2+3: Fix → Review (pipeline, independent per issue) ════════════════
const worked = await pipeline(
  issues,

  // ── Fix: worktree-isolated; implement + open PR ──
  issue => agent(`## Overnight fixer — ${issue.title}

Repo: \`${REPO}\`. You are in an ISOLATED git worktree — your edits won't collide with sibling fixers. Full shell + \`gh\`.

**Issue** (${issue.severity}/${issue.type || 'general'}${issue.issueNumber ? `, gh #${issue.issueNumber}` : ''}) in **${issue.area}**:
${issue.rationale}
${(issue.files || []).length ? 'Likely files: ' + issue.files.join(', ') : ''}

### Do
1. Branch: \`git checkout -b fix/${issue.slug}\`.
2. Implement the SMALLEST correct fix. Match surrounding style. Don't fold in unrelated polish (keep the diff reviewable).
3. If the repo has tests for the touched area, run them. Confirm it at least compiles (the fast module compile task if one exists — do NOT do a full local release build; CI is the compile gate).
4. Commit (conventional style, reference the issue: \`fix: … (#${issue.issueNumber || ''})\`), push, and open a PR:
   \`gh pr create --repo ${REPO} --fill --head fix/${issue.slug}${issue.issueNumber ? ` --body "Closes #${issue.issueNumber}"` : ''}\`

### Stop & report (don't force it)
- Fix turns out to need design/product judgement, secrets/keystore, or a destructive/irreversible change → action:"too-large", ok:false, summary=what's needed. Do NOT open a PR.
- No change actually warranted → action:"no-change-needed".
- Can't get it to compile → action:"build-failed" with the error.

Return: ok, action (pr-opened | no-change-needed | too-large | build-failed | error), prNumber, branch, summary, filesTouched.`,
    { label: `fix:${issue.slug}`, phase: 'Fix', isolation: 'worktree', schema: FIX_SCHEMA }),

  // ── Review: ultrareview — 3 adversarial lenses, combined into one verdict ──
  (fix, issue) => {
    if (!fix || !fix.ok || !fix.prNumber) return fix // nothing merged → skip review, carry the fix result forward
    const lenses = [
      { k: 'correctness', p: 'Does the change actually fix the issue without introducing bugs? Check edge cases, nulls, lifecycle, threading. Try to find a case where it breaks.' },
      { k: 'regression', p: 'What could this break elsewhere? Shared state, callers of changed functions, behavioral contracts, hot files other PRs touch.' },
      { k: 'scope', p: 'Is the diff minimal and on-target, or does it sprawl? Any secrets, debug artifacts, version/keystore changes, or unrelated edits sneaking in?' },
    ]
    return parallel(lenses.map(l => () =>
      agent(`## Ultrareview (${l.k}) — PR #${fix.prNumber} on ${REPO}

Original issue: ${issue.title} — ${issue.rationale}

Inspect the diff: \`gh pr diff ${fix.prNumber} --repo ${REPO}\` (open changed files for context as needed). READ-ONLY — do NOT edit or push.

Lens — **${l.k}**: ${l.p}

Return a verdict (approve | revise | reject), rationale, blocking[] (must-fix-before-merge), nits[].`,
        { label: `review:${l.k}:#${fix.prNumber}`, phase: 'Review', schema: REVIEW_SCHEMA })
    )).then(verdicts => {
      const valid = verdicts.filter(Boolean)
      const reject = valid.some(v => v.verdict === 'reject')
      const revise = valid.some(v => v.verdict === 'revise')
      const blocking = valid.flatMap(v => v.blocking || [])
      // Approve only on a clean sweep: no reject, no revise, and a quorum actually voted.
      const verdict = reject ? 'reject' : revise ? 'revise' : (valid.length >= 2 ? 'approve' : 'revise')
      log(`Review #${fix.prNumber} (${issue.title.slice(0, 40)}): ${verdict}${blocking.length ? ` — ${blocking.length} blocker(s)` : ''}`)
      return { ...fix, issue: issue.title, severity: issue.severity, review: { verdict, blocking, lenses: valid } }
    })
  }
)

const prs = worked.filter(Boolean).filter(w => w.prNumber)
const opened = prs.length
const approved = prs.filter(w => w.review && w.review.verdict === 'approve')
const needsWork = prs.filter(w => w.review && w.review.verdict !== 'approve')
log(`Fix+Review done: ${opened} PR(s) opened, ${approved.length} approved, ${needsWork.length} need work.`)

// ════════════════ Phase 4: Ship (barrier already passed; SERIAL merge) ════════════════
// no-eager-merge: every PR in the wave is reviewed before we merge any. Merge
// the approved ones one at a time in severity order; if a merge dirties the
// next, that agent rebases it as part of its own step.
phase('Ship')
const queue = [...approved].sort((a, b) => (sevRank[a.severity] - sevRank[b.severity]))
const shipped = []
if (!queue.length) {
  log('Nothing approved to ship this sweep.')
} else {
  log(`Shipping ${queue.length} approved PR(s) serially: [${queue.map(q => '#' + q.prNumber).join(', ')}]`)
  for (const w of queue) {
    const m = await agent(`## Overnight merge warden — PR #${w.prNumber} on ${REPO}

You are merging ONE PR, then stopping. Full shell + \`gh\`. NEVER force-push main; only \`--force-with-lease\` the PR's own branch.

1. \`gh pr view ${w.prNumber} --repo ${REPO} --json state,mergeable,mergeStateStatus,headRefName,baseRefName\` — if already MERGED, return merged:true/action:"merged".
2. If CONFLICTING/BEHIND/DIRTY or no CI run for the head SHA → fetch, checkout the branch, rebase onto origin/main, \`git push --force-with-lease\` (re-triggers CI). Real semantic conflict needing judgement → action:"conflict", merged:false.
3. Wait up to ~${CI_TIMEOUT} min for **${REQUIRED}** to pass (advisory bots — CodeRabbit/DeepSource/Gemini — do NOT gate):
   \`until gh pr checks ${w.prNumber} --repo ${REPO} | grep -qiE '${REQUIRED}.*(pass|success)'; do gh pr checks ${w.prNumber} --repo ${REPO} | grep -qiE '${REQUIRED}.*(fail|error)' && break; sleep 30; done\`
   Failed → action:"ci-red", merged:false. Timeout → action:"ci-timeout", merged:false. Do NOT merge either.
4. If green + mergeable: \`gh pr merge ${w.prNumber} --repo ${REPO} --squash --delete-branch\`, then \`git fetch origin\` and confirm MERGED.

Return: pr, merged, action, mergeCommit, notes.`,
      { label: `ship:#${w.prNumber}`, phase: 'Ship', schema: MERGE_SCHEMA })

    if (!m) { shipped.push({ pr: w.prNumber, merged: false, action: 'error', notes: 'agent null' }); continue }
    shipped.push(m)
    log(m.merged
      ? `Shipped ${shipped.filter(s => s.merged).length}/${queue.length}: #${w.prNumber} — ${w.issue}`
      : `#${w.prNumber} not merged (${m.action}: ${m.notes || ''}) — left open for the next sweep.`)
  }
}

return {
  repo: REPO,
  budget: budget.total ? { targetK: Math.round(budget.total / 1000), spentK: Math.round(budget.spent() / 1000), leftK: Math.round(budget.remaining() / 1000) } : 'no-target',
  scouts: LENSES.map(l => l.key),
  scouted: allIssues.length,
  attempted: issues.length,
  prsOpened: opened,
  approved: approved.length,
  needsWork: needsWork.map(w => ({ pr: w.prNumber, issue: w.issue, verdict: w.review.verdict, blocking: w.review.blocking })),
  merged: shipped.filter(s => s.merged).map(s => s.pr),
  notMerged: shipped.filter(s => !s.merged).map(s => ({ pr: s.pr, action: s.action, notes: s.notes })),
  summary: `Scouted ${allIssues.length} → fixed ${opened} PR(s) → approved ${approved.length} → shipped ${shipped.filter(s => s.merged).length}. ${needsWork.length} PR(s) need follow-up; ${shipped.filter(s => !s.merged).length} approved-but-unmerged left for next sweep.`,
}
