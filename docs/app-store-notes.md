# App Review notes (draft)

Text to paste into App Store Connect's review notes, plus the facts behind it.

## What the app does

Silicon Audit reads CPU security feature flags that the kernel publishes through the public
`sysctl` interface (`hw.optional.arm.*`, e.g. `FEAT_MTE4`, `FEAT_PAuth`, `FEAT_BTI`) and shows,
for the device it runs on, which features the kernel reports as present. Next to those
measurements it shows Apple's own published statements for the chip family, with their source
and publication date, clearly labeled as documentation rather than measurement.

## Privacy

- No network access of any kind. No analytics, no crash reporting SDKs.
- Nothing is stored between launches except a report the user chose to export.
- Export happens only on an explicit user action (share sheet, Save panel, copy).
- The export contains no serial number, UDID, identifierForVendor, hostname, boot time, account,
  or location. The set of keys that may appear is a fixed allowlist; `kern.hostname`,
  `kern.uuid`, `kern.bootsessionuuid`, and `kern.boottime` are never read.
- `PrivacyInfo.xcprivacy` declares no tracking, no collected data types, and no required-reason
  API categories. `sysctl`/`sysctlbyname` are not in Apple's required-reason list; if that list
  changes, the manifest will be updated.

## APIs

Only public APIs: `sysctlbyname(3)`, `sysctlnametomib(3)`, `sysctl(2)`, WatchConnectivity,
SwiftUI, Compression. No private frameworks, no entitlements beyond App Sandbox and
user-selected file access on macOS.

## Fingerprinting concern, answered

The app reads broad hardware characteristics, which can look like fingerprinting. It does not
transmit them anywhere, does not persist them, and the only way data leaves the device is the
user sharing a file. The purpose is transparency for the device owner.

## Distribution fallback

If review rejects the app, it remains buildable from source with a free developer account and
distributable via TestFlight; the results database accepts exports from either.
