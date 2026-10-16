#!/bin/bash
# setup.sh: bring an exe.dev VM to the @nonreagent state. Re-runnable: every
# step skips when its guard holds, and the review watcher installs only when
# this script had to clone. The harness is vendored from nonrational/dotfiles.
# Spec: docs/superpowers/specs/2026-09-25-setup-script-design.md (upstream)
#
#   curl -fsSL https://raw.githubusercontent.com/nonreagent/dotfiles/main/setup.sh | bash
#   ./setup.sh [--dry-run]
set -euf -o pipefail

SETUP_REPO_URL="${SETUP_REPO_URL:-https://github.com/nonreagent/dotfiles}"
SETUP_CLONE_DIR="${SETUP_CLONE_DIR:-$HOME/.dotfiles}"
# Set to test an unmerged branch; empty clones the default branch.
SETUP_BRANCH="${SETUP_BRANCH:-}"

# Under `curl | bash` there is no file on disk and no lib to source, so this
# part cannot live in setup-lib.sh. Clone, mark the first run, and exec the
# on-disk copy; everything after this runs from a checkout.
setup_self_bootstrap() {
    local here=""
    if [ -n "${BASH_SOURCE[0]:-}" ]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -n "$here" ] && [ -f "$here/scripts/setup-lib.sh" ]; then
        SETUP_ROOT="$here"
        return 0
    fi
    case " $* " in
        *" --dry-run "*)
            echo "would: clone $SETUP_REPO_URL -> $SETUP_CLONE_DIR"
            exit 0
            ;;
    esac
    if [ ! -d "$SETUP_CLONE_DIR/.git" ]; then
        git clone ${SETUP_BRANCH:+--branch "$SETUP_BRANCH"} "$SETUP_REPO_URL" "$SETUP_CLONE_DIR"
        export SETUP_FIRST_RUN=1
    fi
    exec "$SETUP_CLONE_DIR/setup.sh" "$@"
}

# --- guards: exit 0 when the step's end state already holds -----------------

# new-exe-box.sh logs gh in before it runs this script; a hand-run box does it here.
gh_authed() { gh auth status >/dev/null 2>&1; }
# install.sh and sync-plugins.sh are idempotent and also prune or add what a
# `git pull` brought in, so they run every time.
never() { return 1; }

# --- runs -------------------------------------------------------------------

install_home() { "$SETUP_ROOT/install.sh"; }
gh_login() { gh auth login && gh auth setup-git; }
sync_plugins() { "$HOME/.claude/sync-plugins.sh"; }
install_review_watcher() { "$HOME/bin/setup-review-watcher"; }

setup_linux() {
    step "install" never install_home
    step "gh auth login" gh_authed gh_login
    step "sync-plugins" never sync_plugins
    first_run_step "setup-review-watcher" install_review_watcher
}

setup_darwin() {
    echo "error: setup.sh here targets exe.dev (Linux) VMs" >&2
    exit 1
}

main() {
    setup_self_bootstrap "$@"
    # shellcheck source=scripts/setup-lib.sh
    . "$SETUP_ROOT/scripts/setup-lib.sh"
    run_setup "$@"
}

main "$@"
