# Enforcement self-test (SPEC §11) on Mac17,7 / macOS 26.6.2 (25G83)

Date: 2026-09-10. Apple M5 (kernel target T6050), `hw.optional.arm.FEAT_MTE4: 1`. Xcode 26.6, ad-hoc signing.

## Entitlement probe (C, before the Swift implementation)

65 `malloc` blocks of 13 sizes (16 B to 1 MiB, five rounds), tag = pointer bits 59:56:

| binary | entitlements | tagged | distinct tags |
|---|---|---|---|
| unsigned | none | 0 / 65 | 1 (only zero) |
| ad hoc | hardened-process, enhanced-security-version (int 1), checked-allocations | 55 / 65 | 16 |
| ad hoc | hardened-process, enhanced-security-version-string ("1"), checked-allocations | 55 / 65 | 16 |

Deliberate faults in the same binaries (`p = malloc(32)`; out of bounds: `p[48] = 7`; use after free: write after `free`):

| binary | clean | out of bounds | use after free |
|---|---|---|---|
| unsigned | exit 0 | exit 0, write survives | exit 0, write survives |
| ad hoc + entitlements | exit 0 | exit 137 (SIGKILL) | exit 137 (SIGKILL) |

## `silicon-audit self-test --fault`

Unsigned `.build/debug/silicon-audit`:

```
Kernel memory-tagging hardware (hw.optional.arm.FEAT_MTE4): present
Enhanced Security checked-allocations entitlement on this binary: not_declared
○ Memory tagging active for this app: not_present   None of 65 heap allocations carried a tag. ...
○ Tag mismatch stops this app: not_present          The child's out-of-bounds store succeeded and it exited normally. ...
```

After `Scripts/sign-hardened.sh`:

```
Enhanced Security checked-allocations entitlement on this binary: declared
● Memory tagging active for this app: present   55 of 65 heap allocations came back with a nonzero tag (15 distinct tag values) ...
● Tag mismatch stops this app: present          ... killed by signal 9 (SIGKILL): the OS detected the tag mismatch ...
```

`export --fault-test` from the hardened binary validates against `Schema/export-v1.schema.json` (1.1.0); the
compact export round-trips through `import` and validates. Each `--fault` run leaves one crash report for
the child (`silicon-audit-<date>.ips`) in `~/Library/Logs/DiagnosticReports`. The report for the hardened
child reads:

```
exception:   type EXC_BAD_ACCESS, signal SIGKILL, subtype EXC_ARM_MTE_TAGCHECK_FAIL at 0x07000008db020050
termination: namespace MTE_FAIL, code 262
faulting frames: _platform_memmove ← UnsafeMutableRawPointer.storeBytes ← FaultTest.performFault() ← SelfTest.run()
```

The faulting address carries tag 0x7 in bits 59:56 and the fault lands on the store instruction itself:
the check is synchronous.

## Hardened app

`xcodebuild -scheme "SiliconAudit Hardened" -configuration DebugHardened -destination platform=macOS` signs
with `Apps/SiliconAudit/macOS-hardened.entitlements` (App Sandbox + the three Enhanced Security keys) and
writes `SiliconAuditEnhancedSecurity = YES` into Info.plist. Launched from the terminal with
`-initialSelection __about_data__`, the process was still alive after 20 s and left no crash report.
