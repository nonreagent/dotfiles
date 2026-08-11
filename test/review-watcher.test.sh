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
  [ "$out" = "NOT_READY" ]
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
  [ "$out" = "NOT_READY" ]
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
  [ "$out" = "NOT_READY" ]
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

# --- review-react end to end (stubbed externals) -------------------------------
# Runs the real script with gh/claude stubbed on PATH. The gh stub serves
# $GH_PR_VIEW_JSON for `pr view` (rw-merge's readiness probe) and records a
# `pr merge` call as $RW_HOME/merged-marker.

RR_BIN="$(mktemp -d)"
cat > "$RR_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "repo clone") mkdir -p "$4/.git" ;;
  "pr view")    printf '%s\n' "$GH_PR_VIEW_JSON" ;;
  "pr merge")   : > "$RW_HOME/merged-marker" ;;
esac
exit 0
STUB
cat > "$RR_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo agent-ok
STUB
chmod +x "$RR_BIN/gh" "$RR_BIN/claude"

rr_invoke() { # rw_home review_state — react to review REV_1 on myrepo#131
  printf 'playbook for {{REPO}}#{{PR}}\n' > "$1/playbook.md"
  # An absent config makes rw_load_config return 1, killing the set -e script;
  # in production setup-review-watcher guarantees one exists.
  : > "$1/config"
  RW_HOME="$1" PATH="$RR_BIN:$PATH" GH_PR_VIEW_JSON="$GH_PR_VIEW_JSON" \
    "$REPO/overlay/bin/review-react" nonrational myrepo 131 REV_1 "$2" nonrational \
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

check test_config_defaults
check test_config_override
check test_seen_file_path
check test_unseen_then_seen
check test_new_review_id_is_unseen
check test_classify_untrusted_is_notify
check test_classify_draft_is_skip
check test_classify_self_review_is_skip
check test_classify_trusted_states
check test_session_name_is_repo_qualified
check test_render_substitutes_placeholders
check test_open_prs_parses_search
check test_latest_review_picks_newest_nonpending
check test_merge_ready_all_green
check test_merge_ready_review_required_is_not_ready
check test_merge_ready_conflicting_is_not_ready
check test_merge_ready_red_check_is_not_ready
check test_merge_ready_in_progress_is_pending
check test_merge_ready_empty_rollup_is_ready
check test_react_approved_merges_then_marks_seen
check test_react_approved_unmergeable_stays_unseen
check test_react_changes_requested_marks_seen_without_merging
rm -rf "$RR_BIN"
echo "----"; echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
