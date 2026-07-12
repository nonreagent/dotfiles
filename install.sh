#!/usr/bin/env bash
# Install the agent home on the VM. The LINKING is delegated to the vendored
# deploy.sh (the shared upstream placement engine) reading the generated manifest.
# This wrapper only keeps what deploy.sh can't own: the VM-base-image pre-flight
# (a host fact, not a placement fact) and the next-steps message.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$REPO/manifest" ]   || { echo "error: no manifest; run build.sh first" >&2; exit 1; }
[ -x "$REPO/deploy.sh" ]  || { echo "error: no vendored deploy.sh; run build.sh first" >&2; exit 1; }

# Pre-flight: deploy.sh's `mkdir -p "$(dirname "$trg")"` aborts if a target's
# parent already exists as a NON-directory (a stray file/symlink the base image
# shipped). Move any such component aside to .bak so apply can create the dir.
DEST="$HOME"
normalize_parents() {
  local trg="$1" rel cur part bak i
  rel="${trg#"$DEST"/}"; cur="$DEST"
  local IFS='/'
  for part in $rel; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    [ "$cur" = "$trg" ] && continue           # the leaf itself is deploy.sh's job
    if [ -e "$cur" ] && [ ! -d "$cur" ]; then
      bak="$cur.bak"; i=1
      while [ -e "$bak" ]; do bak="$cur.bak.$i"; i=$((i + 1)); done
      mv "$cur" "$bak"
      echo "  [preflight] ${cur#"$DEST"/} -> ${bak#"$DEST"/} (was a non-directory)" >&2
    fi
  done
}
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; [ -z "${line//[[:space:]]/}" ] && continue
  read -r _src trg _rest <<<"$line"
  trg="${trg/#\~/$HOME}"
  normalize_parents "$trg"
done < "$REPO/manifest"

rc=0
"$REPO/deploy.sh" apply || rc=$?

cat <<'EOF'

Next steps on this VM:
  1. gh auth login                    # as @nonreagent (sets up the git credential helper)
  2. ~/.claude/sync-plugins.sh        # install enabled Claude plugins
EOF

exit "$rc"
