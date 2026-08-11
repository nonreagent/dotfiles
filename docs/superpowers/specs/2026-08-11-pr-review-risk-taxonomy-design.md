# PR Review-Risk Taxonomy — Design

**Prepared for:** @nonrational \
**Author:** Agent Norton (@nonreagent) \
**Date:** 2026-08-11 \
**Status:** Approved design \
**Repo:** `nonreagent/dotfiles` (agent-only; exe.dev VM)

## Problem

Agent fleets (`issue-sweep`, attended sessions) produce open PRs faster than a maintainer
reviews them. The queue arrives undifferentiated: a 150-line guard tweak with a regression
test sits next to a 2,500-line change with schema migrations, and nothing on the PR list
says which is which. The maintainer either spends deep-review attention on everything
(slow) or skims everything (dangerous). Review time, not implementation time, is now the
bottleneck — and the existing label vocabulary covers issue triage, not review effort.

## Design

A third, PR-only label axis alongside category (`bug`/`enhancement`) and state
(`needs-*`/`ready-*`): **review risk**, with two canonical roles.

- `high-risk` — needs deep human review: block out time, read whole files, maybe run it.
  The **default** under any trigger or any uncertainty.
- `low-risk` — a quick review suffices: read the review map, spot-check the focus files,
  check CI, merge. **Earned, never defaulted.**

A repo's existing manual-QA flag (e.g. `needs-qa`) stays orthogonal and composes with
either role. No risk label means *not assessed at the current head*: an assessment is of
a SHA, recorded in the PR's review-map comment, and a push invalidates the label until
the next audit.

Two skills carry the design, mirroring the `triage` / `triage-sweep` split:

- **`risk-audit`** (base): defines the roles, the hard triggers, the earn-criteria, and
  the review-map comment; audits one PR, attended or dispatched.
- **`risk-sweep`** (parallelizer): recon → per-PR assess → adversarial gate on `low-risk`
  verdicts only → apply; one report in proposed review order. No worktrees — nothing
  checks out code.

### Why the asymmetry

The two mislabelings cost differently. A wrong `low-risk` invites a rubber-stamped bad
merge; a wrong `high-risk` wastes minutes of maintainer skepticism. So uncertainty
resolves high, `low-risk` must be earned against explicit criteria, and the sweep spends
its adversarial-gate tokens only where a wrong label is expensive. The failure mode this
must survive is label inflation in the safe direction: if the rubric over-triggers and
everything lands `high-risk`, the signal dies — the close-of-run report is required to
say so rather than present a uniform queue as information.

### Hard triggers — any one forces `high-risk`

1. Schema migrations, seeders, or irreversible / bulk data mutation
2. AuthN/authZ, session, or access-control changes
3. Deploy, CI, or build config; env-var contract changes
4. External contracts: third-party API clients, public endpoint shapes, webhooks
5. New runtime dependency or major version bump
6. Concurrency, transaction, or locking logic
7. Semantic diff too large for one careful read (soft threshold ~400 semantic lines or
   ~10 non-mechanical files, after discounting lockfiles, generated files, formatter
   fallout, mechanical renames, snapshots)
8. Unhealthy PR signals: red CI at head, unresolved blocking self-review findings, a
   disputed fix round, a PR body admitting untested paths (in the change's core logic —
   render-coverage gaps route to the manual-QA flag instead), or an approval that
   predates the current head

### `low-risk` requires all of

- No hard triggers
- Semantic surface holds in one read
- Behavior changes covered by tests in the diff (or no behavior change)
- CI green at the assessed SHA
- Self-review clean or minor-only, with no unresolved threads

### The review map

One comment per PR, ever — edited in place on re-assessment. It carries: verdict,
assessed SHA, effort class (quick ~10 min / deep 30+ min) with its drivers, **focus**
(the files and hunks that carry behavior), **skim** (what is mechanical), and CI /
self-review state. It is what makes a low-risk review actually quick, and it lets the
maintainer verify the claim instead of trusting it. Per the PR-side attribution rule
(`issue-sweep` precedent): no AI-attribution footers.

### Decisions fixed by the operator up front

1. **Binary labels, `low-risk` / `high-risk`** — not three tiers (medium becomes the
   dumping ground), not effort-named labels. Nuance lives in the review map.
2. **Review map on every PR**, edited in place — not high-risk-only, not report-only.
3. **Placement: overlay-first.** Develop in `overlay/skills/`, graduate upstream once
   proven on real sweeps — the path `issue-sweep` and `triage-sweep` took.
4. **Sweep scope:** drafts are skipped and reported as excluded; the audit may *add* the
   repo's manual-QA flag when user-visible behavior lacks test coverage, and never
   removes one; the adversarial gate runs on `low-risk` verdicts only.

### Per-repo mapping

The skills speak canonical role names and generic trigger classes. Each target repo pins
its actual label strings and its hotspot paths (which directories count as migrations,
auth, deploy config, external contracts) in `docs/agents/risk-labels.md`, following the
existing `triage-labels.md` convention. No mapping doc → the audit derives hotspots from
the repo's own docs and says so in the review map.

### `risk-sweep` shape

- **Recon** (orchestrator, read-only): `gh` auth + label permission; both labels exist
  (else stop); mapping doc or one-time hotspot derivation; queue snapshot of open
  non-draft PRs with head SHAs; PRs whose existing review map matches the current head
  are skipped as up-to-date. Exclusions are reported, never silently dropped.
  Concurrency cap defaults to 4.
- **Pipeline per PR**, chained, no stage barriers: assess (workhorse, read-only dossier +
  draft verdict + draft review map) → gate (strong tier, `low-risk` only: re-derive
  adversarially; a sustained objection flips the verdict and the objection ships in the
  review map) → apply (comment post/edit, label swap read back and asserted, manual-QA
  flag if earned).
- **Close of run:** labels read back; report leads with the queue in proposed review
  order — the `low-risk` stack first with a total-minutes estimate, then `high-risk`
  each with its one-line reason. Verdict flips after a push are flagged loudest;
  a near-uniform `high-risk` queue is called out as rubric recalibration, not signal.

## Test record

**RED baselines** (no skill): two subagents assessed live PRs in a private target repo —
one a small constraint-migration PR, one a ~430-line transactional state-machine change.
Both reached sound `high-risk` verdicts, which located the real failure: not judgment,
but *shape and consistency* — no assessed-at SHA, essay-length comments with the verdict
buried, criteria invented ad hoc per agent, and no label mechanics at all. One probe
independently discovered a stale approval (approved SHA ≠ head), which was promoted into
trigger 8. The smaller PR also proved the size heuristic worthless on its own: 163 lines
hiding a migration with a cross-PR deploy-ordering hazard.

**GREEN runs** (with the skill, dry-run): three assessors on the same queue. Shape held
on all three — SHA pinned, triggers cited by number, earn checklist walked, CI
blind-spots named. One PR earned `low-risk` while composing with the manual-QA flag; the
strong-tier gate then **upheld** it adversarially, resolving both uncertainties the
assessor had left open and catching a behind-main migration the assessor missed. Two
rules were written directly from that gate run: *unchecked is not undeterminable* (a
checkable claim must be checked before `low-risk` is earned), and the optional
**Overlap:** / **Mapping:** map lines the gate had to invent.

## Adversarial review record

Two-lens judge pass on the drafts (operational executability, strong tier; conventions
and integration, mid tier): 3 must-fixes, 9 should-fixes, 5 nits — all merged. The
conventions lens also verified the privacy scrub: no private-repo identifiers in any
shipped file.

| Flagged | Change |
|---|---|
| Mapping-doc precondition contradicted the audit's derive-fallback — the flagship target repo would have failed it | Labels-exist is the hard stop; the doc is the durable form. Recon derives strings from `gh label list` and hotspots from repo docs, and the map discloses the derivation |
| Edit-in-place had no working comment-id path (GraphQL node ids 404 the REST PATCH) and "the posting account" was never collected | Literal id-lookup + PATCH pair in the apply recipe; posting account added to recon preflight and the shared context block |
| The SHA skip made half-applied writes permanent (map landed, label failed → skipped forever) | Skip only when map SHA matches head *and* labels agree with the verdict; mismatches route to apply as repair, not re-derivation |
| Short-vs-full SHA comparison could never match | `assessed at` is the 7-char short SHA, prefix-matched against `headRefOid` |
| Strict schema forced a stale/failed assessor to fabricate a verdict and map | Only `status` unconditionally required; per-status conditional requirements documented |
| Mid-run push: audit said "start over", stage said "stop", and neither state had a report route | The sweep explicitly overrides the audit's attended rule; `pushed-mid-run` exclusion row; the gate got its own currency check |
| The report's headline numbers weren't derivable from any schema field | `semanticLines` and `estimatedMinutes` added to the assess schema; gate may revise |
| The gate couldn't revise the QA decision a flip usually changes | Optional `needsQa` on the gate schema supersedes the assessor's |
| Two named reads don't exist as written (`--json reviewThreads`; `gh pr diff` reads the live head) | GraphQL `reviewThreads{isResolved}` query; diff pinned via `compare/{base}...{sha}`; head re-checked after reading |
| `gh pr edit` is atomic, so a bad QA string would drop the risk label with it | QA flag applied as a second, separate edit; all writable strings preflighted in recon |
| Distribution note fired on tiny queues, recommending loosening a deliberately safety-biased rubric unattended | n ≥ 8 floor; proposals scoped to hotspot tuning, never wholesale trigger loosening |
| Trigger 8's untested-path clause could swallow the manual-QA flag (the gate had to derive the boundary itself) | Core-logic scope written into trigger 8; render/click-through gaps route to the flag |
| No `agents/openai.yaml`, so the other harness would allow implicit invocation both skills forbid | Added to both skills, mirroring the fleet's shape |
