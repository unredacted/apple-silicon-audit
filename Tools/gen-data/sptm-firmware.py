#!/usr/bin/env python3
"""Which chips Apple's firmware boots SPTM and TXM on, read from IPSW and OTA restore manifests.

The `exceptions` on the ppl and sptm rows of documented-matrix.json come from this check
(docs/evidence/sptm-txm-firmware.md). Re-run it for each OS release and update SPTM_FIRMWARE
in generate.py when a chip appears. Only the zip directory and BuildManifest.plist are
fetched, through HTTP range requests, never the whole image. Device lookups use ipsw.me, which
does not list current Apple Watch or Apple TV firmware: pass those images with --url (AppleDB,
https://api.appledb.dev/ios/watchOS;<build>.json, lists their restore and OTA links). Run from anywhere:
    python3 Tools/gen-data/sptm-firmware.py iPhone12,1 iPad13,4 Macmini9,1
    python3 Tools/gen-data/sptm-firmware.py MacBookPro18,1 --version 26.4
    python3 Tools/gen-data/sptm-firmware.py --url https://updates.cdn-apple.com/…/Watch7,1_26.3_23S620_Restore.ipsw
"""
import argparse, io, json, plistlib, urllib.request, zipfile

MANIFESTS = ("BuildManifest.plist", "AssetData/boot/BuildManifest.plist")   # IPSW, then full OTA

class RangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file, one range request per read."""
    def __init__(self, url):
        self.url, self.pos = url, 0
        head = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"))
        self.size = int(head.headers["Content-Length"])
    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, offset, whence=io.SEEK_SET):
        self.pos = {io.SEEK_SET: offset, io.SEEK_CUR: self.pos + offset, io.SEEK_END: self.size + offset}[whence]
        return self.pos
    def readinto(self, buf):
        if not len(buf) or self.pos >= self.size: return 0
        end = min(self.pos + len(buf), self.size) - 1
        resp = urllib.request.urlopen(urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"}))
        if resp.status != 206:
            raise SystemExit(f"{self.url}: server ignored the range request (HTTP {resp.status})")
        data = resp.read()
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)

def firmwares(device):
    return json.load(urllib.request.urlopen(f"https://api.ipsw.me/v4/device/{device}?type=ipsw"))["firmwares"]

def monitors(url):
    """Sorted (ApChipID, board, sptm image, txm image) rows: erase identities for an IPSW, every
    identity for a full OTA (which has only update variants)."""
    if url.lower().endswith(".aea"):
        raise SystemExit(f"{url}: encrypted OTA (.aea), cannot be read this way")
    archive = zipfile.ZipFile(io.BufferedReader(RangeFile(url), buffer_size=1 << 16))
    names = set(archive.namelist())
    path = next((p for p in MANIFESTS if p in names), None)
    if path is None:
        raise SystemExit(f"{url}: no BuildManifest.plist")
    identities = plistlib.loads(archive.read(path))["BuildIdentities"]
    erase = [bi for bi in identities if "erase" in bi["Info"].get("Variant", "").lower()]
    def image(m, key): return m.get(key, {}).get("Info", {}).get("Path", "-").split("/")[-1]
    return sorted({(bi.get("ApChipID"), bi["Info"].get("DeviceClass"),
                    image(bi["Manifest"], "Ap,SecurePageTableMonitor"), image(bi["Manifest"], "Ap,TrustedExecutionMonitor"))
                   for bi in erase or identities})

def show(label, url):
    print(label)
    for chip, board, sptm, txm in monitors(url):
        print(f"  {chip} {board}: SPTM {sptm}, TXM {txm}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("devices", nargs="*", help="product types listed by ipsw.me, e.g. iPhone12,1")
    ap.add_argument("--version", help="exact OS version (default: newest IPSW)")
    ap.add_argument("--url", action="append", default=[], help="an IPSW or full-OTA URL, e.g. from AppleDB")
    args = ap.parse_args()
    if not args.devices and not args.url:
        ap.error("give device identifiers or --url")
    for url in args.url:
        show(url.rsplit("/", 1)[-1], url)
    for device in args.devices:
        fw = firmwares(device)
        pick = next((f for f in fw if f["version"] == args.version), None) if args.version else fw[0]
        if pick is None:
            print(f"{device}: no IPSW for {args.version}"); continue
        show(f"{device} {pick['version']} ({pick['buildid']})", pick["url"])
