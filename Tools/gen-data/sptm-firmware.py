#!/usr/bin/env python3
"""Which chips Apple's firmware boots SPTM and TXM on, read from the IPSW restore manifests.

The `exceptions` on the ppl and sptm rows of documented-matrix.json come from this check
(docs/evidence/sptm-txm-firmware.md). Re-run it for each OS release and update SPTM_FIRMWARE
in generate.py when a chip appears. Only the zip directory and BuildManifest.plist are
fetched, through HTTP range requests, never the whole IPSW. Run from anywhere:
    python3 Tools/gen-data/sptm-firmware.py iPhone12,1 iPad13,4 Macmini9,1
    python3 Tools/gen-data/sptm-firmware.py MacBookPro18,1 --version 26.4
"""
import argparse, io, json, plistlib, urllib.request, zipfile

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
        data = urllib.request.urlopen(urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})).read()
        buf[:len(data)] = data
        self.pos += len(data)
        return len(data)

def firmwares(device):
    return json.load(urllib.request.urlopen(f"https://api.ipsw.me/v4/device/{device}?type=ipsw"))["firmwares"]

def monitors(url):
    """Sorted (ApChipID, board, sptm image, txm image) rows for the erase-install identities."""
    archive = zipfile.ZipFile(io.BufferedReader(RangeFile(url), buffer_size=1 << 16))
    manifest = plistlib.loads(archive.read("BuildManifest.plist"))
    def image(m, key): return m.get(key, {}).get("Info", {}).get("Path", "-").split("/")[-1]
    return sorted({(bi.get("ApChipID"), bi["Info"].get("DeviceClass"),
                    image(bi["Manifest"], "Ap,SecurePageTableMonitor"), image(bi["Manifest"], "Ap,TrustedExecutionMonitor"))
                   for bi in manifest["BuildIdentities"] if "erase" in bi["Info"].get("Variant", "").lower()})

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("devices", nargs="+", help="product types, e.g. iPhone12,1")
    ap.add_argument("--version", help="exact OS version (default: newest IPSW)")
    args = ap.parse_args()
    for device in args.devices:
        fw = firmwares(device)
        pick = next((f for f in fw if f["version"] == args.version), None) if args.version else fw[0]
        if pick is None:
            print(f"{device}: no IPSW for {args.version}"); continue
        print(f"{device} {pick['version']} ({pick['buildid']})")
        for chip, board, sptm, txm in monitors(pick["url"]):
            print(f"  {chip} {board}: SPTM {sptm}, TXM {txm}")
