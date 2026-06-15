#!/usr/bin/env bash
# Install the agent home by symlinking every file under home/ into $HOME.
# Additive + re-runnable: backs up existing non-symlink files to .bak, replaces
# its own symlinks, and never touches paths outside home/ (e.g. .config, .codex).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/home"
DEST="${HOME}"

[ -d "$SRC" ] || { echo "error: no home/ tree; run build.sh on the mac first" >&2; exit 1; }

linked=0
while IFS= read -r -d '' file; do
  rel="${file#"$SRC"/}"
  d="$DEST/$rel"
  mkdir -p "$(dirname "$d")"
  if [ -L "$d" ]; then
    rm -f "$d"
  elif [ -e "$d" ]; then
    # Don't clobber an existing backup — it holds the original base-image file.
    [ -e "$d.bak" ] && { echo "  [skip] $rel already backed up; not overwriting $rel.bak" >&2; continue; }
    mv "$d" "$d.bak"
    echo "  [backup] $rel -> $rel.bak"
  fi
  # Absolute source: symlinks point at this clone, so `git pull` updates config in place.
  ln -s "$file" "$d" || { echo "error: failed to link $rel" >&2; exit 1; }
  linked=$((linked + 1))
done < <(find "$SRC" -type f -print0)

echo "linked $linked files into $DEST"
cat <<'EOF'

Next steps on this VM:
  1. gh auth login                    # as @nonreagent (sets up the git credential helper)
  2. ~/.claude/sync-plugins.sh        # install enabled Claude plugins
EOF
