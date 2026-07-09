# Review Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A systemd-supervised bash watcher on the exe.dev VM that polls @nonreagent's open PRs and, on a trusted reviewer's review, spawns a headless Claude session to react (address change-requests or merge on approval).

**Architecture:** Three layers with clean seams. A **library** (`review-watcher-lib.sh`) holds pure, unit-tested functions (classification, dedup state, playbook rendering). A **supervisor** (`review-watcher --supervise`) runs directly under systemd, polls via `gh`, and dispatches. A **reaction wrapper** (`review-react`) clones/checks-out the PR and launches `claude` in a tmux window. Reactions live in tmux windows on a dedicated socket (attachable); the supervisor logs to journald.

> **Refinement vs the spec:** the spec put "the supervisor in tmux window 0." Planning revealed that running the supervisor *directly* under systemd (journald logs, `Restart=always`) and using tmux only for the *reaction* windows is more robust — systemd genuinely supervises the loop instead of a detached tmux server it can't track. Goals unchanged: durable (systemd), reactions attachable (`tmux -S <socket> attach`), observable (journald + per-reaction log + tmux).

> **Refinement after live test (Task 11):** the spec's reaction runtime was `claude --remote-control`, for live-steering. Launched detached inside the reaction tmux session, its TUI stalled — process state `T`, 0% CPU, the seeded prompt never ran. `--remote-control` needs an attended interactive TTY; it can't drive an unattended background process. Task 6's `review-react` now launches **headless** (`claude -p`), which runs the prompt autonomously to completion. Trade-off: no remote-control live-steering. Observability: the reaction log (`claude -p` buffers, so it mostly fills in on completion), `journalctl -u review-watcher`, `tmux -S ~/.review-watcher/tmux.sock attach` for a still-running session, and the PR itself updating. The tmux session per reaction is kept (isolation + `MAX_CONCURRENT` counting via `rw_session_name` → `<repo>-pr-<n>`); it's just no longer an RC window.

**Tech Stack:** Bash, `gh` CLI (GitHub REST/GraphQL), `claude` CLI (headless `-p` + bypassPermissions), tmux (dedicated socket), systemd (system unit, `User=exedev`), `flock`, `timeout`. Tests: pure-bash `check()` harness matching `test/run.sh` (no bats).

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-07-08-review-watcher-design.md`. Every task's requirements implicitly include these.

- **Permission mode:** launch reactions with `--permission-mode bypassPermissions`. Never set `permissions.defaultMode` globally.
- **Reaction runtime:** `claude -p "<prompt>" --permission-mode bypassPermissions --verbose` — headless, runs to completion and exits. The reaction tmux session is kept for isolation and `MAX_CONCURRENT` counting, not for live-steering.
- **Trust boundary:** only reviews authored by a login in `REVIEWER_ALLOWLIST` (default `nonrational`) trigger action; others → notify-only.
- **Repo scope:** all visible @nonreagent open PRs (`gh search prs --author nonreagent --state open`).
- **Skip:** draft PRs; reviews self-authored by `nonreagent`.
- **Guardrails:** CI-green + `MERGEABLE` before any merge — enforced structurally by `rw-merge` (bash, not the reacting model: `rw_merge_ready` classifies READY/PENDING/NOT_READY from `gh pr view --json reviewDecision,mergeable,statusCheckRollup`, and only a READY verdict may squash-merge); per-PR `flock`; `MAX_CONCURRENT` (default 2) reaction windows; `REACTION_TIMEOUT` (default 1500s) kill; `PAUSED` flag / `systemctl stop` kill switch; mark a review "seen" only after the reaction succeeds.
- **Never re-request review from someone whose latest review is an approval** — check `reviewDecision`. (Approved is routed to merge, never to re-request.)
- **No Claude self-promotion:** commit messages and PR/issue/comment bodies carry only the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` credit — never a "Generated with Claude Code" line or a `claude.ai` session link. (This applies to reaction commits too.)
- **Placement:** agent-only. Scripts live in `overlay/bin/`, vendored to `home/bin/` by `build.sh`; runtime state in `~/.review-watcher/`; systemd unit installed by `setup-review-watcher` (a `sudo` copy, not symlinked).
- **Version floor:** `claude` ≥ 2.1.51 (VM has 2.1.204).

---

## File Structure

**Created in the repo (source of truth):**

- `overlay/bin/review-watcher-lib.sh` — pure functions: config load, dedup state, allowlist, classification, session naming, playbook render. Sourced by the scripts and the tests.
- `overlay/bin/review-watcher` — supervisor: poll loop + dispatch (`--supervise`), plus `--once` for a single poll (testing).
- `overlay/bin/review-react` — reaction wrapper: lock, clone/checkout, render playbook, launch `claude`, mark seen.
- `overlay/bin/setup-review-watcher` — one-time installer: create `~/.review-watcher/`, seed playbook + config, install & enable the systemd unit.
- `overlay/bin/rw-merge` — guarded merge helper: the bash structural gate on the one irreversible action (auto-merge). Polls `rw_merge_ready`; squash-merges only on `READY`.
- `overlay/review-watcher/playbook.md` — reaction prompt template (placeholders `{{REPO}}`, `{{PR}}`, `{{REVIEW_STATE}}`, `{{REVIEWER}}`).
- `overlay/review-watcher/config.example` — config template.
- `overlay/review-watcher/review-watcher.service` — systemd unit template.
- `test/review-watcher.test.sh` — unit tests for the library.

**Modified:**

- `build.sh` — new step: vendor `overlay/bin/*` into `home/bin/` (after the `bin.Linux` copy).
- `test/run.sh` — run the new test file.
- `README.md` — one-time `setup-review-watcher` note.

**Generated by `build.sh` (committed so `install.sh` symlinks them):** `home/bin/review-watcher-lib.sh`, `home/bin/review-watcher`, `home/bin/review-react`, `home/bin/setup-review-watcher`, `home/bin/rw-merge`.

**Runtime (created on the VM, never committed):** `~/.review-watcher/{config,playbook.md,state/,locks/,logs/,repos/,tmux.sock,PAUSED}`.

---

## Task 1: Library skeleton — config load + state paths

**Files:**
- Create: `overlay/bin/review-watcher-lib.sh`
- Create: `overlay/review-watcher/config.example`
- Test: `test/review-watcher.test.sh`

**Interfaces:**
- Produces: `rw_load_config` (sets `POLL_INTERVAL REVIEWER_ALLOWLIST MAX_CONCURRENT REACTION_TIMEOUT`); `rw_seen_file owner repo pr` → path string; globals `RW_HOME` (default `$HOME/.review-watcher`), `RW_BOT_LOGIN` (default `nonreagent`).

- [ ] **Step 1: Write the failing test**

```bash
# test/review-watcher.test.sh
#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; failc=0
check() { if "$@"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; failc=$((failc+1)); fi; }

# Isolate runtime state in a temp dir so tests never touch a real ~/.review-watcher.
RW_HOME="$(mktemp -d)"; export RW_HOME
export RW_BOT_LOGIN="nonreagent"
. "$REPO/overlay/bin/review-watcher-lib.sh"

test_config_defaults() {
  rw_load_config
  [ "$POLL_INTERVAL" = "45" ] && [ "$REVIEWER_ALLOWLIST" = "nonrational" ] \
    && [ "$MAX_CONCURRENT" = "2" ] && [ "$REACTION_TIMEOUT" = "1500" ]
}

test_config_override() {
  printf 'POLL_INTERVAL=10\nMAX_CONCURRENT=5\n' > "$RW_HOME/config"
  rw_load_config
  local ok=0
  [ "$POLL_INTERVAL" = "10" ] && [ "$MAX_CONCURRENT" = "5" ] \
    && [ "$REVIEWER_ALLOWLIST" = "nonrational" ] && ok=1   # unset keys keep defaults
  rm -f "$RW_HOME/config"
  [ "$ok" = 1 ]
}

test_seen_file_path() {
  [ "$(rw_seen_file nonrational myrepo 42)" = "$RW_HOME/state/nonrational__myrepo__42.seen" ]
}

check test_config_defaults
check test_config_override
check test_seen_file_path
echo "----"; echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/review-watcher.test.sh`
Expected: FAIL — `review-watcher-lib.sh` does not exist (`No such file`).

- [ ] **Step 3: Write the minimal library**

```bash
# overlay/bin/review-watcher-lib.sh
# Pure helpers for the review watcher. Sourced by the scripts and the tests;
# never executed directly. No side effects at source time.

: "${RW_HOME:=$HOME/.review-watcher}"
: "${RW_BOT_LOGIN:=nonreagent}"

rw_load_config() {
  POLL_INTERVAL=45
  REVIEWER_ALLOWLIST="nonrational"
  MAX_CONCURRENT=2
  REACTION_TIMEOUT=1500
  [ -f "$RW_HOME/config" ] && . "$RW_HOME/config"
}

rw_seen_file() { # owner repo pr
  printf '%s/state/%s__%s__%s.seen' "$RW_HOME" "$1" "$2" "$3"
}
```

- [ ] **Step 4: Create the config template**

```sh
# overlay/review-watcher/config.example
# Copy to ~/.review-watcher/config and edit. Unset keys keep the built-in defaults.
POLL_INTERVAL=45              # seconds between polls
REVIEWER_ALLOWLIST="nonrational"   # space-separated GitHub logins that may trigger action
MAX_CONCURRENT=2             # max simultaneous reaction windows
REACTION_TIMEOUT=1500        # seconds before a stuck reaction is killed (25m)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/review-watcher.test.sh`
Expected: PASS — `3 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add overlay/bin/review-watcher-lib.sh overlay/review-watcher/config.example test/review-watcher.test.sh
git commit -m "Review watcher: config load + state paths"
```

---

## Task 2: Dedup state — is_seen / mark_seen

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Test: `test/review-watcher.test.sh`

**Interfaces:**
- Consumes: `rw_seen_file` (Task 1).
- Produces: `rw_is_seen owner repo pr review_id` → exit 0 iff that exact review id was already handled; `rw_mark_seen owner repo pr review_id` → records it.

- [ ] **Step 1: Add the failing tests** (append inside `test/review-watcher.test.sh` before the `check` calls)

```bash
test_unseen_then_seen() {
  rw_is_seen nonrational myrepo 42 REVIEW_A && return 1   # nothing recorded yet
  rw_mark_seen nonrational myrepo 42 REVIEW_A
  rw_is_seen nonrational myrepo 42 REVIEW_A               # now seen
}

test_new_review_id_is_unseen() {
  rw_mark_seen nonrational myrepo 42 REVIEW_A
  rw_is_seen nonrational myrepo 42 REVIEW_B && return 1   # a newer review id is unseen
  return 0
}
```

Add `check test_unseen_then_seen` and `check test_new_review_id_is_unseen` to the check list.

- [ ] **Step 2: Run to verify failure**

Run: `bash test/review-watcher.test.sh`
Expected: FAIL — `rw_is_seen: command not found`.

- [ ] **Step 3: Implement** (append to `review-watcher-lib.sh`)

```bash
rw_is_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  [ -f "$f" ] && [ "$(cat "$f")" = "$4" ]
}

rw_mark_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  mkdir -p "$(dirname "$f")"
  printf '%s' "$4" > "$f"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash test/review-watcher.test.sh`
Expected: PASS — `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add overlay/bin/review-watcher-lib.sh test/review-watcher.test.sh
git commit -m "Review watcher: at-most-once dedup state"
```

---

## Task 3: Classification — the trust + routing core

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Test: `test/review-watcher.test.sh`

**Interfaces:**
- Produces: `rw_in_allowlist login "space list"` → exit 0 iff present; `rw_classify reviewer state is_draft pr_author` → echoes one of `SKIP | NOTIFY | REACT_APPROVED | REACT_CHANGES | REACT_COMMENTED`. Reads `REVIEWER_ALLOWLIST` and `RW_BOT_LOGIN`.

- [ ] **Step 1: Add failing tests**

```bash
test_classify_untrusted_is_notify() {
  REVIEWER_ALLOWLIST="nonrational"
  [ "$(rw_classify someone_else APPROVED false alice)" = "NOTIFY" ]
}
test_classify_draft_is_skip() {
  REVIEWER_ALLOWLIST="nonrational"
  [ "$(rw_classify nonrational APPROVED true nonreagent)" = "SKIP" ]
}
test_classify_self_review_is_skip() {
  REVIEWER_ALLOWLIST="nonreagent nonrational"
  [ "$(rw_classify nonreagent APPROVED false nonreagent)" = "SKIP" ]
}
test_classify_trusted_states() {
  REVIEWER_ALLOWLIST="nonrational"
  [ "$(rw_classify nonrational APPROVED false nonreagent)" = "REACT_APPROVED" ] \
  && [ "$(rw_classify nonrational CHANGES_REQUESTED false nonreagent)" = "REACT_CHANGES" ] \
  && [ "$(rw_classify nonrational COMMENTED false nonreagent)" = "REACT_COMMENTED" ] \
  && [ "$(rw_classify nonrational DISMISSED false nonreagent)" = "SKIP" ]
}
```

Add the four `check` lines.

- [ ] **Step 2: Run to verify failure**

Run: `bash test/review-watcher.test.sh`
Expected: FAIL — `rw_classify: command not found`.

- [ ] **Step 3: Implement** (append to `review-watcher-lib.sh`)

```bash
rw_in_allowlist() { # login "space separated list"
  local login="$1" x
  for x in $2; do [ "$x" = "$login" ] && return 0; done
  return 1
}

rw_classify() { # reviewer state is_draft pr_author
  local reviewer="$1" state="$2" is_draft="$3"
  [ "$is_draft" = "true" ] && { echo SKIP; return; }
  [ "$reviewer" = "$RW_BOT_LOGIN" ] && { echo SKIP; return; }
  rw_in_allowlist "$reviewer" "$REVIEWER_ALLOWLIST" || { echo NOTIFY; return; }
  case "$state" in
    APPROVED)          echo REACT_APPROVED ;;
    CHANGES_REQUESTED) echo REACT_CHANGES ;;
    COMMENTED)         echo REACT_COMMENTED ;;
    *)                 echo SKIP ;;
  esac
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash test/review-watcher.test.sh`
Expected: PASS — `9 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add overlay/bin/review-watcher-lib.sh test/review-watcher.test.sh
git commit -m "Review watcher: review classification (trust + routing)"
```

---

## Task 4: Session naming + playbook render

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Create: `overlay/review-watcher/playbook.md`
- Test: `test/review-watcher.test.sh`

**Interfaces:**
- Produces: `rw_session_name owner repo pr` → `<repo>-pr-<pr>` (repo-qualified, resolving spec open-risk #3); `rw_render_playbook template_file repo pr review_state reviewer` → prompt on stdout with placeholders substituted.

- [ ] **Step 1: Add failing tests**

```bash
test_session_name_is_repo_qualified() {
  [ "$(rw_session_name nonrational myrepo 131)" = "myrepo-pr-131" ]
}
test_render_substitutes_placeholders() {
  local tpl; tpl="$(mktemp)"
  printf 'repo={{REPO}} pr={{PR}} state={{REVIEW_STATE}} who={{REVIEWER}}\n' > "$tpl"
  local out; out="$(rw_render_playbook "$tpl" myrepo 131 CHANGES_REQUESTED nonrational)"
  rm -f "$tpl"
  [ "$out" = "repo=myrepo pr=131 state=CHANGES_REQUESTED who=nonrational" ]
}
```

Add the two `check` lines.

- [ ] **Step 2: Run to verify failure**

Run: `bash test/review-watcher.test.sh`
Expected: FAIL — `rw_session_name: command not found`.

- [ ] **Step 3: Implement** (append to `review-watcher-lib.sh`)

```bash
rw_session_name() { # owner repo pr
  printf '%s-pr-%s' "$2" "$3"
}

rw_render_playbook() { # template_file repo pr review_state reviewer
  sed -e "s|{{REPO}}|$2|g" -e "s|{{PR}}|$3|g" \
      -e "s|{{REVIEW_STATE}}|$4|g" -e "s|{{REVIEWER}}|$5|g" "$1"
}
```

- [ ] **Step 4: Write the reaction playbook**

```markdown
You are Agent Norton (@nonreagent). A review just landed on PR #{{PR}} of {{REPO}},
authored by @{{REVIEWER}}, with state {{REVIEW_STATE}}. You are already checked out on
the PR branch in this repo. React autonomously, then exit.

Ground rules (non-negotiable):
- Follow this repo's CLAUDE.md and your ~/.claude rules. Commit messages carry ONLY the
  Co-Authored-By model credit — never a "Generated with Claude Code" line or a claude.ai
  session link, in commits, PR/issue bodies, or comments.
- Verify with the project's own gate (CLAUDE.md / justfile) before any push. Never push red.
- Iterate on THIS PR's branch. Never open a new PR.
- If the right action is unclear, needs a product decision, or would break the rules, do NOT
  guess: post a short clarifying comment, then exit without pushing or merging.

If the review state is CHANGES_REQUESTED:
1. Read the PR (title, body, diff), the review body AND its inline comments, and the linked issue.
2. Interpret intent — feedback is often a symptom. Understand WHY the reviewer objected and
   re-scope if that is the honest fix (remove, don't just relabel).
3. Bring the branch current if behind/conflicting (merge origin/main, resolve), then make the change.
4. Verify (project gate). Commit. Push to this same branch.
5. Reply in-thread to the review comment(s) explaining the change. Retitle/rewrite the PR body
   if scope changed.
6. Re-request review from @{{REVIEWER}}. Then stop — do NOT merge.

If the review state is APPROVED:
1. Confirm reviewDecision is still APPROVED, mergeable is MERGEABLE, and the CI rollup is green
   — wait/poll if CI is pending. Resolve conflicts if origin/main moved (keep new work, drop
   intended deletions), push, wait for CI.
2. Squash-merge (match the repo's convention). Never re-request review on an approved PR.

If the review state is COMMENTED:
- Reply only if there is a concrete question or ask; otherwise acknowledge briefly or do nothing.
```

- [ ] **Step 5: Run to verify pass**

Run: `bash test/review-watcher.test.sh`
Expected: PASS — `11 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add overlay/bin/review-watcher-lib.sh overlay/review-watcher/playbook.md test/review-watcher.test.sh
git commit -m "Review watcher: session naming + playbook render + template"
```

---

## Task 5: Poll — enumerate PRs and read the latest review

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Test: `test/review-watcher.test.sh`

**Interfaces:**
- Produces: `rw_open_prs` → prints `owner<TAB>repo<TAB>number<TAB>isDraft<TAB>author` per open @nonreagent PR; `rw_latest_review owner repo pr` → prints `review_id<TAB>state<TAB>author` for the most recent non-PENDING review (empty if none). Both shell out to `gh`; tests inject a stub `gh` on `PATH`.

- [ ] **Step 1: Add failing tests** (stub `gh` so no network is touched)

```bash
test_open_prs_parses_search() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
# stub: emit one fake search hit as gh would with --json
cat <<'JSON'
[{"repository":{"nameWithOwner":"nonrational/myrepo"},"number":131,"isDraft":false,"author":{"login":"nonreagent"}}]
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_open_prs)"
  rm -rf "$bin"
  [ "$out" = "$(printf 'nonrational\tmyrepo\t131\tfalse\tnonreagent')" ]
}

test_latest_review_picks_newest_nonpending() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"id":1,"state":"COMMENTED","user":{"login":"nonrational"},"submitted_at":"2026-07-01T00:00:00Z"},
 {"id":2,"state":"APPROVED","user":{"login":"nonrational"},"submitted_at":"2026-07-02T00:00:00Z"},
 {"id":3,"state":"PENDING","user":{"login":"nonrational"},"submitted_at":null}]
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_latest_review nonrational myrepo 131)"
  rm -rf "$bin"
  [ "$out" = "$(printf '2\tAPPROVED\tnonrational')" ]
}
```

Add the two `check` lines. (These require `jq`, already used across this repo's tooling.)

- [ ] **Step 2: Run to verify failure**

Run: `bash test/review-watcher.test.sh`
Expected: FAIL — `rw_open_prs: command not found`.

- [ ] **Step 3: Implement** (append to `review-watcher-lib.sh`)

```bash
rw_open_prs() {
  gh search prs --author "$RW_BOT_LOGIN" --state open \
     --json repository,number,isDraft,author --limit 100 \
   | jq -r '.[] | [(.repository.nameWithOwner|split("/")[0]),
                    (.repository.nameWithOwner|split("/")[1]),
                    (.number|tostring), (.isDraft|tostring), .author.login]
                   | @tsv'
}

rw_latest_review() { # owner repo pr — newest non-PENDING review, or empty
  gh api "repos/$1/$2/pulls/$3/reviews" --paginate \
   | jq -rs 'add | map(select(.state != "PENDING")) | sort_by(.submitted_at) | last
             | if . == null then empty else [(.id|tostring), .state, .user.login] | @tsv end'
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash test/review-watcher.test.sh`
Expected: PASS — `13 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add overlay/bin/review-watcher-lib.sh test/review-watcher.test.sh
git commit -m "Review watcher: PR enumeration + latest-review read"
```

---

## Task 6: Reaction wrapper — `review-react`

**Files:**
- Create: `overlay/bin/review-react`
- Test: manual (integration; launches `claude`).

**Interfaces:**
- Consumes: `rw_load_config`, `rw_render_playbook`, `rw_mark_seen`, `RW_HOME`.
- Produces: CLI `review-react <owner> <repo> <pr> <review_id> <review_state> <reviewer>`. Holds a per-PR `flock`, ensures a clone under `$RW_HOME/repos/<owner>/<repo>`, checks out the PR branch, launches `claude` under `timeout`, and on success calls `rw_mark_seen`. A `RW_DRY_RUN=1` env prints the `claude` command instead of running it (used by Step 2).

- [ ] **Step 1: Write the wrapper**

```bash
# overlay/bin/review-react
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/review-watcher-lib.sh"
rw_load_config

owner="$1"; repo="$2"; pr="$3"; review_id="$4"; state="$5"; reviewer="$6"
lock="$RW_HOME/locks/${owner}__${repo}__${pr}.lock"
mkdir -p "$RW_HOME/locks" "$RW_HOME/logs" "$RW_HOME/repos/$owner"
exec 9>"$lock"
flock -n 9 || { echo "review-react: $owner/$repo#$pr already in flight, skipping" >&2; exit 0; }

prompt="$(rw_render_playbook "$RW_HOME/playbook.md" "$repo" "$pr" "$state" "$reviewer")"
log="$RW_HOME/logs/${repo}-pr-${pr}.log"

# Headless: --remote-control needs an attended TTY and stalls in a detached tmux
# session, so run non-interactively. --verbose streams turn-by-turn to the log so
# `tail -f` shows live progress.
cmd=(timeout "$REACTION_TIMEOUT" claude -p "$prompt"
     --permission-mode bypassPermissions --verbose)

if [ "${RW_DRY_RUN:-0}" = "1" ]; then
  printf '%q ' "${cmd[@]}"; echo; exit 0
fi

clone="$RW_HOME/repos/$owner/$repo"
if [ -d "$clone/.git" ]; then
  git -C "$clone" fetch --quiet origin
else
  gh repo clone "$owner/$repo" "$clone" -- --quiet
fi
cd "$clone"
gh pr checkout "$pr" >/dev/null 2>&1 || {
  git fetch --quiet origin "pull/$pr/head"
  git checkout --quiet FETCH_HEAD
}

if "${cmd[@]}" 2>&1 | tee -a "$log"; then
  rw_mark_seen "$owner" "$repo" "$pr" "$review_id"
else
  echo "review-react: reaction on $owner/$repo#$pr failed or timed out; leaving unseen for retry" >&2
fi
```

- [ ] **Step 2: Verify the command assembly (dry run, no clone)**

The `RW_DRY_RUN` check runs before any clone/checkout, so this needs no origin remote and no
pre-created git repo — the whole point of the seam.

Run:
```bash
chmod +x overlay/bin/review-react
RW_HOME="$(mktemp -d)"; mkdir -p "$RW_HOME"
cp overlay/review-watcher/config.example "$RW_HOME/config"
cp overlay/review-watcher/playbook.md "$RW_HOME/playbook.md"
RW_HOME="$RW_HOME" RW_DRY_RUN=1 overlay/bin/review-react nonrational myrepo 131 REVIEW_X CHANGES_REQUESTED nonrational
```
Expected: a single line beginning `timeout 1500 claude -p` followed by the quoted prompt, then `--permission-mode bypassPermissions --verbose`, exit 0. Confirm headless `-p` (no `--remote-control`).

- [ ] **Step 3: Commit**

```bash
git add overlay/bin/review-react
git commit -m "Review watcher: reaction wrapper (clone, checkout, launch claude)"
```

---

## Task 7: Supervisor loop — `review-watcher`

**Files:**
- Create: `overlay/bin/review-watcher`
- Test: manual (integration).

**Interfaces:**
- Consumes: all library functions; `review-react` on `PATH`.
- Produces: CLI `review-watcher --once` (single poll pass) and `review-watcher --supervise` (loop). Dispatches REACT_* via `tmux -S $RW_HOME/tmux.sock new-window` running `review-react`, respecting `MAX_CONCURRENT` and per-PR locks; NOTIFY/SKIP → `rw_mark_seen`. Honors the `PAUSED` flag.

- [ ] **Step 1: Write the supervisor**

```bash
# overlay/bin/review-watcher
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/review-watcher-lib.sh"
rw_load_config
SOCK="$RW_HOME/tmux.sock"

rw_active_reactions() { tmux -S "$SOCK" list-sessions 2>/dev/null | wc -l || true; }

rw_dispatch() { # owner repo pr review_id state reviewer classification
  local owner="$1" repo="$2" pr="$3" rid="$4" state="$5" reviewer="$6" cls="$7"
  case "$cls" in
    SKIP)   rw_mark_seen "$owner" "$repo" "$pr" "$rid" ;;
    NOTIFY)
      gh pr comment "$pr" --repo "$owner/$repo" \
         --body "@nonrational — review by @$reviewer ($state) detected; not acting (reviewer not in allowlist)." \
         >/dev/null 2>&1 || true
      rw_mark_seen "$owner" "$repo" "$pr" "$rid" ;;
    REACT_*)
      if [ "$(rw_active_reactions)" -ge "$MAX_CONCURRENT" ]; then
        echo "at concurrency cap ($MAX_CONCURRENT); deferring $owner/$repo#$pr" >&2; return
      fi
      local sess; sess="$(rw_session_name "$owner" "$repo" "$pr")"
      if tmux -S "$SOCK" has-session -t "$sess" 2>/dev/null; then
        echo "reaction already in flight for $sess; skipping" >&2; return
      fi
      tmux -S "$SOCK" new-session -d -s "$sess" \
        "$HERE/review-react $owner $repo $pr $rid $state $reviewer" ;;
  esac
}

rw_poll_once() {
  [ -f "$RW_HOME/PAUSED" ] && { echo "PAUSED flag set; skipping poll" >&2; return; }
  local owner repo pr is_draft author rid state reviewer cls
  while IFS=$'\t' read -r owner repo pr is_draft author; do
    [ -n "$owner" ] || continue
    IFS=$'\t' read -r rid state reviewer < <(rw_latest_review "$owner" "$repo" "$pr")
    [ -n "${rid:-}" ] || continue
    rw_is_seen "$owner" "$repo" "$pr" "$rid" && continue
    cls="$(rw_classify "$reviewer" "$state" "$is_draft" "$author")"
    echo "$(date -u +%H:%M:%S) $owner/$repo#$pr review=$rid $state by=$reviewer -> $cls"
    rw_dispatch "$owner" "$repo" "$pr" "$rid" "$state" "$reviewer" "$cls"
  done < <(rw_open_prs)
}

case "${1:---once}" in
  --once)      rw_poll_once ;;
  --supervise) while true; do rw_poll_once; sleep "$POLL_INTERVAL"; done ;;
  *) echo "usage: review-watcher [--once|--supervise]" >&2; exit 2 ;;
esac
```

- [ ] **Step 2: Verify a single poll classifies without dispatching (stubbed)**

Run:
```bash
chmod +x overlay/bin/review-watcher
RW_HOME="$(mktemp -d)"; export RW_HOME
cp overlay/review-watcher/config.example "$RW_HOME/config"
bin="$(mktemp -d)"
# stub gh: one non-draft PR, latest review APPROVED by an UNTRUSTED user -> NOTIFY path,
# but stub `pr comment` to a no-op so we assert classification only.
cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"search prs"*) echo '[{"repository":{"nameWithOwner":"nonrational/myrepo"},"number":131,"isDraft":false,"author":{"login":"nonreagent"}}]';;
  *"/reviews"*)   echo '[{"id":9,"state":"APPROVED","user":{"login":"stranger"},"submitted_at":"2026-07-02T00:00:00Z"}]';;
  *"pr comment"*) exit 0;;
esac
STUB
chmod +x "$bin/gh"
PATH="$bin:$PATH" overlay/bin/review-watcher --once
```
Expected: a log line `... nonrational/myrepo#131 review=9 APPROVED by=stranger -> NOTIFY`, and `state/nonrational__myrepo__131.seen` now contains `9` (marked seen after the notify). No tmux window opened.

- [ ] **Step 3: Commit**

```bash
git add overlay/bin/review-watcher
git commit -m "Review watcher: supervisor poll loop + dispatch"
```

---

## Task 8: Installer + systemd unit

**Files:**
- Create: `overlay/bin/setup-review-watcher`
- Create: `overlay/review-watcher/review-watcher.service`
- Test: manual (on the VM).

**Interfaces:**
- Consumes: the built `~/bin/review-*` scripts, the overlay templates.
- Produces: a populated `~/.review-watcher/`, an installed & enabled `review-watcher.service`.

- [ ] **Step 1: Write the systemd unit template**

```ini
# overlay/review-watcher/review-watcher.service
[Unit]
Description=Agent PR-review watcher (@nonreagent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=exedev
Environment=RW_HOME=/home/exedev/.review-watcher
Environment=PATH=/home/exedev/.local/bin:/home/exedev/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/exedev/bin/review-watcher --supervise
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Write the installer**

```bash
# overlay/bin/setup-review-watcher
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RW_HOME="$HOME/.review-watcher"
# Templates ship beside the built scripts under ~/bin? No — they live in the repo's
# overlay, resolved via the script's real location's repo root.
SRC="$(cd "$HERE/../.." && pwd)/overlay/review-watcher"   # when run from a repo checkout
[ -d "$SRC" ] || SRC="$HERE/../review-watcher"            # fallback

mkdir -p "$RW_HOME"/{state,locks,logs,repos}
[ -f "$RW_HOME/config" ]   || cp "$SRC/config.example" "$RW_HOME/config"
cp "$SRC/playbook.md" "$RW_HOME/playbook.md"              # playbook always refreshed from source

sudo cp "$SRC/review-watcher.service" /etc/systemd/system/review-watcher.service
sudo systemctl daemon-reload
sudo systemctl enable --now review-watcher.service
echo "review-watcher installed. Logs: journalctl -u review-watcher -f"
echo "Attach reactions: tmux -S $RW_HOME/tmux.sock attach"
echo "Pause: touch $RW_HOME/PAUSED   (or: sudo systemctl stop review-watcher)"
```

> **Note for the implementer:** `setup-review-watcher` reads templates from the repo's `overlay/review-watcher/`. On the VM the repo lives at `~/.dotfiles`; run the installer from there (`~/.dotfiles/overlay/bin/setup-review-watcher`) or after `install.sh` symlinks `~/bin/setup-review-watcher`, which resolves back into `~/.dotfiles` via `readlink -f`. Verify the `SRC` resolution in Step 3 before relying on it.

- [ ] **Step 3: Verify template resolution (no sudo)**

Run:
```bash
chmod +x overlay/bin/setup-review-watcher
HERE="$(cd overlay/bin && pwd)"; SRC="$(cd "$HERE/../.." && pwd)/overlay/review-watcher"
[ -f "$SRC/playbook.md" ] && [ -f "$SRC/review-watcher.service" ] && echo "SRC resolves: $SRC"
```
Expected: `SRC resolves: /home/exedev/.dotfiles/overlay/review-watcher`.

- [ ] **Step 4: Commit**

```bash
git add overlay/bin/setup-review-watcher overlay/review-watcher/review-watcher.service
git commit -m "Review watcher: installer + systemd unit"
```

---

## Task 9: build.sh integration + home/ mirror

**Files:**
- Modify: `build.sh`
- Create: `home/bin/review-watcher-lib.sh`, `home/bin/review-watcher`, `home/bin/review-react`, `home/bin/setup-review-watcher` (mirrors of the overlay scripts, so `install.sh` symlinks them now).

**Interfaces:** none (build wiring).

- [ ] **Step 1: Add the vendor step to `build.sh`** after step 3 (`bin.Linux -> bin`)

Insert:
```bash
# 3b. nonreagent overlay bin scripts (agent-only tools; e.g. the review watcher).
cp "$OVERLAY"/bin/* "$OUT/bin/"
```

- [ ] **Step 2: Mirror the scripts into `home/bin` so the committed tree is installable now**

Run:
```bash
cp overlay/bin/review-watcher-lib.sh overlay/bin/review-watcher overlay/bin/review-react overlay/bin/setup-review-watcher home/bin/
chmod +x home/bin/review-watcher home/bin/review-react home/bin/setup-review-watcher
```

- [ ] **Step 3: Verify build determinism (idempotency contract)**

Run: `./build.sh >/dev/null && ./build.sh >/dev/null && echo OK`
Expected: `OK` (build.sh clones upstream fresh; the run must not error). Then confirm the watcher scripts survive a build:
Run: `ls home/bin/review-watcher home/bin/review-react home/bin/review-watcher-lib.sh home/bin/setup-review-watcher`
Expected: all four listed.

> If `./build.sh` pulls unrelated upstream drift into `home/`, that is the normal build behavior — review the diff and keep only the watcher additions if you want a scoped PR (`git checkout -- home/<unrelated>`).

- [ ] **Step 4: Commit**

```bash
git add build.sh home/bin/review-watcher-lib.sh home/bin/review-watcher home/bin/review-react home/bin/setup-review-watcher
git commit -m "Review watcher: vendor scripts into home/bin via build.sh"
```

---

## Task 10: Wire tests + README

**Files:**
- Modify: `test/run.sh`, `README.md`

- [ ] **Step 1: Run the new unit tests from `run.sh`** — add before the final summary block

```bash
test_review_watcher_units() { bash "$REPO/test/review-watcher.test.sh" >/dev/null; }
```
and add `check test_review_watcher_units` to the check list.

- [ ] **Step 2: Verify the suite passes**

Run: `bash test/review-watcher.test.sh && echo UNITS_OK`
Expected: `13 passed, 0 failed` then `UNITS_OK`.

- [ ] **Step 3: Add a README section** under "Install"

```markdown
### Review watcher (optional)

Autonomously react to PR reviews on @nonreagent's open PRs. One-time setup on the VM:

    ~/bin/setup-review-watcher     # creates ~/.review-watcher, installs + enables the systemd unit

Observe: `journalctl -u review-watcher -f` · attach reactions: `tmux -S ~/.review-watcher/tmux.sock attach`.
Pause: `touch ~/.review-watcher/PAUSED` or `sudo systemctl stop review-watcher`.
Design + plan: `docs/superpowers/specs/2026-07-08-review-watcher-design.md`, `docs/superpowers/plans/2026-07-08-review-watcher.md`.
```

- [ ] **Step 4: Commit**

```bash
git add test/run.sh README.md
git commit -m "Review watcher: wire unit tests into run.sh + document"
```

---

## Task 11: End-to-end verification on the VM

**Files:** none (operational).

- [ ] **Step 1: Install**

Run: `~/.dotfiles/install.sh && ~/bin/setup-review-watcher`
Expected: `review-watcher installed`. `systemctl is-active review-watcher` → `active`.

- [ ] **Step 2: Confirm the supervisor is polling**

Run: `journalctl -u review-watcher -n 20 --no-pager`
Expected: periodic poll output (or silence if no unseen reviews), no crash loop.

- [ ] **Step 3: Trigger a real reaction (controlled)**

On a throwaway @nonreagent PR, have @nonrational leave a `CHANGES_REQUESTED` review. Within ~`POLL_INTERVAL`s:
- Run: `tmux -S ~/.review-watcher/tmux.sock list-windows` → a `pr-<n>` window appears.
- Run: `tmux -S ~/.review-watcher/tmux.sock attach` → watch the reaction while it's still running; or `tail -f ~/.review-watcher/logs/<repo>-pr-<n>.log`.
Expected: the branch gets an addressing commit + push, an in-thread reply, and a re-requested review; the review id lands in `~/.review-watcher/state/`.

- [ ] **Step 4: Verify the kill switch**

Run: `touch ~/.review-watcher/PAUSED` → next poll logs `PAUSED flag set; skipping`. Then `rm ~/.review-watcher/PAUSED` resumes.

- [ ] **Step 5: Verify reboot survival**

Run: `sudo reboot`; after boot, `systemctl is-active review-watcher` → `active`, and `~/.review-watcher/state/` is intact (no re-reaction to handled reviews).

---

## Task 12: Guarded merge helper (rw-merge)

**Files:**
- Modify: `overlay/bin/review-watcher-lib.sh`
- Create: `overlay/bin/rw-merge` (mirrored to `home/bin/rw-merge` by the same `build.sh` glob)
- Modify: `overlay/review-watcher/playbook.md`
- Test: `test/review-watcher.test.sh`

**Why:** the reacting Claude session decides *when* a PR is ready to merge, but merging is the one
irreversible action in this whole system. Rather than trust the model's judgment on the merge
gate, the gate is a bash function the model cannot talk its way around.

**Interfaces:**
- Produces: `rw_merge_ready owner repo pr` → echoes `READY | PENDING | NOT_READY`. Runs
  `gh pr view "$pr" --repo "$owner/$repo" --json reviewDecision,mergeable,statusCheckRollup` and
  classifies with `jq`: `READY` iff `reviewDecision == APPROVED` and `mergeable == MERGEABLE` and
  the `statusCheckRollup` is green (no red, no pending; an empty rollup counts as green).
  `PENDING` if approved+mergeable but some check is still running (CheckRun `.status` in
  `QUEUED`/`IN_PROGRESS`, or a StatusContext `.state == PENDING`). `NOT_READY` for everything
  else — not approved, not mergeable, or any check red (`.conclusion` in
  `FAILURE`/`CANCELLED`/`TIMED_OUT`/`ACTION_REQUIRED`/`STARTUP_FAILURE`, or `.state` in
  `FAILURE`/`ERROR`). Red is evaluated before pending.
- Produces: CLI `rw-merge <owner> <repo> <pr>`. Loops on `rw_merge_ready`: `READY` →
  `gh pr merge "$pr" --repo "$owner/$repo" --squash` and exit 0 (no `--delete-branch`); `PENDING`
  → sleep 30s and retry, up to 20 attempts (~10 min), then exit 1; `NOT_READY` → refuse on stderr
  and exit 1 immediately. Sources the lib the same way `review-react`/`review-watcher` do.

**Test cases** (stubbed `gh pr view`, same pattern as `rw_open_prs`/`rw_latest_review`):
approved+mergeable+all-SUCCESS rollup → `READY`; `reviewDecision: REVIEW_REQUIRED` → `NOT_READY`;
`mergeable: CONFLICTING` → `NOT_READY`; approved+mergeable with a `FAILURE` conclusion in the
rollup → `NOT_READY`; approved+mergeable with an `IN_PROGRESS` check → `PENDING`;
approved+mergeable with an empty rollup (`[]`, no checks configured) → `READY`.

**Playbook change:** in the `APPROVED` branch, replaced the model-driven "confirm
reviewDecision/mergeable/CI, then squash-merge" instruction with a call to `rw-merge <owner>
<repo> <pr>` — the model still resolves conflicts and pushes if origin/main moved, but the merge
itself, and the CI-green check gating it, happens in bash. The playbook now explicitly says not
to run `gh pr merge` directly.

Run: `bash test/review-watcher.test.sh` → `19 passed, 0 failed`.

---

## Self-Review

**Spec coverage:**
- Poll detector, token-free → Tasks 5, 7. ✓
- Headless reaction (`claude -p`), `bypassPermissions`, repo-qualified tmux session name → Task 6 (open-risk #3 resolved via `rw_session_name`; runtime revised from RC to headless after the Task 11 live test). ✓
- Trust allowlist; others notify-only; skip drafts; ignore self-reviews → Task 3. ✓
- All-visible scope → Task 5 (`rw_open_prs`). ✓
- At-most-once dedup, retry-on-failure → Tasks 2, 6 (`rw_mark_seen` only on success). ✓
- Concurrency cap, per-PR lock, PAUSED kill switch → Tasks 6, 7. ✓
- CI-green + mergeable before merge, re-scope judgment, in-thread reply, re-request, **never re-request an approver** → Task 4 (playbook). ✓
- No Claude self-promotion (session link / ad) in reaction output → Task 4 (playbook) + Global Constraints. ✓
- systemd + tmux lifecycle, observability, kill switch → Tasks 8, 11. ✓
- Overlay placement, build.sh vendoring, runtime state dir → Tasks 1, 8, 9. ✓
- `REACTION_TIMEOUT` kill → Task 6 (`timeout`). ✓

**Open items deferred to implementation (from the spec's risk list):**
- Risk #1 (workspace-trust under bypass): `bypassPermissions` is documented to skip the trust dialog; Task 11 Step 3 is the live confirmation. If a fresh-clone reaction stalls, add a trust-accept step in `review-react`.
- Risk #4 (idempotency after a crash): the playbook opens by reading current PR state, so a re-run on an unchanged review re-derives the same action; `rw_mark_seen`-on-success bounds duplicates. Watch during Task 11.

**Type consistency:** `rw_*` names and their argument orders (`owner repo pr [review_id]`) are uniform across Tasks 1–7 and the two consumer scripts. The reaction session name is `rw_session_name` everywhere (`<repo>-pr-<n>`).
