#!/bin/zsh
# Regenerate SiliconAudit.xcodeproj from project.yml (XcodeGen). The project is gitignored.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f project.yml ]]; then
  echo "project.yml not present yet (arrives with the Phase 2 spike)." >&2
  exit 1
fi
if [[ ! -f Configs/Signing.xcconfig ]]; then
  echo "Configs/Signing.xcconfig missing; copying the example. Fill in DEVELOPMENT_TEAM." >&2
  cp Configs/Signing.xcconfig.example Configs/Signing.xcconfig
fi
xcodegen generate --spec project.yml
