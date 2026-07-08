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
  [ "$(rw_seen_file nonrational lizzie 42)" = "$RW_HOME/state/nonrational__lizzie__42.seen" ]
}

check test_config_defaults
check test_config_override
check test_seen_file_path
echo "----"; echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
