#!/bin/zsh
# Build every product and run the test suite.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
