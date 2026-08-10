#!/bin/bash
# Bumps the version, commits, and tags — so Info.plist and the git tag can't drift apart.
#
#   ./scripts/bump-version.sh 1.1.0
#   git push origin main --tags     # this triggers the Release workflow
#
# CFBundleVersion is derived from the version string rather than tracked separately;
# it only has to increase, and this keeps one number to think about.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Usage: $0 <major.minor.patch>   e.g. $0 1.1.0" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "Working tree is dirty — commit or stash first." >&2
	exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
	echo "Tag v$VERSION already exists." >&2
	exit 1
fi

CURRENT=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
BUILD=$(tr -d '.' <<<"$VERSION")

plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist

git add Resources/Info.plist
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "BudSwitch $VERSION"

echo "$CURRENT → $VERSION, tagged v$VERSION"
echo
echo "Push to publish:"
echo "  git push origin main --tags"
