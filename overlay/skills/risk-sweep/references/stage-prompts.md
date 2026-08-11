# Stage prompts and output schemas

Recipes, not templates. Each stage's dispatch prompt contains the listed parts, in order.

Everything recon learned goes in a **shared context block** reused by every prompt: repo
path, default branch, the posting account (`gh api user -q .login` — comment lookups and
edits key on it), the label mapping (actual strings for both risk roles and the
manual-QA flag, if any — every one preflighted against `gh label list`), the hotspot
paths and where they came from, the read-only rule (no checkouts, no installs, no writes
to the working tree), and the attribution rule (no AI-attribution lines, badges, or
session links on PR comments; the posting account is the provenance). Machine-wide
conventions are restated on purpose: a dispatched agent may run under a harness that
never loaded this machine's rule set.

## Harness notes

- The schemas below are JSON Schema, passed as the harness's structured-output spec.
  **If the harness has no structured output**, append to each prompt: write this JSON as
  the last action to `<scratch>/<pr>/<stage>.json`, and have the orchestrator read the
  file.
- Harness arguments arrive either as an object or as a JSON string; parse defensively
  (`typeof args === 'string' ? JSON.parse(args) : args`).
- Do not rely on workflow resume/caching for idempotency — resumed runs have re-fired
  "cached" stages and re-posted comments. The `assessed at` SHA comparison in recon is
  the only skip mechanism.

## 1. Assess

**Prompt parts, in order:**

1. Role: price the human review attention PR #N needs, for a maintainer who will trust
   the label. The full text of `risk-audit`'s trigger list, earn criteria, mechanical
   discount, and map shape — pasted in from `../risk-audit/SKILL.md` (the sibling skill
   directory, wherever this skill set is installed), since the dispatched agent may not
   have the skill available.
2. Shared context block.
3. The PR number, its head SHA as recon pinned it, recon's CI conclusions for that head,
   and the sibling PRs from the overlap matrix with the shared paths listed.
4. How to read, with the reads that actually exist: `gh pr view` for body and comments;
   thread resolution via GraphQL — `reviewThreads(first: 100) { nodes { isResolved } }`
   — because `gh pr view --json reviewThreads` is not a field; approval currency via
   `gh pr view --json reviews` (`reviews[].commit.oid` against the pinned SHA); the
   diff **pinned** via `gh api repos/{o}/{r}/compare/{base}...{pinnedSha}`, because
   `gh pr diff` reads the live head; whole-file context via `gh api` raw reads at the
   pinned SHA — never a checkout. Re-check `headRefOid` after reading, not only
   before: a push between pin and read otherwise yields a map stamped with the old SHA
   describing new code. If the PR is no longer open (merged or closed since recon), or
   the live head no longer matches the pinned SHA at either check, stop and return
   `skipped-stale` — the snapshot, not the assessor, decides what is in the queue.
5. Classify mechanical vs semantic; map semantic files against the hotspots; apply every
   trigger; walk the earn list explicitly; decide the manual-QA flag only if the mapping
   doc names one.
6. Anything undeterminable resolves `high`, named in `uncertainties` and reflected in
   the map text.
7. Draft the review map exactly in the audit's shape, `assessed at` the pinned SHA.

Only `status` is unconditionally required — a stage that stops on `skipped-stale` or
`failed` must not be forced to fabricate a verdict or a map for a SHA it never read.
When `status` is `assessed`, all of `verdict`, `assessedSha`, `effort`, `triggersFired`,
`earnChecklist`, `semanticLines`, `estimatedMinutes`, and `map` are required, and the
orchestrator routes on `status` first, `verdict` second.

```json
{
  "type": "object",
  "required": ["status"],
  "properties": {
    "status":           { "enum": ["assessed", "skipped-stale", "failed"] },
    "verdict":          { "enum": ["low-risk", "high-risk"] },
    "assessedSha":      { "type": "string" },
    "effort":           { "enum": ["quick", "deep"] },
    "triggersFired":    { "type": "array", "items": { "type": "string" } },
    "earnChecklist":    { "type": "object", "description": "exactly these keys: noTriggers, oneRead, testsCoverBehavior, ciGreen, selfReviewClean -> pass/fail/unknown" },
    "semanticLines":    { "type": "number", "description": "post-discount semantic line count; the report sorts on it" },
    "estimatedMinutes": { "type": "number", "description": "review-minutes estimate; the report sums it" },
    "needsQa":          { "type": "boolean" },
    "needsQaReason":    { "type": "string" },
    "map":              { "type": "string", "description": "the review-map comment, exactly in the audit's shape" },
    "uncertainties":    { "type": "array", "items": { "type": "string" } },
    "dossier":          { "type": "string", "description": "evidence beyond the map: discounted files, sibling overlaps checked, stale-approval math" },
    "failReason":       { "type": "string" }
  }
}
```

## 2. Gate — dispatched only for `low-risk` verdicts

**Prompt parts, in order:**

1. Role: refute the claim that PR #N is safe to review quickly. You are not proofreading
   the assessment — you are hunting for the reason it is wrong. The same pasted audit
   criteria as stage 1.
2. Shared context block; the assessor's full output, dossier included.
3. First, currency: if the PR is no longer open or its head no longer matches the
   assessed SHA, stop and return `skipped-stale` — don't gate a verdict about code
   that no longer exists.
4. Re-derive, don't re-read: apply the triggers against the diff yourself; inspect what
   the assessor discounted as mechanical (spot-check the "generated" claim); walk the
   earn list line by line — **a `low-risk` verdict arriving without its earn checklist
   is an automatic flip**; check the approval-currency math against the head SHA.
5. A sustained objection — a named trigger, a failed earn criterion, an undeterminable
   or *unchecked* claim the assessor glossed — returns `flipped` with the objection in
   one paragraph and a rewritten map (verdict `high-risk`, the objection as the
   **Why** line). A hollow objection upholds; upholding with small map edits is a
   normal outcome, and the gate may revise the QA decision either way.
6. Nothing posts from this stage.

`objection` is required when `result` is `flipped`; `needsQa`/`needsQaReason`, when
present, supersede the assessor's.

```json
{
  "type": "object",
  "required": ["result"],
  "properties": {
    "result":        { "enum": ["upheld", "flipped", "skipped-stale"] },
    "objection":     { "type": "string", "description": "required when flipped: the one-paragraph reason" },
    "map":           { "type": "string", "description": "the map to apply — edited or rewritten; required unless skipped-stale" },
    "needsQa":       { "type": "boolean", "description": "optional revision; supersedes the assessor's decision" },
    "needsQaReason": { "type": "string" }
  }
}
```

## 3. Apply

**Prompt parts, in order:**

1. Role: land the verdict for PR #N — label and map, nothing else.
2. Shared context block; the final verdict, the final map text, and the manual-QA
   decision — the gate's when it revised one, else the assessor's.
3. If the PR's head no longer matches the assessed SHA, or the PR closed or merged,
   write nothing and return `skipped-stale`.
4. **The map comment, edit-in-place**, with the REST ids the PATCH accepts (the
   GraphQL node ids `gh pr view` returns will 404 it):
   `gh api repos/{o}/{r}/issues/{n}/comments --jq '.[] | select(.user.login=="<posting account>") | select(.body|startswith("**Review risk:")) | .id'`
   — if an id comes back, `gh api -X PATCH repos/{o}/{r}/issues/comments/{id} -f body=@-`;
   else `gh pr comment`. Never leave two maps on one PR.
5. **The label, as a replacement:** one `gh pr edit` with `--add-label` for the verdict
   and `--remove-label` for the other role. The manual-QA flag, if decided, is a
   **second, separate** `gh pr edit` — the call is atomic, and a bad QA string must
   not take the risk label down with it (never remove the flag). Read the labels back
   and assert exactly one risk role: a failed read-back or a wrong label state is a
   `failed` item, not a shrug — `readBackOk: false` never rides with `applied`.
6. Return exactly which writes landed, so a failure is repairable rather than
   re-derivable.

```json
{
  "type": "object",
  "required": ["status"],
  "properties": {
    "status":      { "enum": ["applied", "skipped-stale", "failed"] },
    "labelBefore": { "type": "string" },
    "labelAfter":  { "type": "string" },
    "commentUrl":  { "type": "string" },
    "commentWas":  { "enum": ["created", "edited"] },
    "readBackOk":  { "type": "boolean" },
    "landed":      { "type": "array", "items": { "enum": ["label", "comment", "qa-flag"] } },
    "failReason":  { "type": "string" }
  }
}
```

## Close of run

The orchestrator, not a stage: re-list the queue's labels in one `gh pr list --json`
call; assert every applied row still holds its verdict and one risk role; then write the
report in the order the sweep skill fixes — review order first (sorted by
`semanticLines`, minutes summed from `estimatedMinutes`), flips before stable rows,
exclusions (including every `skipped-stale` item as `pushed-mid-run` or
`closed-mid-run`) and failures with reasons, the distribution note last. Every row links
its map comment or names the missing write.
