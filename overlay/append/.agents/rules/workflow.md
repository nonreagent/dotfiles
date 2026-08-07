<!-- --- nonreagent overlay (exe.dev) --- -->

- **Never name a private repo in a public one.** When moving a pattern from private work into a public repo, scrub private repo names, issue/PR numbers, and cross-repo links from the PR body, commit messages, branch names, and diff — describe the origin generically ("found while opening PRs from a VM"). Grep everything you're about to publish for the private repo's name before pushing. Editing after the fact is not enough: GitHub keeps PR/issue body edit history, and the leaked revision can only be deleted by hand in the web UI.
