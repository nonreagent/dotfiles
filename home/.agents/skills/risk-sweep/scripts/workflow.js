// Reference implementation of the risk-sweep pipeline for the Claude Code
// Workflow harness. The prose in ../references/stage-prompts.md is canonical —
// on any conflict, the prose wins and this file has a bug.
//
// The orchestrator still does recon itself (see SKILL.md §0), then invokes:
//   Workflow({ scriptPath: <this file>, args: {
//     repo:            "owner/name",
//     defaultBranch:   "main",
//     postingAccount:  "<gh api user -q .login>",
//     auditSkillPath:  "/abs/path/to/risk-audit/SKILL.md",   // sibling skill dir
//     ctx:             "<shared context block from recon>",  // labels, hotspots,
//                                                            // map-state per PR,
//                                                            // attribution rule
//     queue: [ { pr, sha /* FULL headRefOid — never truncated */, ci, overlap } ]
//   }})
//
// Every string above must come from recon at run time. Nothing repo- or
// machine-specific may be hardcoded here — this file ships in a public repo.

export const meta = {
  name: 'risk-sweep',
  description: 'Assess review risk across open PRs, gate low-risk verdicts, apply labels and review maps',
  phases: [
    { title: 'Assess', detail: 'one read-only assessor per queued PR' },
    { title: 'Gate', detail: 'adversarial refutation of low-risk verdicts only', model: 'opus' },
    { title: 'Apply', detail: 'post or PATCH-edit the review map, swap labels, read back' },
  ],
}

const A = typeof args === 'string' ? JSON.parse(args) : args
for (const k of ['repo', 'defaultBranch', 'postingAccount', 'auditSkillPath', 'ctx', 'queue']) {
  if (!A?.[k]) throw new Error(`risk-sweep workflow: missing args.${k}`)
}

const ASSESS_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: {
    status: { enum: ['assessed', 'skipped-stale', 'failed'] },
    verdict: { enum: ['low-risk', 'high-risk'] },
    assessedSha: { type: 'string' },
    effort: { enum: ['quick', 'deep'] },
    triggersFired: { type: 'array', items: { type: 'string' } },
    earnChecklist: { type: 'object' },
    semanticLines: { type: 'number' },
    estimatedMinutes: { type: 'number' },
    needsQa: { type: 'boolean' },
    needsQaReason: { type: 'string' },
    map: { type: 'string' },
    uncertainties: { type: 'array', items: { type: 'string' } },
    dossier: { type: 'string' },
    failReason: { type: 'string' },
  },
}

const GATE_SCHEMA = {
  type: 'object',
  required: ['result'],
  properties: {
    result: { enum: ['upheld', 'flipped', 'skipped-stale'] },
    objection: { type: 'string' },
    map: { type: 'string' },
    needsQa: { type: 'boolean' },
    needsQaReason: { type: 'string' },
  },
}

const APPLY_SCHEMA = {
  type: 'object',
  required: ['status'],
  properties: {
    status: { enum: ['applied', 'skipped-stale', 'failed'] },
    labelBefore: { type: 'string' },
    labelAfter: { type: 'string' },
    commentUrl: { type: 'string' },
    commentWas: { enum: ['created', 'edited'] },
    readBackOk: { type: 'boolean' },
    landed: { type: 'array', items: { enum: ['label', 'comment', 'qa-flag'] } },
    failReason: { type: 'string' },
  },
}

function assessPrompt(item) {
  return `You are the assess stage of a live review-risk sweep, pricing the human review attention PR #${item.pr} needs, for a maintainer who will trust the label.

FIRST Read ${A.auditSkillPath} — its trigger list, earn criteria, mechanical discount, and review-map shape are your rubric. Follow it exactly.

${A.ctx}

THIS ITEM (from recon's snapshot):
- PR #${item.pr}, pinned head SHA ${item.sha} (short ${item.sha.slice(0, 7)})
- CI conclusions at snapshot: ${item.ci}
- Sibling overlap from recon's matrix: ${item.overlap}
- Existing-map state per PR is stated in the shared context above; when a map exists, the apply stage edits it in place.

THIS STAGE IS READ-ONLY. Do not post, label, push, or check out anything.

How to read, with the reads that actually exist: gh pr view for body and comments; thread resolution via GraphQL reviewThreads(first:100){nodes{isResolved}} (gh pr view --json reviewThreads is not a field); approval currency via gh pr view --json reviews (reviews[].commit.oid against the pinned SHA); the diff PINNED via gh api repos/${A.repo}/compare/${A.defaultBranch}...${item.sha}; whole-file context via gh api raw reads at the pinned SHA — never a checkout. Re-check headRefOid AFTER reading, not only before: if the PR is no longer open or the head no longer matches ${item.sha} at either check, stop and return status "skipped-stale".

Then: classify mechanical vs semantic; map semantic files against the hotspots; apply every trigger (report all that fire, by number); walk the earn checklist explicitly (keys: noTriggers, oneRead, testsCoverBehavior, ciGreen, selfReviewClean -> pass/fail/unknown); decide the manual-QA flag only if the mapping names one; anything undeterminable resolves high and is named in uncertainties — and unchecked is not undeterminable: check every checkable claim before earning low-risk.

Draft the review map exactly in the audit's shape, assessed at ${item.sha.slice(0, 7)}, including the **Mapping:** line when the shared context says hotspots were derived, and an **Overlap:** line when the matrix above shows overlap. semanticLines is your post-discount count; estimatedMinutes your review-minutes estimate.`
}

function gatePrompt(item, a) {
  return `You are the adversarial gate of a live review-risk sweep. REFUTE the claim that PR #${item.pr} (${A.repo}) is safe to review quickly. You are not proofreading — you are hunting for the reason the low-risk verdict is wrong.

FIRST Read ${A.auditSkillPath} — the trigger list, earn criteria, mechanical discount, and map shape are your rubric.

${A.ctx}

THIS STAGE IS READ-ONLY. Do not post, label, push, or check out anything.

Currency first: if PR #${item.pr} is no longer open, or its head no longer matches ${a.assessedSha}, return result "skipped-stale".

The assessor's full output:
${JSON.stringify(a, null, 2)}

Re-derive, don't re-read: apply the triggers against the pinned diff yourself (gh api repos/${A.repo}/compare/${A.defaultBranch}...${a.assessedSha}); inspect what the assessor discounted as mechanical (spot-check any "generated" claim); walk the earn checklist line by line — a low-risk verdict without its earn checklist is an automatic flip; check approval currency (reviews[].commit.oid) against the head; check thread resolution via GraphQL reviewThreads.

A sustained objection — a named trigger, a failed earn criterion, an undeterminable or UNCHECKED claim the assessor glossed — returns "flipped" with the objection in one paragraph and a rewritten map (verdict high-risk, the objection as the **Why** line). A hollow objection upholds; upholding with small map edits is normal, and you may revise the manual-QA decision either way. Return the final map you want applied.`
}

function applyPrompt(item, verdict, map, needsQa, needsQaReason) {
  return `You are the apply stage of a live review-risk sweep. Land the verdict for PR #${item.pr} in ${A.repo} — label and map comment, nothing else. This stage WRITES; make exactly the writes below.

${A.ctx}

Currency first: if gh pr view ${item.pr} --json state,headRefOid shows the PR is not OPEN, or headRefOid no longer starts with ${item.sha.slice(0, 7)}, write NOTHING and return status "skipped-stale".

FINAL VERDICT: ${verdict}
MANUAL-QA FLAG: ${needsQa ? 'ADD the mapping\'s manual-QA label. Reason: ' + (needsQaReason || 'see map') : 'do not add'}
THE MAP (post verbatim, no edits, no additions):
${map}

Steps:
1. Map comment, edit-in-place. Look up an existing map with the REST ids PATCH accepts: gh api repos/${A.repo}/issues/${item.pr}/comments --jq '.[] | select(.user.login=="${A.postingAccount}") | select(.body|startswith("**Review risk:")) | .id' — if an id comes back, write the map to a temp file and gh api -X PATCH repos/${A.repo}/issues/comments/{id} -F body=@thatfile; else gh pr comment ${item.pr} --body-file thatfile. Never leave two maps on one PR.
2. The risk label, as a replacement: gh pr edit ${item.pr} --add-label "${verdict}" --remove-label "${verdict === 'low-risk' ? 'high-risk' : 'low-risk'}" (removing a label absent from the PR is a no-op; both label strings were preflighted by recon).
3. ${needsQa ? 'The manual-QA flag, as a SECOND separate gh pr edit --add-label call (never remove it).' : 'No manual-QA flag call.'}
4. Read back: gh pr view ${item.pr} --json labels — assert exactly one risk role is present and it is "${verdict}"${needsQa ? ' and the manual-QA flag is present' : ''}. A failed read-back or wrong label state is status "failed", never "applied" — readBackOk false never rides with applied.
5. Return exactly which writes landed (landed: label / comment / qa-flag), commentUrl, commentWas created or edited.`
}

phase('Assess')
const results = await pipeline(
  A.queue,
  (item) =>
    agent(assessPrompt(item), {
      label: `assess:#${item.pr}`,
      phase: 'Assess',
      schema: ASSESS_SCHEMA,
      model: 'sonnet',
    }).then((a) => ({ item, a })),
  (prev, item) => {
    if (!prev || !prev.a) return { item, a: null, g: null }
    const { a } = prev
    if (a.status !== 'assessed' || a.verdict !== 'low-risk') return { item, a, g: null }
    log(`#${item.pr}: low-risk draft verdict -> gate`)
    return agent(gatePrompt(item, a), {
      label: `gate:#${item.pr}`,
      phase: 'Gate',
      schema: GATE_SCHEMA,
      model: 'opus',
      effort: 'high',
    }).then((g) => ({ item, a, g }))
  },
  (prev, item) => {
    if (!prev || !prev.a) return { item, outcome: 'assess-failed' }
    const { a, g } = prev
    if (a.status !== 'assessed') return { item, a, outcome: a.status }
    if (g && g.result === 'skipped-stale') return { item, a, g, outcome: 'skipped-stale' }
    const flipped = g && g.result === 'flipped'
    const verdict = flipped ? 'high-risk' : a.verdict
    const map = g && g.map ? g.map : a.map
    const needsQa = g && typeof g.needsQa === 'boolean' ? g.needsQa : !!a.needsQa
    const needsQaReason = (g && g.needsQaReason) || a.needsQaReason || ''
    log(`#${item.pr}: applying ${verdict}${flipped ? ' (gate flipped)' : ''}${needsQa ? ' + manual-QA flag' : ''}`)
    return agent(applyPrompt(item, verdict, map, needsQa, needsQaReason), {
      label: `apply:#${item.pr}`,
      phase: 'Apply',
      schema: APPLY_SCHEMA,
      model: 'sonnet',
      effort: 'low',
    }).then((ap) => ({ item, a, g, apply: ap, verdict, needsQa, outcome: ap ? ap.status : 'apply-died' }))
  }
)

// Close of run stays with the orchestrator: read every touched PR's labels back
// in one call, assert the one-risk-role invariant, and write the report in the
// order SKILL.md fixes. This script only returns the raw per-item outcomes.
return { results: results.filter(Boolean) }
