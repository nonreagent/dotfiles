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

# 1. Selection resolved against placement. Read the upstream manifest (the
#    placement layer) into parallel arrays, then for each allowlist entry (the
#    selection layer) find the row that PLACES it and materialize its tracked
#    files at the manifest-declared target. Only GIT-TRACKED files are copied, so
#    ~/.claude runtime state never ships; symlinks into submodules are deref'd
#    (cp -RL) so the agent stays self-contained.
UPSTREAM_MANIFEST="$DOTFILES/manifest"
[ -f "$UPSTREAM_MANIFEST" ] || { echo "error: upstream manifest not found at $UPSTREAM_MANIFEST" >&2; exit 1; }

msrc=(); mtrg=(); mcond=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  [ -z "${line//[[:space:]]/}" ] && continue
  read -r _s _t _c _rest <<<"$line"
  msrc+=("$_s"); mtrg+=("$_t"); mcond+=("$_c")
done < "$UPSTREAM_MANIFEST"

# Longest source that is the path itself or a directory-prefix of it. Echoes the
# array index, or nothing if no row places the path.
resolve_row() {
  local path="$1" best=-1 bestlen=-1 i s
  for i in "${!msrc[@]}"; do
    s="${msrc[$i]}"
    if [ "$s" = "$path" ] || [ "${path#"$s"/}" != "$path" ]; then
      if [ "${#s}" -gt "$bestlen" ]; then best="$i"; bestlen="${#s}"; fi
    fi
  done
  [ "$best" -ge 0 ] && printf '%s\n' "$best"
}

# "~/.claude" -> ".claude". VM only vendors under $HOME, so require the ~/ form.
home_rel() {
  case "$1" in
    "~/"*) printf '%s\n' "${1#\~/}" ;;
    *) echo "error: manifest target '$1' is not under ~/ (cannot vendor)" >&2; return 1 ;;
  esac
}

while IFS= read -r entry || [ -n "$entry" ]; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"
  [ -z "$entry" ] && continue
  idx="$(resolve_row "$entry")"
  [ -n "$idx" ] || { echo "error: allowlist '$entry': no upstream manifest row places it" >&2; exit 1; }
  cond="${mcond[$idx]}"
  case "$cond" in
    "" | os=Linux) ;;                                   # allowlist ∩ os=Linux
    *) echo "skip: $entry (upstream condition '$cond' not Linux)" >&2; continue ;;
  esac
  S="${msrc[$idx]}"
  relbase="$(home_rel "${mtrg[$idx]}")" || exit 1
  n=0
  while IFS= read -r -d '' f; do
    mode="${f%% *}"; P="${f#*$'\t'}"                    # `ls-files -s` => "<mode> <sha> <stage>\t<path>"
    Prel="${P#"$S"/}"; [ "$Prel" = "$P" ] && Prel=""    # P == S (single-file source)
    dst="$OUT/$relbase${Prel:+/$Prel}"
    mkdir -p "$(dirname "$dst")"
    case "$mode" in
      120000) cp -RL "$DOTFILES/$P" "$dst" ;;           # symlink -> resolved content
      160000) : ;;                                      # gitlink/submodule -> skip
      *)      cp "$DOTFILES/$P" "$dst" ;;
    esac
    n=$((n + 1))
  done < <(git -C "$DOTFILES" ls-files -s -z -- "$entry")
  [ "$n" -gt 0 ] || { echo "error: no tracked files for allowlist path: $entry" >&2; exit 1; }
done < "$REPO/allowlist"

# 2. git identity split: vendor shared, strip the human's identity, overlay owns it.
shared="$OUT/.gitconfig.shared"
cp "$DOTFILES/.gitconfig" "$shared"
for key in user.name user.email github.user commit.gpgsign; do
  git config -f "$shared" --unset-all "$key" 2>/dev/null || true
done
cp "$OVERLAY/gitconfig" "$OUT/.gitconfig"

# 3. nonreagent overlay bin scripts (agent-only tools; e.g. the review watcher).
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

# 8. Vendor the shared placement engine and emit its manifest for home/. On the
#    VM, `deploy.sh apply` reconciles these into symlinks and `deploy.sh audit`
#    detects drift. File-level rows keep ~/.claude a real directory. Output is
#    sorted so re-builds are byte-identical (idempotency).
cp "$DOTFILES/deploy.sh" "$REPO/deploy.sh"
chmod +x "$REPO/deploy.sh"

{
  echo "# GENERATED by build.sh — do not edit. Rebuild: ./build.sh"
  echo "# Consumed by ./deploy.sh (apply|audit) on the VM."
  ( cd "$OUT" && find . -type f | LC_ALL=C sort ) | while IFS= read -r f; do
    rel="${f#./}"
    printf '%s\t%s\n' "home/$rel" "~/$rel"
  done
} > "$REPO/manifest"

echo "built $OUT"
