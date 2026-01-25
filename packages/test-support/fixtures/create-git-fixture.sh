#!/usr/bin/env bash
# create-git-fixture.sh - Generate cached git repo fixture for fast test initialization
#
# This script creates a pre-initialized bare git repo with an initial commit,
# packaged as a tarball. Tests can extract this tarball instead of running
# expensive git init/commit operations.
#
# Usage: bash tests/fixtures/create-git-fixture.sh
# Output: tests/fixtures/git-repo.tar

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

# Create a bare repository
git init --quiet --bare cached-repo.git

# Create initial commit in a temp checkout
TEMP_CHECKOUT=$(mktemp -d)
git clone --quiet "$WORK_DIR/cached-repo.git" "$TEMP_CHECKOUT" 2>/dev/null
cd "$TEMP_CHECKOUT"
git config user.email "test@example.com"
git config user.name "Test User"
echo "test" > README.md
git add README.md
git commit --quiet -m "Initial commit"
git push --quiet origin HEAD:main 2>/dev/null

cd "$WORK_DIR"
rm -rf "$TEMP_CHECKOUT"

# Package as tarball
tar -cf "$FIXTURE_DIR/git-repo.tar" -C "$WORK_DIR" cached-repo.git
echo "Created: $FIXTURE_DIR/git-repo.tar"
