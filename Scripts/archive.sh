#!/bin/zsh
# Archive the app for one platform and export it for App Store Connect (TestFlight) or for direct
# installation on registered devices. Defaults to ReleaseHardened on supported platforms and
# Release on tvOS, where Apple does not support Enhanced Security. --standard opts out elsewhere.
#
# Usage: Scripts/archive.sh <iOS|macOS|tvOS|visionOS> [--standard] [--development] [--no-export|--local-export|--export-only]
#   --hardened     accepted for compatibility; this is already the default
#   --development  export with Configs/ExportOptions-development.plist instead of the App Store one
#   --no-export    stop after the .xcarchive (e.g. to notarize a Developer ID build by hand)
#   --local-export package locally without uploading (useful for checking distribution signing)
#   --export-only  export/upload the existing archive without rebuilding (can use --local-export)
# Mobile App Store archives use manually created distribution profiles; see docs/release.md.
# Output: build/archives/<platform>[-hardened].xcarchive and build/export/<platform>[-hardened]/
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${1:?platform: iOS, macOS, tvOS, or visionOS}"; shift
case "$PLATFORM" in
  iOS|macOS|tvOS|visionOS) ;;
  *) echo "unknown platform $PLATFORM; use iOS, macOS, tvOS, or visionOS" >&2; exit 2 ;;
esac
CONFIG=ReleaseHardened; SUFFIX="-hardened"; OPTIONS=Configs/ExportOptions-appstore.plist; EXPORT=1
[[ "$PLATFORM" == tvOS ]] && { CONFIG=Release; SUFFIX=""; }
DEVELOPMENT=0; LOCAL_EXPORT=0; REUSE_ARCHIVE=0
for arg in "$@"; do
  case "$arg" in
    --hardened)
      if [[ "$PLATFORM" == tvOS ]]; then
        echo "Apple Enhanced Security does not support tvOS. Omit --hardened to build the supported tvOS configuration." >&2
        exit 2
      fi
      CONFIG=ReleaseHardened; SUFFIX="-hardened" ;;
    --standard) CONFIG=Release; SUFFIX="" ;;
    --development) OPTIONS=Configs/ExportOptions-development.plist; DEVELOPMENT=1 ;;
    --no-export) EXPORT=0 ;;
    --local-export) LOCAL_EXPORT=1 ;;
    --export-only) REUSE_ARCHIVE=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
if (( ! EXPORT && (LOCAL_EXPORT || REUSE_ARCHIVE) )); then
  echo "--no-export cannot be combined with --local-export or --export-only" >&2
  exit 2
fi
SCHEME=SiliconAudit
[[ "$CONFIG" == ReleaseHardened ]] && SCHEME="SiliconAudit Hardened"
ARCHIVE="build/archives/$PLATFORM$SUFFIX.xcarchive"
if (( REUSE_ARCHIVE )); then
  if [[ ! -f "$ARCHIVE/Info.plist" ]]; then
    echo "No archive at $ARCHIVE; run without --export-only first." >&2
    exit 1
  fi
else
  Scripts/gen-project.sh >/dev/null
fi
# Xcode's Apple rsync can invoke another rsync through PATH. Homebrew's version has incompatible
# extended-attribute options, causing exportArchive to fail with an unhelpful "Copy failed".
# Generate the project first so Homebrew's xcodegen remains available.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SIGNING_ARGS=()
if (( ! DEVELOPMENT && ! REUSE_ARCHIVE )) && [[ "$PLATFORM" != macOS ]]; then
  PROFILE="${SILICON_AUDIT_APP_PROFILE:-Silicon Audit App Store}"
  [[ "$PLATFORM" == tvOS ]] && PROFILE="${SILICON_AUDIT_APP_PROFILE:-Silicon Audit tvOS App Store}"
  SIGNING_ARGS=(SILICON_AUDIT_SIGN_STYLE=Manual
    "SILICON_AUDIT_SIGN_IDENTITY=Apple Distribution"
    "SILICON_AUDIT_APP_PROFILE=$PROFILE"
    "SILICON_AUDIT_WATCH_PROFILE=${SILICON_AUDIT_WATCH_PROFILE:-Silicon Audit Watch App Store}")
  echo "App Store archive profile: $PROFILE (setup: docs/release.md)"
fi
TEMP_OPTIONS=""; TEMP_ENTITLEMENTS=""
trap '[[ -z "$TEMP_OPTIONS" ]] || rm -f "$TEMP_OPTIONS"; [[ -z "$TEMP_ENTITLEMENTS" ]] || rm -f "$TEMP_ENTITLEMENTS"' EXIT
if (( LOCAL_EXPORT )); then
  TEMP_OPTIONS=$(mktemp "${TMPDIR:-/tmp}/silicon-export.XXXXXX")
  cp "$OPTIONS" "$TEMP_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Add :destination string export' "$TEMP_OPTIONS" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c 'Set :destination export' "$TEMP_OPTIONS"
  OPTIONS="$TEMP_OPTIONS"
fi
mkdir -p build/archives build/export
if (( REUSE_ARCHIVE )); then
  echo "reusing $ARCHIVE (version and build number remain as archived)"
else
  xcodebuild archive -project SiliconAudit.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "generic/platform=$PLATFORM" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    "${SIGNING_ARGS[@]}" -quiet
  echo "archived $ARCHIVE"
fi
# Xcode can silently drop entitlements unsupported by a provisioning profile. Never upload a
# hardened build whose Info.plist claims Enhanced Security but whose signature lacks it.
if [[ "$CONFIG" == ReleaseHardened ]]; then
  TEMP_ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/silicon-entitlements.XXXXXX")
  codesign -d --entitlements - --xml "$ARCHIVE/Products/Applications/Silicon Audit.app" > "$TEMP_ENTITLEMENTS"
  for entry in 'com.apple.security.hardened-process=true' \
    'com.apple.security.hardened-process.checked-allocations=true' \
    'com.apple.security.hardened-process.enhanced-security-version-string=1'; do
    key="${entry%%=*}"; expected="${entry#*=}"
    actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$TEMP_ENTITLEMENTS" 2>/dev/null) || actual=""
    if [[ "$actual" != "$expected" ]]; then
      echo "Refusing export: $PLATFORM archive is missing hardened entitlement $key." >&2
      echo "Check the profile's Enhanced Security support; use --standard only for an intentional non-hardened build. See docs/release.md." >&2
      exit 1
    fi
  done
fi
if (( EXPORT )); then
  if xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "build/export/$PLATFORM$SUFFIX" -allowProvisioningUpdates -quiet; then
    :
  else
    export_result=$?
    echo "Archive retained at $ARCHIVE. After resolving the export error, add --export-only to retry without rebuilding." >&2
    exit "$export_result"
  fi
  if (( LOCAL_EXPORT || DEVELOPMENT )); then
    echo "exported locally to build/export/$PLATFORM$SUFFIX (not uploaded)"
  else
    echo "uploaded $PLATFORM$SUFFIX to App Store Connect"
  fi
fi
