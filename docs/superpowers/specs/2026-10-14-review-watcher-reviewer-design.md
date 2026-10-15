# Review Watcher: Reviewer Sessions and In-Flight Assignment — Design

**Prepared for:** @nonrational \
**Author:** Agent Norton (@nonreagent) \
**Date:** 2026-10-14 \
**Status:** Draft, awaiting review \
**Repo:** `nonreagent/dotfiles` (agent-only; exe.dev VM) \
**Extends:** [`2026-07-08-review-watcher-design.md`](2026-07-08-review-watcher-design.md)

## Summary

Two additions to the review watcher:

1. **In-flight assignment.** While a watcher-launched session works a PR, @nonreagent is that PR's assignee. When the session exits, for any reason, the assignment clears. `assignee:nonreagent` then answers "where is the agent spending effort right now"; every other open PR is waiting on a human.
2. **Reviewer sessions.** When @nonrational requests review from @nonreagent on a PR, the watcher launches a headless session that reviews it and submits exactly one review: **Approve**, or **Request changes** when it finds blockers.

## Motivation

The watcher today reacts only to reviews on PRs @nonreagent authored. Two gaps follow:

- **No visibility into effort.** From GitHub alone, the operator can't tell which PRs have a live agent session on them and which sit idle waiting for review. Assignment is the cheapest signal GitHub already renders in every PR list and filter.
- **No agent reviewer.** The operator wants a second pair of eyes on their own PRs, summoned the same way they'd summon a human reviewer.

## Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Review trigger | **GitHub review request** naming @nonreagent (Reviewers sidebar). @-mentions in comments are out of scope. |
| 2 | Review trust gate | **PR author and requester must both be on `REVIEWER_ALLOWLIST`.** Anything else gets a notify comment. |
| 3 | Reviewer permission mode | **`bypassPermissions`**, same as reactions. Decision 2 means the diff comes from a trusted author, so the session may run the project's test gate. |
| 4 | Review outcome | Exactly one submitted review: Approve (non-blocking notes in the body or inline) or Request changes (blockers only). Never pushes, merges, or edits the branch. |
| 5 | Assignment scope | **Watcher-launched sessions only** (reactions and reviews). Interactive sessions do not assign. |
| 6 | Assignment mechanics | Structural, in the bash wrappers. Assign after taking the lock; unassign from an `EXIT` trap; a per-poll sweep clears assignments a killed wrapper left behind. Touches only @nonreagent, never other assignees. Best-effort. |
| 7 | Placement | Extend the existing supervisor and service. New sibling wrapper `review-pr`; shared helpers in `review-watcher-lib.sh`. |

## Architecture

The three-component split from the original design holds: supervisor detects, dispatcher gates, session judges. The supervisor gains a second pass; the dispatcher gains a second wrapper.

```
┌─ supervisor (review-watcher, every $POLL_INTERVAL) ──────────────────┐
│  pass 1 (existing): PRs authored by @nonreagent → latest review      │
│     → rw_classify → review-react                                     │
│  pass 2 (new):      PRs with @nonreagent as requested reviewer       │
│     → latest review_requested event → rw_classify_request            │
│     → review-pr                                                      │
└──────────────────────────────────────────────────────────────────────┘
          │                                      │
          ▼                                      ▼
┌─ review-react (existing) ─────┐   ┌─ review-pr (new) ─────────────────┐
│ lock → assign → worktree      │   │ lock → assign → worktree          │
│ claude -p playbook.md         │   │ claude -p review-playbook.md      │
│ rw-merge on APPROVED          │   │ verify a review landed            │
│ mark seen                     │   │ mark request seen                 │
│ trap EXIT: unassign, rm wt    │   │ trap EXIT: unassign, rm wt        │
└───────────────────────────────┘   └───────────────────────────────────┘
```

Both passes share one tmux socket, so `MAX_CONCURRENT`, the auth gate, `PAUSED`, and `REACTION_TIMEOUT` cover reviewer sessions without new config.

## Detection and dedup (pass 2)

**Enumerate.** `gh search prs --review-requested "$RW_BOT_LOGIN" --state open --json repository,number,isDraft,author --limit 100`, emitted as TSV in the shape of `rw_open_prs`.

**Identify the request.** For each PR, read the issue timeline (`gh api repos/{o}/{r}/issues/{n}/timeline --paginate`) and take the newest `review_requested` event whose `requested_reviewer.login` is @nonreagent. Emit its `id` and `review_requester.login`. A PR in the search results with no such event (a team request, say) is skipped.

**Dedup key.** The event id, stored in `state/{owner}__{repo}__{n}.review-req`. This file sits beside the existing `.seen` file and never shares it, so a PR could in principle carry both without collision.

**Re-review.** GitHub clears a review request once @nonreagent submits a review. Re-requesting creates a new `review_requested` event with a new id, which the supervisor treats as unseen. "Review it again" therefore needs no extra mechanism.

**Classify** (`rw_classify_request author requester is_draft`, pure bash):

| Condition | Result |
|-----------|--------|
| Draft | `SKIP` (not marked seen; re-evaluated once the PR leaves draft) |
| Author or requester not on the allowlist | `NOTIFY`: comment tagging @nonrational, mark seen |
| Otherwise | `REVIEW` |

Drafts are left unseen, unlike pass 1's `SKIP`, because a request on a draft should fire once the PR is marked ready. The request survives the transition, so the next poll picks it up.

**At-least-once.** The request is marked seen only after `review-pr` confirms a review landed (see below). A crash, timeout, or session that exits without reviewing leaves it unseen, and the next poll retries. This matches the existing model: idempotent sessions, retry over drop.

## Reviewer session (`review-pr`)

Arguments: `owner repo pr request_id requester requested_at` (the request event's `created_at`, used in step 5). Tmux session name: `<repo>-review-<n>` (via a new `rw_review_session_name`), distinct from reactions' `<repo>-pr-<n>`.

Sequence:

1. Take the per-PR `flock` (shared lock path with `review-react`, so no PR ever has two sessions).
2. `rw_assign`; install the `EXIT` trap.
3. Prepare a per-session worktree (see Checkout isolation) on the PR head.
4. Run `timeout "$REACTION_TIMEOUT" claude -p "<rendered review-playbook.md>" --permission-mode bypassPermissions --verbose`, logged to `logs/<repo>-review-<n>.log`.
5. **Verify outcome in bash.** Query `pulls/{n}/reviews` for a review by @nonreagent submitted after the request event's `created_at`, with state `APPROVED` or `CHANGES_REQUESTED`. If found, mark the request seen. If not, log and leave it unseen for retry.

`RW_DRY_RUN=1` prints the `claude` command and exits, as `review-react` does.

### The review playbook

A new `overlay/review-watcher/review-playbook.md`, installed to `~/.review-watcher/review-playbook.md` by `setup-review-watcher`, rendered with `{{REPO}}`, `{{PR}}`, `{{REQUESTER}}`. It instructs the session to:

1. Read the PR title and body, the linked issue, the full diff, and existing review threads (so it doesn't repeat points already raised or resolved).
2. Read the project's own conventions (`CLAUDE.md`, `justfile`, tests) and run its gate where one exists. A red gate is a blocker.
3. Judge against two questions: does the change do what the PR and issue say, and does it break anything or violate the repo's documented standards?
4. Write comments in the `code-review-register` voice.
5. Submit **one** review with `gh pr review` (or `gh api` for inline comments):
   - **Request changes** only for blockers: incorrect behaviour, a red gate, data loss, security exposure, or a spec miss. Name each blocker with its consequence.
   - **Approve** otherwise. Non-blocking suggestions go inline or in the body, marked as optional.
6. Never push, commit, merge, or edit the PR's title, body, or labels.
7. Escape hatch: if the PR can't be judged (too large to read within the timeout, needs a product decision), don't approve. Submit **Request changes** with a body naming what it needs to finish the review, so the outcome stays visible and the request clears.

## In-flight assignment

Two lib helpers:

```bash
rw_assign()   { gh pr edit "$3" --repo "$1/$2" --add-assignee    "$RW_BOT_LOGIN"; }
rw_unassign() { gh pr edit "$3" --repo "$1/$2" --remove-assignee "$RW_BOT_LOGIN"; }
```

Both wrappers call `rw_assign` immediately after the lock succeeds, then `trap 'rw_unassign …; <worktree cleanup>' EXIT`. The trap fires on normal exit, `set -e` failure, and the `timeout` kill of `claude` (which ends the child, not the wrapper). It does not fire if the wrapper itself receives `SIGKILL`, for instance on VM reboot. A **stale-assignment sweep** covers that: at the top of each poll, the supervisor lists open PRs assigned to @nonreagent (`gh search prs --assignee nonreagent --state open`) and unassigns any with no live tmux session under either name (`<repo>-pr-<n>` or `<repo>-review-<n>`).

Rules:

- **Only @nonreagent.** Neither helper touches other assignees.
- **Best-effort.** A failure (no triage rights on the repo, API error) logs one line and continues. Assignment is a status light, never a precondition for the work.
- **Lock first, assign second.** A wrapper that loses the lock race exits without assigning, so a skipped duplicate can't clear the real session's assignment.
- **Merge order.** In `review-react`, the trap's unassign runs after `rw-merge`. Unassigning a merged PR is harmless.

## Checkout isolation

Today `review-react` checks out PRs in one shared clone per repo (`$RW_HOME/repos/<owner>/<repo>`) and `reset --hard`s it on entry. With `MAX_CONCURRENT=2`, two sessions on different PRs in the same repo already share a working tree; reviewer sessions make that likelier.

Both wrappers move to a worktree per session:

1. Ensure the shared clone exists and fetch `origin` plus `pull/<n>/head`.
2. `git -C <clone> worktree add --force --detach "$RW_HOME/worktrees/<repo>-<kind>-<n>" FETCH_HEAD`, where `<kind>` is `pr` or `review`.
3. Reactions then `gh pr checkout` inside the worktree so pushes track the PR branch. Reviews stay detached; they never push.
4. The `EXIT` trap runs `git worktree remove --force` and `git worktree prune`.

The shared clone's working tree is no longer touched, which retires the `reset --hard` / `clean -fd` workaround in `review-react`.

## Configuration

No new keys. `REVIEWER_ALLOWLIST` gates both the review trigger and the PR author. `MAX_CONCURRENT` counts reactions and reviews together.

## Guardrails added

| Guardrail | Behavior |
|-----------|----------|
| Review trust gate | Author and requester both allowlisted, checked in bash before dispatch |
| No writes from reviews | Playbook forbids push, merge, and PR edits; the wrapper never runs `rw-merge` |
| One review per request | Wrapper confirms a review landed before marking seen; GitHub clears the request on submit |
| Shared PR lock | Reactions and reviews share the per-PR `flock`; one session per PR |
| Assignment hygiene | `EXIT` trap plus per-poll stale sweep; touches only @nonreagent |

## Testing

Extend `test/review-watcher.test.sh` (pure functions, no network):

- `rw_classify_request`: draft, untrusted author, untrusted requester, both trusted.
- `rw_review_session_name` and its distinctness from `rw_session_name`.
- `.review-req` seen round trip, and independence from `.seen`.
- `review-pr` under `RW_DRY_RUN=1` prints a `claude -p` command carrying `review-playbook.md` content.
- `rw_render_playbook` substitutes `{{REQUESTER}}`.

`./test/run.sh` stays the gate.

**Live acceptance**, after merge and `setup-review-watcher` re-run:

1. The operator opens a throwaway PR in this repo and requests review from @nonreagent.
2. Within a poll, @nonreagent appears as assignee and a `<repo>-review-<n>` tmux session exists.
3. A review from @nonreagent lands; the assignment clears; the request is gone.
4. Re-requesting review triggers a second pass.
5. A request from a non-allowlisted account (or on a non-allowlisted author's PR) yields a notify comment and no session.

## Success criteria

1. A review request from @nonrational on their own PR produces, unattended, one submitted review from @nonreagent: Approve, or Request changes naming blockers.
2. `assignee:nonreagent` lists exactly the PRs with a live watcher session, within one poll interval.
3. No reviewer session pushes, merges, or edits a PR.
4. A request involving a non-allowlisted author or requester never launches a session.
5. Two concurrent sessions on different PRs in the same repo never touch each other's working tree.
6. Existing reaction behaviour (change requests, approvals, merges) is unchanged apart from assignment and worktrees.

## Risks

1. **Branch protection.** If a repo counts @nonreagent's approval toward required reviews, its Approve can unblock a merge of the operator's PR. Intended or not, the operator should know which repos this applies to.
2. **Review quality on large PRs.** `REACTION_TIMEOUT` (25m) bounds the session. A PR too large to review in that window hits the escape hatch rather than a shallow approval; if that proves common, raise the timeout for reviews.
3. **Timeline pagination cost.** One timeline fetch per requested PR per poll. Requests are few, so this stays cheap; if not, cache by PR `updated_at`.
4. **Stale sweep vs. manual assignment.** If the operator assigns @nonreagent by hand to mean "yours next", the sweep clears it within a poll. Assignment means "in flight" under this design; a different signal (a label) would carry "queued".

## Out of scope

- @-mention triggers in comments.
- Reviewing PRs from non-allowlisted authors (revisit with a read-only reviewer mode).
- Assignment from interactive sessions.
- Reviewer sessions pushing fix-up commits.
