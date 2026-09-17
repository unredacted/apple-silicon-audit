# App Review notes (draft)

Text to paste into App Store Connect's review notes, plus the facts behind it. Platforms: iOS/iPadOS, macOS, watchOS, tvOS, visionOS from one project (`docs/release.md`).

## What the app does

Silicon Audit reads CPU security feature flags that the kernel publishes through the public
`sysctl` interface (`hw.optional.arm.*`, e.g. `FEAT_MTE4`, `FEAT_PAuth`, `FEAT_BTI`) and shows,
for the device it runs on, which features the kernel reports as present. Next to those
measurements it shows Apple's own published statements for the chip family, with their source
and publication date, clearly labeled as documentation rather than measurement. It also keeps the
most recent reading on the device and, when the app opens or the system runs a background refresh,
reads the same values again and tells the owner if anything changed (optionally with a local
notification the user turns on).

## Privacy

- No network access of any kind. No analytics, no crash reporting SDKs.
- Nothing leaves the device. The app keeps, in its own container only: the most recent reading as
  the baseline for change monitoring and the changes it has detected (Application Support); the
  notification preference and launch arguments (UserDefaults); and Apple Watch reports the user
  chose to transfer to the phone. Deleting the app removes all of it. There is no account and no
  sync.
- Export happens only on an explicit user action (share sheet, Save panel, copy).
- The export contains no serial number, UDID, identifierForVendor, hostname, boot time, account,
  or location. The set of keys that may appear is a fixed allowlist; `kern.hostname`,
  `kern.uuid`, `kern.bootsessionuuid`, and `kern.boottime` are never read.
- `PrivacyInfo.xcprivacy` declares no tracking and no collected data types. One required-reason
  API is declared: `UserDefaults` (`NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`)
  for the app's own settings. `sysctl`/`sysctlbyname` are not in Apple's
  required-reason list; if that list changes, the manifest will be updated.

## APIs

Only public APIs: `sysctlbyname(3)`, `sysctlnametomib(3)`, `sysctl(2)`, WatchConnectivity,
SwiftUI, Compression, CoreImage (the QR code on Apple TV), UserNotifications (local notifications
only, opt-in), BackgroundTasks / WatchKit background refresh (to repeat the same reads
periodically), and on macOS `SecTaskCopyValueForEntitlement` to read the app's own entitlements.
No private frameworks.

Background modes: `fetch` (`BGAppRefreshTask`) on iOS, iPadOS, tvOS and visionOS. The refresh
re-runs the sysctl reads and compares them with the stored baseline; it makes no network request.

Entitlements: App Sandbox and user-selected file access on macOS. Builds from the hardened
configuration additionally declare Apple's Enhanced Security capability
(`com.apple.security.hardened-process`, `…enhanced-security-version-string` "1",
`…checked-allocations`), which lets the app measure whether the OS tags and checks its own memory.
That measurement is labeled as being about this build of the app, not the device. No other
entitlements.

## Fingerprinting concern, answered

The app reads broad hardware characteristics, which can look like fingerprinting. It never
transmits them. The one stored copy stays in the app's container so the owner can see whether the
readings change over time, and the only way data leaves the device is the user sharing a file. The
purpose is transparency for the device owner.

## Distribution fallback

If review rejects the app, it remains buildable from source with a free developer account and
distributable via TestFlight; the results database accepts exports from either.
