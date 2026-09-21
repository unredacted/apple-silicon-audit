#!/bin/zsh
# Stage the Mac app for App Store screenshots, one screen at a time.
#
# The Mac's screen is never captured by this script or by anything it runs: it only builds and
# launches the app at a chosen screen. You take each frame with the system screenshot UI
# (Cmd-Shift-4, then Space, then click the window), which needs no screen-recording grant.
# `Scripts/compose-macos-screenshots.swift` then fits those captures onto the exact canvas
# App Store Connect requires.
#
# Usage: Scripts/screenshots-macos.sh [route]        # one screen, or no argument to walk all of them
# Routes: __overview__ memory_tagging __all__ __documented__ __changes__ __monitor__
set -euo pipefail
cd "$(dirname "$0")/.."

ROUTES=(__overview__ memory_tagging __all__ __documented__ __changes__ __monitor__)
[[ $# -gt 0 ]] && ROUTES=("$@")

Scripts/gen-project.sh >/dev/null
DERIVED="$PWD/.build/DerivedData"
XCB=(xcodebuild -project SiliconAudit.xcodeproj -scheme SiliconAudit -destination "generic/platform=macOS" -derivedDataPath "$DERIVED")
echo "Building SiliconAudit for macOS…"
"${XCB[@]}" build -quiet
SETTINGS=$("${XCB[@]}" -showBuildSettings 2>/dev/null)
BUILD_DIR=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *TARGET_BUILD_DIR =/{print $2; exit}')
PRODUCT=$(printf '%s\n' "$SETTINGS" | awk -F' = ' '/^ *FULL_PRODUCT_NAME =/{print $2; exit}')
APP="$BUILD_DIR/$PRODUCT"
[[ -d "$APP" ]] || { echo "Built product not found at $APP" >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")

RAW="build/screenshots/macOS/raw"
mkdir -p "$RAW"
cat <<TXT

Capture each screen with Cmd-Shift-4, then Space, then click the app's window.
Save every file into:  $RAW
Aim for a window near 16:10 (e.g. 1440 x 900) so it fills the store canvas without large margins.
Name them in the order you want them listed, for example 01-overview.png, 02-memory-tagging.png.

TXT

for route in "${ROUTES[@]}"; do
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  # The window frame is restored per app, so the size you set on the first screen carries over.
  open -n "$APP" --args -initialSelection "$route"
  echo "Showing: $route"
  read "?  capture it, then press Return for the next screen… "
done
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
echo "Done. Raw captures go in $RAW; compose them with:"
echo "  swift Scripts/compose-macos-screenshots.swift"
