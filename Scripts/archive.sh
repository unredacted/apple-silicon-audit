#!/bin/zsh
# Archive the app for one platform and export it for App Store Connect (TestFlight) or for direct
# installation on registered devices. Uses the Release configuration, or ReleaseHardened with
# --hardened (Apple's Enhanced Security entitlements; see SPEC.md §11 and docs/release.md).
#
# Usage: Scripts/archive.sh <iOS|macOS|tvOS|visionOS> [--hardened] [--development] [--no-export]
#   --development  export with Configs/ExportOptions-development.plist instead of the App Store one
#   --no-export    stop after the .xcarchive (e.g. to notarize a Developer ID build by hand)
# Output: build/archives/<platform>[-hardened].xcarchive and build/export/<platform>[-hardened]/
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:?platform: iOS, macOS, tvOS, or visionOS}"; shift
CONFIG=Release; SUFFIX=""; OPTIONS=Configs/ExportOptions-appstore.plist; EXPORT=1
for arg in "$@"; do
  case "$arg" in
    --hardened) CONFIG=ReleaseHardened; SUFFIX="-hardened" ;;
    --development) OPTIONS=Configs/ExportOptions-development.plist ;;
    --no-export) EXPORT=0 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
SCHEME=SiliconAudit
[[ "$CONFIG" == ReleaseHardened ]] && SCHEME="SiliconAudit Hardened"
Scripts/gen-project.sh >/dev/null
ARCHIVE="build/archives/$PLATFORM$SUFFIX.xcarchive"
mkdir -p build/archives build/export
xcodebuild archive -project SiliconAudit.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -destination "generic/platform=$PLATFORM" -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet
echo "archived $ARCHIVE"
if (( EXPORT )); then
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "build/export/$PLATFORM$SUFFIX" -allowProvisioningUpdates -quiet
  echo "exported to build/export/$PLATFORM$SUFFIX (options: $OPTIONS)"
fi
