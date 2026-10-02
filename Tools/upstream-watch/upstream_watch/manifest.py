"""BuildManifest.plist: which firmware images each board in an IPSW or OTA is personalized to boot."""
from __future__ import annotations

import plistlib

from .http import Client
from .remote_zip import RemoteZip, Unsupported

MANIFEST_PATHS = ("BuildManifest.plist", "AssetData/boot/BuildManifest.plist")   # IPSW, then full OTA
MAX_MANIFEST = 64 << 20   # the UniversalMac manifest is the largest, a few MB


def chip(ap_chip_id) -> str:
    """"0x8030" or 32816 → "T8030", the spelling kern.version and soc-map use."""
    value = int(ap_chip_id, 16) if isinstance(ap_chip_id, str) else int(ap_chip_id)
    return f"T{value:04X}"


def _image(manifest: dict, key: str) -> str | None:
    path = manifest.get(key, {}).get("Info", {}).get("Path")
    return path.rsplit("/", 1)[-1] if path else None


def rows(build_manifest: dict) -> list[dict]:
    """One row per (chip, board, images). Erase identities when present (IPSWs); every identity
    otherwise, since a full OTA has only "Customer Software Update" variants."""
    identities = build_manifest.get("BuildIdentities", [])
    erase = [i for i in identities if "erase" in i.get("Info", {}).get("Variant", "").lower()]
    seen = set()
    for ident in erase or identities:
        if "ApChipID" not in ident:
            continue
        m = ident.get("Manifest", {})
        seen.add((chip(ident["ApChipID"]), ident.get("Info", {}).get("DeviceClass", "").lower(),
                  _image(m, "Ap,SecurePageTableMonitor"), _image(m, "Ap,TrustedExecutionMonitor"),
                  m.get("KernelCache", {}).get("Info", {}).get("Path")))
    return [{"chip": c, "board": b, "sptm": s, "txm": t, "kernelcache": k}
            for c, b, s, t, k in sorted(seen, key=lambda r: tuple(x or "" for x in r))]


def read(client: Client, url: str) -> tuple[RemoteZip, dict, str]:
    """(archive, manifest, prefix): image paths in the manifest are relative to `prefix` in the zip."""
    archive = RemoteZip(client, url)
    for path in MANIFEST_PATHS:
        if archive.info(path) is not None:
            try:
                return archive, plistlib.loads(archive.read(path, MAX_MANIFEST)), path[:-len("BuildManifest.plist")]
            except plistlib.InvalidFileException as e:
                raise Unsupported(f"{path}: not a plist ({e})") from None
    raise Unsupported("no BuildManifest.plist")
