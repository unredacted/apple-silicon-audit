# Releasing Silicon Audit

Everything here runs from the Mac; nothing needs a device in Developer Mode.

## 1. Version

```bash
Scripts/bump-version.sh 0.2.0        # project.yml, SiliconAuditCore.version, generate-matrix, CHANGELOG
```

Write the release notes under the new heading in `CHANGELOG.md`. The export `schema_version` is
separate and changes only when `Schema/export-v1.schema.json` does (SPEC §8 has the policy).

## 2. Verify

```bash
Scripts/test.sh                                        # package tests
Scripts/run-simulator.sh iOS; Scripts/run-simulator.sh tvOS; Scripts/run-simulator.sh visionOS
swift run silicon-audit export | Scripts/validate-export.sh /dev/stdin
```

CI does the same on every push (`ci.yml`), plus the results validation (`results.yml`).

## 3. Archive and upload (TestFlight / App Store)

```bash
Scripts/archive.sh iOS         # also embeds the watch app
Scripts/archive.sh macOS
Scripts/archive.sh tvOS
Scripts/archive.sh visionOS
```

Each command archives with the `Release` configuration and exports with
`Configs/ExportOptions-appstore.plist` (automatic signing, upload to App Store Connect). Add
`--hardened` to ship the `ReleaseHardened` configuration with Apple's Enhanced Security entitlements:
that is what makes the self-test meaningful for users (SPEC §11). Decide per release; the hardened
configuration changes allocator behaviour, so soak it in TestFlight before it becomes the default.
`--development` exports an installable build for registered devices instead; `--no-export` stops at the
`.xcarchive`.

Paste `docs/app-store-notes.md` into App Store Connect's review notes and re-check its Required Reason
API list against Apple's current one (open item in `docs/spec-review.md`).

## 4. Direct download of the Mac app (optional)

```bash
Scripts/archive.sh macOS --no-export
# export with a Developer ID method in Xcode's Organizer or an ExportOptions plist of your own, then:
xcrun notarytool submit "Silicon Audit.zip" --keychain-profile "notary" --wait
xcrun stapler staple "Silicon Audit.app"
```

## 5. Tag

```bash
git tag -a v0.2.0 -m "Silicon Audit 0.2.0" && git push origin v0.2.0
```

Pushing a `v*` tag runs `release.yml`, which builds the release CLI as a universal binary, signs it ad hoc,
and attaches `silicon-audit-<version>-macos.zip` with its SHA-256 to a GitHub Release. The CLI needs no
entitlements to audit; users who want the self-test to say yes re-sign it with `Scripts/sign-hardened.sh`.
Apps are not attached to GitHub Releases: they need Apple signing, which is App Store Connect's job.
