#!/usr/bin/env bash
# Fail (exit 1) if <dir> contains anything sensitive or the human's identity.
set -euo pipefail
DIR="${1:?usage: check-no-secrets.sh <dir>}"
[ -d "$DIR" ] || { echo "error: tree not found: $DIR" >&2; exit 1; }

fail=0

# Forbidden files anywhere in the tree.
while IFS= read -r -d '' f; do
  echo "SECRET LEAK: $f" >&2; fail=1
done < <(find "$DIR" \( \
      -name '.credentials.json' \
   -o -name '*.pem' \
   -o -name 'id_rsa' \
   -o -name 'id_ed25519' \
   -o -name '.netrc' \
   -o -name 'history.jsonl' \
   -o -name '.bash_history' \
  \) -print0)

# A vendored .local/ would carry private git config.
if [ -d "$DIR/.local" ]; then
  echo "SECRET LEAK: $DIR/.local" >&2; fail=1
fi

# The human's personal git email must never appear in the agent tree.
if grep -RIl 'git@nonration\.al' "$DIR" >/dev/null 2>&1; then
  echo "SECRET LEAK: personal email git@nonration.al present in $DIR" >&2; fail=1
fi

exit "$fail"
