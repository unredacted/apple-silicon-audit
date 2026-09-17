# Changelog

All notable changes to Silicon Audit. The format follows Keep a Changelog; versions are semantic.
The export schema has its own version (`schema_version` in every export; 1.1.0 today).

## Unreleased

- Change monitoring: the first reading becomes a baseline; checks on launch, on return to the
  foreground and in the background (`BGAppRefreshTask`, `WKApplication` refresh) record what moved,
  show it on the Overview and in a Changes screen at two depths (plain sentence, what it could mean,
  technical before/after), and can post an opt-in local notification. The monitoring screen states
  what a kernel reading can and cannot catch. `ReportDiff` in core; `silicon-audit diff` in the CLI.
- Redesign the app around one structure at two depths instead of an Overview/Details mode switch:
  a chip-first summary card with a verdict tally, plain-language checks with the verdict word and its
  source on one line, a "Look deeper" group (or the sidebar) that opens all readings on three shelves,
  Apple's documentation, the new "How this was measured" screen, and About the data. Rows share one
  column layout on every platform; the export sheet gains a Done button; iPad and Mac gain a Refresh
  button; the "From Apple Watch" section no longer appears on devices that cannot pair a watch.
- Use a standard tvOS release with an accurate security marker; Enhanced Security is supported
  on iOS, macOS, and visionOS. Declare the apps' non-exempt encryption usage as false to prevent
  future TestFlight builds getting stuck at Missing Compliance.
- Default release archives to Enhanced Security (`ReleaseHardened`); keep `--standard` for comparison builds.
- Use manual distribution profiles for mobile App Store archives, add `--local-export`, and
  isolate Xcode's PATH to prevent Homebrew rsync export failures. Reject hardened archives when
  Xcode omits their Enhanced Security entitlements.
- Add `--export-only` to retry uploads after account or network failures without rebuilding.

- Replace the monochrome icon with a blue silicon-and-inspection logo across all platforms,
  the README, and the results site; add a reproducible icon installation script.
- Bound child-process fault tests and compact imports; validate schema versions and fact identity.
- Correct partial kernel-walk reporting, uncertain self-test claims, overview verdicts, and legacy PAC fallback.
- Fix raw-byte result conflicts, rejected-submission isolation, and regeneration after concurrent pushes.
- Add regression coverage and adapt live capability-mask checks to newer kernels.
- See [the codebase audit](docs/audit-2026-09-16.md) for findings, verification, and remaining device checks.

## 0.1.0 — 2026-09-16

First complete build (pre-release), squash-merged from nine reviewed phases plus the icon, README, and
release follow-ups. 0.x releases are pre-releases: the export schema is stable (1.1.0), the apps have
run only on the maintainers' devices and simulators, and nothing has been through App Store review.

- Engine: five-way `sysctl` probe, MIB walk with inventory fallback, environment flags, capability
  bitmask decode and cross-check, SoC identity chain, Apple's documented matrix, JSON export
  (schema 1.1.0) and compact Base45 export.
- `silicon-audit` CLI with fixtures.
- Apps for iOS/iPadOS, macOS, watchOS, tvOS, visionOS: Overview and Details modes, provenance on
  every fact, documented-matrix chain, Watch → iPhone transfer, QR export on Apple TV.
- Community results database with validator, conflict detection, generated matrix and site.
- Enforcement self-test: tagged-pointer observation and a child-process tag-mismatch fault test;
  hardened build configurations with Apple's Enhanced Security entitlements.
- App icons for every platform (a black chip), README, release scripts and docs.
