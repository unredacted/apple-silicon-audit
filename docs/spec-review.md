# Spec review: v0.1 → v0.2

**Reviewed:** 2026-09-10
**Method:** Every technical claim in the v0.1 spec was checked against a live machine and primary sources rather than from memory:

- **Host:** Mac17,7 (M5-class, cpufamily `0xf76c5b1a` = `CPUFAMILY_ARM_SOTRA`, cpusubfamily 5 = `HC_HD`), macOS 26.6.2 build 25G83, kernel `xnu-12377.161.14~5/RELEASE_ARM64_T6050`. Raw dump: [evidence/Mac17,7-25G83.txt](evidence/Mac17,7-25G83.txt).
- **Headers:** `MacOSX.sdk/usr/include/sys/sysctl.h`, `arm/cpu_capabilities_public.h`, `mach/machine.h`.
- **Sandbox profiles:** `/System/Library/Sandbox/Profiles/{application,system,appsandbox-common}.sb`.
- **XNU source (apple-oss-distributions/xnu, main):** `bsd/kern/kern_newsysctl.c`, `bsd/kern/kern_mib.c`, `osfmk/arm/arm_features.inc`, `bsd/vm/vm_unix.c`.
- **Apple docs:** Platform Security "Operating system integrity"; Security Research blog "Memory Integrity Enforcement"; Xcode "Enabling enhanced security for your app"; WatchConnectivity `transferUserInfo(_:)`.
- **Kernel binary strings:** `/System/Library/Kernels/kernel.release.t6050`.

Each finding below states what v0.1 said, what is actually true, the evidence, and the edit made in [SPEC.md](../SPEC.md).

---

## A. Factual corrections

### 1. MTE sysctl names were wrong
- **v0.1:** `FEAT_MTE`, `FEAT_MTE2`, `FEAT_MTE3`, `FEAT_MTE4`, `FEAT_MTE_ASYMM`.
- **True:** `FEAT_MTE_ASYMM` does not exist. XNU registers `FEAT_MTE`, `FEAT_MTE2`, `FEAT_MTE3`, `FEAT_MTE4`, `FEAT_MTE_ASYNC`, `FEAT_MTE_CANONICAL_TAGS`, `FEAT_MTE_STORE_ONLY`, `FEAT_MTE_NO_ADDRESS_TAGS`. This M5 Mac reports 1, 1, 0, 1, 0, 1, 1, 1.
- **Evidence:** `sysctl hw.optional | grep MTE`; `cpu_capabilities_public.h` CAP_BIT 60–63 and 69–72; kernel strings.
- **Edit:** §4.3 memory-tagging group rewritten with the real names and the observed EMTE profile.

### 2. `FEAT_EPAC` is not a sysctl
- **v0.1:** listed `FEAT_EPAC` under pointer authentication.
- **True:** PAC keys are `FEAT_PAuth`, `FEAT_PAuth2`, `FEAT_FPAC`, `FEAT_FPACCOMBINE`, `FEAT_PACIMP`.
- **Evidence:** `sysctl hw.optional`; `arm_features.inc`.
- **Edit:** §4.3 pointer-authentication group.

### 3. `hw.optional.arm.caps` is real, public, and 12 bytes long
- **v0.1:** "`hw.optional.arm.caps` if present"; `ProbeResult.supported(Int64)`.
- **True:** It exists, its bit layout is ABI-stable and published in `<arm/cpu_capabilities_public.h>` (`CAP_BIT_NB = 92`), and it returns **12 bytes** although OIDFMT reports `int64_t`. An `Int64` result type truncates it silently.
- **Evidence:** `sysctl -t hw.optional.arm.caps` → `int64_t`; `sysctl -l` → length 12; `sysctl -x` shows 8 bytes because the tool itself assumes the declared type.
- **Edit:** §4.1 result type now carries format, actual length, and raw bytes; §4.3 adds a `bitmask` kind and a cross-check requirement; §14 adds a caps-vs-FEAT consistency test.

### 4. `hw.machine` is `arm64` on macOS
- **v0.1:** device identity and `results/<hw_machine>/` keyed on `hw.machine`.
- **True:** On macOS `hw.machine` = `arm64`; the model is in `hw.product` (`Mac17,7`) and `hw.model`. `hw.product`/`hw.target`/`hw.targettype` are registered on all arm64 platforms.
- **Evidence:** `sysctl hw.machine hw.model hw.product hw.target`; `kern_mib.c`.
- **Edit:** `hw_product` is the identifier everywhere (§4.3, §8, §9), with `hw.machine` as fallback.

### 5. MIB-walk meta-OID details
- **v0.1:** listed `{0,5}` OIDDESCR as usable; said nothing about masked OIDs or privilege.
- **True:** OIDDESCR exists in XNU but returns empty strings. OIDFMT works from userland. The kernel's NEXT handler does not skip `CTLFLAG_MASKED` (0x04000000) OIDs; `sysctl(8)` hides them client-side. The meta handlers have no privilege checks; `name2oid` is `CTLFLAG_ANYBODY`. The constants are not in the public `sys/sysctl.h`.
- **Evidence:** `sysctl -d hw.ncpu` → blank; `kern_newsysctl.c`; `grep CTL_SYSCTL sysctl.h` → no matches.
- **Edit:** §4.2 table with status per meta-OID; masked keys annotated as deprecated; note that restriction shows up per key, not as a failed walk.

### 6. No per-perf-level ISA flags exist
- **v0.1:** "If a device ever reports non-uniform security features across perf levels, flag it prominently."
- **True:** `hw.perflevelN.*` contains only `physicalcpu*`, `logicalcpu*`, `l1icachesize`, `l1dcachesize`, `l2cachesize`, `cpusperl2`, `l3cachesize`, `cpusperl3`, `name`. There is no public API to pin a thread to a cluster. `name` is not a fixed vocabulary (`Super`, `Performance` here).
- **Evidence:** `sysctl hw.perflevel0 hw.perflevel1`; `kern_mib.c`.
- **Edit:** §4.3 heterogeneous-cores paragraph rewritten: context only, explicitly not observable.

### 7. macOS App Sandbox allows all sysctl reads
- **v0.1:** "verify this walk works from a sandboxed app on each platform."
- **True:** `application.sb` imports `system.sb`, which contains an unconditional `(allow sysctl-read)`. iOS/watchOS container profiles cannot be inspected from macOS.
- **Evidence:** `grep -n 'import\|sysctl' application.sb`; `system.sb` line 191.
- **Edit:** §4.2 sandbox status by platform; M0 spike (§13) drops macOS and focuses on iPhone + Watch hardware.

### 8. `kern.version` carries a measured SoC identifier
- **v0.1:** `soc_name_claimed` from an unspecified lookup.
- **True:** `kern.version` ends in the kernel build target, e.g. `RELEASE_ARM64_T6050`. That T-number is the SoC as the kernel knows it. Kernels shipped on this Mac: t6000, t6020, t6030, t6031, t6041, t6050, t8103, t8112, t8122, t8132, t8140, t8142, vmapple.
- **Evidence:** `sysctl kern.version`; `ls /System/Library/Kernels`.
- **Edit:** `soc_id` (measured) added to §4.3 and §8; marketing name becomes `_inferred` via `soc-map.json`.

### 9. OS-level MTE activity *is* partially observable
- **v0.1 §4.4:** "Memory Integrity Enforcement as a whole" cannot be probed; nothing about OS state.
- **True:** This kernel exposes 60+ `vm.mte.*` counters (`vm.mte.tagged`, `vm.mte.tag_storage.activations`, `vm.mte.cell.active`, …). Nonzero values are measured evidence the kernel is tagging memory system-wide. Not proof of per-process protection or synchronous mode. Not registered in `bsd/vm/vm_unix.c` (osfmk side). iOS/watchOS readability unverified.
- **Evidence:** `sysctl -a | grep -E '^(vm\.mte\.|kern\.mte_)'`; kernel strings (`MTE_MASK_*`, `mte_ts_*`).
- **Edit:** §4.4 split into "partially probeable" and "not probeable"; new measured fact with strict copy; added to M0 checklist.

### 10. Documented-matrix sources verified with dates
- **v0.1:** named the sources without dates or column structure.
- **True:** OS-integrity page published 2026-01-28; columns A10 | A11,S3 | A12–A14 | S4–S10 | A15–A18 | M1 | M2–M4 | A19 | M5; rows KIP, Fast Permission Restrictions, SCIP, PAC, PPL, SPTM, MIE(EMTE). MIE blog published 2025-09-09; MIE = kalloc_type/xzone/libpas + EMTE synchronous + TCE; A19/A19 Pro.
- **Edit:** §5 lists sources, dates, columns, and the two-step `soc_id` → family → claim inference.

### 11. Enhanced Security entitlement names are public
- **v0.1 §11:** "opt the app into Apple's Enhanced Security / EMTE build setting."
- **True:** `com.apple.security.hardened-process`, `.enhanced-security-version-string`, `.checked-allocations` (memory tagging, A19+/M5+), `.checked-allocations.soft-mode`, `.checked-allocations.no-tagged-receive`, `.hardened-heap`, `.dyld-ro`, `.platform-restrictions-string`, `.no-guard-objects`. Kernel also recognizes `com.apple.developer.hardened-process*` variants.
- **Evidence:** Apple Xcode docs JSON; kernel strings.
- **Edit:** §11 names the entitlements and soft mode.

### 12. Privacy denylist made concrete
- **v0.1:** general "no identifiers."
- **True:** `kern.hostname`, `kern.bootsessionuuid`, `kern.boottime`, `kern.uuid` exist and are walk-reachable if the walk root is too broad.
- **Edit:** §4.3 and §10: walk root is `hw.optional` only; `kern.*`/`vm.*` read by fixed name list; explicit never-read list; JSON Schema with `additionalProperties: false` is the CI allowlist.

### 13. Required Reason APIs
- **v0.1:** "audit whether any API used falls under Required Reason."
- **Status:** Apple's list page is JavaScript-rendered and could not be fetched in this review. From knowledge, the categories are file timestamps, system boot time (`systemUptime`, `mach_absolute_time`), disk space, active keyboards, user defaults; `sysctl` is not listed. Treat as unconfirmed.
- **Edit:** §10: never read `kern.boottime`; recheck at submission; empty accessed-API array unless the recheck says otherwise.

### 14. Legacy pre-`FEAT_` keys still exist
- **True:** `hw.optional.arm64`, `armv8_1_atomics`, `armv8_2_fhm`, `armv8_2_sha3`, `armv8_2_sha512`, `armv8_3_compnum`, `armv8_crc32`, `armv8_gpi`. Old kernels expose only these.
- **Edit:** §4.3 legacy-alias group; §14 old-device test expects them.

### 15. `hw.cpufamily` is signed on the wire; constants are public
- **True:** `sysctl hw.cpufamily` → `-143893734`; `-x` → `0xf76c5b1a` = `CPUFAMILY_ARM_SOTRA`. `mach/machine.h` lists CYCLONE … TILOS and `CPUSUBFAMILY_ARM_HP/HG/M/HS/HC_HD/HA`. cpufamily identifies the core, not the SoC (A15 and M2 share `BLIZZARD_AVALANCHE`).
- **Edit:** §4.3: unsigned-hex display, table seeded from the header, cannot be used for SoC family mapping.

### 16. Extra context keys worth exporting
- `hw.features.allows_security_research` (Security Research Device), `hw.engineering_sample`, `sysctl.proc_translated`, `kern.osreleasetype`.
- **Edit:** §4.3 context list.

### 17. Repo conflicts
- LICENSE was GPL-3.0; spec says Apache-2.0. **Resolved by the user: Apache-2.0.** LICENSE replaced with the canonical text.
- Repo name contains "Apple"; fine for a repo, not for the shipped app name. Noted in the header of SPEC.md.

---

## B. Design gaps closed

### 18. Result type
"Tri-state" enum had five cases and could not carry strings or bytes. Now `ProbeOutcome` + `SysctlValue` with format, actual length, and int/string/bytes payload. Inventory `kind` (`flag | count | bitmask | string`) decides whether a value maps to present/not-present. (§4.1)

### 19. Collection mode
Walk-with-fallback replaced by walk ∪ known-list, always. Export records `walk_succeeded` and per-fact `discovered_by`. (§4.2, §8)

### 20. Environment detection
"Zero platform conditionals" is impossible for simulator / iOS-on-Mac / Catalyst / Rosetta / Intel detection. Conditionals confined to one `Environment` type; export gains `arch`, `os_build`, `is_translated`, `is_ios_app_on_mac`, `is_catalyst`, `soc_id`. (§6.1, §6.2, §8)

### 21. Intel Macs and Rosetta
Previously unaddressed. Intel: supported, x86 keys unannotated, no ARM claims, matrix grouped by arch. Rosetta: flagged and CI-rejected. (§6.2, §9, §14)

### 22. Device → SoC-family mapping
Documented claims need a mapping the spec never defined. New `soc-map.json` keyed on measured `soc_id`; UI shows the two-step chain. (§5, §12)

### 23. Resource bundling
Top-level `Data/` is not bundled by SwiftPM. Moved under `Sources/SiliconAuditCore/Resources/`; `Schema/export-v1.schema.json` added. (§12)

### 24. Project structure
Five Xcode projects → one project with a multiplatform target plus a watchOS target. Bundle IDs under `org.unredacted.siliconaudit` (user decision). (§6.1, §12)

### 25. watchOS and tvOS export paths
`transferUserInfo` has an undocumented size ceiling (Apple's doc page confirms queued background delivery but says nothing about limits; the field-observed ceiling is in the tens of kilobytes). Switched to `transferFile` + gzip. `ShareLink` on watchOS 9+ for standalone. tvOS (no share sheet, no WCSession): QR of a new `compact` export variant. (§7, §8)

### 26. Conflict key
`(hw_product, os_build)` instead of marketing `os_version`; different builds are shown side by side, not as conflicts. (§9)

### 27. Phase 2 restructured
2a: tagged-pointer observation (read bits 59:56 of malloc'd pointers under `checked-allocations`; no fault possible) gives a measured per-process tagging fact. 2b: the deliberate-fault test, with soft mode for development. Recommend adopting Enhanced Security in Phase 1 after stability testing. (§11)

### 28. Copy discipline
"Measured" = "reported by this kernel," not silicon truth; kernel can mask features. UI verbs constrained. (§3, §6.4, §14)

### 29. Schema tightening
Single `state` enum `present | not_present | key_absent | restricted | error | unknown`; `raw` carries `format`, `length`, `value`/`value_hex`; `unrecognized_keys` scoped to the walk root. (§8)

### 30. M0 spike checklist
Ordered, concrete, iPhone + Watch hardware: `sysctlbyname`, raw meta-OID walk, `caps` length, `hw.product`, `vm.mte.*` readability, `transferFile` round trip. (§13)

### 31. Identifiers
`org.unredacted.siliconaudit` root with `.watchkitapp`, `.cli`, `.tests` suffixes and `group.org.unredacted.siliconaudit`. (§6.1)

### 32. Design principles (new §6.4)
v0.1 had no UI/UX guidance beyond the watch layout. Added: HIG-native navigation per platform and the OS 26 design language; system typography and semantic color; provenance and state never by color alone; summary-first layout; VoiceOver, Dynamic Type, Reduce Motion; string catalogs; one primary export action per platform; persistent system-styled warnings; copy discipline.

### 33. SDK independence (new §6.3)
User question answered in the spec: a 26.6-built app runs on OS 27 and new hardware; the walk finds new keys at runtime; names and constants ship as data updates. Xcode 27 is needed only for new SDK APIs and wired debugging on OS 27 devices.

### 34. Milestones
M1 now includes `Environment`; M5 CI rejects all three environment flags; M0 has a checklist and drops macOS. (§13)

---

## C. Found during Phase 1 implementation

### 35. `ENOTSUP` is a distinct outcome, and `sysctl -a` hides it
The first live MIB walk returned 115 leaves under `hw.optional` where `sysctl hw.optional` prints 86. The 29 extra keys are the legacy x86 table (`hw.optional.sse4_2`, `avx512f`, `x86_64`, …), registered on the arm64 kernel but answering errno 45 (`ENOTSUP`); sysctl(8) drops any key whose read fails. v0.2 mapped this to `error`. **Edit:** new `notApplicable` outcome and `not_applicable` export state (§4.1, §8, schema). The reviewed evidence dump is therefore the sysctl(8) view, not the full subtree; the CLI's `raw --all` is.

### 36. `kern.mte_tag_storage_inactive_target` is not a sysctl
It is present in kernel strings but `sysctlbyname` returns `ENOENT` on macOS 26.6.2; it is a boot tunable. **Edit:** removed from §4.3, §4.4, and the M0 checklist. The `vm.mte.*` counters remain and read fine unsandboxed (`vm.mte.tagged` = 313452 at the time of the run).

---

## D. From the v0.2 pull-request review (Codex, 2026-09-10)

37. **Neutral `value` state.** Non-flag kinds (`count`, `string`, `bitmask`, `unknown`) could only be `present`/`not_present`. Added `value`; `arm.caps` in the §8 example now uses it. (§4.1, §8)
38. **Meta-OID walk and the no-private-API rule.** Clarified that `sysctl(2)` is public and the node-0 ABI underlies the SDK's own `sysctlnametomib(3)`, while the undocumented selectors are exactly why the walk is the discovery layer and the by-name inventory is the guaranteed baseline. (§4.2)
39. **Evidence fixture truncated `caps`.** `sysctl -x` printed 8 of 12 bytes. Appended the full buffer with a bit-by-bit cross-check against the individual `FEAT_*` keys; every bit agrees. (evidence file)
40. **Intel identity.** `hw.machine` is `x86_64` on Intel and `hw.product` is absent; identity is now `hw_product` → `hw_model` → `hw_machine`, exported as `device.identity` and used as the results key. (§4.3, §8, §9)
41. **Gauges vs cumulative MTE counters.** Only `vm.mte.tagged` and `vm.mte.cell.active` (gauges) may drive the "tagging now" verdict; `tag_storage.activations` and other since-boot counters are their own rows. (§4.4)
42. **Matrix-update wording.** "Must not require an app update" contradicted the no-networking v1. Now "must not require a code change." (§5)
43. **Virtual machines.** New `is_virtual_machine` flag from `kern.hv_vmm_present`, `VMAPPLE` kernel target, or `VirtualMac` model; CI rejects. GitHub's own macOS runners are `VMAPPLE` guests, which the project's CI proved by failing a live test that expected a `T`-series target. (§6.2, §8, §9, §14)
44. **Unrecognized keys carry provenance.** They are full measured facts (`kind: unknown`, `category: unrecognized`, `discovered_by: walk`) kept in their own top-level array. (§8)
45. **Legacy keys fully qualified.** They live under `hw.optional.`, not `hw.optional.arm.`; the inventory stores full names. (§4.3)
46. **App Group removed.** Companion and watch are on different devices; only `WCSession` moves state. (§6.1)
47. **Catalyst detection** uses `#if targetEnvironment(macCatalyst)` ahead of the iOS branch so Catalyst reports `platform: macOS`. (§6.2)

---

## E. From the M0 spike on hardware (Phase 2, 2026-09-10)

48. **iOS sandbox: by-name reads work, meta nodes do not.** `sysctlbyname` on every `hw.optional.arm.*` key succeeds on iPhone18,2 / 26.6.2; `CTL_SYSCTL_NEXT` returns `EPERM` and `CTL_SYSCTL_OIDFMT` is refused. The by-name inventory is the primary path on iOS and the walk is a macOS discovery tool. (§4.2)
49. **Inventory must carry formats.** Without OIDFMT the decoder had nothing to type values with and left `hw.product` and every flag as bytes. Added declared formats to the inventory with a `format_source` marker. (§4.2, engine `KnownFormats`)
50. **`vm.mte.*` is restricted on iOS**, along with `kern.hv_support`, `hw.engineering_sample`, `hw.features.allows_security_research`. OS-level tagging activity is measurable from macOS only. (§4.4)
51. **A19 Pro and M5 report the same EMTE profile and a byte-identical `caps`.** MTE, MTE2, MTE4, canonical tags, store-only, no-address-tags set; MTE3 and async clear. (evidence)
53. **watchOS behaves like iOS** for sysctl access (by-name yes, walk and OIDFMT no). `vm.mte.*` is *absent* on the S9 kernel, where iOS reports *restricted*; the schema's distinction is load-bearing. (§4.2, §4.4)
54. **S9 facts:** `T8310`, `hw.cpufamily` `0x8765edea` = `CPUFAMILY_ARM_EVEREST_SAWTOOTH` (A16-class cores), every `FEAT_MTE*` = 0, 40 capability bits vs 64 on the M5. **FEAT_SSBS is set on the S9 but clear on the M5 and A19 Pro**, an unexplained difference the app must surface as measured. (evidence)
52. **`T8150` is the A19 Pro**, not A18 Pro as seeded; `hw.cpufamily` `0xab345f09` is `CPUFAMILY_ARM_THERA`. (SoC map confidence levels earn their keep.)

---

## F. From Phase 3 implementation (core engine, data, CLI)

55. **Every inventory key is read by name on every run** (141 keys), so the five-way outcome exists for all of them even when the walk is refused; the walk only adds discoveries. (§4.2)
56. **`known-keys.json` carries `format`** (I/Q/A) per key; unknown `hw.optional` leaves default to `I`. Values typed this way are exported with `raw.format_source: inventory`; `collection.kernel_formats_available` says which case a whole export is in. (§4.2, §8)
57. **`raw.format` and `raw.errno` are always emitted**, null when not applicable. Swift's Codable drops nil keys by default, which the first exports did, and the schema caught it. (§8)
58. **Compact variant scope narrowed** to security-relevant measured facts plus identity/context and legacy aliases, because all 141 measured facts encode to ~4.5K Base45 characters and a QR code holds 3391 at error-correction M. Measured: ~2.9K for the M5 Mac. (§8)
59. **`capabilities` export field** with popcount, named and unnamed bits, and mismatches; `caps.consistency` inferred fact. On the M5 Mac all 64 named bits agree with their keys. (§8)
60. **Data files are generated** by `Tools/gen-data/generate.py` from the SDK headers plus a curated annotation table, so `caps-bits.json` and `cpufamily-names.json` cannot drift from `<arm/cpu_capabilities_public.h>` and `<mach/machine.h>`. `soc-map.json` stays hand-curated. (§12)
61. **A Rosetta process sees both ISA tables.** Under `arch -x86_64`, `hw.optional.x86_64`-family keys read present *and* the arm `FEAT_*` keys still read present, with `is_translated: true`. Such an export is misleading in both directions and CI must reject it, as §9 already requires. (§14)
62. **Text dumps are fixtures.** `TextDumpSysctl` parses `sysctl(8)` output (first occurrence of a key wins, so appended diagnostic sections do not clobber values) and backs both the tests and `silicon-audit --fixture`. (§14)

---

## Open items not resolvable from a Mac

1. ~~Whether iOS and watchOS container sandboxes permit `sysctlbyname` on `hw.optional.arm.*`, the raw meta-OID walk, and `vm.mte.*` reads.~~ Answered on both: yes / no / no (iOS: `vm.mte` restricted; watchOS: absent). See `docs/evidence/spike-M0.md`.
2. Whether `hw.product` is present on the oldest supported iOS. **Old-device test.**
3. Confirmation of the Required Reason API list at submission time. **§10.**
4. Whether the EMTE logical tag lands in pointer bits 59:56 on Apple's implementation as on reference Arm MTE. **Phase 2a spike.**
