#!/bin/zsh
# Set the marketing version everywhere it lives, and bump the build number.
# Usage: Scripts/bump-version.sh <X.Y.Z> [build-number]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?version X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a semantic version: $VERSION" >&2; exit 2; }
CURRENT=$(awk -F': ' '/^ *CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml)
BUILD="${2:-$((CURRENT + 1))}"
perl -0pi -e "s/(MARKETING_VERSION: )[0-9.]+/\${1}$VERSION/; s/(CURRENT_PROJECT_VERSION: )[0-9]+/\${1}$BUILD/" project.yml
perl -pi -e "s/(public static let version = \")[0-9.]+(\")/\${1}$VERSION\${2}/" Sources/SiliconAuditCore/SiliconAuditCore.swift
# npm updates package.json and package-lock.json together (a perl edit would leave the lockfile stale).
(cd Tools/generate-matrix && npm version --no-git-tag-version --allow-same-version "$VERSION" >/dev/null)
grep -q "^## $VERSION" CHANGELOG.md || perl -0pi -e "s/^## Unreleased\n/## Unreleased\n\n## $VERSION — $(date +%Y-%m-%d)\n/m" CHANGELOG.md
echo "version $VERSION, build $BUILD: project.yml, SiliconAuditCore.swift, Tools/generate-matrix/package{,-lock}.json, CHANGELOG.md"
