#!/bin/zsh
# Re-sign a binary (default: the debug CLI) ad hoc with Apple's Enhanced Security entitlements from
# Configs/hardened.entitlements, so `silicon-audit self-test` measures a tagged, checked process.
# Ad-hoc signing is enough: these entitlements need no provisioning profile (verified on macOS 26).
# Usage: Scripts/sign-hardened.sh [path/to/binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/silicon-audit}"
[[ -x "$BIN" ]] || { echo "No executable at $BIN (run swift build first)" >&2; exit 1; }
codesign --force --sign - --entitlements Configs/hardened.entitlements "$BIN"
codesign --display --entitlements - "$BIN" 2>&1 | grep -E "hardened-process|checked-allocations" | sed 's/^/  /'
echo "signed $BIN"
