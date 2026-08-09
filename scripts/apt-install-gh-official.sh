#!/usr/bin/env bash
#
# Fix `gh issue view` failing with:
#   GraphQL: Projects (classic) is being deprecated ... (repository.issue.projectCards)
#
# Cause: Ubuntu ships an old gh (2.45.0) that queries the deprecated classic
# Projects field. GitHub now returns that deprecation as a hard error.
# Fix: replace the Ubuntu package with the official GitHub CLI apt repo, which
# carries a current gh that no longer queries projectCards.

set -euo pipefail

echo ">> Current gh:"
gh --version 2>/dev/null | head -1 || echo "   (not installed)"

# 1. Remove the Ubuntu-packaged gh so it can't shadow the official one.
echo ">> Removing Ubuntu-packaged gh (if present)..."
sudo apt-get remove -y gh 2>/dev/null || true

# 2. Add GitHub's official apt repository and signing key.
echo ">> Adding official GitHub CLI apt repository..."
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -nv -O- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

# 3. Install the current gh from the official repo.
echo ">> Installing current gh..."
sudo apt-get update
sudo apt-get install -y gh

# 4. Verify.
echo ">> New gh:"
hash -r
gh --version | head -1

echo ">> Done. 'gh issue view' should now work without the projectCards error."
