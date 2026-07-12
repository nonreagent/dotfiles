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

check test_idempotent
check test_no_secrets
check test_identity
check test_base_preserved
check test_review_watcher_units
check test_allowlist_resolves
echo "----"
echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
