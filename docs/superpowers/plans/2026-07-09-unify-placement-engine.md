# Unify the Placement Engine (keep ownership split) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one declarative placement engine (`deploy.sh` + a 3-column `manifest`) the single source of truth for "what goes where," so `nonreagent` *reads* placement as data instead of re-implementing it, and the VM gains drift detection — without forking and without merging the two repos' manifests.

**Architecture:** Split the system into three layers, each owned in exactly one place. **Placement** (source→target + host condition) lives upstream in `nonrational/dotfiles`'s `manifest`, applied by `deploy.sh`. **Selection** (which subset the agent gets) stays in `nonreagent/dotfiles`, but its file is renamed `manifest`→`allowlist` and each entry is resolved *against the upstream manifest*. **Transformation** (identity strip, `CLAUDE.md` swap, appended snippets) stays imperative in `build.sh` and shrinks. The VM closes the loop by having `build.sh` emit a generated `deploy.sh`-format manifest and vendor `deploy.sh` itself, so `install.sh` becomes `deploy.sh apply` and `deploy.sh audit` gives drift detection for free.

**Tech Stack:** Bash 3.2 + coreutils only (both engines target macOS's stock bash). `git` for tracked-file enumeration. Existing test harnesses: `nonrational/dotfiles/test_deploy.sh` and `nonreagent/dotfiles/test/run.sh`.

## Global Constraints

- **Bash 3.2 + coreutils only.** No bash 4 features (no associative arrays, no `mapfile`). This matches `deploy.sh` and `link-dotfiles.sh` today. Copied verbatim from PR #10's constraint.
- **Two repos, two identities, one direction of flow.** Upstream is `nonrational/dotfiles` (the human's, macOS-primary). Downstream is `nonreagent/dotfiles` (the agent's, Linux VM). Flow is upstream→downstream only; identity never leaks upstream.
- **Agent proposes, human disposes.** Agent Norton (@nonreagent) authors branches and PRs and posts self-review; **landing/merging is the human's call.** Request review from **@nonrational** on every PR (both repos). No "Generated with Claude" lines in any PR/issue/commit body — keep only the `Co-Authored-By:` model-credit footer on commits.
- **`deploy.sh` conditions are observable host facts only** — `os=$(uname)` and `host=$(uname -n)`. Never add a `project=` condition; per-project `.claude/` dirs live in their own project repos (Claude Code's native scoping). The manifest stays scoped to `$HOME`.
- **Each phase is independently shippable and must shrink `build.sh`/`install.sh`, never grow them.** A phase that adds net imperative placement logic is a regression against the goal.
- **Idempotent builds.** Re-running `build.sh` must produce no git diff in `home/` **or** in the generated `manifest`. All generated output must be deterministically ordered (`sort`).

---

## File Structure

**Upstream — `nonrational/dotfiles` (Phases 1–2):**
- `deploy.sh` — the placement engine (lands via PR #10). Reads `manifest`, reconciles symlinks. Modes: `apply` (default), `--dry-run`, `audit`. **Unchanged after it lands** — it is the shared engine.
- `manifest` — 3-column `source  target  [condition]`. Phase 2 grows it from the 3-row pilot to full coverage of everything `link-dotfiles.sh` links.
- `link-dotfiles.sh` — **deleted** at the end of Phase 2 once `deploy.sh audit` proves parity.
- `Makefile` — `link-dotfiles` target replaced by a `deploy` target calling `./deploy.sh apply`.
- `README.md` — the two `make link-dotfiles` references updated.
- `test_deploy.sh` — gains a coverage/parity test in Phase 2.

**Downstream — `nonreagent/dotfiles` (Phases 3–4):**
- `allowlist` (renamed from `manifest`) — one selection path per line. Content the agent owns.
- `build.sh` — Phase 3 replaces its "vendor manifest paths" block + the `bin.Linux → bin` special case with an allowlist-against-upstream-manifest resolver. Phase 4 appends a manifest-emit + `deploy.sh`-vendor step. Net line count goes **down**.
- `manifest` (new, **generated** by `build.sh`) — `deploy.sh`-format, one row per file under `home/`, `home/<rel>  ~/<rel>`. Committed so it reaches the VM.
- `deploy.sh` (new, **vendored** by `build.sh` from upstream) — the shared engine, run on the VM.
- `install.sh` — Phase 4 collapses its linking loop into `deploy.sh apply`, keeping only a VM-base-image pre-flight and the next-steps message.
- `test/run.sh` — gains resolver, coverage, and apply/audit tests in Phases 3–4.
- `README.md` — "How it works" / "Install" sections updated for `allowlist` + `deploy.sh apply`.

**Sequencing (each independently shippable):**
1. **Phase 1** — Land PR #10 (upstream). *Ships:* the engine, pilot slice only.
2. **Phase 2** — Grow the upstream manifest to full coverage; retire `link-dotfiles.sh`. *Ships:* `deploy.sh` fully replaces `link-dotfiles.sh` on the mac.
3. **Phase 3** — Rename `manifest`→`allowlist`; resolve against the upstream manifest. *Ships:* `bin.Linux → bin` special case gone; placement is data.
4. **Phase 4** — Emit generated manifest + vendor `deploy.sh`; `install.sh` → `deploy.sh apply`. *Ships:* VM drift detection via `deploy.sh audit`.

Phase 3 depends on Phase 2 (needs full-coverage upstream manifest). Phase 4 depends on Phase 1 (`deploy.sh` must exist upstream to vendor).

---

## Phase 1 — Land the placement engine (upstream pilot)

**Repo:** `nonrational/dotfiles`. **Deliverable:** PR #10 merged; `deploy.sh` + pilot `manifest` + `test_deploy.sh` on `main`; `link-dotfiles.sh` untouched and still owns everything else.

**Note:** Merging is the human's disposition. The agent's job here is to prove the PR is green and current, then hand off.

### Task 1.1: Verify PR #10 is green and current, then request the merge

**Files:**
- Verify: `deploy.sh`, `manifest`, `test_deploy.sh` (all on branch `worktree-manifest-deploy-spike`)

- [ ] **Step 1: Check out the PR branch in the upstream clone**

Run:
```bash
cd ~/src/nonrational-dotfiles
git fetch origin worktree-manifest-deploy-spike
git checkout worktree-manifest-deploy-spike
git rebase origin/main   # resolve any drift since the PR opened
```
Expected: clean rebase, or a conflict you resolve (the pilot only adds `deploy.sh`, `manifest`, `test_deploy.sh`, and 2 docs — conflicts are unlikely).

- [ ] **Step 2: Run the deploy test suite**

Run: `/bin/bash ./test_deploy.sh`
Expected: `23 passed, 0 failed` (the PR's stated result). If any fail after rebase, fix on the branch before proceeding.

- [ ] **Step 3: Live parity check on a real mac (nyx)**

Run (on the mac, from the main working checkout where `link-dotfiles.sh` has already been applied):
```bash
./deploy.sh --dry-run apply
./deploy.sh audit
```
Expected: `--dry-run apply` prints `ok:` / `skip:` for the 3 pilot entries and proposes **zero** `relink`/`backup`/`link` changes; `audit` exits `0`.

- [ ] **Step 4: Hand off for merge**

The agent does not merge upstream. Post the verification result on the PR and request @nonrational's review/merge. Once merged, `git checkout main && git pull` in `~/src/nonrational-dotfiles`.
Expected: `deploy.sh`, `manifest`, `test_deploy.sh` present on `main`.

---

## Phase 2 — Grow the upstream manifest to full coverage; retire `link-dotfiles.sh`

**Repo:** `nonrational/dotfiles`. **Deliverable:** every path `link-dotfiles.sh` links has a `manifest` row with the correct target and condition; `deploy.sh audit` proves parity; `link-dotfiles.sh` is deleted and the `Makefile`/`README` point at `deploy.sh`.

**What `link-dotfiles.sh` links today** (from its `find -maxdepth 1 -name '.*'` minus the excludes, plus the `bin.$(uname) → ~/bin` special case): every top-level dotfile except `.AppleDouble`, `.DS_Store`, `.git`, `.github`, `.gitignore`, `.gitmodules`, `.macos`. Each goes to `~/<same-name>`. `bin.$(uname)` goes to `~/bin`.

**Parity definition (behavioral, not byte-identical).** PR #10 already conditioned `.bashrc.nyx` with `host=nyx` and split `bin` into `os=Darwin`/`os=Linux` rows — deliberate divergences from `link-dotfiles.sh`'s unconditional linking. We continue that: OS/host-specific fragments get their observable-fact condition; everything else is unconditional. Parity means **(a)** every path `link-dotfiles.sh` would link on a given host has a matching manifest row, and **(b)** on that host `deploy.sh --dry-run apply` proposes zero changes and `deploy.sh audit` exits 0. Non-matching conditioned rows (e.g. `os=Linux` on a mac) are `skip`ped by `deploy.sh` and never removed, so a `link-dotfiles`-created `~/.bashrc.Linux` symlink on the mac is left in place and reported neither as drift nor as a change.

### Task 2.1: Expand the manifest to full coverage

**Files:**
- Modify: `manifest`

**Interfaces:**
- Produces: a manifest where `source` names match repo paths exactly. Downstream Phase 3 resolves `allowlist` entries against these `source`/`target`/`condition` triples.

- [ ] **Step 1: Write the full manifest**

Replace `manifest` with (tab- or space-separated columns; `deploy.sh` reads with `read -r src trg cond`):
```
# source            target                condition
.bash_completion    ~/.bash_completion
.bash_completion.d  ~/.bash_completion.d
.bash_profile       ~/.bash_profile
.bashrc             ~/.bashrc
.bashrc.Darwin      ~/.bashrc.Darwin      os=Darwin
.bashrc.Linux       ~/.bashrc.Linux       os=Linux
.bashrc.nyx         ~/.bashrc.nyx         host=nyx
.claude             ~/.claude
.copilot            ~/.copilot
.gemini             ~/.gemini
.gitconfig          ~/.gitconfig
.githelpers         ~/.githelpers
.gitignore_global   ~/.gitignore_global
.inputrc            ~/.inputrc
.irbrc              ~/.irbrc
.nethackrc          ~/.nethackrc
.profile            ~/.profile
.railsrc            ~/.railsrc
.screenrc           ~/.screenrc
.tmux.conf          ~/.tmux.conf
.vim                ~/.vim
.vimrc              ~/.vimrc
.zprofile           ~/.zprofile
.zshrc              ~/.zshrc
bin.Darwin          ~/bin                 os=Darwin
bin.Linux           ~/bin                 os=Linux
```
Note: `.claude` is a single whole-directory row (matches `link-dotfiles.sh`, which symlinks the whole `.claude` dir so plugin runtime state lives under the repo working dir). The `bin.$(uname) → ~/bin` special case becomes the two conditioned `bin.*` rows.

- [ ] **Step 2: Validate the manifest parses**

Run: `./deploy.sh --dry-run audit` (any mac or Linux host)
Expected: no `error: manifest line N` messages. Every `source` exists (`deploy.sh` checks `[ -e "$DOTS/$src" ]` at parse time), every `target` is `~/`-prefixed, every condition is empty/`os=`/`host=`.

### Task 2.2: Add a coverage-parity test to `test_deploy.sh`

**Files:**
- Modify: `test_deploy.sh`

**Interfaces:**
- Consumes: `link-dotfiles.sh`'s exclude list (the source of truth for "what gets linked").

- [ ] **Step 1: Write the failing test**

Add this test function to `test_deploy.sh` (follow the file's existing `test_*`/`assert` style; adapt names to match the harness). It proves every top-level dotfile `link-dotfiles.sh` would link has a manifest `source` row, and that `bin.$(uname)` is covered:
```bash
test_manifest_covers_link_dotfiles() {
  # Mirror link-dotfiles.sh's find + exclude list.
  local linked
  linked="$(find . -maxdepth 1 -name '.*' \
      ! -name '.' ! -name '.AppleDouble' ! -name '.DS_Store' \
      ! -name '.git' ! -name '.github' ! -name '.gitignore' \
      ! -name '.gitmodules' ! -name '.macos' -exec basename {} \; | sort)"
  local sources
  sources="$(grep -v '^[[:space:]]*#' manifest | awk 'NF{print $1}' | sort -u)"
  local missing=""
  local f
  for f in $linked; do
    grep -qxF "$f" <<<"$sources" || missing="$missing $f"
  done
  # bin.$(uname) special case must be represented as a source too.
  grep -qxF "bin.$(uname)" <<<"$sources" || missing="$missing bin.$(uname)"
  [ -z "$missing" ] || { echo "  manifest missing rows for:$missing" >&2; return 1; }
}
```

- [ ] **Step 2: Run it to verify it fails (before Task 2.1 is applied) or passes (after)**

Run: `/bin/bash ./test_deploy.sh`
Expected: with the full manifest from Task 2.1 in place, this test PASSES and the suite still reports `24 passed, 0 failed`. If you wrote the test before expanding the manifest, confirm it FAILS first (lists the missing rows), then apply Task 2.1 and re-run.

- [ ] **Step 3: Commit**

```bash
git add manifest test_deploy.sh
git commit -m "Grow deploy manifest to full link-dotfiles coverage + coverage test"
```

### Task 2.3: Prove live parity on the mac

**Files:** none (verification only)

- [ ] **Step 1: Dry-run against the current (link-dotfiles-produced) state**

Run (on nyx, where `link-dotfiles.sh` has been applied): `./deploy.sh --dry-run apply`
Expected: for every condition-matching row, `ok:`; for non-matching rows (`os=Linux`), `skip:`. **Zero** `relink`/`backup`/`link` lines. This proves manifest ⊆ current state.

- [ ] **Step 2: Audit**

Run: `./deploy.sh audit`
Expected: `ok:` for every matching row, no `drift`/`missing`, exit `0`. Combined with Task 2.2 (coverage ⊇), this is the parity proof.

### Task 2.4: Retire `link-dotfiles.sh`

**Files:**
- Delete: `link-dotfiles.sh`
- Modify: `Makefile` (replace the `link-dotfiles` target), `README.md` (2 references)

- [ ] **Step 1: Replace the Makefile target**

In `Makefile`, replace the `link-dotfiles` target:
```make
deploy:
	./deploy.sh apply
```
Update `.PHONY` (`link-dotfiles` → `deploy`). Leave `link-karabiner` and `link-sublime` untouched — they link `.config/karabiner` and Sublime prefs, which `link-dotfiles.sh` never handled and the manifest intentionally does not (`.config` may hold secrets). The old target's `mkdir -p $HOME/.local` is dropped: `deploy.sh` creates target parents as needed.

- [ ] **Step 2: Update README references**

In `README.md`, change both `make link-dotfiles` occurrences (lines ~28 and ~52) to `make deploy` (or `./deploy.sh apply`).

- [ ] **Step 3: Delete the old linker**

Run: `git rm link-dotfiles.sh`

- [ ] **Step 4: Verify nothing else references it**

Run: `grep -rn "link-dotfiles" --include='*.md' --include='Makefile' --include='*.sh' . | grep -v '\.git/'`
Expected: no matches.

- [ ] **Step 5: Re-run the suite and commit**

Run: `/bin/bash ./test_deploy.sh`
Expected: `24 passed, 0 failed`.
```bash
git add -A
git commit -m "Retire link-dotfiles.sh; deploy.sh is the placement engine"
```

- [ ] **Step 6: Open the PR and hand off**

```bash
gh pr create --repo nonrational/dotfiles --reviewer nonrational \
  --title "Full manifest coverage; retire link-dotfiles.sh" \
  --body "deploy.sh now covers everything link-dotfiles.sh did. Parity proven by the coverage test + a clean audit/dry-run on nyx. link-dotfiles.sh deleted; Makefile/README point at deploy.sh."
```
Human merges. Then `git checkout main && git pull` upstream.

---

## Phase 3 — Resolve `allowlist` against the upstream manifest (downstream)

**Repo:** `nonreagent/dotfiles`. **Deliverable:** `nonreagent`'s `manifest` renamed to `allowlist`; `build.sh` resolves each allowlist entry against the upstream `manifest` (filter by `∩ os=Linux`, materialize at the manifest-declared target). The `bin.Linux → bin` special case is deleted — placement now comes from data.

**Resolution semantics.** The upstream manifest maps *sources* to *targets*. An allowlist entry is a path (a file or a subtree). Resolve it to the manifest row whose `source` is the entry itself **or its longest directory-prefix** (so `.claude/skills` resolves against the `.claude ~/.claude` row). Keep the row only if its condition is empty or `os=Linux` (the `∩ os=Linux` filter; `os=Darwin`/`host=*` rows are skipped with a log line). Materialize each git-tracked file `P` under the entry to `home/<relbase>/<P-relative-to-source>`, where `relbase` is the row's target with the leading `~/` stripped. Consequence: `bin.Linux` (row `bin.Linux ~/bin os=Linux`) lands at `home/bin` with no special-casing, and a future upstream *target* rename propagates automatically; a future *source* rename surfaces as a loud "no manifest row" error (a one-line allowlist fix), never a silent miss.

### Task 3.1: Rename the selection file and update its header

**Files:**
- Rename: `manifest` → `allowlist`

**Interfaces:**
- Produces: `allowlist` — one selection path per line, `#` comments. Consumed by `build.sh`.

- [ ] **Step 1: Rename with git**

Run: `cd ~/src/nonreagent-dotfiles && git mv manifest allowlist`

- [ ] **Step 2: Rewrite the header comment and add the `bin.Linux` entry**

Replace the top comment block of `allowlist` and add `bin.Linux` under a new section (it used to be special-cased in `build.sh`):
```
# Selection layer: which upstream paths the @nonreagent agent gets. One path per
# line; '#' starts a comment. Each entry is resolved against nonrational/dotfiles'
# `manifest` (the placement layer) — build.sh reads the target + condition from
# there. Identity-bearing / transformed files (.gitconfig, .claude/CLAUDE.md) are
# NOT here; build.sh's transformation layer writes them.

# bin (resolves to the upstream `bin.Linux ~/bin os=Linux` row -> home/bin)
bin.Linux
```
Keep all existing entries (`.bashrc`, `.claude/skills`, …). Remove the old note that said `.gitconfig`/`bin.Linux`/`.claude/CLAUDE.md` are "special-cased in build.sh" for `bin.Linux` (it's now an allowlist entry); `.gitconfig` and `.claude/CLAUDE.md` stay out (transformation layer).

- [ ] **Step 3: Commit the rename**

```bash
git add -A
git commit -m "Rename manifest -> allowlist (selection layer); add bin.Linux entry"
```

### Task 3.2: Replace `build.sh`'s vendor block with the allowlist-against-manifest resolver

**Files:**
- Modify: `build.sh` (replace the "1. Vendor the manifest paths" `while` loop at lines ~31–52 and delete the "3. bin.Linux -> bin" block at lines ~62–63)

**Interfaces:**
- Consumes: the upstream `manifest` at `$DOTFILES/manifest` (full coverage from Phase 2); `allowlist` at `$REPO/allowlist`.
- Produces: `home/` tree with each allowlisted path materialized at its manifest-declared target.

- [ ] **Step 1: Write the resolver block**

Replace the current step-1 loop (the block headed `# 1. Vendor the manifest paths …`) with:
```bash
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
    *) echo "skip: $entry (upstream condition '$cond' not Linux)"; continue ;;
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
```

- [ ] **Step 2: Delete the `bin.Linux -> bin` special case**

Remove the block:
```bash
# 3. bin.Linux -> bin
cp -R "$DOTFILES/bin.Linux" "$OUT/bin"
```
It is now covered by the `bin.Linux` allowlist entry resolving to the `bin.Linux ~/bin` row. Renumber the remaining comments if you like (cosmetic). The `# 3b.` overlay-bin copy (`cp "$OVERLAY"/bin/* "$OUT/bin/"`) stays — it runs after the resolver has created `home/bin`.

- [ ] **Step 3: Build and eyeball the result**

Run:
```bash
DOTFILES=~/src/nonrational-dotfiles ./build.sh   # build against the Phase-2 manifest
ls home/bin | head            # bin.Linux content landed at home/bin
ls home/.claude/rules         # curated rule files present
test ! -e home/.bashrc.Darwin && echo "no Darwin fragment (correct)"
```
Expected: `home/bin/*` present, `home/.claude/rules/{language,workflow,markdown,improvement}.md` present, no `home/.bashrc.Darwin`.

### Task 3.3: Add resolver tests to `test/run.sh`

**Files:**
- Modify: `test/run.sh`

**Interfaces:**
- Consumes: `build.sh` output in `$REPO/home`.

- [ ] **Step 1: Write the failing test**

Add to `test/run.sh` (matching its `check`/`test_*` style; register with a `check test_allowlist_resolves` line before the `echo "----"`):
```bash
test_allowlist_resolves() {
  "$REPO/build.sh" >/dev/null || return 1
  # bin.Linux resolved to the manifest's ~/bin target (special case gone):
  [ -d "$REPO/home/bin" ] || { echo "  home/bin missing" >&2; return 1; }
  # a curated .claude sub-path resolved via the .claude prefix row:
  [ -f "$REPO/home/.claude/rules/language.md" ] || { echo "  .claude subpath missing" >&2; return 1; }
  # a Darwin fragment must NOT be vendored even if it sneaks into the allowlist:
  [ ! -e "$REPO/home/.bashrc.Darwin" ] || { echo "  Darwin fragment leaked" >&2; return 1; }
}
```

- [ ] **Step 2: Run the suite**

Run: `DOTFILES=~/src/nonrational-dotfiles ./test/run.sh`
Expected: all checks pass, including `PASS: test_allowlist_resolves`.

- [ ] **Step 3: Commit**

```bash
git add build.sh test/run.sh
git commit -m "Resolve allowlist against upstream manifest; drop bin.Linux special case"
```

### Task 3.4: Update the downstream README and open the PR

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update "How it works"**

Change the `manifest` bullet to describe `allowlist` resolved against the upstream `manifest`. One-liner: "`allowlist` names which upstream paths the agent gets; `build.sh` reads each path's target + OS condition from `nonrational/dotfiles`'s `manifest` (the placement layer) and materializes it into `home/`."

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo nonreagent/dotfiles --reviewer nonrational \
  --title "Resolve allowlist against upstream manifest (placement as data)" \
  --body "manifest -> allowlist (selection). build.sh now reads target + condition from the upstream manifest instead of hardcoding bin.Linux -> bin. Future upstream target renames propagate for free."
```
Human merges.

---

## Phase 4 — Emit a generated manifest, vendor `deploy.sh`, `install.sh` → `deploy.sh apply`

**Repo:** `nonreagent/dotfiles`. **Deliverable:** `build.sh` emits a `deploy.sh`-format `manifest` for `home/` and vendors upstream `deploy.sh`; `install.sh` collapses to a base-image pre-flight + `deploy.sh apply`; the VM gains `deploy.sh audit` drift detection.

**Why file-level rows.** `install.sh` symlinks every *file* under `home/` so `~/.claude` stays a real directory (plugin runtime state, ~10k files, must not enter the repo). The generated manifest preserves that: one row per file, `home/<rel>  ~/<rel>`, unconditional (the tree is already OS-resolved for the VM).

### Task 4.1: Emit the generated manifest and vendor `deploy.sh` in `build.sh`

**Files:**
- Modify: `build.sh` (append after the secrets check, the last step)

**Interfaces:**
- Produces: `$REPO/manifest` (deploy format) and `$REPO/deploy.sh` (executable), both committed.

- [ ] **Step 1: Append the emit + vendor step**

After the `check-no-secrets.sh` call and before the final `echo "built $OUT"`, add:
```bash
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
```
Note: a **newline** pipeline (not NUL) is used deliberately — `sort -z`/`sed -z` are GNU-only and `build.sh` also runs on the mac's BSD userland; dotfile paths never contain newlines, so this is safe. `LC_ALL=C sort` fixes ordering across hosts (idempotency); `${f#./}` strips the `./` that `find .` prefixes. The resulting sources are `home/<rel>`, which `deploy.sh` resolves as `$DOTS/home/<rel>` (i.e. `$REPO/home/<rel>`), and targets are `~/<rel>` → `$HOME/<rel>` — the same absolute-source symlinks `install.sh` created.

- [ ] **Step 2: Build and inspect the generated files**

Run:
```bash
DOTFILES=~/src/nonrational-dotfiles ./build.sh >/dev/null
head -4 manifest
./deploy.sh --dry-run audit >/dev/null && echo "manifest parses"
wc -l manifest; find home -type f | wc -l   # counts must match
```
Expected: `manifest` header + `home/<rel>\t~/<rel>` rows; row count (minus 2 header lines) equals `find home -type f`; `deploy.sh` accepts it.

### Task 4.2: Collapse `install.sh` to a pre-flight + `deploy.sh apply`

**Files:**
- Modify: `install.sh` (replace the linking loop with delegation; keep only the VM-base-image pre-flight and next-steps)

**Interfaces:**
- Consumes: `$REPO/manifest`, `$REPO/deploy.sh` (from Task 4.1).

- [ ] **Step 1: Rewrite `install.sh`**

Replace the whole file with:
```bash
#!/usr/bin/env bash
# Install the agent home on the VM. The LINKING is delegated to the vendored
# deploy.sh (the shared upstream placement engine) reading the generated manifest.
# This wrapper only keeps what deploy.sh can't own: the VM-base-image pre-flight
# (a host fact, not a placement fact) and the next-steps message.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$REPO/manifest" ]   || { echo "error: no manifest; run build.sh first" >&2; exit 1; }
[ -x "$REPO/deploy.sh" ]  || { echo "error: no vendored deploy.sh; run build.sh first" >&2; exit 1; }

# Pre-flight: deploy.sh's `mkdir -p "$(dirname "$trg")"` aborts if a target's
# parent already exists as a NON-directory (a stray file/symlink the base image
# shipped). Move any such component aside to .bak so apply can create the dir.
DEST="$HOME"
normalize_parents() {
  local trg="$1" rel cur part bak i
  rel="${trg#"$DEST"/}"; cur="$DEST"
  local IFS='/'
  for part in $rel; do
    [ -n "$part" ] || continue
    cur="$cur/$part"
    [ "$cur" = "$trg" ] && continue           # the leaf itself is deploy.sh's job
    if [ -e "$cur" ] && [ ! -d "$cur" ]; then
      bak="$cur.bak"; i=1
      while [ -e "$bak" ]; do bak="$cur.bak.$i"; i=$((i + 1)); done
      mv "$cur" "$bak"
      echo "  [preflight] ${cur#"$DEST"/} -> ${bak#"$DEST"/} (was a non-directory)" >&2
    fi
  done
}
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; [ -z "${line//[[:space:]]/}" ] && continue
  # shellcheck disable=SC2086
  set -- $line
  trg="${2/#\~/$HOME}"
  normalize_parents "$trg"
done < "$REPO/manifest"

"$REPO/deploy.sh" apply

cat <<'EOF'

Next steps on this VM:
  1. gh auth login                    # as @nonreagent (sets up the git credential helper)
  2. ~/.claude/sync-plugins.sh        # install enabled Claude plugins
EOF
```
This is ~40 lines vs the old ~58, and the placement engine is no longer duplicated — the linking, backup-on-conflict, and `.bak` non-clobber semantics all come from the shared `deploy.sh`.

- [ ] **Step 2: Verify `install.sh` still satisfies the existing suite**

`test/run.sh`'s `test_identity` and `test_base_preserved` call `$REPO/install.sh` into a fake `$HOME`. They must still pass: `deploy.sh apply` only touches manifest targets (files under `home/`), leaving `.config/shelley/AGENTS.md` and `.codex` untouched, and it backs up base-image `.bashrc`/`.gitconfig` to `.bak` exactly as before.
Run: `DOTFILES=~/src/nonrational-dotfiles ./test/run.sh`
Expected: `PASS: test_identity`, `PASS: test_base_preserved`, all others pass.

### Task 4.3: Add manifest-coverage and deploy apply/audit tests

**Files:**
- Modify: `test/run.sh`

- [ ] **Step 1: Write the failing tests**

Add these functions and register them (`check test_manifest_covers_home`, `check test_deploy_apply`) before `echo "----"`:
```bash
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
```

- [ ] **Step 2: Run the suite**

Run: `DOTFILES=~/src/nonrational-dotfiles ./test/run.sh`
Expected: `PASS: test_manifest_covers_home`, `PASS: test_deploy_apply`, all others pass, `N passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add build.sh install.sh manifest deploy.sh test/run.sh
git commit -m "Emit generated manifest + vendor deploy.sh; install.sh -> deploy.sh apply"
```

### Task 4.4: Update README, note VM drift detection, open the PR

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update Install + Sync sections**

- "Install": after `./install.sh`, note `./deploy.sh audit` reports drift on the VM at any time.
- "Sync": under "VM", add: after `git pull`, run `./deploy.sh apply` (was: re-run `./install.sh` when new files were added) and `./deploy.sh audit` to confirm no drift.
- Add one line clarifying the two root files: `allowlist` is hand-edited (selection); `manifest` is generated by `build.sh` (do not edit).

- [ ] **Step 2: Full build + test + open PR**

Run:
```bash
DOTFILES=~/src/nonrational-dotfiles ./build.sh
./test/run.sh
git add -A && git commit -m "README: allowlist/manifest split, deploy.sh apply/audit on the VM"
gh pr create --repo nonreagent/dotfiles --reviewer nonrational \
  --title "VM uses vendored deploy.sh (apply + audit); drift detection" \
  --body "build.sh emits a deploy-format manifest for home/ and vendors deploy.sh. install.sh collapses to a base-image pre-flight + deploy.sh apply. The VM gets deploy.sh audit for free."
```
Human merges. On the VM: `git pull && ./deploy.sh audit` should exit 0.

---

## Self-Review (spec coverage)

- **"Unify the placement engine, keep ownership split, don't fork, don't unify manifests"** → Phases 1–2 make `deploy.sh`+`manifest` the one engine upstream; Phase 3 keeps a separate `allowlist` downstream (ownership split preserved); Phase 4 vendors the *engine* (shared code) without merging the manifests.
- **Layer 1 Placement** → Phase 1 (land engine) + Phase 2 (full coverage, retire `link-dotfiles.sh`). Parity via Task 2.2 coverage test + Task 2.3 live audit.
- **Layer 2 Selection** → Phase 3: rename to `allowlist`, resolve against manifest, `∩ os=Linux`, `bin.Linux → bin` special case deleted (Task 3.2 Step 2).
- **Layer 3 Transformation** → untouched and still imperative in `build.sh` (identity split, `CLAUDE.md`/`exe.md`/`identity.md` copies, `.bashrc.Linux`/`.tmux.conf` appends, `.bash_profile` patch). Plan does not move these; it only shrinks the vendor + placement code around them.
- **Close the loop on the VM** → Phase 4: emit generated manifest (Task 4.1), vendor `deploy.sh` (Task 4.1), `install.sh` → `deploy.sh apply` (Task 4.2), `audit` drift detection (Tasks 4.3–4.4).
- **No `project=` condition; manifest scoped to `$HOME`** → Global Constraints; manifest rows are all `~/`-targets; no phase adds project scoping.
- **Each step shrinks `build.sh`/`install.sh`** → Phase 3 removes the vendor loop's path-duplication + the `bin` special case; Phase 4 removes `install.sh`'s linking loop. Net negative lines in both.

**Residual decision surfaced (not a blocker):** "install.sh becomes deploy.sh apply" is literal for the *linking*, but the VM-base-image pre-flight (`normalize_parents`) stays in a thin `install.sh` wrapper because it's a host fact `deploy.sh` shouldn't own. If the current exe.dev base image ships no stray non-directory path components, `install.sh` can be deleted outright and the README can say `./deploy.sh apply` — decide by checking a fresh VM before Task 4.2.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-09-unify-placement-engine.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Note the cross-repo dependency: Phase 3 needs Phase 2 merged; Phase 4 needs Phase 1 merged.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.

Which approach?
