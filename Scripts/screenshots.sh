#!/bin/zsh
# Capture App Store screenshots from simulators. No Mac screen capture is involved: every frame
# comes from `xcrun simctl io … screenshot`, which reads the simulator's own framebuffer.
#
# Usage: Scripts/screenshots.sh <iOS|iPadOS|tvOS|visionOS|watchOS> [device name substring]
# Output: build/screenshots/<platform>/<device>/NN-<route>.png
#
# Routes come from `Route.init(launchArgument:)`; the app opens straight to one when launched with
# `-initialSelection <route>` (SPEC §6). Two platforms take only one frame here: the watch app has
# no such argument, and on iPhone `AuditRootView` renders `compactLayout`, which always shows the
# Overview and never reads `selection`, so the argument would silently produce six identical files.
# Deeper iPhone screens have to be navigated to by hand.
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:?platform: iOS, iPadOS, tvOS, visionOS, or watchOS}"
DEVICE_MATCH="${2:-}"

SCHEME=SiliconAudit
SIM_PLATFORM="$PLATFORM"
# Screenshots must come from the configuration that ships, or the app's own self-test reports a
# different answer than the build on the App Store: the *Hardened configurations carry Apple's
# Enhanced Security entitlements and set the marker the audit reads (project.yml). tvOS and watchOS
# have no Enhanced Security, so their shipping configuration is the ordinary Release.
CONFIGURATION=ReleaseHardened
# Restricts the device search, so `iPadOS` cannot land on an iPhone: both share the iOS runtime.
DEVICE_KIND=""
case "$PLATFORM" in
  iOS)      DEFAULT_DEVICE="iPhone 18 Pro Max"; DEVICE_KIND=iphone ;;
  iPadOS)   DEFAULT_DEVICE="iPad Pro 13-inch"; SIM_PLATFORM=iOS; DEVICE_KIND=ipad ;;
  tvOS)     DEFAULT_DEVICE="Apple TV 4K (3rd generation)"; CONFIGURATION=Release ;;
  visionOS) DEFAULT_DEVICE="Apple Vision Pro" ;;
  watchOS)  DEFAULT_DEVICE="Apple Watch Ultra"; SCHEME=SiliconAuditWatch; CONFIGURATION=Release ;;
  *) echo "Unknown platform $PLATFORM" >&2; exit 1 ;;
esac
DEVICE_MATCH="${DEVICE_MATCH:-$DEFAULT_DEVICE}"

# The screens worth showing, in the order App Store Connect will list them.
ROUTES=(__overview__ memory_tagging __all__ __documented__ __changes__ __monitor__)
# Apple TV and Vision Pro have no hardware here, so every reading comes from the host Mac and the
# Overview carries the "Running in the Simulator" banner. The deeper screens do not, so the store
# set for those two platforms starts one screen in rather than showing a warning on the product page.
[[ "$PLATFORM" == tvOS ]] && ROUTES=(memory_tagging __all__ __documented__ __changes__ __monitor__ __export__)
[[ "$PLATFORM" == visionOS ]] && ROUTES=(memory_tagging __all__ __documented__ __changes__ __monitor__)
[[ "$PLATFORM" == watchOS ]] && ROUTES=(__overview__)
# iPhone ignores `-initialSelection`; see the note at the top of this file.
[[ "$PLATFORM" == iOS ]] && ROUTES=(__overview__)

Scripts/gen-project.sh >/dev/null
DERIVED="$PWD/.build/DerivedData"
XCB=(xcodebuild -project SiliconAudit.xcodeproj -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "generic/platform=$SIM_PLATFORM Simulator" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO)
echo "Building $SCHEME ($CONFIGURATION) for $SIM_PLATFORM Simulator…"
"${XCB[@]}" build -quiet
SETTINGS=$("${XCB[@]}" -showBuildSettings 2>/dev/null)
BUILD_DIR=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *TARGET_BUILD_DIR =/{print $2; exit}')
PRODUCT=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *FULL_PRODUCT_NAME =/{print $2; exit}')
APP="$BUILD_DIR/$PRODUCT"
[[ -d "$APP" ]] || { echo "Built product not found at $APP" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

# A device that does not match is a hard error. Falling back to "any simulator on this runtime"
# would quietly capture at a resolution App Store Connect rejects, which is the whole thing this
# script exists to prevent.
SELECTED=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
platform, match, kind = sys.argv[1].lower().replace("visionos", "xros"), sys.argv[2].lower(), sys.argv[3]
devices = [d for rt, ds in json.load(sys.stdin)["devices"].items() if platform in rt.lower() for d in ds]
if kind:
    devices = [d for d in devices if d["name"].lower().startswith(kind)]
# An exact name wins over a substring, so "Apple TV 4K (3rd generation)" does not pick the
# "(at 1080p)" variant of itself.
exact = [d for d in devices if d["name"].lower() == match]
hits = exact or [d for d in devices if match in d["name"].lower()]
if not hits:
    sys.exit(1)
# Newest runtime last in simctl output, so prefer the last match.
d = hits[-1]
print(d["udid"], d["name"])' "$SIM_PLATFORM" "$DEVICE_MATCH" "$DEVICE_KIND") || {
  echo "No available $PLATFORM simulator matching '$DEVICE_MATCH'." >&2
  echo "Pick one from: xcrun simctl list devices available" >&2
  exit 1
}
UDID="${SELECTED%% *}"
DEVICE_NAME="${SELECTED#* }"
echo "Simulator: $DEVICE_NAME ($UDID)"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"

# iPhone and iPad ask for notification permission on first launch (AuditRootView's task), and the
# system alert would sit over an unattended capture. `simctl privacy` has no notifications service,
# so the app's own "already asked" default is set instead, which skips the request.
LAUNCH_ARGS=()
[[ "$SIM_PLATFORM" == iOS ]] && LAUNCH_ARGS=(-monitor.promptDismissed YES)

# A clean, Apple-style status bar. Not every platform has one; failures are harmless.
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null || true

OUT="build/screenshots/$PLATFORM/${DEVICE_NAME// /-}"
rm -rf "$OUT"; mkdir -p "$OUT"
i=0
for route in "${ROUTES[@]}"; do
  i=$((i + 1))
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -initialSelection "$route" "${LAUNCH_ARGS[@]}" >/dev/null
  sleep 6   # the audit runs on launch; the screen is not final before it finishes
  FILE="$OUT/$(printf '%02d' $i)-${route//__/}.png"
  xcrun simctl io "$UDID" screenshot --type png "$FILE" >/dev/null 2>&1
  echo "  $(basename "$FILE")  $(sips -g pixelWidth -g pixelHeight "$FILE" | awk '/pixel/{printf "%s ", $2}')"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
echo "Wrote $i screenshots to $OUT"
