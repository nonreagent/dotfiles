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
