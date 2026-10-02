"""SDK headers on a macOS runner: every installed Xcode's macOS and iOS SDK copies of
<arm/cpu_capabilities_public.h> and <mach/machine.h>. Runner VMs are never a sysctl source
(SPEC §14); headers are files, so they are fine to read here."""
from __future__ import annotations

import glob
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "gen-data"))
from sdk_headers import parse_caps_bits, parse_cpufamily  # noqa: E402

SDKS = ("macosx", "iphoneos")


def _run(cmd, developer_dir):
    env = {**os.environ, "DEVELOPER_DIR": developer_dir}
    return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=120, check=True).stdout.strip()


def xcodes(pattern: str = "/Applications/Xcode*.app") -> list[str]:
    return sorted({os.path.realpath(p) for p in glob.glob(pattern)})


def read_sdk(sdk_root: str) -> dict:
    inc = pathlib.Path(sdk_root) / "usr/include"
    nb, caps = parse_caps_bits((inc / "arm/cpu_capabilities_public.h").read_text())
    fams, subs = parse_cpufamily((inc / "mach/machine.h").read_text())
    return {"cap_bit_nb": nb, "caps": {e["name"]: e["bit"] for e in caps},
            "cpufamily": {f["name"]: f["value"] for f in fams}, "cpusubfamily": {s["name"]: s["value"] for s in subs}}


def observe(producer: str, b, pattern: str = "/Applications/Xcode*.app") -> None:
    members = []
    for app in xcodes(pattern):
        key = f"{producer}:{app}"
        dev = f"{app}/Contents/Developer"
        try:
            version = " ".join(_run(["xcodebuild", "-version"], dev).split())
            sdks = {}
            for sdk in SDKS:
                path = _run(["xcrun", "--sdk", sdk, "--show-sdk-path"], dev)
                name = sdk + _run(["xcrun", "--sdk", sdk, "--show-sdk-version"], dev)
                sdks[sdk] = {"name": name, **read_sdk(path)}
            b.snapshot(key, {"xcode": version[:80], "sdks": sdks})
        except (subprocess.SubprocessError, OSError) as e:
            b.failed(key, e, "network")   # a runner problem; three in a row open health
        except ValueError as e:
            b.failed(key, e, "parse")
        members.append(key)
    b.producer_set(producer, members)
