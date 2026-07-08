#!/usr/bin/env bash
# Build the @nonreagent agent home from a subset of the upstream dotfiles + the
# overlay. Runs anywhere (mac or VM). Idempotent: re-running produces no git diff
# in home/.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/nonrational/dotfiles}"
OUT="$REPO/home"
OVERLAY="$REPO/overlay"

# Source the upstream dotfiles. Default: clone fresh from GitHub so the build is
# self-contained and reproducible on any host. Skills are symlinks into a
# submodule, so --recurse-submodules is required for the cp -RL deref below.
# Override with a local checkout (DOTFILES=~/.dotfiles ./build.sh) to build
# uncommitted edits during the mac edit->build loop.
if [ -n "${DOTFILES:-}" ]; then
  [ -d "$DOTFILES" ] || { echo "error: DOTFILES not found at $DOTFILES" >&2; exit 1; }
else
  DOTFILES="$(mktemp -d)"
  trap 'rm -rf "$DOTFILES"' EXIT
  echo "cloning $SOURCE_REPO -> $DOTFILES"
  git clone --depth 1 --recurse-submodules --shallow-submodules --quiet \
    "$SOURCE_REPO" "$DOTFILES"
fi

# Rebuild from scratch so upstream deletions propagate and appends never double up.
rm -rf "$OUT"
mkdir -p "$OUT"

# 1. Vendor the manifest paths — only GIT-TRACKED files, so we honor the dotfiles
#    allowlist. The live ~/.dotfiles/.claude is symlinked to ~/.claude and holds
#    untracked runtime state (e.g. ~10k installed-plugin files) that must NOT ship.
#    Tracked skills are symlinks into the mattpocock submodule, so dereference them
#    (cp -RL) into real content and the agent stays self-contained.
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comment + trim
  [ -z "$line" ] && continue
  n=0
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"; file="${entry#*$'\t'}"        # `ls-files -s` => "<mode> <sha> <stage>\t<path>"
    src="$DOTFILES/$file"; dst="$OUT/$file"
    mkdir -p "$(dirname "$dst")"
    case "$mode" in
      120000) cp -RL "$src" "$dst" ;;   # symlink -> copy the resolved target content
      160000) : ;;                      # gitlink/submodule entry -> skip
      *)      cp "$src" "$dst" ;;        # regular file
    esac
    n=$((n + 1))
  done < <(git -C "$DOTFILES" ls-files -s -z -- "$line")
  [ "$n" -gt 0 ] || { echo "error: no tracked files for manifest path: $line" >&2; exit 1; }
done < "$REPO/manifest"

# 2. git identity split: vendor shared, strip the human's identity, overlay owns it.
shared="$OUT/.gitconfig.shared"
cp "$DOTFILES/.gitconfig" "$shared"
for key in user.name user.email github.user commit.gpgsign; do
  git config -f "$shared" --unset-all "$key" 2>/dev/null || true
done
cp "$OVERLAY/gitconfig" "$OUT/.gitconfig"

# 3. bin.Linux -> bin
cp -R "$DOTFILES/bin.Linux" "$OUT/bin"

# 3b. nonreagent overlay bin scripts (agent-only tools; e.g. the review watcher).
cp "$OVERLAY"/bin/* "$OUT/bin/"

# 4. claude entrypoint + exe context + agent identity from the overlay (macos import dropped).
mkdir -p "$OUT/.claude"
cp "$OVERLAY/claude-CLAUDE.md" "$OUT/.claude/CLAUDE.md"
cp "$OVERLAY/exe.md"           "$OUT/.claude/exe.md"
cp "$OVERLAY/identity.md"      "$OUT/.claude/identity.md"

# 5. Overlay shell env for the VM: XDG_RUNTIME_DIR (base .profile goes unread once
#    .bash_profile exists) and Rust (rustup installs ~/.cargo/env; upstream now
#    enables rust-analyzer-lsp). Guarded so the line is a no-op where cargo is absent.
cat >> "$OUT/.bashrc.Linux" <<'SNIPPET'

# --- nonreagent overlay (exe.dev) ---
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
SNIPPET

# 5b. tmux: agents don't want mouse reporting — it injects mouse escape sequences
#     into the pane and fights programmatic copy/paste. Upstream sets `mouse on`;
#     append an override to the vendored config (same overlay pattern as the
#     .bashrc.Linux block above), which lands last so `off` wins.
cat >> "$OUT/.tmux.conf" <<'SNIPPET'

# --- nonreagent overlay (exe.dev): disable mouse reporting for agent terminals
set -g mouse off
SNIPPET

# 6. Silence "not added to PATH" noise: the checks run in .bash_profile at login,
#    before .bashrc.Linux, so patch the vendored copy directly.
perl -pi -e 's/^BASH_REPORT_MISSING=true\b/BASH_REPORT_MISSING=false/' "$OUT/.bash_profile"

# 7. Refuse to ship anything sensitive.
"$REPO/test/check-no-secrets.sh" "$OUT"

echo "built $OUT"
