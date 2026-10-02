"""Apple's open-source XNU: the canonical hw.optional.arm feature list and the capability and CPU
family headers, at the newest published tag. Publication lags releases by weeks; the SDK headers
detector usually sees the same changes first."""
from __future__ import annotations

import re
import sys
import pathlib

from ..http import Client, FetchError

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "gen-data"))
from sdk_headers import parse_arm_features, parse_caps_bits, parse_cpufamily  # noqa: E402

TAGS = "https://api.github.com/repos/apple-oss-distributions/xnu/tags?per_page=100&page={}"
RAW = "https://raw.githubusercontent.com/apple-oss-distributions/xnu/{tag}/{path}"
FILES = {"features": "osfmk/arm/arm_features.inc", "caps": "osfmk/arm/cpu_capabilities_public.h",
         "machine": "osfmk/mach/machine.h"}
_TAG = re.compile(r"^xnu-(\d+(?:\.\d+)*)$")


def newest_tag(client: Client) -> str:
    tags = []
    for page in range(1, 6):
        batch = client.get_json(TAGS.format(page))
        if not batch:
            break
        tags += [t["name"] for t in batch if isinstance(t, dict) and _TAG.match(str(t.get("name", "")))]
    if not tags:
        raise FetchError("no xnu-* tags", retryable=False)
    return max(tags, key=lambda t: [int(x) for x in _TAG.match(t).group(1).split(".")])


def parse(tag: str, texts: dict) -> dict:
    nb, caps = parse_caps_bits(texts["caps"])
    fams, subs = parse_cpufamily(texts["machine"])
    return {"tag": tag, "arm_features": parse_arm_features(texts["features"]), "cap_bit_nb": nb,
            "caps": {e["name"]: e["bit"] for e in caps}, "cpufamily": {f["name"]: f["value"] for f in fams},
            "cpusubfamily": {s["name"]: s["value"] for s in subs}}


def observe(client: Client, state: dict, b) -> None:
    key = "xnu:latest"
    try:
        tag = newest_tag(client)
        prev = state["scopes"].get(key)
        if prev and prev["data"].get("tag") == tag:
            b.snapshot(key, prev["data"])   # confirmed, nothing new to fetch
            return
        texts = {name: client.request(RAW.format(tag=tag, path=path), max_bytes=1 << 20).text()
                 for name, path in FILES.items()}
        b.snapshot(key, parse(tag, texts))
    except FetchError as e:
        b.failed(key, e, "network" if e.retryable else "parse")
    except ValueError as e:
        b.failed(key, e, "parse")
