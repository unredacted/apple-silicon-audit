# Releasing Silicon Audit

Everything here runs from the Mac. TestFlight distribution does not require tester device IDs.
The script uses manual Apple Distribution signing for mobile App Store archives, with the
one-time profile setup below. Development builds keep automatic development signing.

## 1. Version

```bash
Scripts/bump-version.sh 0.2.0        # project.yml, SiliconAuditCore.version, generate-matrix, CHANGELOG
```

Write the release notes under the new heading in `CHANGELOG.md`. The export `schema_version` is
separate and changes only when `Schema/export-v1.schema.json` does (SPEC §8 has the policy).
For another beta of the same version, pass an explicit unused build number, for example
`Scripts/bump-version.sh 0.1.0 3`. Choose a number higher than the latest uploaded build;
the local project does not query App Store Connect, and export does not auto-increment it.

## 2. Verify

```bash
Scripts/test.sh                                        # package tests
Scripts/run-simulator.sh iOS; Scripts/run-simulator.sh tvOS; Scripts/run-simulator.sh visionOS
swift run silicon-audit export | Scripts/validate-export.sh /dev/stdin
```

CI does the same on every push (`ci.yml`), plus the results validation (`results.yml`).

## 3. Archive and upload (TestFlight / App Store)

### One-time signing setup

Set `DEVELOPMENT_TEAM` in `Configs/Signing.xcconfig`, sign in to your team in Xcode, and install
an Apple Distribution certificate with its private key. In Apple Developer's
[Profiles](https://developer.apple.com/account/resources/profiles/list), create and download
these **manually managed** profiles using that certificate. Enable **Enhanced Security** on the
main app's identifier before generating its profiles:

| Profile name | Distribution type | App ID |
| --- | --- | --- |
| Silicon Audit App Store | App Store Connect (iOS/iPadOS/watchOS/visionOS) | `org.unredacted.silicon-audit` |
| Silicon Audit Watch App Store | App Store Connect (iOS/iPadOS/watchOS/visionOS) | `org.unredacted.silicon-audit.watchkitapp` |
| Silicon Audit tvOS App Store | tvOS App Store Connect | `org.unredacted.silicon-audit` |

The script's `-allowProvisioningUpdates` downloads the profiles when your team is signed in to
Xcode; alternatively, open the downloaded profiles to install them. iOS embeds the Watch app and needs both
profiles. visionOS uses the same main-app profile. macOS retains automatic signing and does not
need these mobile profiles. Xcode-generated "Team Store Provisioning Profile" profiles cannot
be selected for manual archive signing; create the profiles above in the developer portal.
To use existing manually managed profiles with other names, set `SILICON_AUDIT_APP_PROFILE`
and (for iOS) `SILICON_AUDIT_WATCH_PROFILE` in the shell environment when running the script.

### Build

```bash
Scripts/archive.sh iOS         # also embeds the watch app
Scripts/archive.sh macOS
Scripts/archive.sh tvOS
Scripts/archive.sh visionOS
```

The iOS, macOS, and visionOS commands default to `ReleaseHardened`; tvOS defaults to `Release`
because Apple's Enhanced Security capability does not support tvOS. Each exports with
`Configs/ExportOptions-appstore.plist` (automatic re-signing at export, upload to App Store Connect).
Archive signing uses the profiles above for iOS, tvOS, and visionOS; it never requests development
profiles for those App Store builds. The script checks the actual archive signature for all three
Enhanced Security entitlements and stops before export if Xcode omitted any of them.
The supported platforms' Enhanced Security entitlements are enabled without an extra flag. The ordinary
`SiliconAudit` scheme's Archive action also defaults to `ReleaseHardened` in Xcode.
`--hardened` remains accepted on supported platforms and is rejected explicitly for tvOS;
`--standard` selects an ordinary `Release`
archive for comparison. Hardened output paths end in `-hardened`, for example
`build/archives/iOS-hardened.xcarchive`. This selects the existing hardened configuration;
the Watch target's separate entitlement settings are unchanged. tvOS output uses
`build/archives/tvOS.xcarchive` and reports Enhanced Security as disabled, including when a
Hardened scheme is selected directly in Xcode.
`--development` uses automatic development signing and exports an installable build for registered
devices instead; `--no-export` stops at the `.xcarchive`. Use `--local-export` to create the signed
App Store package locally without uploading, for example `Scripts/archive.sh iOS --local-export`.
It cannot be combined with `--no-export`.

After a failed upload, retry the existing archive without rebuilding:

```bash
Scripts/archive.sh iOS --export-only
Scripts/archive.sh macOS --export-only
Scripts/archive.sh visionOS --export-only
```

`--export-only` retains the archived version and build number, checks hardened entitlements again,
and can be combined with `--local-export` to package locally. Use `--standard` as well when
retrying a standard archive. To change the build number or code, create a new archive instead.

### Signing and upload failures

- **"Failed to Use Accounts" / "App Store Connect access ... is required":** archive signing
  succeeded, but Xcode cannot find a usable App Store Connect account for the team. Browser login
  is separate from Xcode's account session. In **Xcode → Settings → Accounts**, sign in again to
  the account belonging to the intended team; if necessary, remove and re-add that account.
  Confirm that the same account can access the app under the correct organization in
  [App Store Connect](https://appstoreconnect.apple.com/). Uploads require Account Holder, Admin,
  App Manager, or Developer access. Then retry with `--export-only`; this error alone does not
  require a new build number or provisioning profiles.
- **"Bundle version must be higher than ... 2":** build 2 has already been uploaded. Bump to
  3 or a higher unused number, then create a new archive; re-exporting the old archive retains
  its old build number. Keep the same chosen build number across this release's platform builds.
- **"Your team has no devices" / "App Development provisioning profiles":** this is an
  archive-signing failure in the old automatic-development path (or with `--development`).
  Use the current script without `--development` after completing the profile setup above.
  Enabling hardening alone does not resolve this error.
- **Missing "Silicon Audit ... App Store" profile / Apple Distribution identity:** complete
  the one-time signing setup. The profile's team, bundle ID, platform, and certificate must match.
- **"is Xcode managed, but signing settings require a manually managed profile":** create a
  manual App Store profile in Apple Developer instead of selecting an Xcode-managed profile.
- **`exportArchive Copy failed` with an rsync extended-attributes error:** Xcode's bundled
  packaging flow conflicts with Homebrew rsync on PATH. The script now gives Xcode a system-only
  PATH after running XcodeGen.
- **"Refusing export ... missing hardened entitlement":** inspect the provisioning profile's
  Enhanced Security support. Do not bypass the check or upload a rejected archive whose Info.plist
  marker incorrectly claims Enhanced Security is enabled. tvOS is deliberately excluded from
  Enhanced Security: Apple's [platform guidance](https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app)
  lists iOS, iPadOS, macOS, and visionOS. Its missing entitlements are not a profile-generation bug.
- **TestFlight on iPhone says the app requires macOS:** check the **iOS** build's status and tester
  group, not just whether a Mac build is available. A processed iOS build marked **Missing Compliance**
  is not ready for testers. Complete its encryption questionnaire and verify the existing beta group
  has access. The apps implement no non-exempt encryption; the project declares
  `ITSAppUsesNonExemptEncryption = NO` for future builds, following
  [Apple's guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
  Revisit that declaration if encryption functionality or dependencies change.

Apple references: [App Store provisioning profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile),
[distribution signing](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

Paste `docs/app-store-notes.md` into App Store Connect's review notes and re-check its Required Reason
API list against Apple's current one (open item in `docs/spec-review.md`).

## 4. Screenshots

App Store Connect takes only exact pixel sizes, one set per platform:

| Platform | Accepted sizes |
| --- | --- |
| iPhone | 1320 × 2868 or 1290 × 2796 (6.9"), 1242 × 2688 (6.5") |
| iPad | 2064 × 2752 or 2048 × 2732 (13") |
| Mac | 1280 × 800, 1440 × 900, 2560 × 1600, 2880 × 1800 |
| Apple TV | 1920 × 1080 or 3840 × 2160 |
| Apple Vision Pro | 3840 × 2160 |

Everything with a simulator comes out at the right size on its own:

```bash
Scripts/screenshots.sh iOS; Scripts/screenshots.sh iPadOS
Scripts/screenshots.sh tvOS; Scripts/screenshots.sh visionOS; Scripts/screenshots.sh watchOS
```

The script boots a simulator, launches the app once per screen with `-initialSelection <route>`
(SPEC §6; the routes are in `Route.init(launchArgument:)`) and captures each with
`xcrun simctl io … screenshot` into `build/screenshots/<platform>/<device>/`. Pass a device-name
substring as a second argument to pick a different simulator; a substring that matches nothing is an
error rather than a fallback, because the wrong device means the wrong pixel size.

It builds the configuration that ships — `ReleaseHardened` where Apple's Enhanced Security applies,
`Release` for tvOS and watchOS — so the app's own self-test screen reports what the App Store build
reports. It also passes `-monitor.promptDismissed YES` on iPhone and iPad, because those two ask for
notification permission at first launch and the system alert would otherwise sit over every capture.

**iPhone captures only the Overview.** At compact width `AuditRootView` renders `compactLayout`,
which always shows the Overview and never reads `selection`, so `-initialSelection` has no effect
there and asking for six screens would write six identical files. Deeper iPhone screens are
navigated to by hand. Every other platform uses the split layout and honours the argument.

A simulator reports the host Mac's CPU, so the app shows its "Running in the Simulator" banner on
the Overview. Apple has accepted that banner in shipped screenshots, but the tvOS and visionOS sets
start at the Memory tagging screen instead, because those two have no hardware to capture and the
banner would otherwise lead their product pages. Change `ROUTES` in the script to include the
Overview again.

### The Mac

There is no macOS simulator, and capturing this Mac's screen is out of scope for tooling here, so
the Mac set is captured by hand and composed afterwards:

```bash
Scripts/screenshots-macos.sh                       # builds, then opens each screen in turn
swift Scripts/compose-macos-screenshots.swift      # raw/ -> store/, exactly 2880 × 1800
```

Capture each window with **Cmd-Shift-4, then Space, then click the window** — the system screenshot
UI, which needs no screen-recording permission — and save into `build/screenshots/macOS/raw`. Those
captures include the window's drop shadow, so they are never one of the sizes above
(a 1440 × 900 window lands around 2798 × 1836) and App Store Connect rejects them with "the
dimensions of one or more screenshots are wrong". The compose step is what fixes that: it centres
each capture on a 2880 × 1800 canvas, keeping the aspect ratio and never upscaling. **Upload from
`build/screenshots/macOS/store`, not from `raw`.** Size the window near 16:10 on the first screen so
it fills the canvas; macOS restores the frame for the rest.

## 5. Direct download of the Mac app (optional)

```bash
Scripts/archive.sh macOS --no-export
# export with a Developer ID method in Xcode's Organizer or an ExportOptions plist of your own, then:
xcrun notarytool submit "Silicon Audit.zip" --keychain-profile "notary" --wait
xcrun stapler staple "Silicon Audit.app"
```

## 6. Tag

```bash
git tag -a v0.2.0 -m "Silicon Audit 0.2.0" && git push origin v0.2.0
```

Tags with a pre-release suffix (`v0.3.0-beta.1`) are published as GitHub **pre-releases**; plain tags
are releases. 0.2.0 is the first version submitted to the App Store, so the major version no longer
decides. Pushing a `v*` tag runs `release.yml`, which builds the release CLI as a universal binary, signs it ad hoc,
checks that the binary reports the tag's version, and attaches `silicon-audit-<version>-macos.zip` (the binary plus its `SiliconAudit_SiliconAuditCore.bundle` of data files, which must stay beside it) with its SHA-256 to a GitHub Release. The CLI needs no
entitlements to audit; users who want the self-test to say yes re-sign it with `Scripts/sign-hardened.sh`.
Apps are not attached to GitHub Releases: they need Apple signing, which is App Store Connect's job.
