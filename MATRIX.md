# Silicon Audit results matrix

Generated 2026-09-17 from 3 accepted result(s) in `results/` by `Tools/generate-matrix`. Do not edit by hand.

Legend: ● reported present · ○ reported off · – key absent from that kernel · ⊘ restricted by the sandbox · × not applicable (other architecture) · ! read error · ? unknown · ᴬ read through the legacy `armv8_*` alias because the kernel does not register the `FEAT_*` key · ⚠ conflict between submissions for the same device and build.

**Measured** means the kernel on that device reported it, not that the silicon has it. **Documented** rows are Apple's published table applied through the chip family the app inferred from the kernel target, as the app's bundled data understood it when the result was exported; where a device has several results, the row shows the one annotated with the newest documentation data. See each result's own provenance fields.

## Measured security flags

| arch | SoC | identity | OS build | MTE | MTE2 | MTE3 | MTE4 | MTE async | canon. tags | store-only | no-addr tags | PAuth | PAuth2 | FPAC | FPACCOMBINE | PACIMP | BTI | CSV2 | CSV3 | SB | SSBS | SPECRES | SPECRES2 | DIT |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| arm64 | Apple M5 (Pro/Max die; marketing tier unverified) (T6050) | Mac17,7 | macOS 25G83 | ● | ● | ○ | ● | ○ | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ○ | ○ | ○ | ● |
| arm64 | Apple M5 (Pro/Max die; marketing tier unverified) (T6050) | Mac17,7 | macOS 26A428 | ● | ● | ○ | ● | ○ | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ● | ○ | ○ | ○ | ● |
| arm64 | Apple S9 (T8310) | Watch7,1 | watchOS 23U67 | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ● | ● | ● | ○ | ● | ● | ● | ● | ● | ● | ○ | ○ | ● |

## Apple's documented protections, by chip family

| SoC | identity | column | KIP | FPR | SCIP | PAC (OS) | PPL | SPTM | MIE | guide published | data verified | results |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Apple M5 (Pro/Max die; marketing tier unverified) (T6050) | Mac17,7 | M5 | ● | ● | ● | ● | ○ | ● | ● | 2026-01-28 | 2026-09-10 | 2 (1 data snapshot) |
| Apple S9 (T8310) | Watch7,1 | S4-S10 | ● | ● | ● | ● | ● | ○ | ○ | 2026-01-28 | 2026-09-10 | 1 |

## Per-result notes

- **Mac17,7** (macOS 25G83, Mac17,7/25G83-1.json): walk + inventory; caps 67 bits set (64 named, unnamed [38,39,59]), 0 mismatch(es); engine 0.1.0, inventory 2026-09-10
- **Mac17,7** (macOS 26A428, Mac17,7/26A428-1.json): walk + inventory; caps 67 bits set (64 named, unnamed [38,39,59]), 0 mismatch(es); **8 unrecognized key(s)**: hw.optional.arm.FEAT_FP8, hw.optional.arm.FEAT_PAuth_LR, hw.optional.arm.FEAT_LUT, hw.optional.arm.FEAT_FAMINMAX, hw.optional.arm.FEAT_CPA, hw.optional.arm.FEAT_CPA2, hw.optional.arm.FEAT_FPMR, hw.optional.arm.FEAT_SME_LUTv2; self-test of the exporting app: tagging no (0/65 tagged, entitlement not_declared); engine 0.1.0, inventory 2026-09-10
- **Watch7,1** (watchOS 23U67, Watch7,1/23U67-1.json): inventory only; caps 42 bits set (40 named, unnamed [39,59]), 0 mismatch(es); engine 0.1.0, inventory 2026-09-10

## Conflicts

_none_
