#!/usr/bin/env bash
# Publish the current main of ido-pipeline to all projects by moving the version tag (default v1).
# Refuses unless self-test passed on exactly that commit.
#   bash scripts/release.sh [v1]
set -euo pipefail
TAG="${1:-v1}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git fetch -q origin main --tags
SHA="$(git rev-parse origin/main)"
RESULT="$(gh run list --workflow self-test --commit "$SHA" --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || true)"
if [ "$RESULT" != "success" ]; then
  echo "❌ self-test has not passed on main (${SHA:0:7}): '${RESULT:-no run}'. Not releasing."; exit 1
fi
OLD="$(git rev-parse -q --verify "refs/tags/$TAG" || echo none)"
git tag -f "$TAG" "$SHA" >/dev/null
git push -q -f origin "refs/tags/$TAG"
echo "✓ $TAG now → ${SHA:0:7} (was ${OLD:0:7}). Every project uses it from its next run."
echo "  Roll back: git tag -f $TAG ${OLD:0:7} && git push -f origin refs/tags/$TAG"
