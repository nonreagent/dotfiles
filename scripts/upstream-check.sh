#!/usr/bin/env bash
# Check how an unmerged nonrational/dotfiles change lands in this repo, before it merges.
#
#   scripts/upstream-check.sh <upstream-PR-number | upstream-branch>
#
# Builds home/ twice in a throwaway worktree of this repo's origin/main: once from
# the change's merge-base with upstream main (baseline) and once from the change.
# Then it runs the ./test/run.sh gate against the change build, loads the built tmux
# config, and prints what the change alters in home/ and manifest, so upstream drift
# that predates the change stays out of the diff. Never touches the live checkout or $HOME. Exit status is the gate's.
#
# Env: SOURCE_REPO (upstream URL, default as build.sh), DOWNSTREAM_REF (default origin/main).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/nonrational/dotfiles}"
DOWNSTREAM_REF="${DOWNSTREAM_REF:-origin/main}"

[ $# -eq 1 ] || { echo "usage: ${0##*/} <upstream-PR-number | upstream-branch>" >&2; exit 2; }
case "$1" in
  *[!0-9]*) fetch_ref="$1" ;;
  *)        fetch_ref="pull/$1/head" ;;
esac

work="$(mktemp -d)"
trap 'git -C "$REPO" worktree remove --force "$work/downstream" 2>/dev/null; git -C "$REPO" worktree prune; rm -rf "$work"' EXIT

echo "== upstream: baseline (main) and change ($1)"
git clone --quiet "$SOURCE_REPO" "$work/change"
git -C "$work/change" fetch --quiet origin "$fetch_ref"
git -C "$work/change" checkout --quiet --detach FETCH_HEAD
git -C "$work/change" submodule update --init --recursive --quiet
# Baseline is the change's merge-base with main, so a branch cut before recent
# upstream commits does not show those commits as reverted.
mb="$(git -C "$work/change" merge-base FETCH_HEAD origin/HEAD)"
git -C "$work/change" worktree add --quiet --detach "$work/base" "$mb"
git -C "$work/base" submodule update --init --recursive --quiet
echo "change at $(git -C "$work/change" log --oneline -1); baseline at $(git -C "$work/base" log --oneline -1)"

echo "== downstream: worktree of $DOWNSTREAM_REF"
git -C "$REPO" fetch --quiet origin
git -C "$REPO" worktree add --quiet --detach "$work/downstream" "$DOWNSTREAM_REF"
cd "$work/downstream"

# DOTFILES must be exported into every step below: test/run.sh rebuilds through
# build.sh, which silently clones upstream main when it is unset, so the gate would
# pass on a tree that never contained the change.
echo "== build: baseline"
DOTFILES="$work/base" ./build.sh >/dev/null
cp -a home "$work/base-home"; cp manifest "$work/base-manifest"

echo "== build + gate: change"
export DOTFILES="$work/change"
./build.sh >/dev/null
rc=0
./test/run.sh || rc=$?

echo "== tmux: built config loads"
if command -v tmux >/dev/null && [ -f home/.tmux.conf ]; then
  sock="$work/tmux.sock"
  tmux -S "$sock" -f /dev/null new-session -d -s check
  if tmux -S "$sock" source-file "$PWD/home/.tmux.conf"; then
    echo "PASS: tmux sources home/.tmux.conf (default-shell: $(tmux -S "$sock" show -gv default-shell))"
  else
    echo "FAIL: tmux rejected home/.tmux.conf"; rc=1
  fi
  tmux -S "$sock" kill-server 2>/dev/null || true
else
  echo "SKIP: tmux or home/.tmux.conf missing"
fi

echo "== what the change alters (baseline -> change)"
diff -ruN "$work/base-home" home || true
diff -u "$work/base-manifest" manifest || true

[ "$rc" -eq 0 ] && echo "upstream-check: PASS" || echo "upstream-check: FAIL"
exit "$rc"
