#!/bin/zsh
# Build the iOS app for the attached iPhone, install it, and launch it.
# Usage: Scripts/run-device.sh [scheme] [device-identifier]
# Device identifier defaults to the first device listed by devicectl.
set -euo pipefail
cd "$(dirname "$0")/.."
SCHEME="${1:-SiliconAudit}"
DEVICE="${2:-$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["devices"]; print(d[0]["identifier"] if d else "")')}"
if [[ -z "$DEVICE" ]]; then echo "No device attached." >&2; exit 1; fi
Scripts/gen-project.sh
DERIVED="$PWD/.build/DerivedData"
XCB=(xcodebuild -project SiliconAudit.xcodeproj -scheme "$SCHEME" -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates)
"${XCB[@]}" build

# Resolve the product this scheme just built from its own build settings, so a
# stale .app from another scheme in the shared DerivedData is never picked up.
# The first settings block printed belongs to the scheme's primary target.
SETTINGS=$("${XCB[@]}" -showBuildSettings 2>/dev/null)
BUILD_DIR=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *TARGET_BUILD_DIR =/{print $2; exit}')
PRODUCT=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *FULL_PRODUCT_NAME =/{print $2; exit}')
APP="$BUILD_DIR/$PRODUCT"
if [[ ! -d "$APP" ]]; then echo "Built product not found at $APP" >&2; exit 1; fi

xcrun devicectl device install app --device "$DEVICE" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
