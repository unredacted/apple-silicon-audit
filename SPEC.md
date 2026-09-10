# Silicon Audit — Implementation Spec

**Working name:** Silicon Audit (the shipped app name must not contain "Apple"; the repo name is fine)
**Bundle identifier root:** `org.unredacted.siliconaudit`
**Purpose:** An open-source app that reports which CPU-level security features the kernel actually exposes on the exact Apple device it runs on, across every Apple platform.
**Status:** Spec v0.2, reviewed against a live M5-class Mac, the public SDK headers, the macOS sandbox profiles, and XNU source. See [docs/spec-review.md](docs/spec-review.md) for every change from v0.1 and its evidence. Implementation in progress; see open PRs.
**Audience:** The implementing engineer or agent. Assumes Swift, Xcode 26.6+, and basic Darwin/POSIX familiarity.

---

## 1. Motivation

Apple documents platform security features at the level of chip families — "available on A19 and M5 processors or later." That documentation lags hardware releases by months, groups chips coarsely (the Platform Security guide's runtime-protection table has one column for S4 through S10 and one for A12–A14), and never covers the S-series and other derived silicon with any precision.

The concrete question that motivated this project: when Apple ships a new wearable or embedded SoC described only as "derived" from a phone chip, which security primitives came along with it? Apple's marketing doesn't say. The security guide doesn't say for months. But the answer is sitting in `sysctl` on every shipped device, and nobody has built a convenient, trustworthy, cross-platform way to read it.

The app should let anyone answer, in under a minute, on any Apple device they own: **which of these features does this specific chip expose, and which does it not?**

The secondary payoff is a crowdsourced public matrix of results, so the answer for a given chip gets recorded once and stays answered.

---

## 2. Non-goals

Be strict about these. They shape the whole design.

- **Not a jailbreak, exploit, or bypass tool.** No attempt to defeat, disable, or probe around any security feature.
- **No private APIs.** Everything must be shippable through App Store review and buildable by anyone from source. If a data point requires a private API, it does not go in the app.
- **Not a benchmark.** No performance measurement. Feature presence only.
- **Not a fingerprinting service.** No automatic upload, no telemetry, no device identifiers beyond what's needed to interpret a result.
- **Does not claim to measure things it infers.** See §3, which is the most important section in this document.

---

## 3. The core design principle: measured vs. documented

This is the thing that makes the app trustworthy or worthless. Get it right.

Some facts are **measured** — the app read a value from the running kernel and is reporting it. Some facts are **documented** — Apple published them, and the app is displaying a stored claim about this chip family. Some are **inferred** — derived by reasoning from the other two.

These must never be visually or structurally conflated. Every displayed fact carries a provenance tag:

| Provenance | Meaning | UI treatment |
|---|---|---|
| `measured` | Read from this device's kernel at runtime | Primary emphasis, shows the raw source (the sysctl key, type, length, and returned value) |
| `documented` | From Apple's published materials for this chip family | Clearly secondary, must show source citation and a "last verified" date |
| `inferred` | Derived by the app's reasoning | Clearly tertiary, must show the reasoning chain in one sentence |
| `unknown` | Not determinable by any of the above | Shown as unknown, never omitted or silently defaulted |

Two precision points on the word *measured*:

1. **Measured means "reported by this kernel," not "present in the silicon."** XNU populates `hw.optional.arm.*` from the ID registers, but the kernel can and does mask features it has not enabled. The UI copy is "this kernel reports FEAT_MTE4," never "this chip has MTE4." When a feature is reported absent on hardware that Apple documents as having it, that discrepancy is a finding, not an error.
2. **Capability is not enablement.** The presence of `hw.optional.arm.FEAT_MTE4` is measurable. Whether Memory Integrity Enforcement is *enabled* is not measurable from that key alone — MIE is EMTE in synchronous mode plus secure typed allocators plus Tag Confidentiality Enforcement policies in the OS. An app that shows a green checkmark next to "Memory Integrity Enforcement" because a hardware flag is set is actively misleading its users. The correct display is a measured hardware row, a separate measured row for OS-level tag-storage activity (§4.4), and a separate, clearly-labeled documented statement about MIE as a whole.

**Requirement:** The export format (§8) carries provenance per fact. Any UI that drops provenance is a bug.

---

## 4. Probe engine

### 4.1 Primitive: five-way sysctl read

`sysctlbyname` has several distinct outcomes that must be distinguished. Collapsing them is the most common mistake in existing system-info apps.

```swift
enum ProbeOutcome: Equatable {
    case value(SysctlValue)   // returned 0; see SysctlValue for interpretation
    case absent               // returned -1, errno == ENOENT: kernel does not know this key
    case restricted           // returned -1, errno == EPERM or EACCES: sandbox or kernel denied
    case notApplicable        // returned -1, errno == ENOTSUP: registered for another architecture
    case error(Int32)         // returned -1, some other errno
}

struct SysctlValue: Equatable {
    let format: Format        // from CTL_SYSCTL_OIDFMT: .int, .quad, .string, .opaque, .node
    let length: Int           // actual byte count returned
    let payload: Payload      // .int(Int64) | .string(String) | .bytes([UInt8])
}
```

For `hw.optional.*` integer keys the display state is derived from the value: nonzero → `present`, zero → `not_present`. `absent` and `not_present` mean genuinely different things. Absent means this kernel doesn't know the key at all — typically an older OS or a platform where the concept doesn't apply. Not present means the kernel knows the key and reports it off. On a question like "did EMTE make it into this chip," the distinction is the whole answer.

**Not every integer key is a flag.** `hw.optional.breakpoint` (6), `hw.optional.watchpoint` (4), and `hw.optional.arm.sme_max_svl_b` (64) are counts. The inventory (§4.3) marks each key's `kind` as `flag`, `count`, `bitmask`, `string`, or `unknown` (walk discoveries); only `flag` keys get a present/not-present state. Every other kind that reads successfully gets the neutral state `value`, with the reading in `raw`. A zero-valued count or an empty string is a `value`, never `not_present`.

**`ENOTSUP` is its own state.** On an arm64 kernel the walk finds 29 legacy x86 keys (`hw.optional.sse4_2`, `hw.optional.avx512f`, `hw.optional.x86_64`, …) that are registered but answer `ENOTSUP` when read; `sysctl -a` silently drops them, which is why they never appear in a plain listing. Export them as `not_applicable`, never as `error`: they say the kernel carries the other architecture's key table and nothing about this chip. Expect the mirror image on Intel Macs.

**Handle variable width, and do not trust the declared format alone.** Query with a zero-length buffer first to get the size, then allocate, then record the actual returned length. The live example: `hw.optional.arm.caps` reports format `int64_t` via OIDFMT but returns **12 bytes** (`CAP_BIT_NB` = 92 bits, rounded up to bytes). A 4- or 8-byte assumption silently truncates it. Store raw bytes and decode after.

### 4.2 Enumeration plus known list, always both

A fixed list of known keys goes stale the moment Apple ships a new architectural extension — which is precisely the situation this app exists to handle. The engine must therefore **walk the sysctl MIB tree** and discover every key under `hw.optional` dynamically, then annotate the ones it recognizes.

Darwin inherits the BSD MIB-walking interface via the raw `sysctl(2)` call. The meta nodes under root OID `0` are not exposed as named constants in the public SDK header, so hardcode them with a comment:

| OID | Meaning | Status on XNU |
|---|---|---|
| `{0, 1}` | CTL_SYSCTL_NAME: OID → name | Works |
| `{0, 2}` | CTL_SYSCTL_NEXT: iterate to next OID | Works; this is how `sysctl -a` walks |
| `{0, 3}` | CTL_SYSCTL_NAME2OID: name → OID | Works (flagged `CTLFLAG_ANYBODY`) |
| `{0, 4}` | CTL_SYSCTL_OIDFMT: type/format + flags | Works; source of `format` above |
| `{0, 5}` | CTL_SYSCTL_OIDDESCR: description | Exists but returns empty strings. Do not depend on it. |

Walk with NEXT from `hw.optional`, resolve each OID to a name and format, read the values.

**Public-API status.** `sysctl(2)` is a public, documented syscall, and the node-0 meta operations are the BSD sysctl ABI that the public SDK's own `sysctlnametomib(3)` is implemented on. Nothing here links a private framework or symbol, so this is not private API in the App Review sense (§2). The selector numbers are nonetheless undocumented by Apple, which is why the walk is the *discovery* layer and never the only path: the known-key inventory read by `sysctlbyname` is the guaranteed baseline, an export with `walk_succeeded: false` is still valid and complete for every inventoried key, and the app must keep working unchanged if the meta nodes are ever restricted.

Notes from reading `bsd/kern/kern_newsysctl.c`:

- The kernel's NEXT handler does **not** skip OIDs flagged `CTLFLAG_MASKED` (0x04000000, "deprecated, do not display"); `sysctl(8)` hides them in userland. The walk will therefore see `*_compat` keys that the CLI tool never shows. Annotate them as deprecated; do not present them as discoveries.
- The meta handlers carry no privilege checks. Access control happens on the value read, so a sandbox that blocks reads will show up as `restricted` on individual keys, not as a failed walk.

**Run the walk and the known-key inventory (§4.3) every time, and take the union.** The export records `walk_succeeded` and, per fact, `discovered_by: walk | known_list | both`. A known key that the walk did not return is itself a signal (a masked or restricted node, or a broken walk) and must be recorded, not averaged away. A result where `walk_succeeded` is false is not evidence of absence for keys outside the inventory, and the consumer needs to know.

**Sandbox status by platform:**

- **macOS App Sandbox:** resolved. `application.sb` imports `system.sb`, which contains an unconditional `(allow sysctl-read)`. Confirm once in a sandboxed build; do not spend spike time here.
- **iOS (measured, M0 spike on iPhone18,2 / 26.6.2, see `docs/evidence/spike-M0.md`):** `sysctlbyname` works for every `hw.optional.arm.*` key and the identity/context keys; `CTL_SYSCTL_NEXT` returns `EPERM`, and `CTL_SYSCTL_OIDFMT` is refused. So on iOS the by-name inventory *is* the collection path and every export has `walk_succeeded: false`; the walk is a macOS/CLI discovery tool. `vm.mte.*`, `kern.hv_support`, `hw.engineering_sample`, and `hw.features.allows_security_research` read `restricted`.
- **watchOS (measured, M0 spike on Watch7,1 / 26.6):** identical to iOS: by-name reads work, `CTL_SYSCTL_NEXT` returns `EPERM`, OIDFMT is refused. `vm.mte.*` is `absent` (the watch kernel has no such namespace), not `restricted`.
- **tvOS, visionOS:** not yet measured; expect the iOS behavior.

**Consequence: the inventory carries declared formats.** When OIDFMT is refused, a value has no kernel-declared type and the decoder must not guess. The known-key inventory therefore records each key's format (`I`, `Q`, `A`, …) and the engine re-decodes the same bytes with it, marking the result `format_source: inventory` (kernel-declared types are `kernel`). Unknown `hw.optional` leaves default to `I`, because every leaf XNU registers there is a `SYSCTL_INT` except `caps`. The UI and export must show which source typed a value.

### 4.3 Known-key inventory

Ship a curated inventory that provides human-readable names, descriptions, `kind`, and security relevance for keys the app recognizes. Unrecognized keys discovered by the walk are still reported, just without annotation — this is the forward-compatibility path.

The authoritative list of `FEAT_*` names for a given kernel is XNU's `osfmk/arm/arm_features.inc` plus the MTE additions; the authoritative bit assignments for `hw.optional.arm.caps` are in the **public** header `<arm/cpu_capabilities_public.h>` (`CAP_BIT_*`, ABI-stable, `CAP_BIT_NB = 92` as of macOS 26.6). Generate the inventory skeleton from those two sources and hand-annotate on top.

Keys to annotate, grouped by what they tell you. Names below are the exact sysctl leaf names under `hw.optional.arm.` unless otherwise noted, verified on macOS 26.6.2:

**Memory tagging (the headline group)**
`FEAT_MTE`, `FEAT_MTE2`, `FEAT_MTE3`, `FEAT_MTE4`, `FEAT_MTE_ASYNC`, `FEAT_MTE_CANONICAL_TAGS`, `FEAT_MTE_STORE_ONLY`, `FEAT_MTE_NO_ADDRESS_TAGS`, and any `FEAT_MTE*` discovered by the walk. (An M5-class Mac on 26.6.2 reports 1, 1, 0, 1, 0, 1, 1, 1 in that order — MTE4 with canonical tags, store-only, and no-address-tags, without MTE3 or async mode. That profile is Apple's EMTE.)

**Pointer authentication**
`FEAT_PAuth`, `FEAT_PAuth2`, `FEAT_FPAC`, `FEAT_FPACCOMBINE`, `FEAT_PACIMP`.

**Capability bitmask**
`caps` (`kind: bitmask`, 12 bytes). Decode with `CAP_BIT_*` and cross-check against the individual `FEAT_*` keys; any disagreement is a bug or a finding and is exported as such.

**Control flow**
`FEAT_BTI`.

**Speculation and side channels**
`FEAT_CSV2`, `FEAT_CSV3`, `FEAT_SB`, `FEAT_SSBS`, `FEAT_SPECRES`, `FEAT_SPECRES2`.

**Constant-time execution**
`FEAT_DIT` (data-independent timing — relevant to whether crypto code can be written side-channel-resistant).

**Legacy aliases (pre-`FEAT_` naming, still registered)**
These live directly under `hw.optional.`, not under `hw.optional.arm.`: `hw.optional.arm64`, `hw.optional.armv8_1_atomics`, `hw.optional.armv8_2_fhm`, `hw.optional.armv8_2_sha3`, `hw.optional.armv8_2_sha512`, `hw.optional.armv8_3_compnum`, `hw.optional.armv8_crc32`, `hw.optional.armv8_gpi`. The inventory stores every key as its full sysctl name. Older kernels expose only these; the inventory maps each to its `FEAT_` successor so the old-device test (§14) produces comparable rows.

**Everything else under `hw.optional.arm`** (SIMD, SHA, SME, FP) is annotated as "ISA feature, not security-relevant" so the UI can fold it into a secondary section rather than dropping it.

**OS-level memory tagging state (measured, see §4.4)**
`vm.mte.tagged`, `vm.mte.tag_storage.activations`, `vm.mte.cell.active`. (`kern.mte_tag_storage_inactive_target` appears in kernel strings but is a boot tunable, not a sysctl.) Read these by name only; never walk `vm.*` or `kern.*`.

**Context**
`hw.product` (primary device identifier — see below), `hw.machine`, `hw.model`, `hw.target`, `hw.targettype`, `hw.cputype`, `hw.cpusubtype`, `hw.cpufamily`, `hw.cpusubfamily`, `hw.ncpu`, `hw.nperflevels` and the per-level `hw.perflevelN.*` keys, `hw.memsize`, `hw.pagesize`, `hw.features.allows_security_research` (Security Research Device indicator), `hw.engineering_sample`, `kern.osversion` (build, e.g. `25G83`), `kern.osproductversion`, `kern.osreleasetype`, `kern.version`, `kern.hv_support`, `sysctl.proc_translated` (Rosetta).

**Device identity: `hw.product`, then `hw.model`, then `hw.machine`.** On Apple silicon Macs `hw.machine` is the literal string `arm64`; the model lives in `hw.product` (`Mac17,7`) and `hw.model`. On Intel Macs `hw.product` is absent and `hw.machine` is `x86_64`, so `hw.model` (`MacBookPro16,1`) is the identity. On iOS `hw.machine` is `iPhone17,1` and `hw.model` is the board (`D93AP`); `hw.product` is registered on all arm64 platforms in `kern_mib.c`. The export carries all three plus a derived `device.identity` = first non-empty of `hw_product`, `hw_model` (Macs only), `hw_machine`; that field, with `os_build`, is the key for the results database (§9).

**SoC identity: parse `kern.version`.** The string ends in the kernel's build target, e.g. `RELEASE_ARM64_T6050`. That `T`-number is the SoC as the kernel knows it and is *measured*. Export it as `soc_id`; the marketing name (`Apple M5 Pro`) is then `inferred` from a data file, never claimed as measured. Seed the map from the kernels present on any recent Mac (`/System/Library/Kernels/kernel.release.t*`) and from community submissions.

**`hw.cpufamily` deserves special handling.** It identifies the core microarchitecture, not the SoC (A15 and M2 share `CPUFAMILY_ARM_BLIZZARD_AVALANCHE`). The constants are public in `<mach/machine.h>` (`CPUFAMILY_ARM_CYCLONE` … `CPUFAMILY_ARM_TILOS`, plus `CPUSUBFAMILY_ARM_HP/HG/M/HS/HC_HD/HA`). Ship them as a lookup table. The sysctl returns a signed 32-bit int (`-143893734`); always display as unsigned hex (`0xf76c5b1a`). When the value is unrecognized, show the raw hex and say so — an unrecognized cpufamily on a brand-new device is itself a newsworthy data point.

**Heterogeneous cores.** Report `hw.perflevelN.*` as context where `hw.nperflevels > 1`. Those keys contain only core counts, cache sizes, and a cluster `name` (which is not a fixed vocabulary: `Super` and `Performance` appear on M5-class Macs). **No per-cluster ISA feature flags exist in sysctl**, and there is no public API to pin a thread to a cluster to read ID registers directly. The UI states plainly that per-cluster differences are not observable from userland; ISA features are expected uniform because the scheduler migrates threads freely, but the app cannot verify that and must not claim to.

### 4.4 What can and cannot be probed

**Partially probeable — OS-level memory-tagging activity.** Kernels that manage MTE tag storage expose a `vm.mte.*` namespace (60+ counters on macOS 26.6). Two kinds of value live there and must not be mixed. **Gauges** describe the present moment: `vm.mte.tagged` (pages tagged now) and `vm.mte.cell.active` (tag-storage cells in use now). **Cumulative counters** count since boot: `vm.mte.tag_storage.activations` and most of the rest. Only a nonzero *gauge* is **measured** evidence that this kernel is tagging memory right now; a nonzero cumulative counter says only that it has done so at some point since boot, and is exported as its own `count` row, never folded into the activity verdict. `absent` on an older kernel is also informative, and `restricted` is the measured answer on iOS: the sandbox denies `vm.*` reads (M0 spike), so this row is only measurable from macOS. Strict limits on the copy: this proves the OS tag-storage machinery is on. It does not prove any particular process is protected, does not prove synchronous mode, and is not MIE. Display as its own measured row, "Kernel memory-tagging activity," with those caveats in the detail view. Sandbox readability on iOS and watchOS is unverified and is on the M0 checklist.

**Not probeable.** These appear in Apple's security documentation but are **not** exposed via any public interface. They must be surfaced as `documented`, never `measured`:

- Kernel Integrity Protection (KIP)
- System Coprocessor Integrity Protection (SCIP)
- Page Protection Layer (PPL)
- Secure Page Table Monitor (SPTM) and Trusted Execution Monitor (TXM)
- Fast Permission Restrictions
- Tag Confidentiality Enforcement
- Secure Enclave generation
- Secure Exclave presence
- Memory Integrity Enforcement as a whole

Do not invent probes for these. Do not guess. Show them as documented claims sourced from the security guide with a citation and a verification date, and where the guide's chip-family table doesn't cover the running chip, show `unknown`. "Apple hasn't said yet" is a legitimate and useful thing for the app to display.

---

## 5. Documented-matrix data

Ship the Apple-published chip-family matrix as **data, not code** — a versioned JSON file bundled as a SwiftPM resource (§12).

Schema per entry: feature ID, chip families it applies to, source URL, source publication date, date the maintainer last verified it.

**Primary sources, as verified 2026-09-10:**

- Platform Security guide, "Operating system integrity" (published 2026-01-28). Columns: A10 | A11, S3 | A12–A14 | S4–S10 | A15–A18 | M1 | M2–M4 | A19 | M5. Rows: Kernel Integrity Protection, Fast Permission Restrictions, System Coprocessor Integrity Protection, Pointer Authentication Codes, Page Protection Layer, Secure Page Table Monitor, Memory Integrity Enforcement (EMTE). S11 and later are not in the table — that is the motivating `unknown`.
- Apple Security Research, "Memory Integrity Enforcement" (published 2025-09-09). MIE = secure typed allocators (kalloc_type, xzone malloc, libpas) + EMTE in synchronous mode + Tag Confidentiality Enforcement; shipped on A19 and A19 Pro. Apple names three EMTE-over-MTE improvements: synchronous-only, protection of non-tagged memory access, and speculative-execution defenses.

**Mapping this device to a column** is a two-step inference and the UI must show both steps: measured `soc_id` → `soc-map.json` gives SoC family → the guide's column. cpufamily alone cannot do this. Where `soc_id` is not in the map, every documented row becomes `unknown` with the note "SoC not yet in the map."

Two requirements:

1. **Every documented claim shows its source and date in the UI.** Users should be able to tell that a claim is four months old.
2. **Updating the matrix must not require a code change.** It is data: a maintainer edits JSON, nothing in Swift moves. v1 ships without networking, so data updates reach users as app updates; bundle the data and display the bundled `verified` date prominently. An optional user-initiated signed refresh from the repo is a later decision, not a v1 requirement. Do not silently fetch — see privacy, §10.

---

## 6. Platform targets

| Platform | Priority | Notes |
|---|---|---|
| iOS / iPadOS | P0 | Reference implementation, easiest to test; hosts the watch companion |
| macOS | P0 | Also ships the CLI target; Intel and Rosetta handled (§6.2) |
| watchOS | P0 | The motivating case; hardest constraints |
| tvOS | P1 | No share sheet, no WatchConnectivity — QR export (§8) |
| visionOS | P1 | Standard share sheet |

### 6.1 Architecture

A Swift Package containing a `SiliconAuditCore` module with zero UI dependencies. Probe logic is pure POSIX with **no platform conditionals**. Environment detection (§6.2) necessarily branches and is confined to a single `Environment` type inside core; nothing else in core may `#if os(...)`. Thin SwiftUI presentation on top, shared where possible, specialized where the platform demands it. A `silicon-audit` CLI target on macOS linking the same core.

The core module being UI-free and platform-free in its probe path is what makes the results comparable across devices. Resist any temptation to branch probe behavior by platform.

**One Xcode project**, not five: a multiplatform app target (iOS/iPadOS/macOS/visionOS/tvOS) plus a watchOS target embedded in the iOS app. Bundle identifiers: `org.unredacted.siliconaudit` (app), `org.unredacted.siliconaudit.watchkitapp` (watch), `org.unredacted.siliconaudit.cli`, `org.unredacted.siliconaudit.tests`. No App Group: the companion and the watch app run on different devices and share no local container, so watch → phone state moves only over `WCSession` (§7).

### 6.2 Environment detection

Every export must state how it was produced, because several situations produce misleading numbers:

| Situation | Detection | Effect |
|---|---|---|
| Simulator | `#if targetEnvironment(simulator)` plus `SIMULATOR_*` env vars at runtime | `is_simulator: true`; unmissable banner; CI rejects |
| iOS app running on Apple silicon Mac | `ProcessInfo.processInfo.isiOSAppOnMac` | `is_ios_app_on_mac: true`; banner; CI rejects (reports the Mac's chip while claiming iOS) |
| Mac Catalyst | `#if targetEnvironment(macCatalyst)`, checked before the ordinary iOS branch | `platform: macOS`, `is_catalyst: true` |
| Virtual machine (macOS guest, CI runner) | `kern.hv_vmm_present == 1`, or `kern.version` target `VMAPPLE`, or `hw.model` beginning `VirtualMac` | `is_virtual_machine: true`; banner; CI rejects (the guest sees what the hypervisor exposes, not a chip) |
| Rosetta (x86_64 build on arm64 Mac) | `sysctl.proc_translated == 1` | `is_translated: true`; banner; CI rejects |
| Intel Mac | `hw.cputype == CPU_TYPE_X86_64` | `arch: x86_64`; report x86 `hw.optional.*` keys unannotated; no ARM security claims; the matrix groups by arch |

### 6.3 SDK independence

An app built with Xcode 26.6 against the 26 SDKs runs unchanged on OS 27 and on new hardware. The probe engine is runtime-only; new `hw.optional.arm.*` keys in a newer kernel appear in `unrecognized_keys` without a rebuild. New key names, cpufamily constants, and `soc_id` values arrive as data-file updates. Xcode 27 is needed only for new SDK APIs and for wired install/debug onto devices already running OS 27; TestFlight and App Store installs work from a 26.x build.

### 6.4 Design principles

The app must be easy to use and beautiful, and it must look native on each platform. Concretely:

- **Follow the Human Interface Guidelines per platform.** Native navigation: `NavigationSplitView` on iPad and Mac, `NavigationStack` on iPhone, a single scrolling list on watch, a focus-driven layout on tvOS, ornaments and glass on visionOS. Adopt the OS 26 design language (Liquid Glass materials, standard toolbars and controls) rather than custom chrome.
- **System typography and color.** System fonts with Dynamic Type at every size. SF Symbols for every status glyph. Semantic system colors only, so light, dark, and increased-contrast modes work without special casing.
- **Provenance and state are never conveyed by color alone.** Each provenance (`measured`, `documented`, `inferred`, `unknown`) has a distinct glyph, a text label, and an accessibility description. Each state (`present`, `not_present`, `key_absent`, `restricted`, `error`, `unknown`) likewise pairs a glyph with text.
- **Summary first.** One headline card: device, SoC (with its inferred-from chain), "N of M security features reported present," and the OS build. Then grouped sections in the §4.3 order with memory tagging first. Tapping a row opens a detail view showing the raw key, value, type, byte length, one plain-English sentence on what it means, and the provenance chain.
- **Accessibility is not optional.** Full VoiceOver labels and `accessibilityValue` for every state; Reduce Motion respected; nothing conveyed only on hover.
- **Localizable from day one.** All user-facing strings in a string catalog; English only at launch.
- **One primary export action per platform.** Share sheet on iOS/iPadOS/visionOS, Save panel on Mac, "Send to iPhone" on watch, QR on tvOS. Raw JSON is available but never the primary surface.
- **Warnings are persistent and system-styled.** The simulator / Rosetta / iOS-on-Mac banner is a non-dismissable system-styled warning at the top of the summary, not a toast.
- **Copy discipline.** UI strings obey §3: "reports," "exposes," "Apple documents," "not yet documented for this chip." Never "has," "is protected by," or "enabled" unless a measured fact says so.

---

## 7. watchOS specifics

The watch is the reason this project exists, and it's the constrained case.

- **No shell, no terminal.** All probing happens in-process via `sysctlbyname` and raw `sysctl`. This is fine; the C API is available.
- **Display.** A 42mm screen cannot show a feature matrix. Design for a scrollable list of feature rows with a status glyph and a tap-through detail view. Group by category (§4.3). Put a single summary line at top: how many features measured, how many present.
- **Export.** Use `WCSession` to transfer the result payload to the companion iOS app, which then handles display, share sheet, and file export. Use `transferFile` (queued, reliable, background) with a gzip-compressed JSON file rather than `transferUserInfo`; the latter's payload ceiling is undocumented and is hit in practice by dictionaries in the tens of kilobytes, which a full export with per-perf-level data can reach. `sendMessage` requires reachability and is not appropriate.
- **Standalone fallback.** If no companion is reachable, the watch app must still display results locally. Never make viewing depend on the phone. `ShareLink` (watchOS 9+) with the compact export (§8) is the standalone export path.
- **Verify the sandbox.** Confirm early — in the M0 spike, before building anything else — that `hw.optional.arm.*` keys are readable from a sandboxed watchOS app, that the raw `sysctl` MIB walk works, and whether `vm.mte.*` is readable. This is the single biggest technical risk in the project. If reads are restricted on watchOS, the whole app's value proposition on its most important platform collapses, and you want to know in week one.

---

## 8. Export format

Versioned JSON. Stable schema, published as `Schema/export-v1.schema.json` (JSON Schema 2020-12, `additionalProperties: false` throughout — the schema *is* the privacy allowlist). This is the artifact people will paste into forum threads and pull requests, so it needs to be readable by a human and parseable by a script.

```json
{
  "schema_version": "1.0.0",
  "app_version": "0.1.0",
  "collected_at": "2026-09-18T14:22:31Z",
  "collection": {
    "walk_succeeded": true,
    "walk_root": "hw.optional",
    "known_keys_version": "2026-09-10"
  },
  "environment": {
    "platform": "watchOS",
    "arch": "arm64",
    "os_version": "27.0",
    "os_build": "27R123",
    "kernel_version": "Darwin Kernel Version 27.0.0: ...; root:xnu-.../RELEASE_ARM64_T8320",
    "is_simulator": false,
    "is_translated": false,
    "is_ios_app_on_mac": false,
    "is_catalyst": false,
    "is_virtual_machine": false
  },
  "device": {
    "identity": "Watch8,1",
    "hw_product": "Watch8,1",
    "hw_machine": "Watch8,1",
    "hw_model": "N207AP",
    "hw_target": "N207AP",
    "cpufamily": "0x1d7a72b1",
    "cpufamily_name": "unrecognized",
    "cpusubfamily": 3,
    "soc_id": "T8320",
    "soc_name_inferred": "unrecognized",
    "marketing_name_inferred": "unrecognized"
  },
  "facts": [
    {
      "id": "arm.FEAT_MTE4",
      "display_name": "Memory Tagging Extension 4 (FEAT_MTE4)",
      "category": "memory_tagging",
      "kind": "flag",
      "provenance": "measured",
      "state": "present",
      "discovered_by": "both",
      "raw": { "key": "hw.optional.arm.FEAT_MTE4", "format": "int", "length": 4, "value": 1, "errno": null }
    },
    {
      "id": "arm.caps",
      "display_name": "ARM capability bitmask",
      "category": "capability_bitmask",
      "kind": "bitmask",
      "provenance": "measured",
      "state": "value",
      "discovered_by": "both",
      "raw": { "key": "hw.optional.arm.caps", "format": "int64_t", "length": 12, "value_hex": "ffef...", "errno": null }
    },
    {
      "id": "vm.mte.tagged",
      "display_name": "Kernel memory-tagging activity",
      "category": "os_memory_tagging",
      "kind": "count",
      "provenance": "measured",
      "state": "key_absent",
      "discovered_by": "known_list",
      "raw": { "key": "vm.mte.tagged", "format": null, "length": 0, "value": null, "errno": 2 }
    },
    {
      "id": "sptm",
      "display_name": "Secure Page Table Monitor",
      "category": "kernel_integrity",
      "provenance": "documented",
      "state": "unknown",
      "source": {
        "url": "https://support.apple.com/guide/security/operating-system-integrity-sec8b776536b/web",
        "published": "2026-01-28",
        "verified": "2026-09-10",
        "note": "soc_id T8320 is not in soc-map.json; chip-family table does not list S11"
      }
    }
  ],
  "unrecognized_keys": [
    {
      "id": "unrecognized.hw.optional.arm.FEAT_XYZ",
      "display_name": "hw.optional.arm.FEAT_XYZ",
      "category": "unrecognized",
      "kind": "unknown",
      "provenance": "measured",
      "state": "value",
      "discovered_by": "walk",
      "raw": { "key": "hw.optional.arm.FEAT_XYZ", "format": "int", "length": 4, "value": 1, "errno": null }
    }
  ]
}
```

Design notes:

- **`state` is one enum for every fact:** `present | not_present | value | key_absent | restricted | not_applicable | error | unknown`. Measured facts use every state but `unknown`; `present`/`not_present` are for `flag` kinds only and `value` for every other kind that read successfully; documented and inferred facts use `present`, `not_present`, or `unknown`.
- **`unrecognized_keys` entries are ordinary measured facts** (same schema, `provenance: measured`, `discovered_by: walk`, `kind: unknown`, `category: unrecognized`, `display_name` = the key). They are kept in their own top-level array so discoveries are visible at a glance, and they carry their own provenance and read outcome rather than inheriting it from the array. Scoped to the walk root (`hw.optional`), never `kern.*` or `vm.*`.
- `collection.walk_succeeded: false` means the result is not evidence of absence for keys outside the inventory.
- Everything under `device` ending in `_inferred` is a lookup, not a measurement, and the app has no way to verify it. `soc_id` and `cpufamily` are measured.
- `os_build` (from `kern.osversion`) is the conflict-resolution key in §9, not `os_version`.
- **Compact variant** (`"variant": "compact"`): measured facts only, no display names or descriptions, deflate-compressed and base45-encoded for QR (tvOS) and watch `ShareLink`. The companion app or the CI tool expands it against the same `known_keys_version`.
- No serial number, no UDID, no identifierForVendor, no account, no IP-derived location, no hostname, no boot time, no boot-session UUID.

---

## 9. Community results database

The repo hosts a `results/` directory of contributed export files, plus a generated matrix (Markdown table and a small static site) mapping chip → feature → state.

Contribution flow: user exports JSON from the app, opens a PR adding it under `results/<identity>/` (`device.identity`, §4.3). CI validates it against `Schema/export-v1.schema.json` (which rejects any field outside the allowlist), rejects `is_simulator`, `is_translated`, `is_ios_app_on_mac`, or `is_virtual_machine` results, and regenerates the matrix grouped by `arch`, then `soc_id`, then `identity`.

Conflict handling: when two submissions for the same `(identity, os_build)` disagree on a measured fact, do not silently pick one. Surface the disagreement in the generated matrix. Disagreements usually mean a bug in the app, an environment flag that slipped through, or something genuinely interesting. Submissions for the same `identity` on different `os_build`s that disagree are not conflicts; they are the OS-version boundary the app exists to detect, and the matrix shows them side by side.

This database is arguably more valuable than the app. The app is the collection mechanism.

---

## 10. Privacy, review, and licensing

**Privacy.** No network calls in the base app. Export by explicit allowlist only; the walk root is `hw.optional` and nothing else is enumerated. Keys read by name from `kern.*` and `vm.*` are the fixed list in §4.3. Never read `kern.hostname`, `kern.bootsessionuuid`, `kern.boottime`, or `kern.uuid`. Ship a `PrivacyInfo.xcprivacy` manifest. As of this review, `sysctl`/`sysctlbyname` are not listed in Apple's Required Reason API categories (file timestamps, system boot time, disk space, active keyboards, user defaults); recheck the list at submission time, keep `kern.boottime` out regardless, and declare an empty accessed-API array unless the recheck says otherwise.

**App Store review risk.** Diagnostic and system-info apps ship routinely, so this is not exotic. Two areas to watch. First, anything that reads broad device characteristics can attract fingerprinting scrutiny — the mitigation is that the app stores nothing, transmits nothing, and only exports on explicit user action; state this plainly in review notes. Second, if the enforcement self-test (§11) is implemented, expect questions about deliberate crash-adjacent behavior; keep it behind a developer toggle and be prepared to ship without it.

Have a distribution fallback. TestFlight, and buildable-from-source with a free developer account, mean the project survives a rejection.

**License.** Apache-2.0. The explicit patent grant is worth more here than MIT's brevity, given the subject matter. (The repo's initial GPL-3.0 `LICENSE` was replaced during the v0.2 review.)

---

## 11. Phase 2 (optional): enforcement self-test

A hardware capability flag doesn't prove the OS turned enforcement on for this process. Two probes, in order of risk.

**2a — Tagged-pointer observation (low risk, do this first).** Build the app with Xcode's Enhanced Security capability, specifically the entitlements `com.apple.security.hardened-process`, `com.apple.security.hardened-process.enhanced-security-version-string`, and `com.apple.security.hardened-process.checked-allocations` (memory tagging; hardware requirement A19+/M5+). Allocate a few dozen heap blocks of varied sizes and read bits 59:56 of each returned pointer. If tagging is active for this process, the allocator returns logical tags and most values are nonzero; if not, all are zero. This performs no invalid access, cannot fault, and yields a **measured** per-process fact: "memory tagging active for this app." It still does not prove synchronous mode. Recommendation: adopt Enhanced Security in Phase 1 (after stability testing, because it changes allocator behavior) so this probe is meaningful at launch.

**2b — Deliberate tag-check fault (advanced, risky).** Install a Mach exception handler, perform a tagged-memory access with a mismatched tag, and observe whether the fault is delivered synchronously. Use `com.apple.security.hardened-process.checked-allocations.soft-mode` during development (faults are logged as simulated crashes instead of terminating). It must be off by default, behind an explicit developer toggle, isolated so a failure can't corrupt the rest of the app's state, and clearly labeled as experimental. Do not attempt it until Phase 1 is stable and shipping.

If 2b works, it is the only thing in the app that produces a `measured` result for synchronous enforcement rather than capability, which makes it disproportionately valuable. But Phase 1 has standalone value without it. Do not let this block the release.

---

## 12. Repo layout

```
silicon-audit/
├── Package.swift
├── Sources/
│   ├── SiliconAuditCore/          # probe engine, no UI; platform conditionals only in Environment.swift
│   │   ├── SysctlProbe.swift
│   │   ├── MIBWalker.swift
│   │   ├── KnownKeys.swift
│   │   ├── Environment.swift
│   │   ├── FactModel.swift
│   │   ├── Export.swift
│   │   └── Resources/             # bundled via Bundle.module — SwiftPM will not bundle a top-level Data/
│   │       ├── known-keys.json
│   │       ├── documented-matrix.json
│   │       ├── cpufamily-names.json   # seeded from <mach/machine.h>
│   │       ├── caps-bits.json         # seeded from <arm/cpu_capabilities_public.h>
│   │       └── soc-map.json           # soc_id (T-number) → SoC name → security-guide column
│   ├── SiliconAuditUI/            # shared SwiftUI views
│   └── silicon-audit-cli/         # macOS CLI
├── Apps/
│   └── SiliconAudit.xcodeproj     # one project: multiplatform app target + watchOS target
├── Schema/
│   └── export-v1.schema.json      # also the CI privacy allowlist
├── results/                       # community submissions, results/<hw_product>/
├── Tools/
│   └── generate-matrix/           # CI: results → Markdown + static site
├── docs/
│   ├── spec-review.md
│   └── evidence/                  # raw sysctl dumps behind spec claims
└── Tests/
    └── Fixtures/                  # recorded sysctl outputs per device/build
```

---

## 13. Milestones

**M0 — Feasibility spike (do this first).** Done 2026-09-10 on iPhone18,2 and Watch7,1; results in `docs/evidence/spike-M0.md`. Verdict: by-name reads work in both sandboxes, the walk and OIDFMT do not; the by-name inventory with declared formats is the collection path on iOS and watchOS. A throwaway app on a physical iPhone and a physical Apple Watch. Checklist, in order: `sysctlbyname` on four `hw.optional.arm.*` keys; the raw `sysctl` meta-OID walk from `hw.optional`; byte length of `hw.optional.arm.caps`; presence of `hw.product`; readability of `vm.mte.tagged`; a `WCSession.transferFile` round-trip watch → phone. The only goal is answering whether iOS and watchOS permit this. Everything downstream depends on it. Timebox it. (macOS is already known good from the sandbox profile.)

**M1 — Core engine.** `SiliconAuditCore` with the five-way probe, MIB walk unioned with the known list, `Environment` detection (simulator, Rosetta, iOS-on-Mac, Intel), known-key inventory generated from the two public headers, `soc_id` parsing, fact model, JSON export plus compact variant. Unit tested against recorded fixtures, starting with `docs/evidence/Mac17,7-25G83.txt`.

**M2 — iOS and macOS apps.** Full UI per §6.4, share-sheet and Save-panel export, CLI. Ship to TestFlight.

**M3 — watchOS app.** Standalone display plus `transferFile` export to the iOS companion; `ShareLink` compact fallback.

**M4 — Documented matrix and provenance UI.** The measured/documented/inferred separation rendered properly, including the `soc_id` → family → claim chain.

**M5 — Community database.** Repo structure, JSON Schema validation CI with environment-flag rejection, matrix generator grouped by arch/soc/product, contribution docs.

**M6 — tvOS and visionOS.** QR compact export on tvOS.

**M7 — Optional enforcement self-test.** 2a first, then 2b.

---

## 14. Test plan and known traps

**The simulator lies.** A simulator process reports the host Mac's CPU features, not the simulated device's. A watchOS simulator on an M-series Mac will happily report feature flags the physical watch does not have. So does an iOS app running on an Apple silicon Mac, and so does an x86_64 build under Rosetta (which reports x86 keys). These are the most likely sources of bad data in the community database.

Mitigations, all of them: detect each condition at runtime and set the corresponding `environment` flag; display a persistent, unmissable banner in the UI; make CI reject any submitted result with any of the flags set (`is_simulator`, `is_translated`, `is_ios_app_on_mac`, `is_virtual_machine`); and say so in the contribution docs. GitHub's macOS runners are `VMAPPLE` guests: the project's own CI is a virtual machine and must never be a data source.

**Other test requirements:**

- Fixture-based unit tests for the probe engine, covering every `ProbeOutcome` case including `restricted`, every `format`, and malformed returns (length shorter than format implies, length longer than 8 for a declared `int64_t`).
- The 12-byte `caps` value must decode to the same answers as the individual `FEAT_*` keys on every fixture. A mismatch fails the test.
- Round-trip test on the export schema and on the compact variant.
- Test on at least one deliberately old device on a deliberately old OS — an A12-era phone on the oldest OS it will run — to confirm `key_absent` is reported for `FEAT_*` keys, that the legacy `armv8_*` aliases fill in, and that nothing crashes or defaults to false.
- Test across an OS-version boundary on the same hardware, to confirm the app can distinguish a hardware change from a kernel change and that the matrix shows the two builds side by side.
- Test on an Intel Mac and under Rosetta.
- Verify variable-width sysctl handling explicitly; do not let a 4-byte or 8-byte assumption ship.
- Accessibility audit with VoiceOver on iPhone and watch; Dynamic Type at the largest accessibility size.

**A note on interpretation.** The app should be careful in its own copy not to overclaim. "This kernel reports FEAT_MTE4" is a true statement the app can make. "This device has Memory Integrity Enforcement" is not, unless the enforcement self-test measured it. Write the UI strings with the same discipline as the data model.
