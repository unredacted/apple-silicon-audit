# Changelog

All notable changes to Silicon Audit. The format follows Keep a Changelog; versions are semantic.
The export schema has its own version (`schema_version` in every export; 1.1.0 today).

## Unreleased

- App icons for every platform (a black chip), README, release scripts and docs.

## 0.1.0 — 2026-09-10

First complete build, squash-merged from nine reviewed phases.

- Engine: five-way `sysctl` probe, MIB walk with inventory fallback, environment flags, capability
  bitmask decode and cross-check, SoC identity chain, Apple's documented matrix, JSON export
  (schema 1.1.0) and compact Base45 export.
- `silicon-audit` CLI with fixtures.
- Apps for iOS/iPadOS, macOS, watchOS, tvOS, visionOS: Overview and Details modes, provenance on
  every fact, documented-matrix chain, Watch → iPhone transfer, QR export on Apple TV.
- Community results database with validator, conflict detection, generated matrix and site.
- Enforcement self-test: tagged-pointer observation and a child-process tag-mismatch fault test;
  hardened build configurations with Apple's Enhanced Security entitlements.
