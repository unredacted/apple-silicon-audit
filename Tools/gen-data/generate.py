#!/usr/bin/env python3
"""Regenerate the bundled data files in Sources/SiliconAuditCore/Resources.

Sources of truth:
- <arm/cpu_capabilities_public.h>  -> caps-bits.json (bit positions are ABI)
- <mach/machine.h>                  -> cpufamily-names.json
- docs/evidence/*.txt / *.json      -> the observed hw.optional key list
- ANNOTATIONS below                 -> display names, kinds, categories, descriptions
- MATRIX below                      -> documented-matrix.json (Apple Platform Security guide)

soc-map.json is curated by hand and left alone. Run from the repo root:
    python3 Tools/gen-data/generate.py
"""
import json, re, subprocess, sys, pathlib, datetime

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Sources/SiliconAuditCore/Resources"
TODAY = datetime.date.today().isoformat()

def sdk():
    try:
        return pathlib.Path(subprocess.check_output(["xcrun", "--show-sdk-path", "--sdk", "macosx"], text=True).strip())
    except Exception:
        return pathlib.Path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")

SDK = sdk()

def header(rel):
    return (SDK / "usr/include" / rel).read_text()

def write(name, obj):
    path = OUT / name
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {path.relative_to(ROOT)} ({len(obj.get('entries', []))} entries)")

# ---------------------------------------------------------------- caps-bits
def caps_bits():
    text = header("arm/cpu_capabilities_public.h")
    nb = int(re.search(r"#define CAP_BIT_NB\s+(\d+)", text).group(1))
    # CAP_BIT_NB is the bit count, not a capability; everything else below it is a real bit.
    entries = [{"bit": int(b), "name": n} for n, b in re.findall(r"#define CAP_BIT_(\w+)\s+(\d+)\n", text)
               if n != "NB" and int(b) < nb]
    return {
        "schema_version": "1", "version": TODAY, "verified": TODAY,
        "source": "<arm/cpu_capabilities_public.h>, macOS SDK; bit positions are ABI and never change",
        "cap_bit_nb": nb,
        "entries": sorted(entries, key=lambda e: e["bit"]),
    }

# ---------------------------------------------------------- cpufamily-names
def cpufamily_names():
    text = header("mach/machine.h")
    fams = []
    for name, val in re.findall(r"#define CPUFAMILY_(\w+)\s+(0x[0-9a-fA-F]+)", text):
        fams.append({"value": f"0x{int(val, 16):08x}", "name": f"CPUFAMILY_{name}",
                     "arch": "arm64" if name.startswith("ARM") else "x86_64" if name.startswith("INTEL") else "other"})
    subs = [{"value": int(v), "name": f"CPUSUBFAMILY_{n}"} for n, v in re.findall(r"#define CPUSUBFAMILY_(\w+)\s+(\d+)", text)]
    return {
        "schema_version": "1", "version": TODAY, "verified": TODAY,
        "source": "<mach/machine.h>, macOS SDK. hw.cpufamily identifies the core microarchitecture, not the SoC.",
        "entries": fams, "subfamilies": subs,
    }

# --------------------------------------------------------------- known keys
# key -> (display_name, category, kind, security_relevant, description[, alias_of])
A = {}
def add(key, display, category, kind, sec, desc, alias_of=None, fmt=None):
    A[key] = dict(display_name=display, category=category, kind=kind, security_relevant=sec, description=desc,
                  alias_of=alias_of, format=fmt)

arm = "hw.optional.arm."
# Memory tagging
add(arm+"FEAT_MTE",  "Memory Tagging Extension (MTE)", "memory_tagging", "flag", True, "Kernel reports the base Memory Tagging Extension: tag-aware loads/stores and tag memory.")
add(arm+"FEAT_MTE2", "MTE2 (full tag checking)", "memory_tagging", "flag", True, "Kernel reports MTE2: full tag checking on loads and stores, not just tag storage instructions.")
add(arm+"FEAT_MTE3", "MTE3 (asymmetric fault handling)", "memory_tagging", "flag", True, "Kernel reports MTE3: asymmetric mode, synchronous reads with asynchronous writes.")
add(arm+"FEAT_MTE4", "MTE4 (enhanced tagging)", "memory_tagging", "flag", True, "Kernel reports MTE4, the Armv8.9 enhancement group that Apple's EMTE builds on.")
add(arm+"FEAT_MTE_ASYNC", "MTE asynchronous mode", "memory_tagging", "flag", True, "Kernel reports support for asynchronous tag-check faults. Off on Apple's EMTE chips, which are synchronous-only.")
add(arm+"FEAT_MTE_CANONICAL_TAGS", "MTE canonical tags", "memory_tagging", "flag", True, "Kernel reports canonical tag checking, part of MTE4.")
add(arm+"FEAT_MTE_STORE_ONLY", "MTE store-only checking", "memory_tagging", "flag", True, "Kernel reports the store-only tag checking mode, part of MTE4.")
add(arm+"FEAT_MTE_NO_ADDRESS_TAGS", "MTE without address tags", "memory_tagging", "flag", True, "Kernel reports checking of memory accesses that carry no address tag, part of MTE4.")
# PAC
add(arm+"FEAT_PAuth",  "Pointer Authentication", "pointer_authentication", "flag", True, "Kernel reports pointer authentication instructions (PAC).")
add(arm+"FEAT_PAuth2", "Pointer Authentication 2", "pointer_authentication", "flag", True, "Kernel reports the PAuth2 refinements to pointer authentication.")
add(arm+"FEAT_FPAC",   "Faulting PAC", "pointer_authentication", "flag", True, "Kernel reports that a failed pointer authentication faults immediately instead of producing a poisoned pointer.")
add(arm+"FEAT_FPACCOMBINE", "Faulting PAC (combined ops)", "pointer_authentication", "flag", True, "Kernel reports faulting behavior for combined authenticate-and-branch/load instructions.")
add(arm+"FEAT_PACIMP", "Implementation-defined PAC algorithm", "pointer_authentication", "flag", True, "Kernel reports an implementation-defined PAC algorithm (Apple's), rather than the standard QARMA.")
# Control flow / speculation / constant time
add(arm+"FEAT_BTI", "Branch Target Identification", "control_flow", "flag", True, "Kernel reports BTI landing pads for indirect branches.")
add(arm+"FEAT_CSV2", "CSV2 (branch-target speculation safety)", "speculation", "flag", True, "Kernel reports Cache Speculation Variant 2 hardening against branch-target injection.")
add(arm+"FEAT_CSV3", "CSV3 (fault speculation safety)", "speculation", "flag", True, "Kernel reports Cache Speculation Variant 3: no speculative loads from faulting addresses.")
add(arm+"FEAT_SB", "Speculation Barrier", "speculation", "flag", True, "Kernel reports the SB speculation barrier instruction.")
add(arm+"FEAT_SSBS", "Speculative Store Bypass Safe", "speculation", "flag", True, "Kernel reports SSBS control over speculative store bypass. Set on the S9, clear on the M5 and A19 Pro in the project's own measurements.")
add(arm+"FEAT_SPECRES", "Speculation restriction (SPECRES)", "speculation", "flag", True, "Kernel reports the prediction-invalidation instructions of FEAT_SPECRES.")
add(arm+"FEAT_SPECRES2", "Speculation restriction 2", "speculation", "flag", True, "Kernel reports FEAT_SPECRES2 (COSP RCTX).")
add(arm+"FEAT_DIT", "Data Independent Timing", "constant_time", "flag", True, "Kernel reports the DIT control that makes selected instructions data-independent in timing, relevant to constant-time crypto.")
# Bitmask
add(arm+"caps", "ARM capability bitmask", "capability_bitmask", "bitmask", True, "One bit per FEAT extension as defined in <arm/cpu_capabilities_public.h>; 12 bytes on macOS 26, declared int64_t.", fmt="Q")
# Crypto / SIMD / misc ISA (not security-relevant for this app)
crypto = {"FEAT_AES": "AES instructions", "FEAT_PMULL": "Polynomial multiply (PMULL)", "FEAT_SHA1": "SHA-1 instructions", "FEAT_SHA256": "SHA-256 instructions", "FEAT_SHA512": "SHA-512 instructions", "FEAT_SHA3": "SHA-3 instructions", "FEAT_CRC32": "CRC32 instructions"}
for k, d in crypto.items():
    add(arm+k, d, "isa_crypto", "flag", False, f"Kernel reports {d}.")
simd = {"AdvSIMD": "Advanced SIMD", "AdvSIMD_HPFPCvt": "Advanced SIMD half-precision conversion", "FEAT_FP16": "Half-precision floating point", "FEAT_BF16": "BFloat16", "FEAT_EBF16": "Extended BFloat16", "FEAT_I8MM": "Int8 matrix multiply", "FEAT_DotProd": "Dot product", "FEAT_FHM": "FP16 multiply-add to FP32", "FEAT_FCMA": "Complex-number arithmetic", "FEAT_JSCVT": "JavaScript conversion", "FEAT_RDM": "Rounding double multiply", "FEAT_FRINTTS": "Float round to integer", "FEAT_AFP": "Alternate floating-point behavior", "FEAT_RPRES": "Reciprocal estimate precision", "FP_SyncExceptions": "Synchronous floating-point exceptions"}
for k, d in simd.items():
    add(arm+k, d, "isa_simd", "flag", False, f"Kernel reports {d}.")
misc = {"FEAT_FlagM": "Flag manipulation", "FEAT_FlagM2": "Flag manipulation 2", "FEAT_LSE": "Large System Extensions (atomics)", "FEAT_LSE2": "LSE2 (atomic 16-byte access)", "FEAT_LRCPC": "Release-consistent loads", "FEAT_LRCPC2": "Release-consistent loads 2", "FEAT_DPB": "Data cache clean to point of persistence", "FEAT_DPB2": "DC CVADP", "FEAT_ECV": "Enhanced counter virtualization", "FEAT_WFxT": "WFE/WFI with timeout", "FEAT_CSSC": "Common short sequence compression", "FEAT_HBC": "Hinted conditional branches"}
for k, d in misc.items():
    add(arm+k, d, "isa_misc", "flag", False, f"Kernel reports {d}.")
sme = {"FEAT_SME": "Scalable Matrix Extension", "FEAT_SME2": "SME2", "FEAT_SME2p1": "SME2.1", "FEAT_SME_F64F64": "SME FP64 outer product", "FEAT_SME_I16I64": "SME Int16 to Int64", "FEAT_SME_F16F16": "SME FP16", "FEAT_SME_B16B16": "SME BF16", "FEAT_SME_F8F16": "SME FP8 to FP16", "FEAT_SME_F8F32": "SME FP8 to FP32", "SME_F32F32": "SME FP32 outer product", "SME_BI32I32": "SME binary outer product", "SME_B16F32": "SME BF16 to FP32", "SME_F16F32": "SME FP16 to FP32", "SME_I8I32": "SME Int8 to Int32", "SME_I16I32": "SME Int16 to Int32", "FEAT_SVE_B16B16": "SVE BF16 arithmetic"}
for k, d in sme.items():
    add(arm+k, d, "isa_sme", "flag", False, f"Kernel reports {d}.")
add(arm+"sme_max_svl_b", "SME maximum vector length (bytes)", "isa_sme", "count", False, "Maximum streaming vector length in bytes.")
# Legacy aliases directly under hw.optional.
legacy = {"hw.optional.arm64": ("64-bit ARM", None), "hw.optional.armv8_1_atomics": ("ARMv8.1 atomics (legacy name)", arm+"FEAT_LSE"), "hw.optional.armv8_2_fhm": ("ARMv8.2 FHM (legacy name)", arm+"FEAT_FHM"), "hw.optional.armv8_2_sha3": ("ARMv8.2 SHA-3 (legacy name)", arm+"FEAT_SHA3"), "hw.optional.armv8_2_sha512": ("ARMv8.2 SHA-512 (legacy name)", arm+"FEAT_SHA512"), "hw.optional.armv8_3_compnum": ("ARMv8.3 complex numbers (legacy name)", arm+"FEAT_FCMA"), "hw.optional.armv8_crc32": ("ARMv8 CRC32 (legacy name)", arm+"FEAT_CRC32"), "hw.optional.armv8_gpi": ("ARMv8 generic PAC (legacy name)", arm+"FEAT_PAuth")}
for k, (d, alias) in legacy.items():
    add(k, d, "legacy_alias", "flag", alias is not None and "gpi" in k, f"Pre-FEAT_ naming still registered by the kernel; older kernels expose only this name.", alias_of=alias)
for k, d in {"hw.optional.floatingpoint": "Floating point", "hw.optional.neon": "NEON", "hw.optional.neon_fp16": "NEON FP16", "hw.optional.neon_hpfp": "NEON half-precision", "hw.optional.ucnormal_mem": "Uncached normal memory"}.items():
    add(k, d, "legacy_alias", "flag", False, "Legacy hw.optional flag.")
add("hw.optional.breakpoint", "Hardware breakpoints", "debug", "count", False, "Number of hardware breakpoint registers.")
add("hw.optional.watchpoint", "Hardware watchpoints", "debug", "count", False, "Number of hardware watchpoint registers.")
# x86 table (registered on arm64 kernels too; reads ENOTSUP there)
x86 = ["adx", "aes", "avx1_0", "avx2_0", "avx512bw", "avx512cd", "avx512dq", "avx512f", "avx512ifma", "avx512vbmi", "avx512vl", "bmi1", "bmi2", "enfstrg", "f16c", "fma", "hle", "mmx", "mpx", "rdrand", "rtm", "sgx", "sse", "sse2", "sse3", "sse4_1", "sse4_2", "supplementalsse3", "x86_64"]
for k in x86:
    sec = k in ("sgx", "mpx", "rdrand")
    add("hw.optional."+k, f"x86 {k}", "x86_isa", "flag", sec, "Intel feature flag. Registered on arm64 kernels too, where it reads ENOTSUP (not applicable).")
# Context
ctx = {
 "hw.product": ("Product identifier", "context_identity", "string", "Device model identifier (Mac17,7, iPhone18,2, Watch7,1). Primary identity.", "A"),
 "hw.machine": ("Machine", "context_identity", "string", "Model identifier on iOS/watchOS; the literal 'arm64' or 'x86_64' on macOS.", "A"),
 "hw.model": ("Model / board", "context_identity", "string", "Model on macOS (also Intel identity); board identifier on iOS/watchOS (V54AP, N207sAP).", "A"),
 "hw.target": ("Board target", "context_identity", "string", "Board target identifier (J714cAP).", "A"),
 "hw.targettype": ("Board target type", "context_identity", "string", "Board target type (J714c).", "A"),
 "hw.cputype": ("CPU type", "context_cpu", "count", "Mach CPU type constant.", "I"),
 "hw.cpusubtype": ("CPU subtype", "context_cpu", "count", "Mach CPU subtype constant.", "I"),
 "hw.cpufamily": ("CPU family", "context_cpu", "count", "Core microarchitecture family; see <mach/machine.h>. Display as unsigned hex.", "I"),
 "hw.cpusubfamily": ("CPU subfamily", "context_cpu", "count", "Core subfamily (HP, HG, M, HS, HC_HD, HA).", "I"),
 "hw.ncpu": ("Logical CPUs", "context_cpu", "count", "Number of logical CPUs.", "I"),
 "hw.nperflevels": ("Performance levels", "context_cpu", "count", "Number of core clusters (performance levels).", "I"),
 "hw.memsize": ("Memory size", "context_cpu", "count", "Physical memory in bytes.", "Q"),
 "hw.pagesize": ("Page size", "context_cpu", "count", "VM page size in bytes.", "Q"),
 "hw.features.allows_security_research": ("Security Research Device", "context_os", "flag", "1 on Apple Security Research Devices. Restricted on iOS and watchOS.", "I"),
 "hw.engineering_sample": ("Engineering sample", "context_os", "flag", "1 on engineering-sample hardware. Restricted on iOS and watchOS.", "I"),
 "kern.version": ("Kernel version string", "context_os", "string", "Full kernel banner; its RELEASE_ARM64_<T-number> suffix is the measured SoC identifier.", "A"),
 "kern.osversion": ("OS build", "context_os", "string", "OS build number (25G83, 23G90, 23U67).", "A"),
 "kern.osproductversion": ("OS version", "context_os", "string", "Marketing OS version (26.6.2).", "A"),
 "kern.osreleasetype": ("OS release type", "context_os", "string", "User, Beta, or internal release type.", "A"),
 "kern.hv_support": ("Hypervisor support", "context_os", "flag", "Hypervisor.framework availability. Restricted on iOS and watchOS.", "I"),
 "sysctl.proc_translated": ("Rosetta translation", "context_os", "flag", "1 when this process runs under Rosetta; the environment flag is_translated is derived from it.", "I"),
 "vm.mte.tagged": ("Pages tagged now (gauge)", "os_memory_tagging", "count", "Live gauge of MTE-tagged pages; nonzero is measured evidence the kernel is tagging memory right now. Restricted on iOS, absent on watchOS.", "I"),
 "vm.mte.cell.active": ("Active tag-storage cells (gauge)", "os_memory_tagging", "count", "Live gauge of tag-storage cells in use. Restricted on iOS, absent on watchOS.", "I"),
 "vm.mte.tag_storage.activations": ("Tag-storage activations (cumulative)", "os_memory_tagging", "count", "Cumulative since boot; says tagging happened at some point, not that it is happening now.", "Q"),
}
for k, (d, cat, kind, desc, fmt) in ctx.items():
    add(k, d, cat, kind, k.startswith("vm.mte") or k in ("hw.features.allows_security_research",), desc, fmt=fmt)
# Per-performance-level context (SPEC §4.3): counts, caches and cluster name only; no ISA flags exist here.
for n in range(3):
    for leaf, (d, kind, fmt) in {"physicalcpu": ("physical CPUs", "count", "I"), "physicalcpu_max": ("physical CPUs (max)", "count", "I"),
                                 "logicalcpu": ("logical CPUs", "count", "I"), "logicalcpu_max": ("logical CPUs (max)", "count", "I"),
                                 "l1icachesize": ("L1 instruction cache", "count", "Q"), "l1dcachesize": ("L1 data cache", "count", "Q"),
                                 "l2cachesize": ("L2 cache", "count", "Q"), "cpusperl2": ("CPUs per L2", "count", "I"),
                                 "l3cachesize": ("L3 cache", "count", "Q"), "cpusperl3": ("CPUs per L3", "count", "I"),
                                 "name": ("cluster name", "string", "A")}.items():
        add(f"hw.perflevel{n}.{leaf}", f"Perf level {n} {d}", "context_cpu", kind, False,
            f"Core cluster {n}: {d}. Context only; the kernel exposes no per-cluster ISA feature flags.", fmt=fmt)

def observed_keys():
    keys = set()
    for line in (ROOT / "docs/evidence/Mac17,7-25G83.txt").read_text().splitlines():
        m = re.match(r"^(hw\.optional\.[A-Za-z0-9_.]+):", line)
        if m: keys.add(m.group(1))
    # x86 names are not printed by sysctl(8) on arm64 (ENOTSUP); they came from the engine's walk.
    keys.update("hw.optional." + k for k in x86)
    return keys

def known_keys():
    entries = []
    keys = observed_keys() | set(A)
    for key in sorted(keys):
        a = A.get(key)
        leaf = key.split(".")[-1]
        if a is None:
            a = dict(display_name=leaf, category="isa_misc", kind="flag", security_relevant=False,
                     description=f"Arm ISA feature {leaf}; observed in the kernel's hw.optional table, no curated description yet.", alias_of=None, format=None)
        fmt = a["format"] or ("I" if key.startswith("hw.optional.") else None)
        e = {"id": key.replace("hw.optional.", ""), "key": key, "display_name": a["display_name"], "category": a["category"],
             "kind": a["kind"], "format": fmt, "security_relevant": a["security_relevant"], "description": a["description"]}
        if a["alias_of"]: e["alias_of"] = a["alias_of"]
        entries.append(e)
    return {
        "schema_version": "1", "version": TODAY, "verified": TODAY,
        "notes": "Keys the engine annotates. `format` is the sysctl format string used when the sandbox refuses OIDFMT (I=int32, Q=int64, A=string). kind: flag keys map to present/not_present; everything else reads as value. security_relevant selects the headline sections.",
        "categories": ["memory_tagging", "pointer_authentication", "control_flow", "speculation", "constant_time", "capability_bitmask", "os_memory_tagging", "legacy_alias", "isa_crypto", "isa_simd", "isa_sme", "isa_misc", "debug", "x86_isa", "context_identity", "context_cpu", "context_os"],
        "entries": entries,
    }

# --------------------------------------------------------- documented matrix
GUIDE = "https://support.apple.com/guide/security/operating-system-integrity-sec8b776536b/web"
MIE_BLOG = "https://security.apple.com/blog/memory-integrity-enforcement/"
COLUMNS = ["A10", "A11-S3", "A12-A14", "S4-S10", "A15-A18", "M1", "M2-M4", "A19", "M5"]
def row(id_, name, cols, desc, url=GUIDE, published="2026-01-28", verified="2026-09-10", tabulated=True, note=None):
    r = {"id": id_, "display_name": name, "category": "kernel_integrity", "tabulated": tabulated, "columns_present": cols,
         "description": desc, "source": {"url": url, "published": published, "verified": verified}}
    if note: r["source"]["note"] = note
    return r
def matrix():
    all_ = COLUMNS
    return {
        "schema_version": "1", "version": TODAY, "verified": "2026-09-10",
        "columns": COLUMNS,
        "notes": "Apple's Platform Security guide, 'Operating system integrity', runtime-protection table as read on 2026-09-10 (page published 2026-01-28). A chip family not in `columns` is unknown to the guide and every row reads unknown for it.",
        "entries": [
            row("kip", "Kernel Integrity Protection", all_, "Hardware prevents modification of kernel code and read-only data after boot."),
            row("fast_permission_restrictions", "Fast Permission Restrictions", [c for c in all_ if c != "A10"], "Hardware register that quickly restricts memory permissions, used by the kernel and by JIT hardening."),
            row("scip", "System Coprocessor Integrity Protection", [c for c in all_ if c not in ("A10", "A11-S3")], "Coprocessor firmware (including the Secure Enclave's) is protected against runtime modification."),
            row("pac", "Pointer Authentication Codes (OS use)", [c for c in all_ if c not in ("A10", "A11-S3")], "Apple's documented use of PAC across the OS. The measured FEAT_PAuth rows say what the kernel reports; this row says what Apple documents."),
            row("ppl", "Page Protection Layer", ["A12-A14", "S4-S10", "A15-A18"], "Higher-privileged kernel layer guarding page tables and code signing, predecessor of SPTM.", note="Footnoted for S4-S10 in the guide."),
            row("sptm", "Secure Page Table Monitor (with TXM)", ["A15-A18", "M2-M4", "A19", "M5"], "Page-table monitor running above the kernel, paired with the Trusted Execution Monitor."),
            row("mie", "Memory Integrity Enforcement", ["A19", "M5"], "EMTE in synchronous mode plus secure typed allocators plus Tag Confidentiality Enforcement. A hardware FEAT_MTE4 flag alone does not make this true.", note="Composition per the Apple Security Research post of 2025-09-09 (" + MIE_BLOG + ")."),
            row("tce", "Tag Confidentiality Enforcement", [], "Policies protecting allocator tags against side-channel and speculative-execution leaks; part of MIE, not tabulated per chip.", url=MIE_BLOG, published="2025-09-09", tabulated=False),
            row("secure_exclaves", "Secure Exclaves", [], "Isolated execution domains introduced alongside SPTM; not tabulated per chip in the guide.", tabulated=False),
            row("secure_enclave_generation", "Secure Enclave generation", [], "Secure Enclave hardware generation is not exposed to apps and not tabulated in the runtime-protection table.", tabulated=False),
        ],
    }

if __name__ == "__main__":
    write("caps-bits.json", caps_bits())
    write("cpufamily-names.json", cpufamily_names())
    write("known-keys.json", known_keys())
    write("documented-matrix.json", matrix())
