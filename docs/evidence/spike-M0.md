# M0 feasibility spike — results

The spec's biggest open question was whether a sandboxed app on iOS and watchOS can read
`hw.optional.arm.*` at all, and whether the MIB walk works there. Answers below come from the
Phase 2 spike app (`Apps/Shared/Spike`), pulled off the devices with `devicectl`.

## iPhone 17 Pro Max — iPhone18,2, board V54AP, iOS 26.6.2 (23G90), kernel target T8150

Raw report: [spike-iPhone18,2-23G90.json](spike-iPhone18,2-23G90.json). Collected 2026-09-10.

| M0 question | Answer |
|---|---|
| `sysctlbyname` on `hw.optional.arm.*` | **Works.** Every FEAT_* key in the inventory read successfully. |
| `hw.optional.arm.caps` | Readable, **12 bytes**, hex `ffefffffd77ffebfdb030008` — byte-identical to the M5 Mac. |
| Raw `sysctl(2)` MIB walk (`CTL_SYSCTL_NEXT`) | **Refused: errno 1 (EPERM).** The walk cannot run in the iOS sandbox. |
| `CTL_SYSCTL_OIDFMT` (kernel-declared types) | **Refused.** No value carried a kernel format; all types came from the inventory. |
| `hw.product` | `iPhone18,2` (readable; `hw.model`/`hw.target` = `V54AP`). |
| `vm.mte.*` gauges and counters | **Restricted (EPERM)** — `vm.mte.tagged`, `vm.mte.cell.active`, `vm.mte.tag_storage.activations`. |
| Other restricted keys | `hw.engineering_sample`, `hw.features.allows_security_research`, `kern.hv_support`. |
| `kern.version` / `kern.osversion` / `kern.osproductversion` | Readable. `RELEASE_ARM64_T8150`, `23G90`, `26.6.2`. |
| `hw.cpufamily` | `0xab345f09` = `CPUFAMILY_ARM_THERA` (`<mach/machine.h>`). |

Memory-tagging keys as reported by the A19 Pro kernel (same profile as the M5):

| key | value |
|---|---|
| FEAT_MTE | 1 |
| FEAT_MTE2 | 1 |
| FEAT_MTE3 | 0 |
| FEAT_MTE4 | 1 |
| FEAT_MTE_ASYNC | 0 |
| FEAT_MTE_CANONICAL_TAGS | 1 |
| FEAT_MTE_STORE_ONLY | 1 |
| FEAT_MTE_NO_ADDRESS_TAGS | 1 |

Consequences for the design:
- The by-name inventory is the primary collection path on iOS, not a fallback. The walk is a
  macOS (and CLI) discovery tool. `collection.walk_succeeded` will be false on every iOS export.
- The inventory must carry declared formats; without OIDFMT nothing decodes otherwise. Values
  typed this way are marked `source: inventory` in the engine and `*` in the spike UI.
- OS-level memory-tagging activity (`vm.mte.*`) is **not observable from a sandboxed iOS app**;
  that row will read `restricted` on iOS and is only measurable from macOS.
- `T8150` is the A19 Pro (this device), so the seeded SoC map's "A18 Pro" guess for T8150 was
  wrong; `soc-map.json` now carries T8150 = A19 Pro, T8310 = S9 and T6050 (Mac17,7) as `verified`
entries, and every other seeded entry stays `reported`, not `verified`.

## Apple Watch Series 9 — Watch7,1, board N207sAP, watchOS 26.6 (23U67), kernel target T8310

Raw report: [spike-Watch7,1-23U67.json](spike-Watch7,1-23U67.json). Collected 2026-09-10, pulled
directly from the watch's app container over the CoreDevice tunnel.

| M0 question | Answer |
|---|---|
| `sysctlbyname` on `hw.optional.arm.*` | **Works**, exactly as on iOS. |
| `hw.optional.arm.caps` | Readable, **12 bytes**, hex `ffeffffb9f000e0c00020000`. |
| Raw `sysctl(2)` MIB walk (`CTL_SYSCTL_NEXT`) | **Refused: errno 1 (EPERM).** Same as iOS. |
| `CTL_SYSCTL_OIDFMT` | **Refused.** Types come from the inventory. |
| `hw.product` | `Watch7,1` (`hw.model`/`hw.target` = `N207sAP`). |
| `vm.mte.*` | **Absent (ENOENT)** — the watch kernel has no `vm.mte` namespace at all, unlike iOS where it exists but is restricted. The absent/restricted distinction earns its keep. |
| Restricted keys | `hw.engineering_sample`, `hw.features.allows_security_research`, `kern.hv_support`. |
| `kern.version` | `RELEASE_ARM64_T8310`. `T8310` is therefore the S9 (verified). |
| `hw.cpufamily` | `0x8765edea` = `CPUFAMILY_ARM_EVEREST_SAWTOOTH`: the S9's cores are A16-generation. |

Memory tagging on the S9: every `FEAT_MTE*` key reads **0** (known to the kernel, reported off), not
absent. That is the answer the project was built to give: the kernel knows the keys, the S9 does
not have the feature.

Capability bitmask decoded against `<arm/cpu_capabilities_public.h>`, S9 vs M5/A19 Pro:
- Popcount: **42** bits set on the S9, **67** on the M5/A19 Pro. Of those, 40 and 64 have names in
  the public header; the rest are set bits the header does not name: bits 39 and 59 on the S9,
  bits 38, 39 and 59 on the M5/A19 Pro. Bit 38 is therefore set only on the newer chips. These
  will be exported by the Phase 3 caps decoder as unnamed bits, so nobody has to redo this arithmetic.
- Named bits missing on the S9: all MTE bits, all SME/SVE bits, FEAT_CSSC, FEAT_EBF16, FEAT_HBC,
  FEAT_WFxT, FEAT_FPACCOMBINE.
- Security-relevant bits present on the S9: FEAT_PAuth, FEAT_PAuth2, FEAT_FPAC, FEAT_PACIMP,
  FEAT_BTI, FEAT_CSV2, FEAT_CSV3, FEAT_SB, FEAT_DIT, **FEAT_SSBS**.
- **FEAT_SSBS is set on the S9 and clear on both the M5 and the A19 Pro.** Whether that is a
  hardware difference or the newer kernels masking it is exactly the kind of question the
  measured/documented split is for; the app must report it, not explain it away.

## WatchConnectivity round trip — confirmed

With the watch app running, "Send to iPhone" queued the report with `WCSession.transferFile`. The
file arrived in the iPhone app's WatchConnectivity inbox within seconds (phone unlocked, Bluetooth
just re-enabled), and on the next launch the iOS receiver copied it to `Documents/spike-watchOS-Watch7,1-23U67.json`.
The delivered JSON is byte-identical to the report pulled directly from the watch's container.
`transferFile` is therefore the export path for the watch app (SPEC §7).

## Hardware access notes (for contributors)

Reaching the Watch from the Mac needed: Developer Mode on the Watch, the Watch unlocked and on
the same Wi-Fi as the Mac (the Watch drops Wi-Fi while Bluetooth-connected to the phone, so
turning the phone's Bluetooth off briefly helps), and the Mac firewall's "block all incoming
connections" off for the duration; the tunnel is `localNetwork` and negotiated through the
phone. Free-team profiles only include devices Xcode has connected to, so the watch app cannot
install until that first connection registers the Watch.

## Simulator (for the record, never a data source)

An iPhone 17 Pro simulator on the Mac17,7 host reported the host's chip (`hw.product` `Mac17,7`,
SoC `T6050`, `vm.mte.tagged` nonzero, 115 walked keys) under `platform: iOS` with
`is_simulator: true` — exactly the trap spec §14 describes.
