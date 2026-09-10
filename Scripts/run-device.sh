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
xcodebuild -project SiliconAudit.xcodeproj -scheme "$SCHEME" -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build
APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "*.app" -path "*iphoneos*" | head -1)
xcrun devicectl device install app --device "$DEVICE" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
