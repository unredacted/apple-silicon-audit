#!/usr/bin/env python3
"""Which chips Apple's firmware boots SPTM and TXM on, read from IPSW and OTA restore manifests.

The upstream watcher (Tools/upstream-watch, SPEC §15) runs the same check on every new build and
opens an issue when the firmware disagrees with documented-matrix.json. This is the manual version,
for bisecting a chip's first build or checking one image. Only the zip directory and the manifest
are fetched, through HTTP range requests, never the whole image.
    python3 Tools/gen-data/sptm-firmware.py iPhone12,1 iPad13,4 Macmini9,1
    python3 Tools/gen-data/sptm-firmware.py MacBookPro18,1 --version 26.4
    python3 Tools/gen-data/sptm-firmware.py --url https://updates.cdn-apple.com/…/Watch7,1_26.3_23S620_Restore.ipsw
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "upstream-watch"))
from upstream_watch import manifest  # noqa: E402
from upstream_watch.http import Client  # noqa: E402


def firmwares(client, device):
    return client.get_json(f"https://api.ipsw.me/v4/device/{device}?type=ipsw")["firmwares"]


def show(client, label, url):
    _, bm, _ = manifest.read(client, url)
    print(label)
    for r in manifest.rows(bm):
        print(f"  {r['chip']} {r['board']}: SPTM {r['sptm'] or '-'}, TXM {r['txm'] or '-'}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("devices", nargs="*", help="product types, e.g. iPhone12,1 (listed by ipsw.me)")
    ap.add_argument("--version", help="exact OS version (default: newest IPSW)")
    ap.add_argument("--url", action="append", default=[], help="an IPSW or full-OTA URL, e.g. from AppleDB")
    args = ap.parse_args()
    if not args.devices and not args.url:
        ap.error("give device identifiers or --url")
    client = Client()
    for url in args.url:
        show(client, url.rsplit("/", 1)[-1], url)
    for device in args.devices:
        fw = firmwares(client, device)
        pick = next((f for f in fw if f["version"] == args.version), None) if args.version else fw[0]
        if pick is None:
            print(f"{device}: no IPSW for {args.version}")
            continue
        show(client, f"{device} {pick['version']} ({pick['buildid']})", pick["url"])
