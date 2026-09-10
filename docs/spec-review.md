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
- **True:** This kernel exposes 60+ `vm.mte.*` counters (`vm.mte.tagged`, `vm.mte.tag_storage.activations`, `vm.mte.cell.active`, …) and `kern.mte_tag_storage_inactive_target`. Nonzero values are measured evidence the kernel is tagging memory system-wide. Not proof of per-process protection or synchronous mode. Not registered in `bsd/vm/vm_unix.c` (osfmk side). iOS/watchOS readability unverified.
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

## Open items not resolvable from a Mac

1. Whether iOS/watchOS container sandboxes permit `sysctlbyname` on `hw.optional.arm.*`, the raw meta-OID walk, and `vm.mte.*` reads. **M0 spike.**
2. Whether `hw.product` is present on the oldest supported iOS. **Old-device test.**
3. Confirmation of the Required Reason API list at submission time. **§10.**
4. Whether the EMTE logical tag lands in pointer bits 59:56 on Apple's implementation as on reference Arm MTE. **Phase 2a spike.**
