"""Parsers for the headers the data files come from: SDK copies (generate.py) and XNU source (the
upstream watcher). One module so both read a header the same way.
"""
import re

_CAP_NB = re.compile(r"#define CAP_BIT_NB\s+(\d+)")
# Numeric definitions only: aliases such as `CAP_BIT_CRC32 CAP_BIT_FEAT_CRC32` are not new bits.
_CAP_BIT = re.compile(r"#define CAP_BIT_(\w+)\s+(\d+)\n")
_CPUFAMILY = re.compile(r"#define CPUFAMILY_(\w+)\s+(0x[0-9a-fA-F]+)")
_CPUSUBFAMILY = re.compile(r"#define CPUSUBFAMILY_(\w+)\s+(\d+)")
_ARM_FEATURE = re.compile(r"^\s*ARM_FEATURE_FLAG\(\s*(\w+)\s*\)", re.M)

# Key names whose curation decides what the app headlines. generate.py refuses to give one of these
# the default "not security-relevant" annotation, and the watcher flags them in its issues.
SECURITY_HINT = re.compile(r"PAuth|PAC|MTE|BTI|CSV|SSBS|SPECRES|DIT|CPA|GCS")


def parse_caps_bits(text):
    """(cap_bit_nb, [{"bit", "name"}] sorted by bit) from <arm/cpu_capabilities_public.h>."""
    m = _CAP_NB.search(text)
    if not m:
        raise ValueError("CAP_BIT_NB not found")
    nb = int(m.group(1))
    # CAP_BIT_NB is the bit count, not a capability; everything else below it is a real bit.
    entries = [{"bit": int(b), "name": n} for n, b in _CAP_BIT.findall(text) if n != "NB" and int(b) < nb]
    return nb, sorted(entries, key=lambda e: e["bit"])


def parse_cpufamily(text):
    """(families, subfamilies) from <mach/machine.h>, in header order."""
    fams = [{"value": f"0x{int(val, 16):08x}", "name": f"CPUFAMILY_{name}",
             "arch": "arm64" if name.startswith("ARM") else "x86_64" if name.startswith("INTEL") else "other"}
            for name, val in _CPUFAMILY.findall(text)]
    subs = [{"value": int(v), "name": f"CPUSUBFAMILY_{n}"} for n, v in _CPUSUBFAMILY.findall(text)]
    if not fams:
        raise ValueError("no CPUFAMILY_ definitions found")
    return fams, subs


def parse_arm_features(text):
    """Sorted feature names from XNU's osfmk/arm/arm_features.inc; each is hw.optional.arm.<name>."""
    names = sorted(set(_ARM_FEATURE.findall(text)))
    if not names:
        raise ValueError("no ARM_FEATURE_FLAG entries found")
    return names
