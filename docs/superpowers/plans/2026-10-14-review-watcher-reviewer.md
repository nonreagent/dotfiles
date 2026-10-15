# Review Watcher Reviewer Sessions and In-Flight Assignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the review watcher to assign @nonreagent to a PR only while a watcher session works it, and to review PRs where @nonrational requests @nonreagent's review.

**Architecture:** The bash supervisor (`review-watcher`) gains a stale-assignment sweep and a second detection pass over review requests. A new wrapper, `review-pr`, mirrors `review-react`: lock, assign, per-session git worktree, headless `claude -p` with a review playbook, then a bash check that a review landed. Both wrappers clean up (unassign, remove worktree) from an `EXIT` trap.

**Tech Stack:** bash, `gh` CLI, `jq`, `git worktree`, `flock`, `tmux`, `claude -p`.

**Spec:** `docs/superpowers/specs/2026-10-14-review-watcher-reviewer-design.md` (extends `docs/superpowers/specs/2026-07-08-review-watcher-design.md`).

## Global Constraints

- Work in the worktree `.worktrees/review-watcher-reviewer` on branch `review-watcher-reviewer`. Never switch branches in `~/.dotfiles` itself: its `home/` is the live config.
- Edit only `overlay/`, `test/`, `README.md`, and `docs/`. `home/` and `manifest` are generated: regenerate them with `./build.sh` and commit them in the same commit as the overlay change they reflect.
- Fast loop: `bash test/review-watcher.test.sh`. The gate before every commit: `./test/run.sh` (it runs the fast suite plus build idempotency, manifest, secrets, and install checks; it clones upstream, so it needs network).
- Commit messages: plain descriptive subject, no Conventional Commit prefix, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (or the implementing model's name).
- `review-watcher-lib.sh` stays side-effect free at source time: functions only.
- Scripts keep `set -euo pipefail` (wrappers) / `set -uo pipefail` (supervisor) as they have today.
- Bot login comes from `$RW_BOT_LOGIN` (default `nonreagent`); never hardcode it in new lib code. Notify comments tag `@nonrational`, matching the existing `NOTIFY` comment.
- Comments describe why, not what.

## Review Focus

1. **tmux prefix matching.** `tmux has-session -t myrepo-pr-1` matches a live `myrepo-pr-13`, so a dead session reads as alive (sweep skips a stale assignment; dispatch skips a real PR). Every `has-session` target must use the exact-match form `=<name>`. Test lands in Task 3.
2. **A stale worktree at the session's own path** (wrapper killed by a reboot) must not block the next session on that PR. Test lands in Task 1.
3. **Hangup from `tmux kill-session`** must still unassign and remove the worktree. Test lands in Task 2.
4. **An older review from @nonreagent** (from a previous request round) must not count as the review for a new request. Test lands in Task 4.
5. **A team review request** (no `review_requested` event naming @nonreagent) must be skipped, not crash the poll. Test lands in Task 4.

## Commit series

0. `latest from upstream` (only if the build pulls drift; goes to `main`, not this branch)
1. Give each review-watcher session its own worktree
2. Assign @nonreagent to PRs while a watcher session works them
3. Clear stale watcher assignments and match tmux sessions exactly
4. Detect review requests for @nonreagent
5. Add review-pr, the watcher's reviewer session
6. Dispatch reviewer sessions from the watcher

---

### Task 0: Take upstream drift onto main first

The build clones upstream fresh, so the first build on this branch may pull upstream changes unrelated to this work. Those go to `main` on their own.

**Files:** none edited by hand.

- [ ] **Step 1: Build on the branch and look for drift**

```bash
cd ~/.dotfiles/.worktrees/review-watcher-reviewer
./build.sh >/dev/null && git status --short home manifest
```

Expected: no output. If no output, skip to Task 1.

- [ ] **Step 2 (only if Step 1 printed changes): commit drift to main**

Drift belongs on `main` as its own `latest from upstream` commit, never on this branch. Do not stash.

```bash
git checkout -- home manifest && git clean -fdq home          # drop the probe build
git -C ~/.dotfiles worktree add --detach ~/.dotfiles/.worktrees/drift origin/main
cd ~/.dotfiles/.worktrees/drift
./build.sh >/dev/null && ./test/run.sh | tail -1               # expect "0 failed"
git add home manifest
git commit -m "latest from upstream

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push origin HEAD:main
cd ~/.dotfiles/.worktrees/review-watcher-reviewer
git -C ~/.dotfiles worktree remove ~/.dotfiles/.worktrees/drift
git fetch -q origin && git rebase origin/main
```

---

### Task 1: Give each review-watcher session its own worktree

Today `review-react` checks PRs out in one shared clone per repo and `reset --hard`s it on entry, so two sessions on different PRs in one repo trample each other. Move to one worktree per session.

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh` (append helpers)
- Modify: `overlay/bin/review-react` (replace the clone/checkout block; add cleanup trap)
- Modify: `overlay/bin/setup-review-watcher` (create `worktrees/`)
- Modify: `test/review-watcher.test.sh` (real git origin for the RR stub; two tests)
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Produces: `rw_clone_dir owner repo` → prints `$RW_HOME/repos/<owner>/<repo>`; `rw_worktree_dir repo kind pr` → prints `$RW_HOME/worktrees/<repo>-<kind>-<pr>`; `rw_prepare_worktree owner repo pr kind` → creates a detached worktree at the PR head, prints its path, returns non-zero on failure; `rw_remove_worktree owner repo path`. `kind` is `pr` (reactions) or `review` (reviews).
- Produces (test harness): `RR_ORIGIN` (bare repo with `refs/heads/main` and `refs/pull/131/head`), the RR `gh` stub cloning it, and the RR `claude` stub writing its cwd to `$RW_HOME/claude-cwd`.

- [ ] **Step 1: Give the RR test harness a real origin**

In `test/review-watcher.test.sh`, replace the block from `RR_BIN="$(mktemp -d)"` through `chmod +x "$RR_BIN/gh" "$RR_BIN/claude"` with:

```bash
RR_BIN="$(mktemp -d)"
# A real bare origin, so the wrappers' clone/fetch/worktree steps run for real.
RR_ORIGIN="$(mktemp -d)/origin.git"; export RR_ORIGIN
git init -q --bare -b main "$RR_ORIGIN"
( seed="$(mktemp -d)" && cd "$seed" && git init -q -b main \
  && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed \
  && git push -q "$RR_ORIGIN" HEAD:refs/heads/main HEAD:refs/pull/131/head \
  && rm -rf "$seed" )
cat > "$RR_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo clone") git clone --quiet "$RR_ORIGIN" "$4" ;;
  "pr view")    printf '%s\n' "$GH_PR_VIEW_JSON" ;;
  "pr merge")   : > "$RW_HOME/merged-marker" ;;
esac
exit 0
STUB
cat > "$RR_BIN/claude" <<'STUB'
#!/usr/bin/env bash
pwd > "$RW_HOME/claude-cwd"
echo agent-ok
STUB
chmod +x "$RR_BIN/gh" "$RR_BIN/claude"
```

Also change the last cleanup line from `rm -rf "$RR_BIN"` to `rm -rf "$RR_BIN" "$(dirname "$RR_ORIGIN")"`.

- [ ] **Step 2: Write the failing tests**

Append before the `check` list:

```bash
test_react_runs_in_its_own_worktree_and_removes_it() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  [ "$(cat "$home/claude-cwd" 2>/dev/null)" = "$home/worktrees/myrepo-pr-131" ] \
    && [ ! -e "$home/worktrees/myrepo-pr-131" ] \
    && [ "$(git -C "$home/repos/nonrational/myrepo" worktree list | wc -l)" -eq 1 ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

# A wrapper killed outright (reboot) leaves its worktree behind; the next session
# on that PR must replace it rather than fail on "already exists".
test_react_replaces_stale_worktree() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  rm -f "$home/state/nonrational__myrepo__131.seen" "$home/claude-cwd"
  git -C "$home/repos/nonrational/myrepo" worktree add --quiet --detach \
    "$home/worktrees/myrepo-pr-131" HEAD
  : > "$home/worktrees/myrepo-pr-131/leftover"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  [ "$(cat "$home/claude-cwd" 2>/dev/null)" = "$home/worktrees/myrepo-pr-131" ] \
    && [ "$(cat "$home/state/nonrational__myrepo__131.seen" 2>/dev/null)" = "REV_1" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}
```

Add to the `check` list, after `check test_react_changes_requested_marks_seen_without_merging`:

```bash
check test_react_runs_in_its_own_worktree_and_removes_it
check test_react_replaces_stale_worktree
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: `FAIL: test_react_runs_in_its_own_worktree_and_removes_it` and `FAIL: test_react_replaces_stale_worktree` (claude runs in the clone, not a worktree). The three existing `test_react_*` tests still pass.

- [ ] **Step 4: Add the worktree helpers to the lib**

Append to `overlay/bin/review-watcher-lib.sh`:

```bash
rw_clone_dir() { # owner repo
  printf '%s/repos/%s/%s' "$RW_HOME" "$1" "$2"
}

rw_worktree_dir() { # repo kind pr
  printf '%s/worktrees/%s-%s-%s' "$RW_HOME" "$1" "$2" "$3"
}

# One worktree per session: sessions on different PRs in one repo used to share
# the clone's working tree and reset it under each other.
rw_prepare_worktree() { # owner repo pr kind — prints the worktree path
  local clone wt
  clone="$(rw_clone_dir "$1" "$2")"; wt="$(rw_worktree_dir "$2" "$4" "$3")"
  mkdir -p "$(dirname "$clone")" "$RW_HOME/worktrees" || return 1
  if [ -d "$clone/.git" ]; then
    git -C "$clone" fetch --quiet origin || return 1
  else
    gh repo clone "$1/$2" "$clone" -- --quiet >&2 || return 1
  fi
  # Sessions before worktrees checked PR branches out in the clone itself, and a
  # branch held there blocks `gh pr checkout` in every worktree.
  git -C "$clone" checkout --quiet --detach || return 1
  # A wrapper killed outright (reboot) leaves its worktree behind.
  git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt"
  git -C "$clone" worktree prune
  git -C "$clone" fetch --quiet origin "pull/$3/head" || return 1
  git -C "$clone" worktree add --quiet --detach "$wt" FETCH_HEAD >&2 || return 1
  printf '%s' "$wt"
}

rw_remove_worktree() { # owner repo worktree_path
  local clone; clone="$(rw_clone_dir "$1" "$2")"
  git -C "$clone" worktree remove --force "$3" >/dev/null 2>&1 || rm -rf "$3"
  git -C "$clone" worktree prune
}
```

- [ ] **Step 5: Rewire `review-react`**

In `overlay/bin/review-react`:

1. Change `mkdir -p "$RW_HOME/locks" "$RW_HOME/logs" "$RW_HOME/repos/$owner"` to `mkdir -p "$RW_HOME/locks" "$RW_HOME/logs"`.
2. Replace everything from `clone="$RW_HOME/repos/$owner/$repo"` through the closing `}` of the `gh pr checkout ... || { ... }` block with:

```bash
wt=""
rw_react_cleanup() {
  cd /
  [ -z "$wt" ] || rw_remove_worktree "$owner" "$repo" "$wt"
}
trap rw_react_cleanup EXIT
# tmux kill-session delivers SIGHUP; route fatal signals through exit so the EXIT
# trap still runs.
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

wt="$(rw_prepare_worktree "$owner" "$repo" "$pr" pr)"
cd "$wt"
# A named branch, so the agent's push lands on the PR. --force resets a local
# branch an earlier session left behind to the PR's current head.
gh pr checkout "$pr" --force >/dev/null 2>&1 \
  || echo "review-react: gh pr checkout failed; staying detached at the PR head" >&2
```

This deletes the old `reset --hard` / `clean -fd` block and its comment: the clone's own tree is no longer used. Leave the `"${cmd[@]}" ...` line and the merge block below it unchanged.

- [ ] **Step 6: Create `worktrees/` in setup**

In `overlay/bin/setup-review-watcher`, change `mkdir -p "$RW_HOME"/{state,locks,logs,repos}` to `mkdir -p "$RW_HOME"/{state,locks,logs,repos,worktrees}`.

- [ ] **Step 7: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `32 passed, 0 failed`

- [ ] **Step 8: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest
git commit -m "Give each review-watcher session its own worktree

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: the gate's last line reports `0 failed`.

---

### Task 2: Assign @nonreagent to PRs while a watcher session works them

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh` (append helpers)
- Modify: `overlay/bin/review-react` (assign; unassign in cleanup)
- Modify: `test/review-watcher.test.sh` (stub records `pr edit`; four tests)
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Consumes: `rw_react_cleanup`, the HUP/INT/TERM traps, and the RR harness from Task 1.
- Produces: `rw_assign owner repo pr` and `rw_unassign owner repo pr`. Both always return 0 and log a line to stderr on failure. The RR `gh` stub appends each `pr edit` argv to `$RW_HOME/gh-edits.log`; the RR `claude` stub honours `CLAUDE_FAIL=1` (exit 1) and `CLAUDE_SLEEP=<secs>`.

- [ ] **Step 1: Extend the RR stubs**

In the RR `gh` stub heredoc, add a case before `esac`:

```bash
  "pr edit")    echo "$*" >> "$RW_HOME/gh-edits.log" ;;
```

Replace the RR `claude` stub body with:

```bash
#!/usr/bin/env bash
pwd > "$RW_HOME/claude-cwd"
[ -z "${CLAUDE_SLEEP:-}" ] || sleep "$CLAUDE_SLEEP"
[ "${CLAUDE_FAIL:-0}" = 1 ] && exit 1
echo agent-ok
```

In `rr_invoke`, add `CLAUDE_FAIL="${CLAUDE_FAIL:-0}"` to the environment prefix of the `review-react` call (beside `GH_PR_VIEW_JSON=...`).

- [ ] **Step 2: Write the failing tests**

Append before the `check` list:

```bash
test_react_assigns_then_unassigns() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  [ "$(wc -l < "$home/gh-edits.log")" -eq 2 ] \
    && sed -n 1p "$home/gh-edits.log" | grep -q -- '--add-assignee nonreagent' \
    && sed -n 2p "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_react_unassigns_when_agent_fails() {
  local home; home="$(mktemp -d)"
  CLAUDE_FAIL=1 GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  tail -1 "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' \
    && [ ! -f "$home/state/nonrational__myrepo__131.seen" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

# tmux kill-session sends SIGHUP; the assignment and worktree must still clear.
test_react_unassigns_on_hangup() {
  local home pid i ok=0; home="$(mktemp -d)"
  printf 'playbook\n' > "$home/playbook.md"; : > "$home/config"
  RW_HOME="$home" PATH="$RR_BIN:$PATH" CLAUDE_SLEEP=2 GH_PR_VIEW_JSON="$RR_GREEN" \
    "$REPO/overlay/bin/review-react" nonrational myrepo 131 REV_1 CHANGES_REQUESTED nonrational \
    >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 50); do [ -f "$home/claude-cwd" ] && break; sleep 0.1; done
  kill -HUP "$pid"; wait "$pid" 2>/dev/null
  tail -1 "$home/gh-edits.log" 2>/dev/null | grep -q -- '--remove-assignee nonreagent' \
    && [ ! -e "$home/worktrees/myrepo-pr-131" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

# A wrapper that loses the lock race must not touch the assignment, or it would
# clear the live session's.
test_react_lock_loss_does_not_assign() {
  local home; home="$(mktemp -d)"; mkdir -p "$home/locks"
  ( flock -n 9 && GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED ) \
    9>"$home/locks/nonrational__myrepo__131.lock"
  local ok=0
  [ ! -f "$home/gh-edits.log" ] && [ ! -f "$home/claude-cwd" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}
```

Add to the `check` list after the Task 1 checks:

```bash
check test_react_assigns_then_unassigns
check test_react_unassigns_when_agent_fails
check test_react_unassigns_on_hangup
check test_react_lock_loss_does_not_assign
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: the first three new tests FAIL (no `gh-edits.log`); `test_react_lock_loss_does_not_assign` passes already (it pins existing lock behaviour against regression).

- [ ] **Step 4: Add the helpers**

Append to `overlay/bin/review-watcher-lib.sh`:

```bash
# Assignment is a status light for the operator: the bot is assigned exactly while
# a watcher session works the PR. Best-effort, so it never blocks the work.
rw_assign() { # owner repo pr
  gh pr edit "$3" --repo "$1/$2" --add-assignee "$RW_BOT_LOGIN" >/dev/null 2>&1 \
    || echo "could not assign @$RW_BOT_LOGIN to $1/$2#$3" >&2
  return 0
}

rw_unassign() { # owner repo pr
  gh pr edit "$3" --repo "$1/$2" --remove-assignee "$RW_BOT_LOGIN" >/dev/null 2>&1 \
    || echo "could not unassign @$RW_BOT_LOGIN from $1/$2#$3" >&2
  return 0
}
```

- [ ] **Step 5: Wire them into `review-react`**

In `overlay/bin/review-react`, change `rw_react_cleanup` to:

```bash
rw_react_cleanup() {
  cd /
  [ -z "$wt" ] || rw_remove_worktree "$owner" "$repo" "$wt"
  rw_unassign "$owner" "$repo" "$pr"
}
```

and insert directly after the three `trap` lines (before `wt="$(rw_prepare_worktree ...)"`):

```bash
rw_assign "$owner" "$repo" "$pr"
```

The trap is installed before assigning, so a signal between the two still unassigns. Unassign runs after `rw-merge` because the trap fires at exit; unassigning a merged PR is harmless.

- [ ] **Step 6: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `36 passed, 0 failed`

- [ ] **Step 7: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest
git commit -m "Assign @nonreagent to PRs while a watcher session works them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Clear stale watcher assignments and match tmux sessions exactly

A wrapper killed outright (reboot) never runs its trap. Each poll, clear @nonreagent from open PRs with no live session. Fix tmux prefix matching while touching every `has-session`.

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh` (`rw_search_prs`; `rw_open_prs` delegates; `rw_review_session_name`)
- Modify: `overlay/bin/review-watcher` (`rw_sweep_assignments`; exact `=` targets; call the sweep each poll)
- Modify: `test/review-watcher.test.sh` (watcher harness `WB_*`; four tests)
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Consumes: `rw_unassign`, `rw_session_name`.
- Produces: `rw_search_prs <gh search flags...>` → TSV `owner repo pr is_draft author` per open PR; `rw_review_session_name owner repo pr` → `<repo>-review-<pr>`. Watcher test harness: `WB_BIN` stubs and `wb_invoke rw_home`, driven by env `GH_ASSIGNED`, `GH_REQUESTED`, `GH_AUTHORED`, `GH_TIMELINE` (JSON strings, default `[]`), `TMUX_LIVE` (one live session name), `CLAUDE_LOGGED_IN` (`1` or `0`). The stubs log to `$RW_HOME/gh-calls.log` (every `gh pr …` argv), `$RW_HOME/tmux-has.log` (every `has-session` target), and `$RW_HOME/tmux-new.log` (every `new-session` argv).

- [ ] **Step 1: Add the watcher harness**

Append to `test/review-watcher.test.sh`, after the RR harness block and its tests, before the `check` list:

```bash
# --- review-watcher end to end (stubbed externals) ------------------------------
WB_BIN="$(mktemp -d)"
cat > "$WB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  search)
    case "$*" in
      *--assignee*)         printf '%s\n' "${GH_ASSIGNED:-[]}" ;;
      *--review-requested*) printf '%s\n' "${GH_REQUESTED:-[]}" ;;
      *)                    printf '%s\n' "${GH_AUTHORED:-[]}" ;;
    esac ;;
  api)
    case "$2" in
      */timeline) printf '%s\n' "${GH_TIMELINE:-[]}" ;;
      *)          echo '[]' ;;
    esac ;;
  pr) echo "$*" >> "$RW_HOME/gh-calls.log" ;;
esac
exit 0
STUB
cat > "$WB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "$3" in                     # argv: -S <sock> <command> ...
  has-session) echo "$5" >> "$RW_HOME/tmux-has.log"
               [ -n "${TMUX_LIVE:-}" ] && [ "$5" = "=$TMUX_LIVE" ] ;;
  new-session) echo "$*" >> "$RW_HOME/tmux-new.log" ;;
  list-sessions) [ -n "${TMUX_LIVE:-}" ] && echo "$TMUX_LIVE: 1 windows" ;;
esac
STUB
cat > "$WB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${CLAUDE_LOGGED_IN:-0}" = 1 ]; then echo '{"loggedIn":true}'; exit 0; fi
echo '{"loggedIn":false}'; exit 1
STUB
chmod +x "$WB_BIN/gh" "$WB_BIN/tmux" "$WB_BIN/claude"

wb_invoke() { # rw_home — one poll
  : > "$1/config"
  RW_HOME="$1" PATH="$WB_BIN:$PATH" \
    GH_ASSIGNED="${GH_ASSIGNED:-[]}" GH_REQUESTED="${GH_REQUESTED:-[]}" \
    GH_AUTHORED="${GH_AUTHORED:-[]}" GH_TIMELINE="${GH_TIMELINE:-[]}" \
    TMUX_LIVE="${TMUX_LIVE:-}" CLAUDE_LOGGED_IN="${CLAUDE_LOGGED_IN:-0}" \
    "$REPO/overlay/bin/review-watcher" --once >/dev/null 2>&1
}
WB_PR131='[{"repository":{"nameWithOwner":"nonrational/myrepo"},"number":131,"isDraft":false,"author":{"login":"nonrational"}}]'
```

At the end of the file, change `rm -rf "$RR_BIN" "$(dirname "$RR_ORIGIN")"` to `rm -rf "$RR_BIN" "$(dirname "$RR_ORIGIN")" "$WB_BIN"`.

- [ ] **Step 2: Write the failing tests**

Append after the harness:

```bash
test_review_session_name_is_distinct() {
  [ "$(rw_review_session_name nonrational myrepo 131)" = "myrepo-review-131" ] \
    && [ "$(rw_review_session_name nonrational myrepo 131)" != "$(rw_session_name nonrational myrepo 131)" ]
}

test_sweep_clears_assignment_without_session() {
  local home ok=0; home="$(mktemp -d)"
  GH_ASSIGNED="$WB_PR131" wb_invoke "$home"
  grep -q -- 'pr edit 131 --repo nonrational/myrepo --remove-assignee nonreagent' "$home/gh-calls.log" 2>/dev/null && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_sweep_keeps_assignment_with_live_review_session() {
  local home ok=0; home="$(mktemp -d)"
  GH_ASSIGNED="$WB_PR131" TMUX_LIVE=myrepo-review-131 wb_invoke "$home"
  ! grep -q -- '--remove-assignee' "$home/gh-calls.log" 2>/dev/null && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

# tmux resolves a bare target by prefix, so `myrepo-pr-1` would match a live
# `myrepo-pr-13`. Every has-session must use the exact `=name` form.
test_watcher_targets_tmux_sessions_exactly() {
  local home ok=0; home="$(mktemp -d)"
  GH_ASSIGNED="$WB_PR131" wb_invoke "$home"
  [ -s "$home/tmux-has.log" ] && ! grep -qv '^=' "$home/tmux-has.log" && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}
```

Add to the `check` list:

```bash
check test_review_session_name_is_distinct
check test_sweep_clears_assignment_without_session
check test_sweep_keeps_assignment_with_live_review_session
check test_watcher_targets_tmux_sessions_exactly
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: `test_review_session_name_is_distinct`, `test_sweep_clears_assignment_without_session`, and `test_watcher_targets_tmux_sessions_exactly` FAIL. `test_sweep_keeps_assignment_with_live_review_session` passes vacuously until the sweep exists; it guards the sweep's second lookup.

- [ ] **Step 4: Generalize the PR search and add the review session name**

In `overlay/bin/review-watcher-lib.sh`, replace the whole `rw_open_prs` function with:

```bash
rw_search_prs() { # gh search flags... — open PRs as TSV: owner repo pr is_draft author
  gh search prs "$@" --state open \
     --json repository,number,isDraft,author --limit 100 \
   | jq -r '.[] | [(.repository.nameWithOwner|split("/")[0]),
                    (.repository.nameWithOwner|split("/")[1]),
                    (.number|tostring), (.isDraft|tostring), .author.login]
                   | @tsv'
}

rw_open_prs() { rw_search_prs --author "$RW_BOT_LOGIN"; }
```

and add after `rw_session_name`:

```bash
rw_review_session_name() { # owner repo pr
  printf '%s-review-%s' "$2" "$3"
}
```

- [ ] **Step 5: Add the sweep and exact targets to the supervisor**

In `overlay/bin/review-watcher`:

1. Change `if tmux -S "$SOCK" has-session -t "$sess" 2>/dev/null; then` to `if tmux -S "$SOCK" has-session -t "=$sess" 2>/dev/null; then`.
2. Add after the `rw_active_reactions` line:

```bash
rw_session_live() { tmux -S "$SOCK" has-session -t "=$1" 2>/dev/null; }

# A wrapper killed outright (reboot, SIGKILL) never runs its EXIT trap, so its
# assignment would outlive it. Assignment means "a session is working this now".
rw_sweep_assignments() {
  local owner repo pr _rest
  while IFS=$'\t' read -r owner repo pr _rest; do
    [ -n "$owner" ] || continue
    rw_session_live "$(rw_session_name "$owner" "$repo" "$pr")" && continue
    rw_session_live "$(rw_review_session_name "$owner" "$repo" "$pr")" && continue
    echo "$(date -u +%H:%M:%S) $owner/$repo#$pr assigned without a live session; unassigning"
    rw_unassign "$owner" "$repo" "$pr"
  done < <(rw_search_prs --assignee "$RW_BOT_LOGIN")
}
```

3. In `rw_poll_once`, insert `rw_sweep_assignments` on the line after the `PAUSED` check.

- [ ] **Step 6: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `40 passed, 0 failed` (including the pre-existing `test_watcher_holds_reactions_while_logged_out` and `test_open_prs_parses_search`).

- [ ] **Step 7: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest
git commit -m "Clear stale watcher assignments and match tmux sessions exactly

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Detect review requests for @nonreagent

Pure detection helpers, unit-tested with `gh` stubs. Nothing calls them until Tasks 5 and 6.

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Modify: `test/review-watcher.test.sh`
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Consumes: `rw_search_prs`, `rw_in_allowlist`, `$REVIEWER_ALLOWLIST`, `$RW_BOT_LOGIN`.
- Produces:
  - `rw_review_requests` → TSV `owner repo pr is_draft author` for open PRs requesting @nonreagent.
  - `rw_latest_review_request owner repo pr` → TSV `event_id requester created_at` for the newest `review_requested` event naming @nonreagent, or empty.
  - `rw_classify_request author requester is_draft` → `SKIP` | `NOTIFY` | `REVIEW`.
  - `rw_request_seen_file owner repo pr` → `$RW_HOME/state/<owner>__<repo>__<pr>.review-req`; `rw_is_request_seen owner repo pr event_id`; `rw_mark_request_seen owner repo pr event_id`.
  - `rw_review_landed owner repo pr since` → exit 0 iff @nonreagent submitted an `APPROVED` or `CHANGES_REQUESTED` review with `submitted_at` later than `since`.
  - `rw_render_playbook template repo pr review_state reviewer [requester]` now also substitutes `{{REQUESTER}}` with the optional sixth argument.

- [ ] **Step 1: Write the failing tests**

Append before the `check` list:

```bash
test_classify_request() {
  REVIEWER_ALLOWLIST="nonrational"
  [ "$(rw_classify_request nonrational nonrational true)"  = "SKIP" ] \
  && [ "$(rw_classify_request alice nonrational false)"    = "NOTIFY" ] \
  && [ "$(rw_classify_request nonrational alice false)"    = "NOTIFY" ] \
  && [ "$(rw_classify_request nonrational nonrational false)" = "REVIEW" ]
}

test_request_seen_is_independent_of_review_seen() {
  [ "$(rw_request_seen_file nonrational myrepo 77)" = "$RW_HOME/state/nonrational__myrepo__77.review-req" ] || return 1
  rw_is_request_seen nonrational myrepo 77 EV_1 && return 1
  rw_mark_request_seen nonrational myrepo 77 EV_1
  rw_is_request_seen nonrational myrepo 77 EV_1 || return 1
  rw_is_seen nonrational myrepo 77 EV_1 && return 1      # review-seen untouched
  rw_is_request_seen nonrational myrepo 77 EV_2 && return 1   # a re-request is unseen
  return 0
}

test_render_substitutes_requester() {
  local tpl out; tpl="$(mktemp)"
  printf '{{REPO}}#{{PR}} for {{REQUESTER}}\n' > "$tpl"
  out="$(rw_render_playbook "$tpl" myrepo 131 REVIEW_REQUESTED nonrational nonrational)"
  rm -f "$tpl"
  [ "$out" = "myrepo#131 for nonrational" ]
}

test_review_requests_parses_search() {
  local bin out; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--review-requested nonreagent"*)
    echo '[{"repository":{"nameWithOwner":"nonrational/myrepo"},"number":9,"isDraft":true,"author":{"login":"nonrational"}}]' ;;
  *) echo '[]' ;;
esac
STUB
  chmod +x "$bin/gh"
  out="$(PATH="$bin:$PATH" rw_review_requests)"
  rm -rf "$bin"
  [ "$out" = "$(printf 'nonrational\tmyrepo\t9\ttrue\tnonrational')" ]
}

test_latest_review_request_picks_newest_for_bot() {
  local bin out; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"id":10,"event":"review_requested","created_at":"2026-10-01T00:00:00Z","requested_reviewer":{"login":"nonreagent"},"review_requester":{"login":"nonrational"}},
 {"id":11,"event":"commented","created_at":"2026-10-02T00:00:00Z"},
 {"id":12,"event":"review_requested","created_at":"2026-10-03T00:00:00Z","requested_reviewer":{"login":"someone"},"review_requester":{"login":"nonrational"}},
 {"id":13,"event":"review_requested","created_at":"2026-10-04T00:00:00Z","requested_reviewer":{"login":"nonreagent"},"review_requester":{"login":"alice"}}]
JSON
STUB
  chmod +x "$bin/gh"
  out="$(PATH="$bin:$PATH" rw_latest_review_request nonrational myrepo 9)"
  rm -rf "$bin"
  [ "$out" = "$(printf '13\talice\t2026-10-04T00:00:00Z')" ]
}

# A team request carries requested_team, not requested_reviewer.
test_latest_review_request_ignores_team_requests() {
  local bin out; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '[{"id":20,"event":"review_requested","created_at":"2026-10-01T00:00:00Z","requested_team":{"slug":"core"},"review_requester":{"login":"nonrational"}}]'
STUB
  chmod +x "$bin/gh"
  out="$(PATH="$bin:$PATH" rw_latest_review_request nonrational myrepo 9)"; local rc=$?
  rm -rf "$bin"
  [ "$rc" = 0 ] && [ -z "$out" ]
}

rl_with_reviews() { # reviews_json since — runs rw_review_landed against a stub
  local bin rc; bin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$GH_REVIEWS"\n' > "$bin/gh"
  chmod +x "$bin/gh"
  GH_REVIEWS="$1" PATH="$bin:$PATH" rw_review_landed nonrational myrepo 9 "$2"; rc=$?
  rm -rf "$bin"
  return "$rc"
}

test_review_landed_after_request() {
  rl_with_reviews '[{"user":{"login":"nonreagent"},"state":"CHANGES_REQUESTED","submitted_at":"2026-10-05T00:00:00Z"}]' 2026-10-04T00:00:00Z
}

# A review from an earlier request round must not satisfy a new request.
test_review_landed_ignores_older_review() {
  ! rl_with_reviews '[{"user":{"login":"nonreagent"},"state":"APPROVED","submitted_at":"2026-10-01T00:00:00Z"}]' 2026-10-04T00:00:00Z
}

test_review_landed_ignores_comment_only_and_others() {
  ! rl_with_reviews '[{"user":{"login":"nonreagent"},"state":"COMMENTED","submitted_at":"2026-10-05T00:00:00Z"},{"user":{"login":"nonrational"},"state":"APPROVED","submitted_at":"2026-10-05T00:00:00Z"}]' 2026-10-04T00:00:00Z
}
```

Add to the `check` list:

```bash
check test_classify_request
check test_request_seen_is_independent_of_review_seen
check test_render_substitutes_requester
check test_review_requests_parses_search
check test_latest_review_request_picks_newest_for_bot
check test_latest_review_request_ignores_team_requests
check test_review_landed_after_request
check test_review_landed_ignores_older_review
check test_review_landed_ignores_comment_only_and_others
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: every new test FAILs except `test_review_landed_ignores_older_review` and `test_review_landed_ignores_comment_only_and_others`, which pass vacuously while `rw_review_landed` is undefined (command not found returns non-zero). Confirm after Step 3 that `test_review_landed_after_request` passes, which proves those two are meaningful.

- [ ] **Step 3: Implement the helpers**

In `overlay/bin/review-watcher-lib.sh`, replace `rw_render_playbook` with:

```bash
rw_render_playbook() { # template_file repo pr review_state reviewer [requester]
  sed -e "s|{{REPO}}|$2|g" -e "s|{{PR}}|$3|g" \
      -e "s|{{REVIEW_STATE}}|$4|g" -e "s|{{REVIEWER}}|$5|g" \
      -e "s|{{REQUESTER}}|${6:-}|g" "$1"
}
```

and append:

```bash
rw_review_requests() { rw_search_prs --review-requested "$RW_BOT_LOGIN"; }

# The event id is the dedup key: GitHub clears the request when the bot reviews, and
# a re-request mints a new event, so "review it again" needs no extra state.
rw_latest_review_request() { # owner repo pr — event_id requester created_at, or empty
  gh api "repos/$1/$2/issues/$3/timeline" --paginate \
   | jq -rs --arg me "$RW_BOT_LOGIN" '
       (add // []) | map(select(.event == "review_requested"
                                and (.requested_reviewer.login? // "") == $me))
       | sort_by(.created_at) | last
       | if . == null then empty
         else [(.id|tostring), .review_requester.login, .created_at] | @tsv end'
}

# Both ends must be trusted: the session runs with bypassPermissions over the PR's
# code, so an untrusted author could steer it as surely as an untrusted requester.
rw_classify_request() { # author requester is_draft
  [ "$3" = "true" ] && { echo SKIP; return; }
  if rw_in_allowlist "$1" "$REVIEWER_ALLOWLIST" && rw_in_allowlist "$2" "$REVIEWER_ALLOWLIST"; then
    echo REVIEW
  else
    echo NOTIFY
  fi
}

rw_request_seen_file() { # owner repo pr
  printf '%s/state/%s__%s__%s.review-req' "$RW_HOME" "$1" "$2" "$3"
}

rw_is_request_seen() { # owner repo pr event_id
  local f; f="$(rw_request_seen_file "$1" "$2" "$3")"
  [ -f "$f" ] && [ "$(cat "$f")" = "$4" ]
}

rw_mark_request_seen() { # owner repo pr event_id
  local f; f="$(rw_request_seen_file "$1" "$2" "$3")"
  mkdir -p "$(dirname "$f")"
  printf '%s' "$4" > "$f"
}

rw_review_landed() { # owner repo pr since — did the bot submit a verdict after `since`?
  gh api "repos/$1/$2/pulls/$3/reviews" --paginate \
   | jq -es --arg me "$RW_BOT_LOGIN" --arg since "$4" '
       (add // []) | any(.user.login == $me
                         and (.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                         and .submitted_at > $since)' >/dev/null
}
```

- [ ] **Step 4: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `49 passed, 0 failed`

- [ ] **Step 5: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest
git commit -m "Detect review requests for @nonreagent

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Add review-pr, the watcher's reviewer session

**Files:**
- Create: `overlay/bin/review-pr` (executable)
- Create: `overlay/review-watcher/review-playbook.md`
- Modify: `overlay/bin/setup-review-watcher` (install the review playbook)
- Modify: `test/review-watcher.test.sh` (RR `gh` stub serves `api`; five tests)
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Consumes: `rw_prepare_worktree`, `rw_remove_worktree`, `rw_assign`, `rw_unassign`, `rw_render_playbook` (six-argument form), `rw_review_landed`, `rw_mark_request_seen`, the RR harness.
- Produces: `review-pr owner repo pr request_id requester requested_at`. Takes the same per-PR lock file as `review-react` (`$RW_HOME/locks/<owner>__<repo>__<pr>.lock`), logs to `$RW_HOME/logs/<repo>-review-<pr>.log`, honours `RW_DRY_RUN=1`. Marks the request seen only when `rw_review_landed` succeeds. Never pushes or merges.

- [ ] **Step 1: Let the RR `gh` stub serve reviews**

In the RR `gh` stub, add before `esac`:

```bash
  api*)         printf '%s\n' "${GH_API_JSON:-[]}" ;;
```

Note: `case "$1 $2"` sees `api repos/...`, which `api*` matches. `rw-merge`'s `gh api … --jq .merge_commit_sha` call in the react tests will now print `[]` as the SHA; those tests do not check it.

- [ ] **Step 2: Write the failing tests**

Append before the `check` list:

```bash
rp_invoke() { # rw_home — review request REQ_1 on myrepo#131, requested at T0
  printf 'review {{REPO}}#{{PR}} for {{REQUESTER}}\n' > "$1/review-playbook.md"
  : > "$1/config"
  RW_HOME="$1" PATH="$RR_BIN:$PATH" GH_API_JSON="${GH_API_JSON:-[]}" \
    CLAUDE_FAIL="${CLAUDE_FAIL:-0}" RW_DRY_RUN="${RW_DRY_RUN:-0}" \
    "$REPO/overlay/bin/review-pr" nonrational myrepo 131 REQ_1 nonrational 2026-10-14T00:00:00Z
}
RP_LANDED='[{"user":{"login":"nonreagent"},"state":"APPROVED","submitted_at":"2026-10-14T00:05:00Z"}]'

test_review_pr_marks_seen_when_review_lands() {
  local home ok=0; home="$(mktemp -d)"
  GH_API_JSON="$RP_LANDED" rp_invoke "$home" >/dev/null 2>&1
  [ "$(cat "$home/state/nonrational__myrepo__131.review-req" 2>/dev/null)" = "REQ_1" ] \
    && [ "$(cat "$home/claude-cwd" 2>/dev/null)" = "$home/worktrees/myrepo-review-131" ] \
    && [ ! -e "$home/worktrees/myrepo-review-131" ] \
    && [ ! -f "$home/merged-marker" ] \
    && sed -n 1p "$home/gh-edits.log" | grep -q -- '--add-assignee nonreagent' \
    && sed -n 2p "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_stays_unseen_without_review() {
  local home ok=0; home="$(mktemp -d)"
  GH_API_JSON='[]' rp_invoke "$home" >/dev/null 2>&1
  [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] \
    && tail -1 "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_unassigns_when_agent_fails() {
  local home ok=0; home="$(mktemp -d)"
  CLAUDE_FAIL=1 GH_API_JSON="$RP_LANDED" rp_invoke "$home" >/dev/null 2>&1
  [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] \
    && tail -1 "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_dry_run_prints_review_prompt() {
  local home out ok=0; home="$(mktemp -d)"
  out="$(RW_DRY_RUN=1 rp_invoke "$home" 2>/dev/null)"
  [[ "$out" == *"claude -p"* ]] && [[ "$out" == *"myrepo#131"* ]] && [[ "$out" == *nonrational* ]] \
    && [ ! -f "$home/gh-edits.log" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_shares_the_react_lock() {
  local home ok=0; home="$(mktemp -d)"; mkdir -p "$home/locks"
  ( flock -n 9 && GH_API_JSON="$RP_LANDED" rp_invoke "$home" >/dev/null 2>&1 ) \
    9>"$home/locks/nonrational__myrepo__131.lock"
  [ ! -f "$home/gh-edits.log" ] && [ ! -f "$home/claude-cwd" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}
```

Add to the `check` list:

```bash
check test_review_pr_marks_seen_when_review_lands
check test_review_pr_stays_unseen_without_review
check test_review_pr_unassigns_when_agent_fails
check test_review_pr_dry_run_prints_review_prompt
check test_review_pr_shares_the_react_lock
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: the five `test_review_pr_*` tests FAIL (`review-pr` does not exist); the lock test may pass vacuously for the same reason and is meaningful once Step 6 passes.

- [ ] **Step 4: Write `overlay/bin/review-pr`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/review-watcher-lib.sh"
rw_load_config

owner="$1"; repo="$2"; pr="$3"; request_id="$4"; requester="$5"; requested_at="$6"
# Same lock file as review-react: one session per PR, whatever its kind.
lock="$RW_HOME/locks/${owner}__${repo}__${pr}.lock"
mkdir -p "$RW_HOME/locks" "$RW_HOME/logs"
exec 9>"$lock"
flock -n 9 || { echo "review-pr: $owner/$repo#$pr already in flight, skipping" >&2; exit 0; }

prompt="$(rw_render_playbook "$RW_HOME/review-playbook.md" "$repo" "$pr" REVIEW_REQUESTED "$requester" "$requester")"
log="$RW_HOME/logs/${repo}-review-${pr}.log"
cmd=(timeout "$REACTION_TIMEOUT" claude -p "$prompt"
     --permission-mode bypassPermissions --verbose)

if [ "${RW_DRY_RUN:-0}" = "1" ]; then
  printf '%q ' "${cmd[@]}"; echo; exit 0
fi

wt=""
rw_review_cleanup() {
  cd /
  [ -z "$wt" ] || rw_remove_worktree "$owner" "$repo" "$wt"
  rw_unassign "$owner" "$repo" "$pr"
}
trap rw_review_cleanup EXIT
# tmux kill-session delivers SIGHUP; route fatal signals through exit so the EXIT
# trap still runs.
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
rw_assign "$owner" "$repo" "$pr"

# Detached at the PR head: a reviewer never pushes, so it needs no branch.
wt="$(rw_prepare_worktree "$owner" "$repo" "$pr" review)"
cd "$wt"

"${cmd[@]}" 2>&1 | tee -a "$log" || {
  echo "review-pr: review of $owner/$repo#$pr failed or timed out; leaving request unseen for retry" >&2
  exit 0
}

# The session's exit status says nothing about whether it submitted a verdict, so
# ask GitHub. No verdict means the next poll retries the same request.
if rw_review_landed "$owner" "$repo" "$pr" "$requested_at"; then
  rw_mark_request_seen "$owner" "$repo" "$pr" "$request_id"
else
  echo "review-pr: no review from @$RW_BOT_LOGIN on $owner/$repo#$pr since $requested_at; leaving unseen for retry" >&2
fi
```

Then: `chmod +x overlay/bin/review-pr`.

- [ ] **Step 5: Write `overlay/review-watcher/review-playbook.md`**

```markdown
You are Agent Norton (@nonreagent). @{{REQUESTER}} requested your review on PR #{{PR}} of
{{REPO}}. You are in a detached checkout of the PR head. Review it, submit exactly one
review, then exit.

Ground rules (non-negotiable):
- You are the reviewer, not the author. Never commit, push, merge, or edit the PR's title,
  body, labels, or branch. A change you would make goes in the review as a suggestion.
- Follow this repo's CLAUDE.md and your ~/.claude rules. Load the code-review-register skill
  and write every comment in that voice. No "Generated with Claude Code" line or claude.ai
  link anywhere.
- First call of the session: `gh pr view {{PR}} --json state,isDraft,headRefOid,baseRefName,reviewRequests`.
  If the PR is closed or merged, or @nonreagent is no longer among the requested reviewers,
  exit without reviewing.
- Pin the head SHA from that call and read the change as `git diff origin/<baseRefName>...<sha>`,
  never as a HEAD-relative range.

How to review:
1. Read the PR title and body, the linked issue, the full diff, and existing review threads
   (`gh pr view {{PR}} --comments`, `gh api repos/{owner}/{repo}/pulls/{{PR}}/comments`).
   Don't repeat a point already raised or resolved.
2. Read the project's conventions (CLAUDE.md, justfile, tests) and run its gate where one
   exists. A red gate is a blocker.
3. Answer two questions. Does the change do what the PR and its issue say? Does it break
   anything or violate the repo's documented standards?
4. Sort findings. Blockers: incorrect behaviour, a red gate, data loss, security exposure,
   or a miss against the issue or spec. Everything else is non-blocking.

Submit exactly one review, then exit:
- Any blocker: request changes. Name each blocker and its consequence.
- No blockers: approve. Mark non-blocking suggestions as optional.
- Without inline comments: `gh pr review {{PR}} --approve --body-file <file>` or
  `gh pr review {{PR}} --request-changes --body-file <file>`.
- With inline comments: one call, `gh api --method POST repos/{owner}/{repo}/pulls/{{PR}}/reviews --input <file.json>`,
  where the JSON carries `commit_id` (the pinned SHA), `event` (`APPROVE` or
  `REQUEST_CHANGES`), `body`, and `comments` as `[{path, line, side: "RIGHT", body}]`.
  Never submit two reviews.
- If you can't judge the PR (too large for the time you have, or it needs a product decision),
  don't approve. Request changes, naming what you need to finish the review.

After you exit, the harness checks that a review from you landed. If none did, it retries later.
```

- [ ] **Step 6: Install the review playbook in setup**

In `overlay/bin/setup-review-watcher`, after the line `cp "$SRC/playbook.md" "$RW_HOME/playbook.md" ...`, add:

```bash
cp "$SRC/review-playbook.md" "$RW_HOME/review-playbook.md"
```

- [ ] **Step 7: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `54 passed, 0 failed`

- [ ] **Step 8: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest
git commit -m "Add review-pr, the watcher's reviewer session

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Check `git show --stat HEAD` lists `home/bin/review-pr`; if `build.sh` copies `overlay/bin/*` but `manifest` lacks the new file, the gate's `test_manifest_covers_home` fails and says so.

---

### Task 6: Dispatch reviewer sessions from the watcher

**Files:**
- Modify: `overlay/bin/review-watcher` (`rw_launch`; `rw_dispatch` uses it; `rw_dispatch_review`; second pass in `rw_poll_once`)
- Modify: `README.md` (review watcher section)
- Modify: `test/review-watcher.test.sh` (five tests)
- Regenerate: `home/bin/*`, `manifest`

**Interfaces:**
- Consumes: Task 3 harness (`wb_invoke`, `WB_PR131`, logs), Task 4 helpers, `review-pr` argv from Task 5.
- Produces: `rw_launch session label command...` (auth gate, concurrency cap, exact-match in-flight check, `tmux new-session`); `rw_dispatch_review owner repo pr event_id requester requested_at author classification`.

- [ ] **Step 1: Write the failing tests**

Append before the `check` list:

```bash
WB_REQ_EVENT='[{"id":55,"event":"review_requested","created_at":"2026-10-14T00:00:00Z","requested_reviewer":{"login":"nonreagent"},"review_requester":{"login":"nonrational"}}]'

test_watcher_launches_review_for_trusted_request() {
  local home ok=0; home="$(mktemp -d)"
  GH_REQUESTED="$WB_PR131" GH_TIMELINE="$WB_REQ_EVENT" CLAUDE_LOGGED_IN=1 wb_invoke "$home"
  grep -q -- '-s myrepo-review-131 .*review-pr nonrational myrepo 131 55 nonrational 2026-10-14T00:00:00Z' \
    "$home/tmux-new.log" 2>/dev/null && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_watcher_notifies_untrusted_requester() {
  local home ok=0; home="$(mktemp -d)"
  GH_REQUESTED="$WB_PR131" CLAUDE_LOGGED_IN=1 \
    GH_TIMELINE="$(sed 's/"review_requester":{"login":"nonrational"}/"review_requester":{"login":"mallory"}/' <<<"$WB_REQ_EVENT")" \
    wb_invoke "$home"
  grep -q '^pr comment 131 --repo nonrational/myrepo' "$home/gh-calls.log" 2>/dev/null \
    && [ "$(cat "$home/state/nonrational__myrepo__131.review-req" 2>/dev/null)" = "55" ] \
    && [ ! -f "$home/tmux-new.log" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_watcher_leaves_draft_request_unseen() {
  local home ok=0; home="$(mktemp -d)"
  GH_REQUESTED="$(sed 's/"isDraft":false/"isDraft":true/' <<<"$WB_PR131")" GH_TIMELINE="$WB_REQ_EVENT" \
    CLAUDE_LOGGED_IN=1 wb_invoke "$home"
  [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] && [ ! -f "$home/tmux-new.log" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_watcher_skips_seen_request() {
  local home ok=0; home="$(mktemp -d)"
  mkdir -p "$home/state"; printf '55' > "$home/state/nonrational__myrepo__131.review-req"
  GH_REQUESTED="$WB_PR131" GH_TIMELINE="$WB_REQ_EVENT" CLAUDE_LOGGED_IN=1 wb_invoke "$home"
  [ ! -f "$home/tmux-new.log" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_watcher_holds_reviews_while_logged_out() {
  local home ok=0; home="$(mktemp -d)"
  GH_REQUESTED="$WB_PR131" GH_TIMELINE="$WB_REQ_EVENT" CLAUDE_LOGGED_IN=0 wb_invoke "$home"
  [ ! -f "$home/tmux-new.log" ] && [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}
```

Add to the `check` list:

```bash
check test_watcher_launches_review_for_trusted_request
check test_watcher_notifies_untrusted_requester
check test_watcher_leaves_draft_request_unseen
check test_watcher_skips_seen_request
check test_watcher_holds_reviews_while_logged_out
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/review-watcher.test.sh | grep -E 'FAIL|passed'`
Expected: `test_watcher_launches_review_for_trusted_request` and `test_watcher_notifies_untrusted_requester` FAIL. The other three pass vacuously until pass 2 exists; they pin behaviour that pass 2 must not break.

- [ ] **Step 3: Extract `rw_launch` and add pass 2**

In `overlay/bin/review-watcher`, replace the `REACT_*)` branch of `rw_dispatch` (from `REACT_*)` through its `;;`) with:

```bash
    REACT_*)
      rw_launch "$(rw_session_name "$owner" "$repo" "$pr")" "$owner/$repo#$pr" \
        "$HERE/review-react" "$owner" "$repo" "$pr" "$rid" "$state" "$reviewer" ;;
```

Add above `rw_dispatch`:

```bash
rw_launch() { # session label command... — start a session unless a guard holds it
  local sess="$1" label="$2"; shift 2
  if ! rw_logged_in; then
    echo "claude auth unconfirmed (logged out, or \`claude auth status\` failed); run \`claude auth login\` as $(id -un). Holding $label" >&2; return
  fi
  if [ "$(rw_active_reactions)" -ge "$MAX_CONCURRENT" ]; then
    echo "at concurrency cap ($MAX_CONCURRENT); deferring $label" >&2; return
  fi
  if rw_session_live "$sess"; then
    echo "session already in flight for $sess; skipping" >&2; return
  fi
  tmux -S "$SOCK" new-session -d -s "$sess" "$*"
}

rw_dispatch_review() { # owner repo pr event_id requester requested_at author classification
  local owner="$1" repo="$2" pr="$3" eid="$4" requester="$5" at="$6" author="$7" cls="$8"
  case "$cls" in
    SKIP) ;;   # draft: left unseen so the request fires once the PR is ready
    NOTIFY)
      gh pr comment "$pr" --repo "$owner/$repo" \
         --body "@nonrational: @$requester requested a review from @$RW_BOT_LOGIN on this PR by @$author; not acting (author and requester must both be allowlisted)." \
         >/dev/null 2>&1 || true
      rw_mark_request_seen "$owner" "$repo" "$pr" "$eid" ;;
    REVIEW)
      rw_launch "$(rw_review_session_name "$owner" "$repo" "$pr")" "review of $owner/$repo#$pr" \
        "$HERE/review-pr" "$owner" "$repo" "$pr" "$eid" "$requester" "$at" ;;
  esac
}
```

`rw_session_live` is defined in Task 3; make sure it sits above `rw_launch` in the file. Delete the now-unused `local sess; sess=...` and `has-session` lines that the old `REACT_*` branch carried.

At the end of `rw_poll_once` (after the existing `done < <(rw_open_prs)`), append:

```bash
  local eid requester at
  while IFS=$'\t' read -r owner repo pr is_draft author; do
    [ -n "$owner" ] || continue
    IFS=$'\t' read -r eid requester at < <(rw_latest_review_request "$owner" "$repo" "$pr")
    [ -n "${eid:-}" ] || continue
    rw_is_request_seen "$owner" "$repo" "$pr" "$eid" && continue
    cls="$(rw_classify_request "$author" "$requester" "$is_draft")"
    echo "$(date -u +%H:%M:%S) $owner/$repo#$pr review request=$eid by=$requester author=$author -> $cls"
    rw_dispatch_review "$owner" "$repo" "$pr" "$eid" "$requester" "$at" "$author" "$cls"
  done < <(rw_review_requests)
```

- [ ] **Step 4: Run the fast suite**

Run: `bash test/review-watcher.test.sh | tail -1`
Expected: `59 passed, 0 failed` (including `test_watcher_holds_reactions_while_logged_out`).

- [ ] **Step 5: Document it in the README**

In `README.md`, directly after the line beginning `Pause: \`touch ~/.review-watcher/PAUSED\``, add:

```markdown
Reviews: request a review from @nonreagent on a PR by an allowlisted author and the watcher launches a reviewer session that approves or requests changes; re-request for another pass. While any watcher session works a PR, @nonreagent is its assignee, so `assignee:nonreagent` lists the PRs in flight. Re-run `~/bin/setup-review-watcher` after upgrading to install the review playbook.
```

And change the `Design + plan:` line to also list `docs/superpowers/specs/2026-10-14-review-watcher-reviewer-design.md` and `docs/superpowers/plans/2026-10-14-review-watcher-reviewer.md`.

- [ ] **Step 6: Rebuild, run the gate, commit**

```bash
./build.sh >/dev/null && ./test/run.sh | tail -3
git add overlay test home manifest README.md
git commit -m "Dispatch reviewer sessions from the watcher

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the series

1. Final whole-branch review on the top-tier model against the spec.
2. Push, open the PR against `nonreagent/dotfiles` (`gh pr create --repo nonreagent/dotfiles`), request review from @nonrational. No issue exists, so the body has no link line: the four H3 sections only.
3. Deploy is the operator's call after merge: `git -C ~/.dotfiles pull`, `./install.sh`, `~/bin/setup-review-watcher` (copies `review-playbook.md`, restarts nothing by itself), `sudo systemctl restart review-watcher`.
4. Live acceptance from the spec's Testing section.
