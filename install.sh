#!/usr/bin/env bash
# Install the agent home by symlinking every file under home/ into $HOME.
# Additive + re-runnable: backs up existing non-symlink files to .bak, replaces
# its own symlinks, and never touches paths outside home/ (e.g. .config, .codex).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/home"
DEST="${HOME}"

[ -d "$SRC" ] || { echo "error: no home/ tree; run build.sh on the mac first" >&2; exit 1; }

# Ensure every ancestor of a target is a real directory. If a path component
# exists as a NON-directory (a stray file or symlink the base image shipped),
# move it aside to .bak rather than letting `mkdir -p` abort the whole install.
ensure_parent() {
  local dir="$1"
  [ "$dir" = "$DEST" ] && return 0
  local rel="${dir#"$DEST"/}" cur="$DEST" part bak i
  local IFS='/'
  for part in $rel; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    if [ -e "$cur" ] && [ ! -d "$cur" ]; then
      bak="$cur.bak"; i=1
      while [ -e "$bak" ]; do bak="$cur.bak.$i"; i=$((i + 1)); done
      mv "$cur" "$bak"
      echo "  [backup] ${cur#"$DEST"/} -> ${bak#"$DEST"/} (was a non-directory)" >&2
    fi
    [ -d "$cur" ] || mkdir "$cur"
  done
}

linked=0
while IFS= read -r -d '' file; do
  rel="${file#"$SRC"/}"
  d="$DEST/$rel"
  ensure_parent "$(dirname "$d")"
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

# Prune orphaned symlinks: links from an earlier install that now dangle because
# their source moved or was removed from home/ (e.g. a file relocated into a subdir
# upstream). Scoped to the roots we manage — the top-level entries of home/ — so we
# never scan or touch anything outside them (.config, .codex). The safety invariant
# is the target check: we only remove a BROKEN link that points back into this
# clone's home/, so a user's own symlinks are never disturbed.
pruned=0
while IFS= read -r -d '' top; do
  root="$DEST/${top#"$SRC"/}"
  [ -e "$root" ] || [ -L "$root" ] || continue
  while IFS= read -r -d '' l; do
    [ -e "$l" ] && continue   # still resolves — keep
    case "$(readlink "$l")" in
      "$SRC"/*) rm -f "$l" && { echo "  [prune] ${l#"$DEST"/} (source removed from home/)"; pruned=$((pruned + 1)); } ;;
    esac
  done < <(find "$root" -type l -print0 2>/dev/null)
done < <(find "$SRC" -mindepth 1 -maxdepth 1 -print0)
[ "$pruned" -gt 0 ] && echo "pruned $pruned orphaned symlink(s)"
cat <<'EOF'

Next steps on this VM:
  1. gh auth login                    # as @nonreagent (sets up the git credential helper)
  2. ~/.claude/sync-plugins.sh        # install enabled Claude plugins
EOF
