# nonreagent/dotfiles

Built agent home for **Agent Norton (@nonreagent)** on exe.dev VMs — a curated
subset of [`nonrational/dotfiles`](https://github.com/nonrational/dotfiles) plus
an agent-identity overlay.

## How it works

- `manifest` allowlists which dotfiles get vendored.
- `build.sh` clones [`nonrational/dotfiles`](https://github.com/nonrational/dotfiles)
  fresh from GitHub, copies that subset into the committed `home/` tree, and
  applies the `@nonreagent` overlay (git identity + `gh` auth, a macOS-free
  `CLAUDE.md`, `XDG_RUNTIME_DIR`, path-noise silencing). It runs anywhere.
- `install.sh` (run on the VM) symlinks every file under `home/` into `$HOME`.
  `~/.claude` stays a real directory, so Claude's runtime state never enters the
  repo, and `.config/`/`.codex/` are never touched.

## Build

    ./build.sh            # clones nonrational/dotfiles + overlay -> home/
    ./test/run.sh         # idempotency, secret hygiene, identity, base preservation
    git add home && git commit && git push

By default `build.sh` builds from the pushed state of `nonrational/dotfiles`, so
it reflects what's on GitHub — not uncommitted local edits. To build a local
checkout (the mac edit→build loop), point it at one:

    DOTFILES=~/.dotfiles ./build.sh   # build uncommitted edits

`SOURCE_REPO=<url> ./build.sh` overrides which repo gets cloned.

## Install (on an exe.dev VM)

    git clone https://github.com/nonreagent/dotfiles ~/.dotfiles
    cd ~/.dotfiles
    ./install.sh
    gh auth login                 # as @nonreagent
    ~/.claude/sync-plugins.sh     # install enabled Claude plugins

## Sync

- **Source edits:** push to `nonrational/dotfiles`, then `./build.sh` here picks
  them up. To preview uncommitted edits, `DOTFILES=~/.dotfiles ./build.sh`.
- **VM:** `git pull` (symlinks make it live immediately). Re-run `./install.sh`
  only when new files were added.
