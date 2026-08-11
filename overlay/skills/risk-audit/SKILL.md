---
name: risk-audit
description: Use when deciding how much human review attention an open PR needs — before merging, when a maintainer asks "is this safe to review quickly?", when a PR queue needs review-risk labels, or when a risk label looks stale after a push.
argument-hint: "Which PR?"
disable-model-invocation: true
---

# Risk Audit

Assess one open PR and label how much human review attention it needs. The output is a
**risk label** plus a **review map** — a short, fixed-shape PR comment that tells the
maintainer where to spend their minutes and lets them verify the verdict instead of
trusting it. `risk-sweep` runs this across a whole queue; this skill defines the axis.

The point is triage of *attention*, not judgment of *quality*. A beautifully built
migration is still `high-risk`; a scrappy one-line copy fix is still `low-risk`. The
label prices the review, it does not grade the author.

## The axis

Two canonical roles, an orthogonal manual-QA flag, and a meaningful absence:

- **`high-risk`** — needs deep review: block out time, read whole files, maybe run it.
  The **default** under any trigger or any uncertainty.
- **`low-risk`** — a quick review suffices: read the map, spot-check the focus files,
  check CI, merge. **Earned against the criteria below, never defaulted.**
- The repo's **manual-QA flag** (if its mapping doc names one) is orthogonal and
  composes with either role. The audit may *add* it when the diff changes user-visible
  behavior no test in the PR covers; it never removes one a human set.
- **No risk label = not assessed at the current head.** An assessment is of a SHA. The
  map records it; a push invalidates the label until the next audit.

Exactly one risk role per PR after an audit: apply as a **replacement** (remove the
other role, add the verdict), then read the labels back and assert the invariant.

**Per-repo mapping.** The skill speaks canonical names; the repo pins its actual label
strings and its hotspot paths (which directories count as migrations, auth, deploy
config, external contracts) in `docs/agents/risk-labels.md`, alongside its
`triage-labels.md`. **The labels must exist on the tracker; the doc is the durable
form, not a precondition.** No mapping doc → match label strings against the live
label list (`gh label list`), derive the hotspots from the repo's own docs
(conventions file, deploy config, migration directory), add a **Mapping:** line to the
map naming the source — and when you can write to the repo, record the derivation into
`docs/agents/risk-labels.md` so the next audit reads instead of re-deriving.

## Hard triggers — any one forces `high-risk`

1. **Schema migrations, seeders, or irreversible / bulk data mutation.** Size is
   irrelevant: a 3-line constraint change outranks a 400-line UI diff, and migration
   *ordering* against sibling PRs is part of the hazard.
2. **AuthN/authZ, session, or access-control changes.**
3. **Deploy, CI, or build config; env-var contract changes.**
4. **External contracts** — third-party API clients, public endpoint shapes, webhooks.
5. **New runtime dependency or major version bump.**
6. **Concurrency, transactions, or locking.**
7. **Semantic diff too large for one careful read** — soft threshold ~400 semantic
   lines or ~10 non-mechanical files, *after* the mechanical discount (below).
8. **Unhealthy PR signals** — red CI at head, unresolved blocking self-review findings,
   a disputed fix round, a PR body admitting untested paths, or an approval that
   predates the current head (approvals are of a SHA too — compare, and name staleness
   in the map). The untested-path clause reads on the change's **core logic** — data
   writes, concurrency, contracts. A user-visible change lacking only render or
   click-through coverage is the manual-QA flag's business, not this trigger's;
   collapsing the two would make every UI change high-risk and the flag meaningless.

**The mechanical discount.** Lockfiles, generated files, formatter fallout, mechanical
renames, and snapshot updates don't count toward trigger 7 — but they are skimmed, not
ignored: name them in **Skim** with one spot-check each, since "generated" is a claim
the diff can fake.

## `low-risk` requires all of

- No hard trigger fires.
- The semantic surface holds in one read.
- Behavior changes are covered by tests in the diff — or there is no behavior change.
- CI is green at the assessed SHA.
- Self-review (posted review comments, open threads) is clean or minor-only, nothing
  unresolved.

Anything you cannot determine resolves **high**, and the map says what was
undeterminable. Uncertainty is not a tiebreak — it is the definition of `high-risk`.
And *undeterminable* means the evidence cannot be had read-only — not that you didn't
look. Nothing on the earn list may rest on an unchecked claim: a checkable uncertainty
gets checked, or the verdict is high.

## Process

1. **Pin the snapshot.** Record the head SHA first (`gh pr view --json headRefOid`).
   Everything is assessed against it; if the head moves mid-audit, start over.
2. **Gather, read-only.** PR body and comments, review threads and their resolution
   state, the diff, CI conclusions at head, existing labels, and any sibling-PR file
   overlap the orchestrator handed you. Nothing is checked out; the working tree stays
   untouched.
3. **Classify the diff.** Split mechanical from semantic; map semantic files against
   the repo's hotspot list.
4. **Apply the triggers**, in order. Note every one that fires, not just the first —
   the map reports them all.
5. **Earn or deny `low-risk`.** Walk the all-of list explicitly.
6. **Decide the manual-QA flag**, if the mapping doc names one.
7. **Write the review map** (shape below) and post it — or **edit the existing map in
   place**. One map per PR, ever: find yours by the `Review risk:` marker and your own
   account as author; never post a second.
8. **Apply the label as a replacement**, read back, assert exactly one risk role.

Green CI is evidence, not a verdict: CI runs from a fresh database and a clean
checkout, so it structurally cannot see out-of-order migrations, stale approvals, or
production data shape. On a `high-risk` map, say what the suite cannot see about this
change; that sentence is often the most useful one in the review.

## The review map

The map is a contract, not an essay. It is these parts, in this order, and nothing
else — a maintainer should absorb it in ten seconds. No AI-attribution lines, badges,
or session links; the posting account is the provenance. The `assessed at` stamp is
the 7-char short SHA; anything comparing it to a live head (a sweep's recon, your own
re-audit) matches it as a prefix of the full `headRefOid`.

```markdown
**Review risk: high** · assessed at `4539215`

Effort: deep (30+ min). Migration + cross-PR ordering + stale approval.

**Why:** constraint migration (`database/migrations/…`) whose file-timestamp order
diverges from deploy order against #NN; approval predates head by one commit.
**Focus:** read `up()`/`down()` against #NN's migration text, then the ordering
argument in the PR body — in that order.
**Skim:** comment updates in 2 files; snapshot fallout (spot-checked one).
**QA:** not needed — no user-visible behavior change.
**CI:** green at head, but a fresh-DB suite cannot exercise the applied-out-of-order
path this PR exists to survive.
**Self-review:** clean; the prior approval is stale (pre-dates the ordering fix).
```

A `low-risk` map is the same shape with `Effort: quick (~10 min)`, **Why** replaced by
the earn line ("no triggers; behavior change is `<file>` only, regression-tested"), and
**Focus** naming the one or two hunks that carry behavior. Omit a line only when its
subject genuinely does not exist (no QA flag in the repo, say); never omit **Focus**,
**CI**, or the assessed SHA. Two optional lines join the shape only when their subject
exists: **Overlap:** when a sweep's matrix handed you sibling PRs touching the same
files, and **Mapping:** when the hotspots were derived rather than read from the
repo's mapping doc.

## Red flags — stop

- A verdict with no head SHA pinned, or a map without `assessed at`.
- A `low-risk` about to ship on any fired trigger, "because the trigger part is small".
- "Couldn't determine X" followed by anything but `high-risk`.
- A second map comment about to post instead of an edit.
- A label added without removing the other role, or never read back.
- A map longer than the diff deserves — an essay where the shape should be.
- Removing a manual-QA flag, or grading code quality instead of pricing attention.

## Rationalizations

| Excuse | Reality |
|---|---|
| "163 lines, obviously quick" | A 163-line PR can hide a constraint migration with a deploy-ordering hazard. Size is one criterion; triggers outrank it. |
| "CI is green" | A fresh-DB suite can't see out-of-order migrations, stale approvals, or prod data shape. Evidence, not verdict. |
| "It already has an approval" | Approvals are of a SHA. Compare it to head; a post-approval push voids it. |
| "Self-review came back clean" | Clean review ≠ low risk. Triggers price blast radius, not defect count. |
| "I can't verify that claim, but it's plausible" | Undeterminable resolves high, and the map says so. |
| "Calling this high-risk insults good work" | The label prices the review, not the author. Say so in the map if it helps. |
| "This deserves a thorough write-up" | The essay buries the verdict. Dossier detail beyond the map's shape dies with the audit. |
