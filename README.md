# nonreagent/dotfiles

Built agent home for **Agent Norton (@nonreagent)** on exe.dev VMs — a curated
subset of [`nonrational/dotfiles`](https://github.com/nonrational/dotfiles) plus
an agent-identity overlay.

## How it works

- `manifest` allowlists which dotfiles get vendored.
- `build.sh` (run on the mac) copies that subset from `~/.dotfiles` into the
  committed `home/` tree and applies the `@nonreagent` overlay (git identity +
  `gh` auth, a macOS-free `CLAUDE.md`, `XDG_RUNTIME_DIR`, path-noise silencing).
- `install.sh` (run on the VM) symlinks every file under `home/` into `$HOME`.
  `~/.claude` stays a real directory, so Claude's runtime state never enters the
  repo, and `.config/`/`.codex/` are never touched.

## Build (on the mac)

    ./build.sh            # re-vendors home/ from ~/.dotfiles + overlay
    ./test/run.sh         # idempotency, secret hygiene, identity, base preservation
    git add home && git commit && git push

`DOTFILES=/path/to/dotfiles ./build.sh` overrides the source location.

## Install (on an exe.dev VM)

    git clone https://github.com/nonreagent/dotfiles ~/nonreagent-dotfiles
    cd ~/nonreagent-dotfiles
    ./install.sh
    gh auth login                 # as @nonreagent
    ~/.claude/sync-plugins.sh     # install enabled Claude plugins

## Sync

- **Mac:** edit `~/.dotfiles` → `./build.sh` → review the `home/` diff → commit + push.
- **VM:** `git pull` (symlinks make it live immediately). Re-run `./install.sh`
  only when new files were added.
