#!/bin/zsh
# Build the app for a simulator platform, install it on a booted (or the first available) simulator
# of that platform, and launch it. Extra arguments are passed to the app as launch arguments;
# `-key value` pairs land in UserDefaults, e.g. `-presentationMode details -initialSelection __export__`.
# Usage: Scripts/run-simulator.sh <iOS|tvOS|visionOS|watchOS> [launch args...]
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:?platform: iOS, tvOS, visionOS, or watchOS}"; shift
SCHEME=SiliconAudit
[[ "$PLATFORM" == watchOS ]] && SCHEME=SiliconAuditWatch
Scripts/gen-project.sh >/dev/null
DERIVED="$PWD/.build/DerivedData"
XCB=(xcodebuild -project SiliconAudit.xcodeproj -scheme "$SCHEME" -destination "generic/platform=$PLATFORM Simulator" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO)
"${XCB[@]}" build -quiet
SETTINGS=$("${XCB[@]}" -showBuildSettings 2>/dev/null)
BUILD_DIR=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *TARGET_BUILD_DIR =/{print $2; exit}')
PRODUCT=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *FULL_PRODUCT_NAME =/{print $2; exit}')
APP="$BUILD_DIR/$PRODUCT"
[[ -d "$APP" ]] || { echo "Built product not found at $APP" >&2; exit 1; }

# Prefer a booted simulator of this platform; otherwise boot the first available one.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
platform = sys.argv[1].lower().replace("visionos", "xros")
devices = [d for rt, ds in json.load(sys.stdin)["devices"].items() if platform in rt.lower() for d in ds]
booted = [d for d in devices if d["state"] == "Booted"]
print((booted or devices or [{"udid": ""}])[0]["udid"])' "$PLATFORM")
[[ -n "$UDID" ]] || { echo "No $PLATFORM simulator available." >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
echo "simulator $UDID; screenshot with: xcrun simctl io $UDID screenshot out.png"
