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

# The gate is `claude auth status`: a failed token refresh blanks the stored
# tokens, so it reports logged out from the first failed reaction onward.
test_logged_in_reads_auth_status() {
  local bin ok=0; bin="$(mktemp -d)"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${CLAUDE_STUB_LOGGED_IN:-}" = 1 ]; then
  echo '{"loggedIn":true,"authMethod":"claude.ai"}'; exit 0
fi
echo '{"loggedIn":false,"authMethod":"none"}'; exit 1
STUB
  chmod +x "$bin/claude"
  CLAUDE_STUB_LOGGED_IN=1 PATH="$bin:$PATH" rw_logged_in \
    && ! CLAUDE_STUB_LOGGED_IN=0 PATH="$bin:$PATH" rw_logged_in && ok=1
  rm -rf "$bin"
  [ "$ok" = 1 ]
}

# `claude auth status` opens a network connection, and the gate runs inline in the
# poll loop: a stall there would freeze every PR, so it must be bounded.
test_logged_in_bounded_by_timeout() {
  local bin ok=0 start elapsed; bin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$bin/claude"
  chmod +x "$bin/claude"
  start="$(date +%s)"
  RW_AUTH_TIMEOUT=1 PATH="$bin:$PATH" rw_logged_in
  local rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" != 0 ] && [ "$elapsed" -lt 10 ] && ok=1
  rm -rf "$bin"
  [ "$ok" = 1 ]
}

test_session_name_is_repo_qualified() {
  [ "$(rw_session_name nonrational myrepo 131)" = "myrepo-pr-131" ]
}
# tmux turns "." into "_" in session names; a raw dotted name never matches has-session.
test_session_names_sanitize_dotted_repos() {
  [ "$(rw_session_name o foo.github.io 3)" = "foo_github_io-pr-3" ] \
    && [ "$(rw_review_session_name o foo.github.io 3)" = "foo_github_io-review-3" ]
}
test_render_substitutes_placeholders() {
  local tpl; tpl="$(mktemp)"
  printf 'repo={{REPO}} pr={{PR}} state={{REVIEW_STATE}} who={{REVIEWER}}\n' > "$tpl"
  local out; out="$(rw_render_playbook "$tpl" myrepo 131 CHANGES_REQUESTED nonrational)"
  rm -f "$tpl"
  [ "$out" = "repo=myrepo pr=131 state=CHANGES_REQUESTED who=nonrational" ]
}

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

test_merge_ready_all_green() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[
  {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"StatusContext","state":"SUCCESS"}
]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [ "$out" = "READY" ]
}

test_merge_ready_review_required_is_not_ready() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [[ "$out" == "NOT_READY "* ]]
}

test_merge_ready_conflicting_is_not_ready() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"APPROVED","mergeable":"CONFLICTING","statusCheckRollup":[]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [[ "$out" == "NOT_READY "* ]]
}

test_merge_ready_red_check_is_not_ready() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[
  {"status":"COMPLETED","conclusion":"SUCCESS"},
  {"status":"COMPLETED","conclusion":"FAILURE"}
]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [[ "$out" == "NOT_READY "* ]]
}

test_merge_ready_in_progress_is_pending() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[
  {"status":"IN_PROGRESS","conclusion":null},
  {"status":"COMPLETED","conclusion":"SUCCESS"}
]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [ "$out" = "PENDING" ]
}

test_merge_ready_empty_rollup_is_ready() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]}
JSON
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [ "$out" = "READY" ]
}

test_merge_ready_unknown_mergeable() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"reviewDecision":"APPROVED","mergeable":"UNKNOWN","statusCheckRollup":[]}'
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [ "$out" = "UNKNOWN" ]
}

test_merge_ready_names_failed_check() {
  local bin; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[]}'
STUB
  chmod +x "$bin/gh"
  local out; out="$(PATH="$bin:$PATH" rw_merge_ready nonrational myrepo 131)"
  rm -rf "$bin"
  [[ "$out" == *REVIEW_REQUIRED* ]]
}

# rw-merge against a gh stub: `pr view` serves an UNKNOWN verdict, `api` serves
# $GH_API_OUT, `pr merge` is recorded.
rwm_invoke() { # api_out — prints rw-merge's combined output; sets RWM_RC
  local home bin; home="$(mktemp -d)"; bin="$(mktemp -d)"; : > "$home/config"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")  echo '{"reviewDecision":"APPROVED","mergeable":"UNKNOWN","statusCheckRollup":[]}' ;;
  "pr merge") : > "$RW_HOME/merged-marker" ;;
  api*)       printf '%b\n' "$GH_API_OUT" ;;
esac
STUB
  chmod +x "$bin/gh"
  RWM_OUT="$(RW_HOME="$home" PATH="$bin:$PATH" GH_API_OUT="$1" RW_UNKNOWN_SECS=0 \
    "$REPO/overlay/bin/rw-merge" nonrational myrepo 131 2>&1)"; RWM_RC=$?
  RWM_MERGED=0; [ -f "$home/merged-marker" ] && RWM_MERGED=1
  rm -rf "$home" "$bin"
}

test_rw_merge_unknown_but_merged_exits_zero() {
  rwm_invoke 'true\tnonrational\t2026-10-14T00:00:00Z'
  [ "$RWM_RC" = 0 ] && [ "$RWM_MERGED" = 0 ] && [[ "$RWM_OUT" == *"already merged by nonrational"* ]]
}

test_rw_merge_unknown_unmerged_refuses_after_window() {
  rwm_invoke 'false\tunknown\t'
  [ "$RWM_RC" = 1 ] && [ "$RWM_MERGED" = 0 ] && [[ "$RWM_OUT" == *"still UNKNOWN"* ]]
}

test_rw_merge_success_prints_sha() {
  local home bin; home="$(mktemp -d)"; bin="$(mktemp -d)"; : > "$home/config"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")  echo '{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[]}' ;;
  api*)       echo abc1234 ;;
esac
STUB
  chmod +x "$bin/gh"
  local out; out="$(RW_HOME="$home" PATH="$bin:$PATH" "$REPO/overlay/bin/rw-merge" nonrational myrepo 131 2>&1)"
  rm -rf "$home" "$bin"
  [[ "$out" == *"merged nonrational/myrepo#131 (squash, abc1234)"* ]]
}

# --- review-react end to end (stubbed externals) -------------------------------
# Runs the real script with gh/claude stubbed on PATH. The gh stub serves
# $GH_PR_VIEW_JSON for `pr view` (rw-merge's readiness probe) and records a
# `pr merge` call as $RW_HOME/merged-marker.

RR_BIN="$(mktemp -d)"
# A real bare origin, so the wrappers' clone/fetch/worktree steps run for real.
RR_ORIGIN="$(mktemp -d)/origin.git"; export RR_ORIGIN
git init -q --bare -b main "$RR_ORIGIN"
( seed="$(mktemp -d)" && cd "$seed" && git init -q -b main \
  && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed \
  && git push -q "$RR_ORIGIN" HEAD:refs/heads/main \
  && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m pr-head \
  && git push -q "$RR_ORIGIN" HEAD:refs/pull/131/head \
  && rm -rf "$seed" )
cat > "$RR_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo clone") git clone --quiet "$RR_ORIGIN" "$4" ;;
  "pr view")    printf '%s\n' "$GH_PR_VIEW_JSON" ;;
  "pr merge")   : > "$RW_HOME/merged-marker" ;;
  "pr edit")    echo "$*" >> "$RW_HOME/gh-edits.log" ;;
  api*)         printf '%s\n' "${GH_API_JSON:-[]}" ;;
esac
exit 0
STUB
cat > "$RR_BIN/claude" <<'STUB'
#!/usr/bin/env bash
pwd > "$RW_HOME/claude-cwd"
git rev-parse HEAD > "$RW_HOME/claude-head"
printf '%s' "${GH_REPO:-}" > "$RW_HOME/claude-gh-repo"
[ -z "${CLAUDE_SLEEP:-}" ] || sleep "$CLAUDE_SLEEP"
[ "${CLAUDE_FAIL:-0}" = 1 ] && exit 1
echo agent-ok
STUB
chmod +x "$RR_BIN/gh" "$RR_BIN/claude"

rr_invoke() { # rw_home review_state — react to review REV_1 on myrepo#131
  printf 'playbook for {{REPO}}#{{PR}}\n' > "$1/playbook.md"
  # An absent config makes rw_load_config return 1, killing the set -e script;
  # in production setup-review-watcher guarantees one exists.
  : > "$1/config"
  RW_HOME="$1" PATH="$RR_BIN:$PATH" GH_PR_VIEW_JSON="$GH_PR_VIEW_JSON" \
    CLAUDE_FAIL="${CLAUDE_FAIL:-0}" "$REPO/overlay/bin/review-react" nonrational myrepo 131 REV_1 "$2" nonrational \
    >/dev/null 2>&1
}
RR_GREEN='{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
RR_RED='{"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}'

test_react_approved_merges_then_marks_seen() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" APPROVED
  local ok=0
  [ -f "$home/merged-marker" ] \
    && [ "$(cat "$home/state/nonrational__myrepo__131.seen" 2>/dev/null)" = "REV_1" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_react_approved_unmergeable_stays_unseen() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_RED" rr_invoke "$home" APPROVED
  local ok=0
  [ ! -f "$home/merged-marker" ] \
    && [ ! -f "$home/state/nonrational__myrepo__131.seen" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_react_changes_requested_marks_seen_without_merging() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  [ ! -f "$home/merged-marker" ] \
    && [ "$(cat "$home/state/nonrational__myrepo__131.seen" 2>/dev/null)" = "REV_1" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_watcher_holds_reactions_while_logged_out() {
  local home bin err ok=0
  home="$(mktemp -d)"; bin="$(mktemp -d)"
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  search) echo '[{"repository":{"nameWithOwner":"nonrational/myrepo"},"number":131,"isDraft":false,"author":{"login":"nonreagent"}}]' ;;
  api)    echo '[{"id":7,"state":"APPROVED","user":{"login":"nonrational"},"submitted_at":"2026-07-02T00:00:00Z"}]' ;;
esac
STUB
  cat > "$bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$3" in                     # argv: -S <sock> <command> ...
  has-session) exit 1 ;;
  new-session) : > "$RW_HOME/new-session-marker" ;;
esac
STUB
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"loggedIn":false,"authMethod":"none"}'; exit 1
STUB
  chmod +x "$bin/gh" "$bin/tmux" "$bin/claude"
  : > "$home/config"
  err="$(RW_HOME="$home" PATH="$bin:$PATH" "$REPO/overlay/bin/review-watcher" --once 2>&1 >/dev/null)"
  grep -q 'claude auth login' <<<"$err" && [ ! -f "$home/new-session-marker" ] && ok=1
  rm -rf "$home" "$bin"
  [ "$ok" = 1 ]
}

test_react_runs_in_its_own_worktree_and_removes_it() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local ok=0
  [ "$(cat "$home/claude-cwd" 2>/dev/null)" = "$home/worktrees/myrepo-pr-131" ] \
    && [ "$(cat "$home/claude-gh-repo" 2>/dev/null)" = "nonrational/myrepo" ] \
    && [ ! -e "$home/worktrees/myrepo-pr-131" ] \
    && [ "$(git -C "$home/repos/nonrational/myrepo" worktree list | wc -l)" -eq 1 ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

# The PR head differs from main, so a worktree cut from FETCH_HEAD or the default
# branch instead of the per-PR ref fails here.
test_react_worktree_lands_on_pr_head() {
  local home; home="$(mktemp -d)"
  GH_PR_VIEW_JSON="$RR_GREEN" rr_invoke "$home" CHANGES_REQUESTED
  local want ok=0; want="$(git -C "$RR_ORIGIN" rev-parse refs/pull/131/head)"
  [ "$(git -C "$home/repos/nonrational/myrepo" rev-parse refs/rw/pull/131)" = "$want" ] \
    && [ "$(cat "$home/claude-head" 2>/dev/null)" = "$want" ] \
    && [ "$want" != "$(git -C "$RR_ORIGIN" rev-parse refs/heads/main)" ] && ok=1
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
rp_invoke() { # rw_home — review request REQ_1 on myrepo#131, requested at T0
  printf 'review {{REPO}}#{{PR}} for {{REQUESTER}} budget={{TIMEOUT_MIN}}m\n' > "$1/review-playbook.md"
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
    && [ "$(cat "$home/claude-gh-repo" 2>/dev/null)" = "nonrational/myrepo" ] \
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

test_review_pr_failed_exit_without_review_stays_unseen() {
  local home ok=0; home="$(mktemp -d)"
  CLAUDE_FAIL=1 GH_API_JSON='[]' rp_invoke "$home" >/dev/null 2>&1
  [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] \
    && tail -1 "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_failed_exit_after_review_marks_seen() {
  local home ok=0; home="$(mktemp -d)"
  CLAUDE_FAIL=1 GH_API_JSON="$RP_LANDED" rp_invoke "$home" >/dev/null 2>&1
  [ "$(cat "$home/state/nonrational__myrepo__131.review-req" 2>/dev/null)" = "REQ_1" ] \
    && tail -1 "$home/gh-edits.log" | grep -q -- '--remove-assignee nonreagent' && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_dry_run_prints_review_prompt() {
  local home out ok=0; home="$(mktemp -d)"
  out="$(RW_DRY_RUN=1 rp_invoke "$home" 2>/dev/null)"
  [[ "$out" == *"claude -p"* ]] && [[ "$out" == *"nonrational/myrepo#131"* ]] && [[ "$out" == *nonrational* ]] \
    && [[ "$out" == *"budget=25m"* ]] && [[ "$out" == *remote.origin.pushurl* ]] \
    && [ ! -f "$home/gh-edits.log" ] && ok=1
  rm -rf "$home"
  [ "$ok" = 1 ]
}

test_review_pr_missing_playbook_logs_and_stays_unseen() {
  local home err ok=0; home="$(mktemp -d)"
  : > "$home/config"
  err="$(RW_HOME="$home" PATH="$RR_BIN:$PATH" "$REPO/overlay/bin/review-pr" \
    nonrational myrepo 131 REQ_1 nonrational 2026-10-14T00:00:00Z 2>&1 >/dev/null)"
  [ $? -eq 0 ] && [[ "$err" == *review-playbook.md* ]] && [[ "$err" == *setup-review-watcher* ]] \
    && grep -q setup-review-watcher "$home/logs/myrepo-review-131.log" \
    && [ ! -f "$home/state/nonrational__myrepo__131.review-req" ] && ok=1
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

check test_config_defaults
check test_config_override
check test_seen_file_path
check test_unseen_then_seen
check test_new_review_id_is_unseen
check test_classify_untrusted_is_notify
check test_classify_draft_is_skip
check test_classify_self_review_is_skip
check test_classify_trusted_states
check test_logged_in_reads_auth_status
check test_logged_in_bounded_by_timeout
WB_REQ_EVENT='[{"id":55,"event":"review_requested","created_at":"2026-10-14T00:00:00Z","requested_reviewer":{"login":"nonreagent"},"review_requester":{"login":"nonrational"}}]'

test_watcher_launches_review_for_trusted_request() {
  local home ok=0; home="$(mktemp -d)"
  GH_REQUESTED="$WB_PR131" GH_TIMELINE="$WB_REQ_EVENT" CLAUDE_LOGGED_IN=1 wb_invoke "$home"
  grep -q -- '-s myrepo-review-131 .*review-pr nonrational myrepo 131 55 nonrational 2026-10-14T00:00:00Z' \
    "$home/tmux-new.log" 2>/dev/null \
    && grep -qx '=myrepo-review-131' "$home/tmux-has.log" 2>/dev/null && ok=1
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

check test_session_name_is_repo_qualified
check test_session_names_sanitize_dotted_repos
check test_render_substitutes_placeholders
check test_open_prs_parses_search
check test_latest_review_picks_newest_nonpending
check test_merge_ready_all_green
check test_merge_ready_review_required_is_not_ready
check test_merge_ready_conflicting_is_not_ready
check test_merge_ready_red_check_is_not_ready
check test_merge_ready_in_progress_is_pending
check test_merge_ready_empty_rollup_is_ready
check test_merge_ready_unknown_mergeable
check test_merge_ready_names_failed_check
check test_rw_merge_unknown_but_merged_exits_zero
check test_rw_merge_unknown_unmerged_refuses_after_window
check test_rw_merge_success_prints_sha
check test_react_approved_merges_then_marks_seen
check test_react_approved_unmergeable_stays_unseen
check test_react_changes_requested_marks_seen_without_merging
check test_react_runs_in_its_own_worktree_and_removes_it
check test_react_replaces_stale_worktree
check test_react_worktree_lands_on_pr_head
check test_react_assigns_then_unassigns
check test_react_unassigns_when_agent_fails
check test_react_unassigns_on_hangup
check test_react_lock_loss_does_not_assign
check test_watcher_holds_reactions_while_logged_out
check test_review_session_name_is_distinct
check test_sweep_clears_assignment_without_session
check test_sweep_keeps_assignment_with_live_review_session
check test_watcher_targets_tmux_sessions_exactly
check test_classify_request
check test_request_seen_is_independent_of_review_seen
check test_render_substitutes_requester
check test_review_requests_parses_search
check test_latest_review_request_picks_newest_for_bot
check test_latest_review_request_ignores_team_requests
check test_review_landed_after_request
check test_review_landed_ignores_older_review
check test_review_landed_ignores_comment_only_and_others
check test_review_pr_marks_seen_when_review_lands
check test_review_pr_stays_unseen_without_review
check test_review_pr_failed_exit_without_review_stays_unseen
check test_review_pr_failed_exit_after_review_marks_seen
check test_review_pr_dry_run_prints_review_prompt
check test_review_pr_missing_playbook_logs_and_stays_unseen
check test_review_pr_shares_the_react_lock
check test_watcher_launches_review_for_trusted_request
check test_watcher_notifies_untrusted_requester
check test_watcher_leaves_draft_request_unseen
check test_watcher_skips_seen_request
check test_watcher_holds_reviews_while_logged_out
rm -rf "$RR_BIN" "$(dirname "$RR_ORIGIN")" "$WB_BIN"
echo "----"; echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
