#!/usr/bin/env bash
# Verification suite. Runs anywhere: build.sh clones the upstream dotfiles by
# default, or honors DOTFILES=/path for a local checkout.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; failc=0
check() { if "$@"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; failc=$((failc+1)); fi; }

tree_hash() { ( cd "$1" && find . -type f -exec shasum {} \; | sort ); }

test_idempotent() {
  "$REPO/build.sh" >/dev/null || return 1   # inherits DOTFILES from env if set, else clones
  local a b
  a="$(tree_hash "$REPO/home")"
  "$REPO/build.sh" >/dev/null || return 1
  b="$(tree_hash "$REPO/home")"
  [ "$a" = "$b" ]
}

test_no_secrets() { "$REPO/test/check-no-secrets.sh" "$REPO/home"; }

test_identity() {
  local tmp; tmp="$(mktemp -d)"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local email name
  email="$(HOME="$tmp" git config user.email 2>/dev/null)"
  name="$(HOME="$tmp" git config user.name 2>/dev/null)"
  rm -rf "$tmp"
  [ "$email" = "agent@nonration.al" ] && [ "$name" = "Agent Norton" ]
}

test_base_preserved() {
  local tmp; tmp="$(mktemp -d)"
  cp -R "$REPO/exe-dev-home/." "$tmp/" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  local agents_md="$tmp/.config/shelley/AGENTS.md"
  # Guard: an empty before/after (missing file) would otherwise compare equal and false-PASS.
  [ -f "$agents_md" ] || { echo "  exe-dev-home missing .config/shelley/AGENTS.md" >&2; rm -rf "$tmp"; return 1; }
  local before after
  before="$(shasum "$agents_md" | awk '{print $1}')"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  after="$(shasum "$agents_md" | awk '{print $1}')"
  [ -d "$tmp/.codex" ] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [ "$before" = "$after" ]
}

test_orphan_pruned() {
  local tmp; tmp="$(mktemp -d)"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  # orphan: a broken link into our home/ (simulates a file moved/removed upstream)
  ln -s "$REPO/home/.claude/__gone__.md" "$tmp/.claude/__gone__.md"
  # control A: broken link NOT pointing into home/ — must be preserved
  ln -s "/does/not/exist" "$tmp/.claude/__external__"
  # control B: valid unrelated symlink — must be preserved
  : > "$tmp/__real__"; ln -s "$tmp/__real__" "$tmp/.claude/__valid__"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local rc=0
  [ -L "$tmp/.claude/__gone__.md" ]  && rc=1   # orphan should be gone
  [ -L "$tmp/.claude/__external__" ] || rc=1   # external dangling link should remain
  [ -L "$tmp/.claude/__valid__" ]    || rc=1   # valid link should remain
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
}

test_review_watcher_units() { bash "$REPO/test/review-watcher.test.sh" >/dev/null; }

test_allowlist_resolves() {
  "$REPO/build.sh" >/dev/null || return 1
  # bin.Linux resolved to the manifest's ~/bin target (special case gone):
  [ -d "$REPO/home/bin" ] || { echo "  home/bin missing" >&2; return 1; }
  # a curated .claude sub-path resolved via the .claude prefix row:
  [ -f "$REPO/home/.claude/rules/language.md" ] || { echo "  .claude subpath missing" >&2; return 1; }
  # a Darwin fragment must NOT be vendored even if it sneaks into the allowlist:
  [ ! -e "$REPO/home/.bashrc.Darwin" ] || { echo "  Darwin fragment leaked" >&2; return 1; }
}

test_manifest_covers_home() {
  "$REPO/build.sh" >/dev/null || return 1
  local a b
  a="$(cd "$REPO/home" && find . -type f | sed 's|^\./|home/|' | LC_ALL=C sort)"
  b="$(grep -v '^[[:space:]]*#' "$REPO/manifest" | awk 'NF{print $1}' | LC_ALL=C sort)"
  [ "$a" = "$b" ] || { echo "  manifest != home/ file set" >&2; return 1; }
}

test_deploy_apply() {
  local tmp rc=0 rel; tmp="$(mktemp -d)"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  # every home/ file is a symlink in $tmp pointing back into the repo
  while IFS= read -r f; do
    rel="${f#"$REPO"/home/}"
    [ "$(readlink "$tmp/$rel" 2>/dev/null)" = "$REPO/home/$rel" ] \
      || { echo "  not linked: $rel" >&2; rc=1; }
  done < <(find "$REPO/home" -type f)
  # audit is clean, and a second apply is a no-op (no new backups)
  HOME="$tmp" "$REPO/deploy.sh" audit >/dev/null 2>&1 || { echo "  audit dirty" >&2; rc=1; }
  if HOME="$tmp" "$REPO/deploy.sh" apply 2>/dev/null | grep -q backup; then
    echo "  second apply not idempotent" >&2; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

check test_idempotent
check test_no_secrets
check test_identity
check test_base_preserved
check test_orphan_pruned
check test_review_watcher_units
check test_allowlist_resolves
check test_manifest_covers_home
check test_deploy_apply
echo "----"
echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
