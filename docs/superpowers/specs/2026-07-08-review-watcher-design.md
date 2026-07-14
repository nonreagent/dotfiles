# Review Watcher — Design

**Prepared for:** @nonrational \
**Author:** Agent Norton (@nonreagent) \
**Date:** 2026-07-08 \
**Status:** Approved design — ready for implementation plan \
**Repo:** `nonreagent/dotfiles` (agent-only; exe.dev VM)

## Summary

A watcher that runs on the exe.dev VM and **autonomously reacts to GitHub PR reviews**
on @nonreagent's open pull requests. A cheap bash poll loop detects new reviews; when a
trusted reviewer acts, it spawns a headless Claude Code session (`claude -p`, in its own tmux
session for isolation) that carries out the reaction — address change requests, or merge on
approval.

The detector is token-free. Tokens are spent only when a real, trusted, actionable review
arrives and a reaction session is launched.

## Motivation

This design is drawn from a live session on 2026-07-08 where @nonrational drove exactly this
loop by hand across a private project repo:

- **Approved PRs**: verify mergeable + CI green → wait for pending CI → resolve conflicts when
  `main` moved underneath (keep new work, drop intended deletions) → squash-merge in ascending
  PR order.
- **A changes-requested PR**: the reviewer questioned whether a UI control should exist at all.
  The correct reaction was to **remove** it, not tweak it — a re-scope, not a mechanical edit.
  Then: verify (typecheck/lint), push to the same branch, reply in-thread, retitle the PR,
  re-request review.

The key lesson: reactions need **judgment**, not a fixed script. So each reaction is a full
Claude Code session seeded with a playbook; the watcher's own job is only **detect → dispatch → track**.

**Revised after live test (Task 11):** the original design launched reactions with
`claude --remote-control`, for live-steering. Launched detached inside the reaction tmux session,
its TUI stalled — process state `T`, 0% CPU, the seeded prompt never ran. `--remote-control` needs
an attended interactive TTY; it can't drive an unattended background process. Reactions now launch
**headless** (`claude -p`), which runs the prompt autonomously to completion. Trade-off: no more
live-steering a reaction from claude.ai or a phone — RC is an attended feature. Observability
shifts to the reaction log (`~/.review-watcher/logs/<repo>-pr-<n>.log`; `claude -p` buffers, so it
flushes on completion), `journalctl -u review-watcher` for the supervisor, `tmux -S
~/.review-watcher/tmux.sock attach` for a still-running session, and the PR itself updating. The
tmux **session** per reaction is kept — still useful for isolation and `MAX_CONCURRENT` counting
via `rw_session_name` (`<repo>-pr-<n>`) — it's just no longer an RC window.

## Locked decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Autonomy | **Full.** changes-requested → address & re-request; approved → verify + squash-merge; commented → reply if actionable |
| 2 | Trigger | **Polling** (~45s bash + `gh`; token-free) |
| 3 | Reaction runtime | **Headless (`claude -p`) per reaction**; tmux session kept for isolation + concurrency counting |
| 4 | Trust boundary | **Operator allowlist** (default: `nonrational`). Others → notify-only |
| 5 | Repo scope | **All visible** @nonreagent open PRs (`gh search prs`) |
| 6 | Permission mode | **`bypassPermissions`** (disposable VM, no user data; cheaper + faster than `auto`) |
| 7 | Rollout | **Live from commit one** (no shadow mode; @nonreagent's access is limited) |
| 8 | Lifecycle | **systemd system service** (`User=exedev`, `Restart=always`) supervising a persistent tmux session |
| 9 | Placement | **`overlay/`** (agent-only); scripts on PATH via `home/bin`; runtime state in `~/.review-watcher` |
| 10 | Notifications | **GitHub-native + logs** (re-request/comment/merge already ping; observe via the reaction log + `journalctl`) |

## Architecture

Three components with clean boundaries. Only the third spends tokens.

```
┌─ supervisor  (tmux window 0, systemd-supervised, 0 tokens) ──────────┐
│  loop every $POLL_INTERVAL:                                          │
│    gh search prs --author @nonreagent --state open --json …         │
│    for each non-draft PR:                                            │
│      gh api repos/{owner}/{repo}/pulls/{n}/reviews → latest review   │
│      compare latest review id to state/{owner}__{repo}__{n}.seen     │
│      NEW review? → hand (repo, pr, review) to the dispatcher         │
└──────────────────────────────────────────────────────────────────────┘
                    │ new-review event
                    ▼
┌─ dispatcher  (pure bash, 0 tokens) ─────────────────────────────────┐
│  classify:                                                          │
│    reviewer ∉ allowlist            → NOTIFY, mark seen, stop         │
│    review self-authored (@nonreagent) → ignore, mark seen           │
│    state == commented && !actionable  → NOTIFY, mark seen           │
│    approved | changes_requested (trusted) → REACT                   │
│  guard: per-PR lock held? → skip.  concurrency cap hit? → queue.     │
│  prepare: ensure repo clone, fetch PR branch                        │
│  launch: tmux new-window "pr-{n}" → review-react wrapper            │
└──────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌─ reaction  (claude session — the ONLY token spend) ─────────────────┐
│  cd <repo clone on PR branch>                                       │
│  claude -p "<playbook + PR/review context>"                         │
│         --permission-mode bypassPermissions --verbose               │
│  runs headless to completion; observe via the reaction log,          │
│  journalctl, or tmux attach while still running                      │
│  on exit: mark review seen, release lock, emit outcome              │
└──────────────────────────────────────────────────────────────────────┘
```

### Component boundaries

- **supervisor** (`review-watcher`): the only long-lived process. Enumerates PRs, diffs review
  state, emits events. Knows nothing about *how* to react.
- **dispatcher**: classification + safety gating + process management (locks, cap, clone,
  tmux). Decides *whether* and *where*, never *what*. Folded into `review-watcher` as a function
  or a sibling call — an implementation detail.
- **reaction** (`review-react` → `claude`): the judgment. Given a repo checkout and a seeded
  playbook, it performs the reaction and exits.

## State & dedup

Per-PR state files under `~/.review-watcher/state/`, one per PR
(`{owner}__{repo}__{n}.seen`), each holding the id of the latest **handled** review.

- A review is "handled" (its id written) only **after** the reaction succeeds (or after a
  notify-only classification). A crash mid-reaction leaves the old id, so the next poll retries
  rather than skipping — **at-most-once becomes at-least-once with idempotent reactions** (a
  re-run re-reads current PR state, so re-reacting to an already-addressed review is safe).
- Survives restart/reboot: state is on the persistent disk, so a fresh supervisor never
  re-reacts to reviews it already handled.
- Per-PR **lock** (`~/.review-watcher/locks/{…}.lock`, `flock`): prevents two concurrent
  reactions on the same PR (e.g., a slow reaction still running when the next poll fires).

## The reaction playbook

A versioned markdown file (`~/.review-watcher/playbook.md`) seeded into every reaction session.
The reaction runs inside the repo checkout, so the project's own `CLAUDE.md`, `~/.claude/rules`,
and agent identity load automatically — project-specific verify commands are **discovered, not
hardcoded**.

**Design principle — split enforcement from judgment:**
- **Structural invariants** (trust gate, CI-green gate, locks, kill switch, skip-drafts) are
  enforced in bash. The model is never trusted to self-police them.
- **Judgment** (interpret intent, resolve conflicts, decide if a comment is actionable, when to
  escalate) is instructed in the playbook prompt.

### Branch: `changes_requested`

1. Read the whole picture — PR title/body/diff, the review body **and** inline comments, the
   linked issue.
2. **Interpret intent, don't transcribe it.** Feedback is often a symptom. Understand *why* the
   reviewer objected and re-scope if that's the honest fix (the remove-don't-relabel lesson).
3. Bring the branch current if behind/conflicting (merge `main`, resolve), then make the change.
4. **Verify with the project's own gate** (from `CLAUDE.md` / `justfile`). Never push red.
5. Commit (plain message + `Co-Authored-By` + agent identity), push to the **same branch** —
   iterate on the open PR, never open a new PR per tweak.
6. Reply **in-thread** to the review comment(s) explaining the change.
7. Retitle / rewrite the PR body if the scope changed.
8. **Re-request review** from the reviewer. Then stop — do not merge.

### Branch: `approved`

1. Re-verify: still approved, `mergeable == MERGEABLE`, CI rollup green — **wait/poll if CI is
   pending**.
2. If conflicting/behind: resolve (merge `main`, keep new work / drop intended deletions), push,
   wait for CI.
3. For a related set, merge in **ascending PR number** order. Squash-merge (match the repo's
   detected convention). No `--delete-branch` when repo auto-delete is on.

### Branch: `commented`

Reply only if there's a concrete question/ask; otherwise acknowledge or skip. Fuzziest case →
conservative.

### Escape hatch (identity rule under full autonomy)

If the right action isn't clear, needs a product decision, or would violate the rules — **do not
guess**. Post a clarifying comment, notify, and exit notify-only. "I propose; the human disposes"
survives as the bot knowing its limits.

## Guardrails

Enforced structurally in bash (the model cannot override):

| Guardrail | Behavior |
|-----------|----------|
| Trust gate | Only allowlisted reviewer → REACT; others → notify-only |
| CI-green + mergeable gate | Approved→merge dispatched *and* re-checked only when rollup green + MERGEABLE; never merges red |
| Skip drafts/WIP | Draft PRs ignored |
| Per-PR lock | Never two reactions on one PR |
| Concurrency cap | `$MAX_CONCURRENT` reaction windows (default 2); excess queues |
| Ignore self-reviews | Reviews authored by @nonreagent never trigger |
| Per-reaction timeout | A window running > `$REACTION_TIMEOUT` (default 25m) is killed + flagged |
| Kill switch | `~/.review-watcher/PAUSED` flag **or** `systemctl stop review-watcher` halts dispatch |
| Retry-safe (mark-seen-on-success) | Review id marked seen only after the reaction succeeds — a crash retries rather than drops (see State & dedup) |

### Permission mode

Reactions launch with **`--permission-mode bypassPermissions`** (equivalently
`--dangerously-skip-permissions`): no permission prompts for `git`/`gh`/edit/push/merge, so an
unattended session never stalls.

- Justified by the docs' carve-out ("isolated VMs where Claude Code cannot damage your host") —
  a disposable VM with no user data and a limited-scope `gh` token.
- Cheaper + faster than `auto` (no per-action classifier round-trips).
- The guard is therefore the **structural bash gates + the playbook's judgment rules**, not a
  model-level classifier.
- **Scope the flag per-reaction — never set `permissions.defaultMode` globally**, or interactive
  sessions on the VM would inherit it. (Project `.claude/settings.json` can't grant `auto`
  anyway since v2.1.142; the CLI flag is the clean route.)
- **Bonus:** bypass also skips the per-repo **workspace-trust** dialog, dissolving the "new repo
  first-reaction stalls on trust" gotcha for the all-repos scope. (Verify during implementation.)

## Reaction invocation

Confirmed against Claude Code docs (v2.1.204 on the VM):

```bash
cd "$REPO_CHECKOUT"           # PR branch checked out; loads project CLAUDE.md + rules
timeout "$REACTION_TIMEOUT" claude -p "$(render_playbook "$REPO" "$PR" "$REVIEW")" \
       --permission-mode bypassPermissions --verbose
```

- **Headless (`-p`), not `--remote-control`.** `-p` runs the prompt autonomously to completion and
  exits — no attended TUI, no live-steering. See "Revised after live test" in the Motivation
  section: `--remote-control` needs an attended interactive TTY and stalled when launched detached.
- `--verbose` is intended to stream turn-by-turn progress to stdout, which `review-react` captures
  to the per-PR reaction log; in practice `claude -p`'s output tends to buffer, so the log mostly
  fills in on completion rather than growing live.
- The tmux **session** per reaction survives unchanged — kept for isolation and for
  `MAX_CONCURRENT` counting (`rw_session_name` → `<repo>-pr-<n>`) — it's just a plain headless
  process now, not an RC window.
- Auth: the VM already has a claude.ai **Max** OAuth login; `claude -p` runs under the same
  subscription, no API key / `ANTHROPIC_BASE_URL` needed. Token auto-refreshes.

## Lifecycle & persistence

A **systemd system service** (`/etc/systemd/system/review-watcher.service`, `User=exedev`,
`Restart=always`, `WantedBy=multi-user.target`) — the shape exe.dev documents for its GH-actions
runner — ensures a persistent **tmux session** `review-watcher` exists with the supervisor in
window 0.

- Survives **reboot + disconnect** (systemd) *and* the reaction tmux session is **attachable**
  (`tmux -S ~/.review-watcher/tmux.sock attach`) while a reaction is still running.
- Observability, three ways: `journalctl -u review-watcher` (supervisor), the per-reaction log
  `~/.review-watcher/logs/<repo>-pr-<n>.log` (`claude -p` buffers, so it mostly fills in on
  completion), `tmux attach` (live, while the process is still running).
- The reaction runs headless to completion under `timeout $REACTION_TIMEOUT`; if the VM loses
  network to `api.anthropic.com` mid-run, the reaction just fails/times out like any other API
  call — no separate RC-specific outage window to reason about.

## Placement in the dotfiles

The watcher is **agent-only** (acts as @nonreagent, uses its Max auth, meaningful only on the
VM) → it lives in the **`overlay/`**, not the shared `nonrational/dotfiles` source.

Proposed layout (final file split to be settled in the plan):

- **Scripts** (static, on PATH) → vendored by a new `build.sh` step into `home/bin/`, symlinked
  by `install.sh`:
  - `review-watcher` — supervisor poll loop (+ dispatch).
  - `review-react` — per-PR wrapper: ensure clone, checkout branch, render playbook, launch
    `claude`, record outcome.
  - `setup-review-watcher` — one-time installer: create `~/.review-watcher/`, copy playbook +
    config template, `sudo` install & `systemctl enable --now` the unit.
- **Runtime state** (mutable, never in the repo) → created by the setup script under
  `~/.review-watcher/`: `config`, `playbook.md`, `state/`, `locks/`, `logs/`, `PAUSED` flag.
- **systemd unit + playbook + config template** → shipped in the repo (overlay), installed by
  `setup-review-watcher` (a `sudo cp` + copy, **not** symlinked — keeps runtime writes out of the
  repo and sidesteps the "`install.sh` never touches `~/.config`" rule).
- **build.sh** grows one overlay step; **README** documents the one-time `setup-review-watcher`.

## Configuration

`~/.review-watcher/config` (shell-sourced):

```sh
POLL_INTERVAL=45              # seconds between polls
REVIEWER_ALLOWLIST="nonrational"   # space-separated GitHub logins that may trigger action
MAX_CONCURRENT=2             # max simultaneous reaction windows
REACTION_TIMEOUT=1500        # seconds before a stuck reaction is killed (25m)
# Repo scope is "all visible @nonreagent open PRs" — no config needed.
# DRY_RUN intentionally omitted: rollout is live from commit one.
```

## Notifications (v1)

**GitHub-native + logs**, no new infra:

- The bot's own actions already ping you: re-request-review, a merge, or an in-thread reply all
  generate GitHub notifications.
- notify-only / escalation posts a short comment tagging @nonrational.
- Per-reaction logs on the VM (`~/.review-watcher/logs/<repo>-pr-<n>.log`); `tmux attach` while a
  reaction is still running.

If the GitHub pings prove too quiet, add a phone push (ntfy/Pushover) later. **YAGNI now.**

## Open risks / to resolve in the plan

1. **Workspace-trust under bypass** — confirm `bypassPermissions` truly skips the per-repo trust
   dialog for a freshly cloned repo (expected, but the failure mode is a silently stalled first
   reaction). Fallback: a trust-bootstrap step in `review-react` on first clone.
2. **`gh search prs` latency/pagination** across all visible repos — bound result size; ensure
   pagination doesn't miss PRs.
3. **Reaction tmux session naming collisions** — `pr-{n}` isn't globally unique across repos;
   include the repo (`{repo}-pr-{n}`) so per-PR isolation and `MAX_CONCURRENT` counting don't
   collide across repos.
4. **Reaction idempotency** — verify re-running a reaction after a mid-flight crash can't
   double-comment or double-merge (guard on current PR state at the top of the playbook).
5. **Loop safety** — confirm the bot's own pushes/replies/re-requests don't count as new reviews
   (they don't create review objects) and can't retrigger.
6. **Token budget visibility** — reactions run under the Max subscription; a runaway reaction is
   bounded by `REACTION_TIMEOUT` but not by tokens. Consider surfacing per-reaction cost in logs.

## Out of scope (YAGNI for v1)

- Webhook / near-real-time trigger (polling is enough; ~45s lag is invisible for reviews).
- Shadow/dry-run mode.
- Non-GitHub notification channels.
- Reacting to anything other than PR reviews (issue comments, CI failures, etc.).
- Multi-account / multi-agent orchestration.

## Success criteria

1. A `changes_requested` review by @nonrational on a @nonreagent PR results, unattended, in an
   addressed branch, an in-thread reply, and a re-requested review — the change-request flow,
   automated.
2. An `approved` review by @nonrational results, unattended, in a squash-merge once CI is green
   and the PR is mergeable — conflicts resolved if `main` moved.
3. A review by a non-allowlisted user results in notify-only, no code changes or merges.
4. The watcher survives a VM reboot and does not re-react to already-handled reviews.
5. Any reaction is observable via the reaction log (fills in on completion), `journalctl`, and
   live via `tmux attach` while it's still running.
6. `systemctl stop review-watcher` (or the `PAUSED` flag) halts all new reactions.
