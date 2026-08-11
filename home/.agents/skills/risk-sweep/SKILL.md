---
name: risk-sweep
description: Use when a repo's open-PR queue needs review-risk labels in one run — after an agent fleet opens a batch of PRs, before a maintainer sits down to review, or when pushes have gone stale on existing risk labels.
argument-hint: "Which repo, and any PRs to skip?"
disable-model-invocation: true
---

# Risk Sweep

Run `risk-audit` across every open PR in one unattended pass, so the maintainer sits
down to a queue that already says where their minutes should go.

The output is not a pile of labels. It is a labeled queue plus a **report in proposed
review order** — the `low-risk` stack first with a total-minutes estimate, then each
`high-risk` PR with its one-line reason — and a review map on every assessed PR that
makes the quick reviews actually quick.

**Use when** several PRs are open and unassessed, or pushes have invalidated prior
assessments. **Don't use** to review code (that's a code review — this prices one),
for one contentious PR with the maintainer present (that's `risk-audit`, attended), or
on a repo whose tracker lacks the two risk labels — create those first, or the sweep
has nothing to apply. The mapping doc (`docs/agents/risk-labels.md`) is the durable
form of the label strings and hotspots, not a precondition: recon derives both when
it's absent and says so.

**REQUIRED BACKGROUND:** `risk-audit` defines the roles, the hard triggers, the earn
criteria, the review-map shape, and the label mechanics. This skill parallelizes that
audit; it does not redefine it.

## Reference

- [references/stage-prompts.md](references/stage-prompts.md) — the harness contract,
  per-stage dispatch recipes, and output schemas.

## The pipeline

Each PR flows through these stages independently. Nothing waits on a sibling.

| # | Stage | Model | Writes? | Returns |
|---|-------|-------|---------|---------|
| 1 | Assess | workhorse | nothing | dossier + draft verdict + draft map |
| 2 | Gate — `low-risk` verdicts only | strong | nothing | `upheld` / `flipped` + objection |
| 3 | Apply | workhorse | label swap + **one map comment (edit-in-place)** | `applied` / `failed` |

**Strong** = the top reasoning tier at high effort; **workhorse** = the mid tier (see
`~/.agents/rules/prudence.md` if it's loaded). Name the model on every dispatch or it
inherits the session's.

**Control flow.** A `high-risk` verdict skips the gate and applies directly — the two
mislabelings cost differently, and gate tokens are spent only where a wrong label
invites a rubber-stamped merge. A gate `flipped` verdict applies as `high-risk` with
the objection shipped inside the map, so the maintainer sees *why* the quick-looking
PR isn't. One gate round, never two; the gate may edit the map it upholds, including
its QA decision. **A mid-run push is terminal for that item** — here the sweep
overrides the audit's attended rule ("head moves → start over"): assess, gate, and
apply all stop on a moved head or a no-longer-open PR, the item lands in the report's
exclusions as `pushed-mid-run`, and the next sweep picks it up. The snapshot, not the
stages, decides what is in the queue.

## 0. Recon before you dispatch anything

The orchestrator does this itself, read-only, in the main checkout.

1. **Preflight.** `gh auth status` and label-edit permission; the posting account
   (`gh api user -q .login`) — map lookups and edits key on it, so it rides in the
   shared context block; the default branch (`gh repo view --json defaultBranchRef`);
   the label strings from the mapping doc or matched against `gh label list` — **every
   string the sweep may write (both risk roles and any manual-QA flag) is preflighted
   against the live label list, and both risk labels must exist, else stop and say
   so**; the repo's hotspot paths from the mapping doc, or one derivation pass from
   the repo's docs, done once and passed to every assessor.
2. **The queue, snapshotted.** Open, non-draft PRs with the **full** `headRefOid` —
   never truncate it in the snapshot; the stages equality-check it, and a re-derived or
   padded SHA sends every item to `skipped-stale` (only the map's stamp is short) —
   plus existing risk labels,
   and each PR's existing review-map SHA (parse `assessed at` from the map comment —
   a short SHA, prefix-matched against `headRefOid`). **Skip a PR only when its map
   matches the current head *and* its labels carry exactly one risk role agreeing with
   the map's verdict** — the sweep's idempotency lives here, in that comparison, never
   in harness caching or resume machinery. A current map with wrong or missing labels
   is a half-applied write: route it straight to apply with the existing map text —
   repair, don't re-derive, don't re-post. Excluded rows — drafts, up-to-date PRs, PRs
   that close mid-run — are reported with reasons, never silently dropped.
3. **The file-overlap matrix.** `gh pr diff --name-only` per queued PR, intersected
   pairwise. Hand each assessor the sibling PRs that touch its files: overlapping
   migrations and shared hotspots are exactly the cross-PR ordering hazards a
   single-PR read cannot see.
4. **CI conclusions at each head**, fetched once — don't make ten assessors poll the
   same checks API.
5. **A concurrency cap.** Default 4. Assessment is read-only — no worktrees, no
   dependency installs — so the cap is about API rate limits, not machine headroom.

Order the queue **stalest-assessment-first**: PRs whose labels a push invalidated are
misinformation sitting in front of the maintainer; fresh unassessed PRs merely lack
information.

## The disciplines

- **Assessment is read-only.** No stage checks out code, touches the working tree, or
  waits on pending CI. A check still pending at assess time is recorded as pending —
  and pending is not green, so it resolves high like any other uncertainty.
- **The gate refutes; it does not proofread.** Its brief is "find the reason this PR
  deserves care": re-derive the triggers against the diff, hunt for what the assessor
  discounted as mechanical, check the earn list line by line. A sustained objection
  flips the verdict; a hollow one upholds it. Upheld-with-edits is a normal outcome.
- **The map is the deliverable.** The dossier and the gate's reasoning die with the
  run; what survives is the label and the map, and `risk-audit`'s shape contract binds
  both stages that write map text.
- **Every label write is a replacement, read back.** Exactly one risk role per PR at
  run end — the audit's invariant, enforced at apply time.
- **Verdict flips are the report's headline.** A PR whose label *changed* — push
  invalidated a `low-risk`, or the gate overturned a draft verdict — is where the
  maintainer's mental model is most wrong. Flag those loudest, before the stable rows.
- **A uniform queue is a rubric problem, not a finding.** In a queue of eight or more,
  if ~80% of assessments land on one verdict, the report proposes hotspot-path tuning
  for this repo — never a wholesale loosening of the trigger list — rather than
  presenting uniformity as information. Smaller queues skip the note: at n≤5, one
  verdict class clears 80% by chance, and the axis is deliberately biased high.

## Close the run

- Read every touched PR's labels back; assert the one-risk-role invariant; repair or
  report any miss.
- **Write a report that leads with the proposed review order:** the `low-risk` stack
  first (sorted by the assessors' `semanticLines`, with their summed
  `estimatedMinutes` — "~50 min clears 6 of 10"), then `high-risk` rows each with the
  one-line reason and its map link. Then flips,
  exclusions with reasons, failures with exactly which writes landed (label, comment,
  neither), and the distribution note. The maintainer should know what to open first
  from the first ten lines.
- Before declaring the run done, apply `superpowers:verification-before-completion` —
  every row links the label state or comment that justifies it.

## Red flags — stop

- About to dispatch without the label mapping, the queue snapshot, or the overlap
  matrix.
- A `low-risk` label about to apply that no gate has seen.
- A gate dispatched on a `high-risk` verdict — that budget belongs to the low side.
- A second map comment on any PR, or a map without `assessed at`.
- An assessor checking out code, installing dependencies, or waiting on pending CI.
- A report ordered by PR number instead of review order, or one that buries a flip.
- An excluded PR that appears nowhere in the report.

## Rationalizations

| Excuse | Reality |
|---|---|
| "This one's trivially low, skip the gate" | The gate exists precisely for labels that invite a skim. Trivial-looking is the input, not the proof. |
| "Assess the drafts too, they'll promote soon" | A draft is a PR its own author hasn't vouched for. Assess it when it promotes — the SHA check makes that cheap. |
| "Its map is one commit stale; close enough" | One commit is how the last hazard arrived. Stale is stale; re-assess or skip it explicitly. |
| "Re-assess everything, freshness is free" | Up-to-date maps are skipped by SHA. Re-deriving them burns the run's budget to change nothing. |
| "Editing comments is fiddly, post a new one" | Two maps means neither is authoritative. Find yours by marker and author; edit in place. |
| "Everything came back high-risk — accurate!" | Maybe — but say so as a distribution note and propose threshold changes. A signal that never varies isn't one. |
| "The queue is huge, raise the cap to 12" | Twelve read-only assessors against one API rate limit. Cap it; the remainder appears as not-attempted. |
