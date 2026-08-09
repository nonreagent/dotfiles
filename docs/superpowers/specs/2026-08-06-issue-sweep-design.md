# Issue Sweep — Design

**Prepared for:** @nonrational \
**Author:** Agent Norton (@nonreagent) \
**Date:** 2026-08-06 \
**Status:** Implemented — `overlay/skills/issue-sweep/` \
**Repo:** `nonreagent/dotfiles` (agent-only; exe.dev VM)

## Problem

A queue of triaged, `ready-for-agent` issues costs the maintainer one attended session per item to turn into PRs, while overnight agent capacity sits idle. A naive unattended fan-out produces the wrong artifact: a pile of unreviewed branches the maintainer must re-derive from scratch, which is slower than not running it at all.

## Design

One independent pipeline per issue — plan → build → adversarial review → fix → verify — chained per item with no stage barriers, emitting **reviewed draft PRs**: each PR carries a posted adversarial review, and each blocking finding is either fixed with a regression test proven to fail pre-fix or answered with evidence. The human wakes to reviews, not just diffs. The skill distills a successful unattended overnight run on a private project of the operator's.

Load-bearing decisions:

- **Recon before dispatch.** Dedupe the queue against merged PRs and branches; collect verify commands; for every shared resource (test database, port, rate-limited API) record the override knob plus literal create and drop commands. Dispatching before recon is the most expensive mistake in the pattern.
- **The planner may refuse.** "Sweep each issue" is not "each issue gets a PR". A skip with a comment citing the PRs that already landed is a successful outcome.
- **Per-item isolation and cleanup**, not per-run — a cut-short run leaves no worktrees or scratch databases.
- **The review is a posted PR comment**, not a structured verdict that dies with the run.
- **No `blocking` finding without an empirical repro**; no regression test never watched to fail; no finding marked resolved on the fixer's word — the verifier distrusts the fixer.
- **Per-item chaining, never a stage barrier** — one stalled planner must not cost the whole run.

`references/stage-prompts.md` owns the per-stage prompt recipes, the five output schemas, and the harness contract; `SKILL.md` keeps the judgment.

## Why the overlay layer

`home/` is generated: `build.sh` does `rm -rf home/` and re-materializes it from upstream `nonrational/dotfiles`. A skill hand-committed under `home/.agents/skills/` would be deleted by the next build and never reach the generated `manifest`, so `deploy.sh apply` would never symlink it.

So agent-only skills live in `overlay/skills/<name>/`, and `build.sh` step 3b vendors them into `home/.agents/skills/` alongside the upstream set — the same shape as the existing `overlay/bin/*` step. A name that also exists upstream is a **build error**, not a silent shadow: if a skill graduates to `nonrational/dotfiles`, the build fails until the overlay copy is deleted. README documents the layer.

## Adversarial review record

Two adversarial judges landed twelve must-fixes. All addressed:

| Flagged | Change |
|---|---|
| Skill authored in the generated tree — next build deletes it, never deployed | Moved to `overlay/skills/`, new `build.sh` step, `manifest` regenerated |
| Dispatch mechanism undefined — assumed one harness's `pipeline()` | "How the run is driven" section: the harness contract, plus the file-based fallback (`<scratch>/<issue>/<stage>.json`) when structured output isn't available |
| Control flow after round 1 ambiguous; `partial` / `could-not-fix` / `still-broken` had no handler | Explicit: auto-chain, one fix round, every other state terminal with its own report row |
| Per-item resource isolation unexecutable — "drop the scratch database" with no command | Recon outputs the knob **and** the literal create/drop commands per hazard |
| No concurrency cap — 40 issues meant 40 worktrees | Cap is a recon deliverable (default 4); the remainder is reported, never silently dropped |
| Failure paths stopped at the agent | A `failed` build comments on the issue; no auto-retry; a CI-red fix round runs off the CI log instead of a review comment |
| One repo's e2e policy stated as universal | Rewritten conditionally — follow the repo's documented policy; if CI doesn't run the suite, the build agent does |
| Missing `agents/openai.yaml`, so the invocation guard didn't cross runtimes | Added, with `allow_implicit_invocation: false` matching `triage` |
| Description written as triggers despite `disable-model-invocation` | Rewritten as a one-line statement of what it does; `argument-hint` added |
| Collision with `triage`'s AI-disclaimer rule on tracker comments | Resolved explicitly: provenance disclaimer on the issue tracker, nothing on PRs, co-author trailer on commits |
| Length and 4x restatement of the same safeguards | Per-stage prose cut; `stage-prompts.md` owns the imperatives, `SKILL.md` keeps the judgment plus one reinforcement pass |
| `still-broken` dead-ended | Named as a terminal state with a distinct, hardest-flagged report row |

Smaller ones taken: preflight checks before dispatch, `strong`/`workhorse` grounded in `prudence.md`, default branch not hard-coded to `main`, `gh pr comment` named explicitly (not `gh pr review`), cleanup verified with commands, CI judged once at close of run, absent-skill fallback for `code-review-register`, reviewer handle and commit trailer promoted to recon outputs, branch-name collisions handled at build time.

Deliberately skipped: a sample morning-report table (grows the file for little gain), and dispatching the existing `code-review` skill at the review stage (its two-axis parallel split fits a human-attended review of one branch; the sweep needs a single adversarial pass per PR with a posted comment).

## Verification

`./test/run.sh` — 10 passed, 0 failed, including `test_idempotent` (build twice, diff the tree), `test_manifest_covers_home`, and `test_deploy_apply`. `bash -n build.sh` clean; `shellcheck` reports only the two pre-existing `SC2088` tilde warnings.
