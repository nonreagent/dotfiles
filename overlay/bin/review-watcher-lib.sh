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

rw_is_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  [ -f "$f" ] && [ "$(cat "$f")" = "$4" ]
}

rw_mark_seen() { # owner repo pr review_id
  local f; f="$(rw_seen_file "$1" "$2" "$3")"
  mkdir -p "$(dirname "$f")"
  printf '%s' "$4" > "$f"
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

rw_merge_ready() { # owner repo pr — READY | PENDING | NOT_READY
  gh pr view "$3" --repo "$1/$2" --json reviewDecision,mergeable,statusCheckRollup \
   | jq -r '
       def is_red: (.conclusion // "") as $c | (.state // "") as $s |
         ($c == "FAILURE" or $c == "CANCELLED" or $c == "TIMED_OUT"
            or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE")
         or ($s == "FAILURE" or $s == "ERROR");
       def is_pending: (.status // "") as $st | (.state // "") as $s |
         ($st == "QUEUED" or $st == "IN_PROGRESS") or ($s == "PENDING");
       if .reviewDecision != "APPROVED" or .mergeable != "MERGEABLE" then "NOT_READY"
       elif (.statusCheckRollup | any(is_red)) then "NOT_READY"
       elif (.statusCheckRollup | any(is_pending)) then "PENDING"
       else "READY"
       end'
}
