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
  wrong and has been corrected; every unverified entry in that map stays `reported`, not `verified`.

## Apple Watch — pending

The watch app is embedded in the iOS build. Steps: open Silicon Audit on the Watch, then tap
"Send to iPhone"; the phone stores the report in its Documents directory, from where it is
pulled the same way. Results will be appended here.

## Simulator (for the record, never a data source)

An iPhone 17 Pro simulator on the Mac17,7 host reported the host's chip (`hw.product` `Mac17,7`,
SoC `T6050`, `vm.mte.tagged` nonzero, 115 walked keys) under `platform: iOS` with
`is_simulator: true` — exactly the trap spec §14 describes.
