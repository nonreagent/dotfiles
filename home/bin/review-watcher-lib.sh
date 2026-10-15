# Pure helpers for the review watcher. Sourced by the scripts and the tests;
# never executed directly. No side effects at source time.

: "${RW_HOME:=$HOME/.review-watcher}"
: "${RW_BOT_LOGIN:=nonreagent}"
: "${RW_AUTH_TIMEOUT:=10}"

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

rw_is_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  [ -f "$f" ] && [ "$(cat "$f")" = "$4" ]
}

rw_mark_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  mkdir -p "$(dirname "$f")"
  printf '%s' "$4" > "$f"
}

# A reaction under an expired login burns a poll and reports nothing useful (the
# reactor's stderr dies with its detached tmux session). The first such failure
# blanks the stored tokens, so `claude auth status` reports logged out from then
# on and the watcher can hold instead of retrying every poll.
# Bounded: `claude auth status` makes a network call, and this runs inline in the
# poll loop, so a stall here would freeze every PR. An unanswered check holds
# reactions rather than dispatching one blind.
rw_logged_in() {
  timeout "$RW_AUTH_TIMEOUT" claude auth status 2>/dev/null \
    | jq -e '.loggedIn == true' >/dev/null 2>&1
}

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

rw_session_name() { # owner repo pr
  printf '%s-pr-%s' "$2" "$3"
}

rw_render_playbook() { # template_file repo pr review_state reviewer
  sed -e "s|{{REPO}}|$2|g" -e "s|{{PR}}|$3|g" \
      -e "s|{{REVIEW_STATE}}|$4|g" -e "s|{{REVIEWER}}|$5|g" "$1"
}

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

rw_merge_ready() { # owner repo pr — READY | PENDING | UNKNOWN | NOT_READY <reason>
  gh pr view "$3" --repo "$1/$2" --json reviewDecision,mergeable,statusCheckRollup \
   | jq -r '
       def is_red: (.conclusion // "") as $c | (.state // "") as $s |
         ($c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT"
            or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE")
         or ($s == "FAILURE" or $s == "ERROR");
       def is_pending: (.status // "") as $st | (.state // "") as $s |
         ($st == "QUEUED" or $st == "IN_PROGRESS") or ($s == "PENDING");
       if .reviewDecision != "APPROVED" then "NOT_READY review decision is \(.reviewDecision // "none"), not APPROVED"
       elif (.statusCheckRollup | any(is_red)) then "NOT_READY a CI check is red"
       elif .mergeable == "UNKNOWN" then "UNKNOWN"
       elif .mergeable != "MERGEABLE" then "NOT_READY mergeable is \(.mergeable), not MERGEABLE"
       elif (.statusCheckRollup | any(is_pending)) then "PENDING"
       else "READY"
       end'
}

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
  # Concurrent sessions share the clone and FETCH_HEAD is per-clone, so fetch into
  # a per-PR ref rather than reading back whatever fetch ran last.
  git -C "$clone" fetch --quiet origin "+pull/$3/head:refs/rw/pull/$3" || return 1
  git -C "$clone" worktree add --quiet --detach "$wt" "refs/rw/pull/$3" >&2 || return 1
  printf '%s' "$wt"
}

rw_remove_worktree() { # owner repo worktree_path
  local clone; clone="$(rw_clone_dir "$1" "$2")"
  git -C "$clone" worktree remove --force "$3" >/dev/null 2>&1 || rm -rf "$3"
  git -C "$clone" worktree prune
}

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
