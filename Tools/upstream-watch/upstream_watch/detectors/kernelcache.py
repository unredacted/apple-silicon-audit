"""Kernelcache strings: an early, heuristic signal for new hw.optional feature names.

The kernelcache member is streamed out of the IPSW with one ranged GET; the pinned `ipsw` tool
only decompresses it. Token and banner extraction happen here, so nothing depends on ipsw's output
format. A name in the kernel's strings is not proof that the sysctl is registered: findings are
labelled heuristic unless results or XNU corroborate them.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import tempfile

from ..http import Client, FetchError
from ..remote_zip import RemoteZip, Unsupported

_TOKEN = re.compile(rb"(?<![A-Za-z0-9_])((?:FEAT_|SME_|AdvSIMD|FP_)[A-Za-z0-9_]{1,40})\x00")
_BANNER = re.compile(rb"Darwin Kernel Version [^\x00]{1,200}")
_TARGET = re.compile(rb"RELEASE_ARM64_(T\d{4,5}|VMAPPLE\w*)")
_XNU = re.compile(rb"(xnu-[\d.]+)")
MAX_COMPRESSED = 256 << 20
MAX_SIZE = 256 << 20


def extract(blob: bytes) -> dict:
    tokens = sorted({m.group(1).decode() for m in _TOKEN.finditer(blob)})
    banner = _BANNER.search(blob)
    target = _TARGET.search(banner.group(0)) if banner else None
    xnu = _XNU.search(banner.group(0)) if banner else None
    return {"tokens": tokens, "target": target.group(1).decode() if target else None,
            "xnu": xnu.group(1).decode() if xnu else None}


def decompress(ipsw: str, src: pathlib.Path, workdir: pathlib.Path) -> bytes:
    out = workdir / "out"
    subprocess.run([ipsw, "kernel", "dec", str(src), "-o", str(out)], check=True, capture_output=True, timeout=600)
    files = [out] if out.is_file() else sorted(out.rglob("*"), key=lambda p: p.stat().st_size if p.is_file() else -1)
    files = [f for f in files if f.is_file()]
    if not files:
        raise Unsupported("ipsw produced no output")
    return files[-1].read_bytes()


def observe(client: Client, scheduled: list[dict], ipsw: str, b) -> None:
    for item in scheduled:
        wid, fp = item["work_id"], item["source_fp"]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                work = pathlib.Path(tmp)
                raw = work / "kernelcache.im4p"
                with raw.open("wb") as f:
                    RemoteZip(client, item["url"]).fetch_member(item["member"], f, max_compressed=MAX_COMPRESSED,
                                                                max_size=MAX_SIZE)
                found = extract(decompress(ipsw, raw, work))
            if found["target"] is None:
                raise Unsupported("no Darwin banner in the decompressed kernel")
            b.outcome(wid, fp, "done", {"type": "kernelcache", "os": item["os"], "build": item["build"],
                                        "version": item["version"], "beta": item["beta"], **found})
        except Unsupported as e:
            b.outcome(wid, fp, "unsupported", error=str(e))
        except FetchError as e:
            b.outcome(wid, fp, "retryable" if e.retryable else "unsupported", error=str(e))
        except (subprocess.SubprocessError, OSError) as e:
            b.outcome(wid, fp, "retryable", error=f"decompress: {e}")
