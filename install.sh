#!/usr/bin/env bash
# Install the agent home on the VM. The LINKING is delegated to the vendored
# deploy.sh (the shared upstream placement engine) reading the generated manifest.
# This wrapper only keeps what deploy.sh can't own: the VM-base-image pre-flight
# (a host fact, not a placement fact), pruning symlinks orphaned by a move/removal
# in home/, and the next-steps message.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/home"

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

exit "$rc"
