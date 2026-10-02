"""Firmware: which builds exist (AppleDB, betas included), which chips each covers, and what each
chip's restore manifest boots. Also the device → chip map and the macOS kernel targets (KDK).

Manifest reads come from the durable queue: the observe job schedules up to the cap from the
committed queue plus the work this run's newly fetched builds derive, deterministically.
"""
from __future__ import annotations

import hashlib
import json
import re
import urllib.parse

from .. import manifest, merge, queue, statefile, versions
from ..http import Client, FetchError
from ..remote_zip import Unsupported

APPLEDB = "https://api.appledb.dev"
IPSWME_DEVICES = "https://api.ipsw.me/v4/devices"
KDK_RELEASES = "https://api.github.com/repos/dortania/KdkSupportPkg/releases?per_page=1"
_TARGET = re.compile(r"RELEASE_ARM64_(T\d{4,5}|VMAPPLE\w*)")


def _chip_of(device: str, devices: dict) -> str:
    return devices.get(device) or devices.get(device.split("-", 1)[0]) or f"?{device}"


def device_map(client: Client) -> dict:
    """{"devices": {identifier: "T8030"}, "socs": {"T8030": ["A13"]}} from AppleDB, ipsw.me filling gaps."""
    devices, socs = {}, {}
    for d in client.get_json(f"{APPLEDB}/device/main.json", max_bytes=16 << 20):
        cpid = d.get("cpid")
        if not isinstance(cpid, str) or not re.match(r"^0x[0-9a-fA-F]{4,5}$", cpid):
            continue
        c = manifest.chip(cpid)
        for ident in d.get("identifier") or []:
            devices[ident] = c
        if d.get("soc"):
            socs.setdefault(c, set()).add(str(d["soc"])[:40])
    try:
        for d in client.get_json(IPSWME_DEVICES, max_bytes=4 << 20):
            if isinstance(d.get("cpid"), int) and d.get("identifier") and d["identifier"] not in devices:
                devices[d["identifier"]] = manifest.chip(d["cpid"])
    except FetchError:
        pass   # a cross-check only; AppleDB alone is enough
    return {"devices": dict(sorted(devices.items())), "socs": {c: sorted(s) for c, s in sorted(socs.items())}}


def kdk_targets(client: Client) -> dict:
    releases = client.get_json(KDK_RELEASES)
    if not releases:
        raise FetchError("no KDK releases", retryable=False)
    rel = releases[0]
    asset = next((a for a in rel.get("assets", []) if a.get("name") == "kernel_versions.json"), None)
    if asset is None:
        raise FetchError(f"{rel.get('tag_name')}: no kernel_versions.json", retryable=False)
    kv = client.get_json(asset["browser_download_url"], max_bytes=1 << 20)
    targets = sorted({m.group(1) for v in kv.values() if isinstance(v, str) for m in [_TARGET.search(v)] if m})
    xnu = sorted({m.group(1) for v in kv.values() if isinstance(v, str) for m in [re.search(r"(xnu-[\d.]+)", v)] if m})
    return {"release": str(rel.get("tag_name", ""))[:40], "targets": targets, "xnu": xnu[-1] if xnu else ""}


def index_keys(raw: list, oses: list[str], floor_train: int) -> dict[str, list[str]]:
    """Build keys per OS in the newest two trains, without simulator, SDK or duplicate RC entries."""
    if not isinstance(raw, list):
        raise ValueError(f"index is a {type(raw).__name__}, not a list")
    by_os: dict[str, set] = {}
    for key in raw:
        if not isinstance(key, str):
            continue
        os, build, suffix = versions.split_index_key(key)
        if os not in oses or {"sim", "SDK"} & set(suffix.split("-")) or versions.train(build) is None:
            continue
        if versions.train(build) < floor_train:
            continue
        by_os.setdefault(os, set()).add(key)
    out = {}
    for os, keys in by_os.items():
        plain = {k for k in keys if not k.endswith("-RC")}
        keys = {k for k in keys if not (k.endswith("-RC") and k[:-3] in plain)}
        newest = max(versions.train(versions.split_index_key(k)[1]) for k in keys)
        out[os] = sorted(k for k in keys if versions.train(versions.split_index_key(k)[1]) >= newest - 1)
    return out


def bootstrap_picks(keys: list[str], releases: int = 3, betas: int = 2) -> list[str]:
    """First sight of an OS: track only its newest few releases and betas. More than one of each,
    because the highest build number is sometimes a device-specific build with no images."""
    order = lambda k: versions.build_key(versions.split_index_key(k)[1])   # noqa: E731
    rel = sorted((k for k in keys if not versions.is_beta_build(versions.split_index_key(k)[1])), key=order)
    beta = sorted((k for k in keys if versions.is_beta_build(versions.split_index_key(k)[1])), key=order)
    return sorted(set(rel[-releases:]) | set(beta[-betas:]))


def build_record(doc: dict, devices: dict) -> dict:
    """A tracked build: its sources' fingerprint and the smallest set of images covering every chip."""
    usable, fp_material = [], []
    for s in doc.get("sources") or []:
        links = sorted([str(l.get("url")), bool(l.get("preferred")), bool(l.get("active", True))]
                       for l in s.get("links", []) if isinstance(l.get("url"), str))
        fp_material.append([s.get("type"), sorted(s.get("deviceMap") or []), links, s.get("prerequisiteBuild")])
        if s.get("type") not in ("ipsw", "ota") or s.get("prerequisiteBuild"):
            continue
        https = [l["url"] for l in s.get("links", []) if str(l.get("url", "")).startswith("https://")
                 and l.get("active", True)]
        https.sort(key=lambda u: (0 if any(l.get("preferred") and l["url"] == u for l in s["links"]) else 1, u))
        if not https or not s.get("deviceMap"):
            continue
        devs = sorted(s["deviceMap"])
        usable.append({"type": s["type"], "url": https[0], "devices": devs,
                       "chips": sorted({_chip_of(d, devices) for d in devs}),
                       "unsupported": "aea-encrypted" if https[0].lower().endswith(".aea") else None})
    usable.sort(key=lambda u: (0 if u["type"] == "ipsw" else 1, 1 if u["unsupported"] else 0, -len(u["chips"]), u["url"]))
    covered, candidates = set(), []
    for u in usable:
        if set(u["chips"]) - covered:
            covered |= set(u["chips"])
            device = "universal" if len(u["devices"]) > 8 else u["devices"][0]
            # The URL hash keeps two images that share a first device (or are both universal) apart.
            candidates.append({"id": f"{device}-{hashlib.sha256(u['url'].encode()).hexdigest()[:8]}",
                               "device": device, "url": u["url"], "type": u["type"], "chips": u["chips"],
                               "unsupported": u["unsupported"]})
    fp = hashlib.sha256(json.dumps(sorted(fp_material, key=json.dumps)).encode()).hexdigest()[:16]
    return {"key": doc["key"], "os": doc.get("osStr", ""), "build": doc.get("build", ""),
            "version": str(doc.get("version", "")), "beta": bool(doc.get("beta") or doc.get("rc")),
            "released": doc.get("released"), "track": True, "source_fp": fp,
            "candidates": sorted(candidates, key=lambda c: c["id"])}


def observe(client: Client, state: dict, config: dict, b, run_date: str, manifest_cap: int, kc_cap: int) -> None:
    fw = config["firmware"]

    def guard(key, fn):
        try:
            data = fn()
            b.snapshot(key, data)
            return data
        except FetchError as e:
            b.failed(key, e, "network" if e.retryable else "parse")
        except (ValueError, KeyError, TypeError) as e:
            b.failed(key, e, "parse")
        return None

    dm = guard("firmware:devices", lambda: device_map(client))
    devices = (dm or state["scopes"].get("firmware:devices", {}).get("data") or {}).get("devices", {})
    guard("firmware:kdk", lambda: kdk_targets(client))

    to_fetch = []
    for index, oses in fw["indexes"].items():
        try:
            raw = client.get_json(f"{APPLEDB}/ios/{index}/index.json", max_bytes=16 << 20)
            per_os = index_keys(raw, oses, fw["floor_train"].get(index, 0))
        except FetchError as e:
            for os in oses:
                b.failed(f"firmware:index:{os}", e, "network" if e.retryable else "parse")
            continue
        except (ValueError, TypeError) as e:
            for os in oses:
                b.failed(f"firmware:index:{os}", e, "parse")
            continue
        for os in oses:
            if os not in per_os:   # a schema change or partial outage must not leave the old index looking current
                b.failed(f"firmware:index:{os}", f"the {index} index lists no {os} builds in its newest trains", "parse")
        for os, keys in per_os.items():
            b.snapshot(f"firmware:index:{os}", {"keys": keys})
            prev = state["scopes"].get(f"firmware:index:{os}")
            new = sorted(set(keys) - set(prev["data"]["keys"])) if prev else bootstrap_picks(keys)
            to_fetch += [k for k in new if f"firmware:build:{k}" not in state["scopes"]]
    tracked = [k[len("firmware:build:"):] for k, s in state["scopes"].items()
               if k.startswith("firmware:build:") and s["data"].get("track")]
    window = {k for s in state["scopes"].values() if "keys" in s.get("data", {}) for k in s["data"]["keys"]}
    to_fetch += queue.rotation([k for k in tracked if k in window], run_date,
                               floor=config["limits"]["refetch_floor"], ceiling=config["limits"]["refetch_ceiling"])
    for key in sorted(set(to_fetch)):
        url = f"{APPLEDB}/ios/{urllib.parse.quote(key, safe=';,')}.json"
        guard(f"firmware:build:{key}", lambda url=url: build_record(client.get_json(url, max_bytes=32 << 20), devices))

    # Manifest work: the committed queue plus what this run's builds derive, scheduled deterministically.
    effective = statefile.clone(state)
    merge.apply(effective, b.doc, config, scratch=True)
    for wid in queue.schedule(effective, "manifest", manifest_cap, run_date):
        q = effective["queue"][wid]
        try:
            _, bm, prefix = manifest.read(client, q["url"])
            b.outcome(wid, q["source_fp"], "done", {
                "type": "manifest", "os": q["os"], "build": q["build"], "version": q["version"],
                "beta": q["beta"], "url": q["url"], "device": q["device"], "prefix": prefix,
                "rows": manifest.rows(bm)})
        except Unsupported as e:
            b.outcome(wid, q["source_fp"], "unsupported", error=str(e))
        except FetchError as e:
            b.outcome(wid, q["source_fp"], "retryable" if e.retryable else "unsupported", error=str(e))
    merge.apply(effective, b.doc, config, scratch=True)
    schedule_kernelcaches(effective, b, run_date, kc_cap)


def schedule_kernelcaches(state: dict, b, run_date: str, cap: int) -> None:
    for wid in queue.schedule(state, "kernelcache", cap, run_date):
        q = state["queue"][wid]
        b.doc["kernelcache_scheduled"].append({k: q[k] for k in ("url", "member", "source_fp", "os", "build",
                                                                 "version", "beta")} | {"work_id": wid})
