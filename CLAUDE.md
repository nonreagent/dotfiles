# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The built agent home for @nonreagent on exe.dev VMs: a curated subset of the public `nonrational/dotfiles` plus an identity overlay. The README covers the build and install mechanics. Two facts shape every edit:

- **`home/` is generated.** `./build.sh` deletes `home/` and regenerates it from a fresh clone of upstream (its pushed state on GitHub, not a local checkout) plus `overlay/`. Hand edits to `home/` are silently reverted on the next build. Durable changes go in `overlay/` (identity files; `overlay/append/<rel>` blocks appended verbatim to same-named vendored files; `overlay/skills/<name>/` for agent-only skills) or in `allowlist` (which upstream paths get vendored). A rule that holds for any repo on any machine goes upstream by PR, not here.
- **`home/` is live.** On the VM, `install.sh` symlinks every file under `home/` into `$HOME`, so the working tree *is* the deployed shell, git, and agent config. Checking out another branch swaps the live config, including the `gh` credential helper.

## Commands

- `./build.sh` regenerates `home/` and `manifest` (see the README for `DOTFILES=` and `SOURCE_REPO=`). Run it deliberately as a step, never speculatively mid-edit: a build that fails halfway leaves `home/` half-deleted, and with it the live config, until the rebuild completes.
- `./test/run.sh` is **the gate.** This repo has no CI; `gh pr checks` reporting nothing is not a pass. Run it before every push and after every merge of `main` into a branch. `manifest` is generated, so git will auto-merge two branches that both added rows and report `MERGEABLE`/`CLEAN` while the merged file no longer matches what `build.sh` emits; `test_idempotent` and `test_manifest_covers_home` catch that.
- `./install.sh` links `home/` into `$HOME` and prunes symlinks orphaned by a move or removal. Re-run it after any build that added, moved, or removed files.
- `just` runs `build` then `install`.

## Workflow on this VM

- **This checkout is usually behind.** The operator edits and merges from other machines; the shared fetch-first rule applies with extra force here.
- **Commit upstream drift on its own.** A build on a clean tree pulls whatever upstream changed since the last build. Commit that as `latest from upstream` before the feature commit; never restore it to keep a diff clean. The operator wants this VM tracking upstream continuously, and those commits go straight to `main`.
- **Then edit `overlay/` or `allowlist`, rebuild, run the gate, commit `home/` together with the overlay change**, and `./install.sh`.
- **Upstream PRs do not start from this checkout.** `origin` (nonreagent/dotfiles) shares no history with `upstream` (nonrational/dotfiles) and is not a GitHub fork, so a branch cut from `main` here cannot become an upstream PR. Use a plain clone of upstream (this VM keeps one at `~/src/nonrational-dotfiles`): fetch, branch off its `origin/main`, push, `gh pr create --repo nonrational/dotfiles`. If you must work from here, branch from `upstream/main` and expect plain `git push` to fail while that branch is out, because the live `.gitconfig` changed under you: `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='!gh auth git-credential' git push …`, then return to `main` promptly.

## Gotchas

- **`home/.claude/settings.json` drops its `model` key on the way into git.** Claude Code rewrites that key whenever a session picks a model, and the file is a live symlink, so the repo would otherwise be permanently dirty. `.gitattributes` runs the file through a clean filter (`jq 'del(.model)'`, written into local git config by `install.sh` and `build.sh`) so the index never holds a model and `git status` ignores the churn; every other key still flows from upstream through `build.sh`. If the file shows as modified with only the model line differing, the filter is unconfigured on this clone: run `./install.sh`.
- **The shims are load-bearing.** `home/.claude/rules`, `home/.claude/skills`, and `home/.gemini/antigravity-cli/skills` are upstream symlinks *into* `home/.agents/`, which the allowlist vendors wholesale, so `build.sh` keeps them verbatim and there is exactly one materialised copy of the skills tree. Dropping the `home/.agents/skills` allowlist entry makes the build fall back to a full deref'd copy per shim. `test_symlink_policy` guards both halves.
- **The overlay `CLAUDE.md` double-loads four rules.** `overlay/claude-CLAUDE.md` `@`-imports language, workflow, markdown, and improvement, which Claude Code also auto-discovers from `~/.claude/rules/`. Pre-existing. When vendoring a new rule, add it to the allowlist only, not to the import list. A bare `CLAUDE.md` beside a populated `rules/` is not orphaned; don't "fix" it by adding imports.
- **`rw-merge` is silent on success** and refuses `NOT_READY` whenever GitHub reports `mergeable` as anything but `MERGEABLE`, which includes the `UNKNOWN` it serves for a few seconds after any push and permanently for a PR that is merging or already merged. Before treating a refusal as a real block, read `merged` via REST and re-query `mergeable`/`reviewDecision`; if they read `MERGEABLE` and `APPROVED`, re-run it. Never fall back to `gh pr merge` by hand. Fix tracked in #16.
