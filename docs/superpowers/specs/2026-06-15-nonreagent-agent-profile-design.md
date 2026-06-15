# nonreagent/dotfiles — built agent profile

**Status:** Approved design \
**Date:** 2026-06-15 \
**Owner:** nonrational \
**Target identity:** Agent Norton (@nonreagent)

## Problem

Run Claude Code sessions under an alter-ego GitHub identity — **Agent Norton (@nonreagent)** — inside tmux on exe.dev Linux VMs. The agent's home should be built from a curated **subset** of the personal `~/.dotfiles` (`nonrational/dotfiles`), layered over the exe.dev base image, with the `.claude/` config kept in sync over time. No personal identity or secrets may leak into the agent's config.

## Constraints and context

- **Source of truth:** `~/.dotfiles` (`github.com/nonrational/dotfiles`, public). macOS-centric. Its `.claude/.gitignore` is already an allowlist — only curated config is tracked (the `*.md` guides, `skills/`, `settings.json`, `sync-plugins.sh`, and empty `agents|commands|hooks|output-styles|plugins` dirs); credentials/history/caches are ignored.
- **Base image:** captured in `exe-dev-home/`. A Debian-ish exe.dev Linux home: stock `.bashrc`/`.profile` with an exe.dev welcome banner, a near-empty `.gitconfig` (`defaultBranch=main`), empty `.claude/CLAUDE.md` + `.codex/AGENTS.md` placeholders, and exe.dev's own `.config/shelley/AGENTS.md`.
- **Delivery (decided):** git repo + installer. This repo is pushed to `nonreagent/dotfiles`, cloned on each VM, and linked by an installer. Sync = rebuild on mac → push → `git pull` on VM.
- **Identity & auth (decided):** unsigned commits, `gh`-based auth. `gh auth login` runs once per VM as @nonreagent; the git credential helper is `gh auth git-credential`. No keys or tokens are ever committed.
  - name = `Agent Norton`, email = `agent@nonration.al`, github user = `nonreagent`.
- **Repo name (decided):** `nonreagent/dotfiles`.
- **exe.dev banner (decided):** dropped (terminal noise for an agent).

## Approach (decided: A)

Manifest-driven vendoring + symlink installer. A plain-text `manifest` lists the allowlisted paths. `build.sh` (run on the mac) copies that subset from `~/.dotfiles` into the repo's committed `home/` tree and applies the `@nonreagent` overlay. `install.sh` (run on the VM) symlinks `home/*` into `$HOME`. The committed `home/` makes the install trivial and every rebuild a reviewable diff, and is secret-safe by construction because the build only ever copies allowlisted paths.

Rejected: (B) `~/.dotfiles` as a submodule — submodule friction for no real gain over a reviewable vendored snapshot; (C) clone both repos and merge on the VM — puts the full personal config on the agent box and adds on-VM logic.

## Repo layout

```
nonreagent-dotfiles/            # local checkout → GitHub: nonreagent/dotfiles
├── README.md                   # what it is, build + install steps
├── manifest                    # allowlist: paths to vendor from ~/.dotfiles
├── build.sh                    # run on MAC: vendor subset + apply overlay → home/
├── install.sh                  # run on VM: symlink home/* into $HOME (additive)
├── overlay/                    # @nonreagent-specific sources (not in ~/.dotfiles)
│   ├── gitconfig               # identity + auth; includes .gitconfig.shared
│   ├── claude-CLAUDE.md        # CLAUDE.md without the macos import
│   └── exe.md                  # exe.dev VM context for Claude (imported by CLAUDE.md)
├── home/                       # BUILT, COMMITTED — the agent's $HOME overlay
│   └── … (see "What lands in home/")
└── exe-dev-home/               # reference snapshot of the base image (for diffing/tests)
```

`home/` is a committed build artifact, not hand-edited.

## Components

### `manifest`

Plain text, one path per line (relative to `~/.dotfiles`), `#` comments. Defines exactly what gets vendored. Grouped:

- **shell:** `.bashrc`, `.bashrc.Linux`, `.bash_profile`, `.bash_completion`, `.bash_completion.d`, `.inputrc`
- **git:** `.gitconfig` (→ vendored as `.gitconfig.shared`; overlay supplies `.gitconfig`), `.githelpers`, `.gitignore_global`
- **tmux/editor/repl:** `.tmux.conf`, `.vimrc`, `.vim`, `.irbrc`, `.railsrc`, `.screenrc`
- **bin:** `bin.Linux` (→ `home/bin`)
- **claude:** `.claude/CLAUDE.md` (→ overlay), `.claude/language.md`, `.claude/workflow.md`, `.claude/markdown.md`, `.claude/improvement.md`, `.claude/settings.json`, `.claude/sync-plugins.sh`, `.claude/skills`, `.claude/agents`, `.claude/commands`, `.claude/hooks`, `.claude/output-styles`, `.claude/plugins`

**Excluded** (never vendored): `.bashrc.Darwin`, `bin.Darwin`, `.macos`, `karabiner`, `fonts`, `Brewfile`, `etc/`, host-specific `.bashrc.*` (mercury/nyx/ICN-…), `.zshrc`/`.zprofile`, `.profile` (empty `# NONE`; leaving the base `.profile` intact is preferable), `.claude/macos_interactions.md`, and anything secret (`.credentials.json`, tokens, history — already excluded by the dotfiles allowlist).

### `build.sh` (runs on the mac)

1. Read `manifest`; copy each path from `~/.dotfiles` into `home/` (mirroring relative paths).
2. Apply the overlay:
   - **gitconfig split.** Copy `~/.dotfiles/.gitconfig` to `home/.gitconfig.shared`, then `--unset` its `user.name`, `user.email`, `github.user`, and `commit.gpgsign` (via `git config -f`) so the shared file carries only aliases/colors/behavior and the overlay is the **sole** identity source. Write `home/.gitconfig` from `overlay/gitconfig`: `[include] path = ~/.gitconfig.shared` **first**, then the overrides last so they win — `[user] name = Agent Norton`, `email = agent@nonration.al`; `[github] user = nonreagent`; `[commit] gpgsign = false`; `[init] defaultBranch = main`; and `[credential "https://github.com"]` that resets the helper list (`helper =`) then sets `helper = !gh auth git-credential`. Git applies includes/keys in order, last value wins, so aliases/colors/behavior from the shared file carry over while identity + auth flip to the agent.
   - **CLAUDE.md.** Write `home/.claude/CLAUDE.md` from `overlay/claude-CLAUDE.md` — imports `language/workflow/markdown/improvement` and `exe.md`, but **not** `macos_interactions`. `macos_interactions.md` is not vendored.
   - **bin.** `bin.Linux/` → `home/bin/`.
   - **Linux shell snippet.** Append to `home/.bashrc.Linux`: export `XDG_RUNTIME_DIR="/run/user/$(id -u)"` (the one functional thing lost when our `.bash_profile` shadows the base `.profile`).
   - **Silence path noise.** Patch the vendored `home/.bash_profile` to set `BASH_REPORT_MISSING=false`. The "not added to PATH" checks for missing macOS paths run at login inside `.bash_profile`, *before* `.bashrc.Linux` is sourced, so a snippet there would be too late.
3. Build is **idempotent**: a second run produces no `git diff`.

### `overlay/`

- **`gitconfig`** — the include-first + override-last file described above.
- **`claude-CLAUDE.md`** — the macos-free CLAUDE.md entrypoint.
- **`exe.md`** — short exe.dev context imported by CLAUDE.md: running in an exe.dev VM, committing as Agent Norton (@nonreagent), use only documented exe.dev features (https://exe.dev/docs.md), HTTPS proxy at https://exe.dev/docs/proxy.md.

### `home/` (what lands in the agent's $HOME)

Shell (`.bashrc`, `.bashrc.Linux` + snippet, `.bash_profile`, `.bash_completion`, `.bash_completion.d/`, `.inputrc`); git (`.gitconfig` overlay, `.gitconfig.shared` vendored, `.githelpers`, `.gitignore_global`); tmux/editor/repl (`.tmux.conf`, `.vimrc`, `.vim/`, `.irbrc`, `.railsrc`, `.screenrc`); `bin/`; and `.claude/` (`CLAUDE.md` overlay, the four md guides, `settings.json`, `sync-plugins.sh`, `skills/` with real content, empty `agents|commands|hooks|output-styles` with `.keep`, `plugins/` config). The dotfiles `.claude/{agents,commands,hooks,output-styles}` are empty upstream — the agent gets the **skills** and **md guides**; live hooks/plugins come from installing plugins on the VM.

### `install.sh` (runs on the VM)

- Symlink each path under `home/` into `$HOME`, creating parent dirs, backing up any existing **non-symlink** base file to `.bak` (same spirit as `link-dotfiles.sh`). `bin/ → ~/bin`.
- **Never touch `.config/` or `.codex/`** → preserves `.config/shelley/AGENTS.md` and the codex placeholder.
- Post-install reminder: run `gh auth login` (as @nonreagent) and `./.claude/sync-plugins.sh` to install enabled plugins (superpowers, frontend-design, rust-analyzer-lsp).
- Installed files are symlinks into the cloned repo, so a later `git pull` updates live config instantly. Re-run `install.sh` only when new paths appear.

## Base-image preservation rules

| Base item | Rule |
|---|---|
| `.config/shelley/AGENTS.md` | Preserve untouched; installer never writes into `.config/`. |
| `XDG_RUNTIME_DIR` | Port into `home/.bashrc.Linux` (base `.profile` goes unread once `.bash_profile` exists). |
| exe.dev welcome banner | Dropped. |
| base `.profile` (`# NONE` upstream) | Not managed; left in place for `sh`/POSIX logins. |
| `.bash_logout`, `.hushlogin` | Left as base provides. |
| `.codex/AGENTS.md` (empty) | Left in place. |
| `.claude/CLAUDE.md`, `.gitconfig` | Overwritten by the build (intended). |

## Data flow

```
~/.dotfiles ──(manifest)──▶ build.sh ──(+ overlay/)──▶ home/ ──(commit, push)──▶ nonreagent/dotfiles
                                                                                      │
                                                                          VM: git clone / git pull
                                                                                      │
                                                                          install.sh ─▶ symlinks in $HOME
```

- **Mac:** edit `~/.dotfiles` → `./build.sh` → review `home/` diff → commit + push.
- **VM:** `git pull` (live immediately); re-run `install.sh` only if files were added.

## Error handling & edge cases

- **Identity override correctness:** the `[include]` of `.gitconfig.shared` must come *before* the identity/auth keys; otherwise the shared file's `[user]`/`[commit]` would win. Verified by the identity smoke test.
- **Harmless gitconfig residue:** after identity is stripped, `.gitconfig.shared` still carries the inert `signingkey`/`op-ssh-sign` program and macOS `gh` credential helper. They never fire because the overlay sets `gpgsign=false` and resets the credential helper list. The `~/.local/.gitconfig` and `~/wrk` includes silently no-op when absent.
- **`pbcopy`-based git aliases** (`bcp`, etc.) fail harmlessly on Linux; not worth stripping.
- **`BASH_REPORT_MISSING` noise:** the login-time PATH checks live in `.bash_profile` and run before `.bashrc.Linux`, so the build patches the vendored `home/.bash_profile` to set `BASH_REPORT_MISSING=false` directly.
- **`.claude/ext/mattpocock-skills` submodule:** if any vendored skill references it, the build copies the resolved working-tree contents (no submodule on the VM). Out of scope for v1 unless a vendored skill needs it.
- **Plugins:** referenced by `settings.json` but their code is not in this repo; installed on the VM via `sync-plugins.sh`.
- **Installer safety:** backs up non-symlink base files to `.bak`; idempotent re-runs replace its own symlinks only.

## Verification / success criteria

1. **Idempotency:** `build.sh` run twice → clean `git diff`.
2. **Secret hygiene:** build fails if `home/` contains `.credentials.json`, private keys, `.netrc`, history files, `.local/`, or the personal email `git@nonration.al`.
3. **Identity smoke test:** install into `HOME=$(mktemp -d)` and assert `git config user.email` = `agent@nonration.al` and `git config user.name` = `Agent Norton`.
4. **Base preservation:** after install over a copy of `exe-dev-home/`, `.config/shelley/AGENTS.md` is unchanged and `.codex/` is untouched.

## Out of scope (v1)

- Codex/Shelley agent configs (leave placeholders).
- Multi-VM secret distribution / automated `gh auth`.
- Pulling live `~/.claude` hooks (those are macOS/personal; the agent gets plugins instead).
