# Phase 5 — real-report round trip, Apple Watch Series 9 → iPhone 17 Pro Max

Date: 2026-09-10. Devices: Watch7,1 (S9, watchOS 26.6 / 23U67), iPhone18,2 (iOS 26.6.2 / 23G90).
Report: [report-Watch7,1-23U67.json](report-Watch7,1-23U67.json), 82,555 bytes, schema 1.0.0, validates
with `Scripts/validate-export.sh`.

## What happened

1. The watch app (shared `SiliconAuditUI` views, no spike code) ran `Auditor.audit()` on the S9 and
   queued the full JSON export with `WCSession.transferFile` when the user tapped **Send to iPhone**.
2. The iOS app's `ReportTransferBridge` received the file, `ReceivedReportStore` validated the
   schema version and stored it as `Application Support/SiliconAudit/ReceivedReports/silicon-audit-Watch7,1-23U67.json`.
   The WatchConnectivity inbox was empty afterwards: the delivery was consumed, not left behind.
3. The file was pulled from the phone with `devicectl device copy from` and validated unchanged.

## What the S9 reported (real device, no simulator)

| | |
|---|---|
| identity / model | `Watch7,1` / `N207sAP` |
| kernel target → SoC | `T8310` → Apple S9 (`verified` map entry) |
| cpufamily | `0x8765edea` `CPUFAMILY_ARM_EVEREST_SAWTOOTH` |
| collection | walk refused (`CTL_SYSCTL_NEXT` errno 1), kernel formats unavailable, inventory-typed |
| facts | 187: present 61, not_present 31, value 30, key_absent 57, restricted 3, error 2, unknown 3 |
| memory tagging | all eight `FEAT_MTE*` **not_present** (known to the kernel, reported off) |
| caps | 12 bytes, 42 bits set, 40 named, unnamed bits 39 and 59, **0 mismatches** against the keys |
| documented (S4–S10 column) | KIP, Fast Permission Restrictions, SCIP, PAC, PPL present; SPTM, MIE not present; TCE, Secure Exclaves, Secure Enclave generation unknown (not tabulated) |
| restricted | `hw.engineering_sample`, `hw.features.allows_security_research`, `kern.hv_support` |
| unrecognized keys | none (the walk is refused, so only inventory keys are read) |

## Two data findings from this run

- **`hw.perflevel0.l3cachesize` and `cpusperl3` return `EINVAL` (errno 22)** on the S9, which has no
  L3. The kernel registers the keys but rejects the read. The engine records `error` with the errno,
  which is the honest answer; it is not `key_absent` and not `not_present`.
- **Cache-size keys are 4-byte integers.** The inventory had declared `l1icachesize`, `l1dcachesize`,
  `l2cachesize` and `l3cachesize` as `Q`; the kernel declares them `I` (`sysctl -t` says "integer",
  `sysctl -l` says 4 bytes). On the Mac the kernel's own OIDFMT corrected this silently; on the Watch,
  where OIDFMT is refused, the wrong inventory type left the values as raw bytes. Fixed in the
  generator. This is exactly the failure mode the `format_source: inventory` marker exists to expose.
