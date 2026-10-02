# SPTM and TXM on chips Apple's table leaves out

Date: 2026-10-01. Prompted by a report that iOS 27 brought the Secure Page Table Monitor and the
Trusted Execution Monitor to A13. Apple's guide still lists SPTM for A15 and later and M2 and later
only: the "Operating system integrity" page (published 2026-01-28) and the August 2026 PDF agree.

## Method

An IPSW's `BuildManifest.plist` lists the firmware images each board is personalized to boot. A
chip that boots SPTM and TXM has `Ap,SecurePageTableMonitor` and `Ap,TrustedExecutionMonitor`
entries in its erase-install identity. The upstream watcher (`Tools/upstream-watch`, SPEC §15)
reads the manifest of every new build, betas included, and opens a `gap/sptm` issue when a chip
boots SPTM where documented-matrix.json disagrees. `Tools/gen-data/sptm-firmware.py` is the manual
version, for bisecting a chip's first build. It reads only the zip directory and the manifest,
using HTTP range requests against Apple's IPSW URLs (as listed by ipsw.me):

    python3 Tools/gen-data/sptm-firmware.py iPhone12,1 iPhone13,2 iPad13,4 MacBookPro18,1
    python3 Tools/gen-data/sptm-firmware.py MacBookPro18,1 --version 26.3.1
    python3 Tools/gen-data/sptm-firmware.py --url <IPSW or full-OTA URL from AppleDB>

ipsw.me doesn't list current Apple Watch firmware. Watch restore images are on Apple's CDN, and
their URLs come from AppleDB (`https://api.appledb.dev/ios/watchOS;<build>.json`, which needs a
non-default User-Agent). AppleDB lists Watch7,1 restore images only for watchOS 10.0.1, 10.0.2 and
26.3 onward.

## What the manifests list

| chip (soc_id) | device read | without SPTM and TXM | with SPTM and TXM |
|---|---|---|---|
| A13 (T8030) | iPhone12,1 | iOS 26.6.2 (23G90) | iOS 27.0 (24A437), 27.0.1 (24A446) |
| A14 (T8101) | iPhone13,2 | iOS 26.6.2 (23G90) | iOS 27.0 (24A437), 27.0.1 (24A446) |
| M1 (T8103) | iPad13,4 | iPadOS 26.6.2 (23G90) | iPadOS 27.0 (24A437), 27.0.1 (24A446) |
| M1 (T8103) | Macmini9,1 | macOS 26.6.2 (25G83) | macOS 27.0.1 (26A434) |
| M1 Pro/Max/Ultra (T6000/1/2) | MacBookPro18,1 | macOS 13.6 through 26.3.1 (25D2128) | macOS 26.4 (25E246) onward |
| A15 (T8110), control | iPhone14,5 | none | iOS 26.6.2 and 27.0.1 |
| S9/S10 (T8310) | Watch7,1 | watchOS 10.0.1, 10.0.2 (21R371) | watchOS 26.3 (23S620) through 27.0.1 (24R365) |
| S6–S8 (T8301) | Watch6,x | every release checked, through watchOS 26.6 (23U67) | none |
| A12, A12Z | iPad11,6, iPad8,9, iPhone11,2 | every release they get | none: no iOS or iPadOS 27 IPSW |

## What the app does with it

Apple's table remains the documented source. Where the firmware contradicts it, from the version
above on, the `sptm` row and the `ppl` row (the guide says SPTM replaces PPL) read `unknown` with
the evidence in the note. For S9/S10 the start is bounded, not known: no restore image exists
between 10.0.2 and 26.3, so the exception starts at 10.1, the first version not shown to lack SPTM.
On those intermediate versions the claim reads unknown instead of repeating Apple's "not present".
A booted image shows that the monitor runs, not what it guarantees.
The guide says SPTM relies on silicon primitives only its listed chips have, so what it provides
on these chips is undocumented, and the app does not claim it. The exceptions live in
`SPTM_FIRMWARE` in `Tools/gen-data/generate.py`.

tvOS: current Apple TVs have no restore images. The full OTA for AppleTV11,1 (A12) on tvOS 27.0
(24J361) boots no SPTM. The OTAs for A15 Apple TVs are encrypted (`.aea`) and cannot be read this way.

## Also found: the PPL row was read one column off

The guide's table prints seven columns: "A12–A14" shares a column with "S4–S10", and "A19" with
"M5". Decoding the check and cross icons from the page source gives PPL ✓ for A11/S3, A12–A14/S4–S10
and M1 (footnote: no code-signing enforcement on macOS), and ✗ for A15–A18 (footnote: replaced by
SPTM), M2–M4 and A19/M5. The bundled data had marked PPL present for A15–A18 and absent for A11/S3
and M1. The other rows were correct. The fix doesn't change the PPL answer for the published S9 and
M5 results. Their exported files keep the documented claims as the app read them at export time; a
new S9 export on watchOS 26.3 or later reads SPTM and PPL unknown because of the exception above.
