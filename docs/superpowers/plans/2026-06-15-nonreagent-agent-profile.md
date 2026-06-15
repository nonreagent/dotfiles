# nonreagent Agent Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `@nonreagent`'s exe.dev VM home from a curated subset of `~/.dotfiles` plus an agent-identity overlay, delivered as the `nonreagent/dotfiles` git repo with a symlink installer.

**Architecture:** A `manifest` allowlists paths to vendor from `~/.dotfiles`. `build.sh` (run on the mac) copies that subset into a committed `home/` tree and applies the `@nonreagent` overlay (git identity/auth, macOS-free `CLAUDE.md`, `XDG_RUNTIME_DIR`, path-noise silencing). `install.sh` (run on the VM) symlinks every file under `home/` into `$HOME` at file granularity — keeping `~/.claude` a real directory so Claude's runtime state never lands in the repo, and never touching `.config/`/`.codex/`. A `test/` suite enforces idempotency, secret hygiene, the agent identity, and base-image preservation.

**Tech Stack:** Bash, `git config -f` for config surgery, `find -print0` for file walks, plain-bash test asserts (no bats dependency).

---

## File Structure

| File | Responsibility |
|---|---|
| `manifest` | Allowlist of generic verbatim copies from `~/.dotfiles`. |
| `overlay/gitconfig` | `@nonreagent` git identity + auth; includes `.gitconfig.shared` first. |
| `overlay/claude-CLAUDE.md` | `CLAUDE.md` entrypoint without the macOS import. |
| `overlay/exe.md` | exe.dev VM context imported by `CLAUDE.md`. |
| `build.sh` | Vendor subset + apply overlay → `home/` (on the mac). Idempotent. |
| `install.sh` | File-level symlink installer (on the VM). Additive, backs up conflicts. |
| `test/check-no-secrets.sh` | Fail if a tree contains secrets / the personal email. Called by `build.sh` and the suite. |
| `test/run.sh` | Idempotency + secret + identity + base-preservation checks. |
| `home/` | Committed build artifact (the agent's `$HOME` overlay). |
| `README.md` | Build / install / sync instructions. |
| `.gitignore` | Ignore `*.bak`, `.DS_Store`. |
| `exe-dev-home/` | Reference snapshot of the base image (already present; used by base-preservation test). |

Conventions: `DOTFILES` defaults to `$HOME/.dotfiles` but is overridable. All scripts use `set -euo pipefail` and resolve the repo root from `BASH_SOURCE`.

---

## Task 1: Repo scaffolding — `.gitignore`, `manifest`, dirs

**Files:**
- Create: `.gitignore`
- Create: `manifest`
- Create: `overlay/.keep`, `test/.keep` (placeholder dirs)

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# editor/OS cruft
.DS_Store

# installer backups created on the VM
*.bak

# legacy hand-built artifact, replaced by build.sh + home/
home.tgz
```

- [ ] **Step 2: Create `manifest`**

Generic verbatim copies only. Identity, the macOS `CLAUDE.md` import, `bin.Linux`→`bin`, and `.gitconfig` are special-cased in `build.sh`, so they are NOT listed here.

```text
# Paths vendored verbatim from $DOTFILES into home/ (same relative path).
# One per line; '#' starts a comment. Special-cased paths (.gitconfig, bin.Linux,
# .claude/CLAUDE.md) are handled in build.sh and intentionally omitted here.

# shell
.bashrc
.bashrc.Linux
.bash_profile
.bash_completion
.bash_completion.d
.inputrc

# git (identity-bearing .gitconfig is special-cased; these are safe verbatim)
.githelpers
.gitignore_global

# tmux / editor / repl
.tmux.conf
.vimrc
.vim
.irbrc
.railsrc
.screenrc

# claude (curated subset; CLAUDE.md comes from the overlay, macos_interactions.md excluded)
.claude/language.md
.claude/workflow.md
.claude/markdown.md
.claude/improvement.md
.claude/settings.json
.claude/sync-plugins.sh
.claude/skills
.claude/agents
.claude/commands
.claude/hooks
.claude/output-styles
.claude/plugins
```

- [ ] **Step 3: Create placeholder dirs**

Run:
```bash
mkdir -p overlay test && touch overlay/.keep test/.keep
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore manifest overlay/.keep test/.keep
git commit -m "Scaffold nonreagent profile repo: gitignore and vendoring manifest"
```

---

## Task 2: The `@nonreagent` overlay files

**Files:**
- Create: `overlay/gitconfig`
- Create: `overlay/claude-CLAUDE.md`
- Create: `overlay/exe.md`

- [ ] **Step 1: Create `overlay/gitconfig`**

The shared config is included **first** so these identity/auth keys (and the credential-helper reset) win under git's last-value-wins rule.

```ini
# @nonreagent identity + auth overlay.
# .gitconfig.shared (vendored, identity-stripped) is included FIRST so the keys
# below win. gh provides the credential helper after `gh auth login` on the VM.
[include]
	path = ~/.gitconfig.shared

[user]
	name = Agent Norton
	email = agent@nonration.al

[github]
	user = nonreagent

[init]
	defaultBranch = main

[commit]
	gpgsign = false

[credential "https://github.com"]
	helper =
	helper = !gh auth git-credential

[credential "https://gist.github.com"]
	helper =
	helper = !gh auth git-credential
```

- [ ] **Step 2: Create `overlay/claude-CLAUDE.md`**

Same imports as the personal `CLAUDE.md` minus `macos_interactions`, plus the exe.dev context.

```markdown
# CLAUDE.md

@language.md
@workflow.md
@markdown.md
@improvement.md
@exe.md
```

- [ ] **Step 3: Create `overlay/exe.md`**

```markdown
## exe.dev VM context

You are running as **Agent Norton (@nonreagent)** in an exe.dev VM. Commits you make are authored by this identity — not the human operator.

- The disk is persistent and you have `sudo`.
- Use only **documented** exe.dev features: https://exe.dev/docs.md. Undocumented local endpoints are internal infrastructure — unstable and unsupported.
- The exe.dev HTTPS proxy is documented at https://exe.dev/docs/proxy.md.
```

- [ ] **Step 4: Commit**

```bash
git add overlay/gitconfig overlay/claude-CLAUDE.md overlay/exe.md
git commit -m "Add @nonreagent overlay: git identity, macOS-free CLAUDE.md, exe.dev context"
```

---

## Task 3: Secret-hygiene gate + test suite skeleton (tests first)

These tests are written before `build.sh`/`install.sh` exist, so the suite fails until they do. `check-no-secrets.sh` is also a runtime gate called by `build.sh`.

**Files:**
- Create: `test/check-no-secrets.sh`
- Create: `test/run.sh`

- [ ] **Step 1: Create `test/check-no-secrets.sh`**

```bash
#!/usr/bin/env bash
# Fail (exit 1) if <dir> contains anything sensitive or the human's identity.
set -euo pipefail
DIR="${1:?usage: check-no-secrets.sh <dir>}"

fail=0

# Forbidden files anywhere in the tree.
while IFS= read -r -d '' f; do
  echo "SECRET LEAK: $f" >&2; fail=1
done < <(find "$DIR" \( \
      -name '.credentials.json' \
   -o -name '*.pem' \
   -o -name 'id_rsa' \
   -o -name 'id_ed25519' \
   -o -name '.netrc' \
   -o -name 'history.jsonl' \
   -o -name '.bash_history' \
  \) -print0)

# A vendored .local/ would carry private git config.
if [ -d "$DIR/.local" ]; then
  echo "SECRET LEAK: $DIR/.local" >&2; fail=1
fi

# The human's personal git email must never appear in the agent tree.
if grep -RIl 'git@nonration\.al' "$DIR" >/dev/null 2>&1; then
  echo "SECRET LEAK: personal email git@nonration.al present in $DIR" >&2; fail=1
fi

exit "$fail"
```

Run `chmod +x test/check-no-secrets.sh`.

- [ ] **Step 2: Create `test/run.sh`**

```bash
#!/usr/bin/env bash
# Verification suite. Run on the mac (build.sh needs $DOTFILES present).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
pass=0; failc=0
check() { if "$@"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; failc=$((failc+1)); fi; }

tree_hash() { ( cd "$1" && find . -type f -exec shasum {} \; | sort ); }

test_idempotent() {
  DOTFILES="$DOTFILES" "$REPO/build.sh" >/dev/null || return 1
  local a b
  a="$(tree_hash "$REPO/home")"
  DOTFILES="$DOTFILES" "$REPO/build.sh" >/dev/null || return 1
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
  local before after
  before="$(shasum "$tmp/.config/shelley/AGENTS.md" | awk '{print $1}')"
  HOME="$tmp" "$REPO/install.sh" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  after="$(shasum "$tmp/.config/shelley/AGENTS.md" | awk '{print $1}')"
  [ -d "$tmp/.codex" ] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [ "$before" = "$after" ]
}

check test_idempotent
check test_no_secrets
check test_identity
check test_base_preserved
echo "----"
echo "$pass passed, $failc failed"
[ "$failc" -eq 0 ]
```

Run `chmod +x test/run.sh`.

- [ ] **Step 3: Run the suite to confirm it fails (no build.sh/install.sh yet)**

Run: `./test/run.sh`
Expected: every check FAILs (scripts missing), ending `0 passed, 4 failed`. Confirms the harness wires up the not-yet-built scripts.

- [ ] **Step 4: Commit**

```bash
git add test/check-no-secrets.sh test/run.sh
git commit -m "Add secret-hygiene gate and verification suite (red)"
```

---

## Task 4: `build.sh` — vendor subset + apply overlay

Makes `test_idempotent` and `test_no_secrets` pass; `test_identity`/`test_base_preserved` still fail (no installer yet).

**Files:**
- Create: `build.sh`

- [ ] **Step 1: Create `build.sh`**

```bash
#!/usr/bin/env bash
# Build the @nonreagent agent home from a subset of $DOTFILES + the overlay.
# Run on the mac. Idempotent: re-running produces no git diff in home/.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
OUT="$REPO/home"
OVERLAY="$REPO/overlay"

[ -d "$DOTFILES" ] || { echo "error: DOTFILES not found at $DOTFILES" >&2; exit 1; }

# Rebuild from scratch so upstream deletions propagate and appends never double up.
rm -rf "$OUT"
mkdir -p "$OUT"

# 1. Generic verbatim copies from the manifest.
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comment + trim
  [ -z "$line" ] && continue
  src="$DOTFILES/$line"; dst="$OUT/$line"
  [ -e "$src" ] || { echo "error: manifest path missing in dotfiles: $line" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
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

# 4. claude entrypoint + exe context from the overlay (macos import dropped).
mkdir -p "$OUT/.claude"
cp "$OVERLAY/claude-CLAUDE.md" "$OUT/.claude/CLAUDE.md"
cp "$OVERLAY/exe.md"           "$OUT/.claude/exe.md"

# 5. Restore XDG_RUNTIME_DIR (base .profile goes unread once .bash_profile exists).
cat >> "$OUT/.bashrc.Linux" <<'SNIPPET'

# --- nonreagent overlay (exe.dev) ---
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
SNIPPET

# 6. Silence "not added to PATH" noise: the checks run in .bash_profile at login,
#    before .bashrc.Linux, so patch the vendored copy directly.
perl -pi -e 's/^BASH_REPORT_MISSING=true\b/BASH_REPORT_MISSING=false/' "$OUT/.bash_profile"

# 7. Refuse to ship anything sensitive.
"$REPO/test/check-no-secrets.sh" "$OUT"

echo "built $OUT"
```

Run `chmod +x build.sh`.

- [ ] **Step 2: Run the build**

Run: `./build.sh`
Expected: prints `built …/home` with no `SECRET LEAK` lines and exit 0.

- [ ] **Step 3: Spot-check the overlay was applied**

Run:
```bash
grep -c 'git@nonration.al' home/.gitconfig.shared        # expect 0
grep -E 'agent@nonration.al|Agent Norton' home/.gitconfig # expect both
grep -c 'macos_interactions' home/.claude/CLAUDE.md       # expect 0
grep -c 'XDG_RUNTIME_DIR' home/.bashrc.Linux              # expect 1
grep -c 'BASH_REPORT_MISSING=false' home/.bash_profile    # expect 1
```
Expected: `0`, both strings printed, `0`, `1`, `1`.

- [ ] **Step 4: Run the suite — build checks now green**

Run: `./test/run.sh`
Expected: `test_idempotent` PASS, `test_no_secrets` PASS, `test_identity` FAIL, `test_base_preserved` FAIL → `2 passed, 2 failed`.

- [ ] **Step 5: Commit**

```bash
git add build.sh home
git commit -m "Add build.sh and the built home/ tree (idempotent, secret-clean)"
```

---

## Task 5: `install.sh` — file-level symlink installer

Makes `test_identity` and `test_base_preserved` pass (suite fully green).

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Create `install.sh`**

File-granular symlinks keep `~/.claude`, `~/.vim`, `~/bin` real directories, so Claude/vim runtime writes never land in the repo, and `.config/`/`.codex/` are never traversed (they are not under `home/`).

```bash
#!/usr/bin/env bash
# Install the agent home by symlinking every file under home/ into $HOME.
# Additive + re-runnable: backs up existing non-symlink files to .bak, replaces
# its own symlinks, and never touches paths outside home/ (e.g. .config, .codex).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/home"
DEST="${HOME}"

[ -d "$SRC" ] || { echo "error: no home/ tree; run build.sh on the mac first" >&2; exit 1; }

linked=0
while IFS= read -r -d '' file; do
  rel="${file#"$SRC"/}"
  d="$DEST/$rel"
  mkdir -p "$(dirname "$d")"
  if [ -L "$d" ]; then
    rm -f "$d"
  elif [ -e "$d" ]; then
    mv "$d" "$d.bak"
    echo "  [backup] $rel -> $rel.bak"
  fi
  ln -s "$file" "$d"
  linked=$((linked + 1))
done < <(find "$SRC" -type f -print0)

echo "linked $linked files into $DEST"
cat <<'EOF'

Next steps on this VM:
  1. gh auth login                    # as @nonreagent (sets up the git credential helper)
  2. ~/.claude/sync-plugins.sh        # install enabled Claude plugins
EOF
```

Run `chmod +x install.sh`.

- [ ] **Step 2: Manually verify a throwaway install**

Run:
```bash
tmp="$(mktemp -d)"; HOME="$tmp" ./install.sh
HOME="$tmp" git config user.email   # expect agent@nonration.al
HOME="$tmp" git config user.name    # expect Agent Norton
ls -la "$tmp/.claude/CLAUDE.md"     # expect a symlink into the repo
test -d "$tmp/.claude" && ! test -L "$tmp/.claude" && echo ".claude is a real dir (good)"
rm -rf "$tmp"
```
Expected: agent email/name, `.claude/CLAUDE.md` is a symlink, `.claude` is a real dir.

- [ ] **Step 3: Run the full suite — all green**

Run: `./test/run.sh`
Expected: `4 passed, 0 failed` (exit 0).

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "Add install.sh: file-level symlink installer, suite fully green"
```

---

## Task 6: README + cleanup

**Files:**
- Create: `README.md`
- Delete: `home.tgz`

- [ ] **Step 1: Create `README.md`**

```markdown
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
```

- [ ] **Step 2: Remove the legacy artifact**

Run: `git rm -f --ignore-unmatch home.tgz; rm -f home.tgz`
Expected: `home.tgz` gone (it was untracked; the build artifact is `home/`).

- [ ] **Step 3: Track the base-image reference snapshot**

`exe-dev-home/` is the reference the base-preservation test installs over.

Run: `git add exe-dev-home README.md`

- [ ] **Step 4: Final verification before commit**

Run: `./build.sh && ./test/run.sh`
Expected: `built …/home`, then `4 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add README, track base-image snapshot, drop legacy home.tgz"
```

---

## Self-Review

**Spec coverage:**
- Repo layout → Tasks 1–6 create every file in the spec's layout (`manifest`, `build.sh`, `install.sh`, `overlay/{gitconfig,claude-CLAUDE.md,exe.md}`, `home/`, `exe-dev-home/`, `README.md`). ✓
- Manifest include/exclude lists → Task 1 manifest + `build.sh` special-cases. ✓
- gitconfig split with identity stripped + include-first overlay → Task 4 step 1 (2) and Task 2 `overlay/gitconfig`. ✓
- macOS-free `CLAUDE.md` + `exe.md` → Task 2, applied in Task 4 step 1 (4). ✓
- `bin.Linux`→`bin`, `XDG_RUNTIME_DIR`, `.bash_profile` patch → Task 4 steps 1 (3,5,6). ✓
- Installer: file-level symlinks, `.bak` backups, never touch `.config`/`.codex` → Task 5. ✓
- Base preservation rules → enforced by `test_base_preserved` (Task 3) and the install design (Task 5). ✓
- Verification criteria (idempotency, secret hygiene incl. personal email, identity, base preservation) → Task 3 suite, green by Task 5. ✓
- Out-of-scope items (codex/shelley configs, secret distribution, live `~/.claude` hooks) → untouched. ✓

**Placeholder scan:** No TBD/TODO; every code/command step shows full content and expected output. ✓

**Type/name consistency:** `DOTFILES`, `OUT`/`SRC`, `home/`, `.gitconfig.shared`, `check-no-secrets.sh`, and the four test function names are used identically across `build.sh`, `install.sh`, and `test/run.sh`. The overlay's `agent@nonration.al` / `Agent Norton` match the identity smoke test's expected values. ✓
