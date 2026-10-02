"""Compare what the detectors saw with the app's data files on main.

Pure and offline. Findings come from committed evidence, which a failed or skipped producer never
changes, so an item can only disappear when the data on main covers it, a fresh observation no
longer shows it, or a human adds it to config/ignore.json.

A topic is one GitHub issue: a gap topic per data file, one per upstream event, one per detector's
health. Each item has `material` fields (hashed: a change posts a comment) and `evidence` fields
(shown but not hashed: a change only edits the body).
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import pathlib

from . import health, versions
from .datafiles import Data

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "gen-data"))
from sdk_headers import SECURITY_HINT  # noqa: E402

GUIDE_URL = "https://support.apple.com/guide/security/operating-system-integrity-sec8b776536b/web"
ITEM_KEY = re.compile(r"^[A-Za-z0-9_.@;+/-]{1,160}$")


def item_hash(material: dict) -> str:
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()[:8]


def slug(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-")[:60] or "x"


class Topic:
    def __init__(self, fp: str, kind: str, title: str, labels: list[str], columns: list[str], guidance: list[str]):
        self.fp, self.kind, self.title = fp, kind, title
        self.labels = set(labels)
        self.columns = columns
        self.guidance = guidance
        self.items: dict[str, dict] = {}
        self.ignored: dict[str, dict] = {}
        self.event_id = None

    def add(self, key: str, material: dict, row: dict, labels=(), evidence=None) -> None:
        if not ITEM_KEY.match(key):
            key = slug(key)
        item = self.items.setdefault(key, {"material": material, "row": row, "evidence": evidence or {}})
        item["row"].update({k: v for k, v in row.items() if v})
        self.labels.update(labels)

    def hashes(self) -> dict[str, str]:
        return {k: item_hash(v["material"]) for k, v in self.items.items()}


# ---------------------------------------------------------------------------- guidance (static)
G_SPTM = [
    "A booted image shows that the monitor runs, not what it guarantees. To cover a chip, add it to "
    "`SPTM_FIRMWARE` in `Tools/gen-data/generate.py` with the first build seen, regenerate the matrix, "
    "and record the evidence in `docs/evidence/sptm-txm-firmware.md`.",
    "`overbroad` means an exception applies but the firmware lacks SPTM; `missing` means Apple's table "
    "says present but the firmware lacks it; `early` means SPTM appears before the exception's "
    "`min_os_version`; `platform-divergence` means the same chip differs between OSes in one release "
    "(exceptions have no platform field).",
]
G_SOC = [
    "`chip id` items come from restore manifests (ApChipID); `kernel target` items from kern.version "
    "strings (KDK, kernelcache banners, results). soc-map.json is keyed by kernel target; several chip "
    "ids can boot one shared kernel.",
    "ReportTests and TopicTests use T8320 as their example of an unmapped SoC; change those fixtures "
    "when mapping it.",
]
G_CAPS = [
    "Bumping `cap_bit_nb` breaks `ReportTests` (capBitNB == 92), `LiveKernelTests` (caps buffer >= "
    "(capBitNB+7)/8 bytes) and `CapsDecoder.covers()` on kernels that return a shorter buffer "
    "(macOS 26 returns 12 bytes). Decide how shorter buffers decode before regenerating.",
]
G_CPUFAMILY = ["Regenerate with `python3 Tools/gen-data/generate.py --only cpufamily-names` using the SDK named here."]
G_KEYS = [
    "Curate each key in `Tools/gen-data/generate.py` by hand. The default annotation marks a key "
    "`isa_misc` and not security-relevant, which would hide it from the app's headline sections; "
    "names flagged as possibly security-relevant need a real description first.",
]
G_KC = [
    "Heuristic: a name in the kernel's strings is not proof that the sysctl is registered. Wait for a "
    "device result or XNU source before curating, or add the token to config/ignore.json.",
]
G_GUIDE = [
    "Re-read the table on the page, update `matrix()` in `Tools/gen-data/generate.py`, bump `VERIFIED`, "
    "and regenerate with `--only documented-matrix`. Columns and rows map through config/watch.json.",
]
G_EVENT = ["Read the change, then close this issue. If it affects a documented claim, open a PR."]
G_HEALTH = [
    "A detector could not observe something. Earlier evidence is kept and no findings were closed "
    "because of it. Items clear when the same producer or scope succeeds again.",
]


def _sptm(topic: Topic, data: Data, state: dict, ignore_exceptions: bool, covered: list, refs: set) -> None:
    sptm_cols = set(data.entry("sptm")["columns_present"])
    seen: dict[tuple, list] = {}
    for ekey, ev in state["evidence"].items():
        d = ev["data"]
        if d.get("type") != "manifest":
            continue
        for r in d["rows"]:
            seen.setdefault((r["chip"], d["os"]), []).append(
                (versions.build_key(versions.split_index_key(d["build"])[1]), d, bool(r["sptm"]), bool(r["txm"]), ekey))
    by_release: dict[tuple, set] = {}
    for (chip, os), obs in sorted(seen.items()):
        soc = data.soc(chip)
        if soc is None:
            continue   # not evaluable; the soc-map topic reports the chip
        table_present = soc["security_guide_column"] in sptm_cols
        ex = None if ignore_exceptions else data.exception_for("sptm", chip)
        for _, d, sptm, txm, ekey in sorted(obs, key=lambda o: o[0]):
            applies = ex is not None and versions.at_least(d["version"], ex["min_os_version"])
            label = f"{d['version']} ({versions.split_index_key(d['build'])[1]}{', beta' if d['beta'] else ''})"
            kinds = []
            if sptm and not table_present:
                if applies:
                    covered.append(f"{chip} {os} {label}: exception from {ex['min_os_version']}")
                    refs.add(ekey)
                else:
                    kinds.append("early" if ex else "uncovered")
            if not sptm and applies:
                kinds.append("overbroad")
            if not sptm and table_present:
                kinds.append("missing")
            if sptm != txm:
                kinds.append("txm-mismatch")
            if not d["beta"]:   # versions are shared across OSes since 26, so one release compares
                by_release.setdefault((chip, d["version"]), set()).add((os, sptm))
            for kind in kinds:
                refs.add(ekey)
                key = f"{kind}/{chip}/{os}"
                item = topic.items.get(key)
                if item is None:
                    topic.add(key, {"kind": kind, "chip": chip, "os": os, "first": label},
                              {"chip": f"{chip} ({soc['soc_name']})", "os": os, "first seen": label,
                               "app shows": data.documented("sptm", chip, d["version"])[0]}, ["watch:firmware"])
                else:
                    item["row"]["latest"] = label
    for (chip, version), pairs in sorted(by_release.items()):
        with_ = sorted({o for o, s in pairs if s})
        without = sorted({o for o, s in pairs if not s})
        if with_ and without:
            topic.add(f"platform-divergence/{chip}/{version}", {"kind": "platform-divergence", "chip": chip,
                      "version": version, "with": with_, "without": without},
                      {"chip": chip, "os": f"SPTM on {', '.join(with_)}; not on {', '.join(without)}",
                       "first seen": version}, ["watch:firmware"])


def _soc_map(topic: Topic, data: Data, state: dict, config: dict) -> None:
    ignore = set(config.get("chip_ignore", []))
    known = data.soc_ids()
    socs = (state["scopes"].get("firmware:devices", {}).get("data") or {}).get("socs", {})
    found: dict[str, set] = {}
    for ev in state["evidence"].values():
        d = ev["data"]
        if d.get("type") == "manifest":
            for r in d["rows"]:
                found.setdefault(r["chip"], set()).add("chip id (restore manifest)")
        elif d.get("type") == "kernelcache" and d.get("target"):
            found.setdefault(d["target"], set()).add("kernel target (kernelcache)")
    for t in (state["scopes"].get("firmware:kdk", {}).get("data") or {}).get("targets", []):
        found.setdefault(t, set()).add("kernel target (KDK)")
    for rel, doc in data.results():
        soc = (doc.get("device") or {}).get("soc_id")
        if isinstance(soc, str) and re.match(r"^T\d{4,5}$", soc):
            found.setdefault(soc, set()).add("kernel target (result)")
    for chip, sources in sorted(found.items()):
        if chip in known or chip in ignore or not re.match(r"^T[0-9A-F]{4,5}$", chip):
            continue
        labels = ["watch:firmware"] + (["watch:results"] if any("result" in s for s in sources) else [])
        topic.add(f"chip/{chip}", {"chip": chip}, {"subject": chip, "upstream": ", ".join(socs.get(chip, [])) or "unknown",
                  "source": "; ".join(sorted(sources))}, labels)
    for e in data.soc_map["entries"]:
        names = socs.get(e["soc_id"], [])
        if e["confidence"] != "reported" or not names:
            continue
        have = e["soc_name"].lower()
        if not all(n.lower() in have for n in names):
            topic.add(f"name/{e['soc_id']}", {"chip": e["soc_id"], "upstream": names, "data": e["soc_name"]},
                      {"subject": e["soc_id"], "upstream": ", ".join(names), "source": f"soc-map says {e['soc_name']}"},
                      ["watch:firmware"])


def _header_sources(state: dict):
    """(label, data) for every SDK and the newest XNU tag."""
    for key, scope in sorted(state["scopes"].items()):
        if key.startswith("headers@") and ":" in key:
            for sdk in scope["data"].get("sdks", {}).values():
                yield f"{sdk['name']} SDK ({scope['data'].get('xcode', '')})", sdk, "watch:headers"
        elif key == "xnu:latest":
            yield f"XNU {scope['data']['tag']}", scope["data"], "watch:xnu"


def _caps_and_families(caps: Topic, fam: Topic, data: Data, state: dict) -> None:
    nb, bits = data.cap_bit_nb(), data.cap_bits()
    names, subs, values = data.cpufamily_names(), data.cpusubfamily_names(), data.cpufamily_values()
    highest = {}
    for label, src, lab in _header_sources(state):
        if src["cap_bit_nb"] > nb:
            highest.setdefault(src["cap_bit_nb"], []).append(label)
            caps.labels.add(lab)
        for name, bit in src["caps"].items():
            if bits.get(name) != bit:
                caps.add(f"bit/{bit}", {"bit": bit, "name": name}, {"subject": f"bit {bit}", "upstream": name,
                         "data": "absent" if name not in bits else f"bit {bits[name]}", "source": label}, [lab])
        for name, value in src["cpufamily"].items():
            if name not in names:
                fam.add(f"family/{name}", {"name": name, "value": value}, {"subject": name, "upstream": value,
                        "source": label}, [lab])
        for name, value in src["cpusubfamily"].items():
            if name not in subs:
                fam.add(f"subfamily/{name}", {"name": name, "value": value}, {"subject": name,
                        "upstream": str(value), "source": label}, [lab])
    if highest:
        top = max(highest)
        caps.add("nb", {"cap_bit_nb": top}, {"subject": "cap_bit_nb", "upstream": str(top), "data": str(nb),
                 "source": "; ".join(sorted(highest[top]))})
    for rel, doc in data.results():
        fam_value = (doc.get("device") or {}).get("cpufamily")
        if isinstance(fam_value, str) and re.match(r"^0x[0-9a-f]{8}$", fam_value) and fam_value not in values:
            fam.add(f"value/{fam_value}", {"value": fam_value}, {"subject": fam_value, "upstream": "measured",
                    "source": rel}, ["watch:results"])


def _keys(keys: Topic, kc: Topic, data: Data, state: dict) -> None:
    known, leaves = data.keys(), data.leaves()

    def add(key, source, label):
        leaf = key.rsplit(".", 1)[-1]
        hint = "possibly security-relevant" if SECURITY_HINT.search(leaf) else ""
        item = keys.items.get(f"key/{key}")
        if item:
            item["row"]["source"] = "; ".join(sorted(set(item["row"]["source"].split("; ")) | {source}))
            keys.labels.add(label)
        else:
            keys.add(f"key/{key}", {"key": key}, {"subject": key, "note": hint, "source": source}, [label])

    for key, files in sorted(data.result_unrecognized_keys().items()):
        add(key, "measured: " + ", ".join(files), "watch:results")
    xnu = state["scopes"].get("xnu:latest")
    if xnu:
        for name in xnu["data"]["arm_features"]:
            key = f"hw.optional.arm.{name}"
            if key not in known:
                add(key, f"XNU {xnu['data']['tag']}", "watch:xnu")
    for ev in sorted(state["evidence"].values(), key=lambda e: e["work_id"]):
        d = ev["data"]
        if d.get("type") != "kernelcache":
            continue
        where = f"kernelcache {d['os']} {d['version']} ({versions.split_index_key(d['build'])[1]})"
        for token in d["tokens"]:
            if token in leaves:
                continue
            key = f"hw.optional.arm.{token}"
            if f"key/{key}" in keys.items:
                add(key, where, "watch:kernelcache")
            else:
                item = kc.items.get(f"token/{token}")
                if item:
                    item["row"]["source"] = "; ".join(sorted(set(item["row"]["source"].split("; ")) | {where}))
                else:
                    kc.add(f"token/{token}", {"token": token}, {"subject": token,
                           "note": "possibly security-relevant" if SECURITY_HINT.search(token) else "",
                           "source": where}, ["watch:kernelcache"])


def _guide(topic: Topic, data: Data, state: dict, config: dict) -> None:
    scope = state["scopes"].get("docs:guide")
    if not scope:
        return
    g, cols, rows = scope["data"], config["guide"]["columns"], config["guide"]["rows"]
    unknown_cols = [c for c in g["columns"] if c not in cols]
    if unknown_cols:
        topic.add("columns", {"columns": g["columns"]}, {"subject": "columns", "upstream": " / ".join(g["columns"]),
                  "data": "unmapped: " + ", ".join(unknown_cols)})
    for label, cells in g["rows"].items():
        entry_id = rows.get(label)
        if entry_id is None:
            topic.add(f"row/{slug(label)}", {"row": label}, {"subject": label, "upstream": "new row", "data": "unmapped"})
            continue
        present = set(data.entry(entry_id)["columns_present"])
        for printed, cell in zip(g["columns"], cells):
            for col in cols.get(printed, []):
                if (cell[0] == "Y") != (col in present):
                    topic.add(f"cell/{entry_id}/{col}", {"entry": entry_id, "column": col, "guide": cell[0]},
                              {"subject": f"{entry_id} / {col}", "upstream": "✓" if cell[0] == "Y" else "✗",
                               "data": "present" if col in present else "not present"})
    published = {e["source"]["published"] for e in data.matrix["entries"] if e["source"]["url"] == GUIDE_URL}
    if published and g["published"] not in published:
        topic.add("published", {"published": g["published"]}, {"subject": "Published Date",
                  "upstream": g["published"], "data": ", ".join(sorted(published))})


def prune(state: dict, refs: set) -> None:
    """Retention. Builds that left every OS's two-train window go, with their finished work. Evidence
    goes only when its build left the window, no current finding references it, and it is not a
    boundary record (the last build of a chip and OS without SPTM, or the first with it)."""
    indexed_os = {k[len("firmware:index:"):] for k in state["scopes"] if k.startswith("firmware:index:")}
    window = {k for key, s in state["scopes"].items() if key.startswith("firmware:index:") for k in s["data"]["keys"]}
    gone = lambda build: versions.split_index_key(build)[0] in indexed_os and build not in window  # noqa: E731
    boundary, firsts = set(), {}
    for ekey, ev in state["evidence"].items():
        d = ev["data"]
        if d.get("type") != "manifest":
            continue
        order = versions.build_key(versions.split_index_key(d["build"])[1])
        for r in d["rows"]:
            slot = firsts.setdefault((r["chip"], d["os"], bool(r["sptm"])), [])
            slot.append((order, ekey))
    for (chip, os, has), recs in firsts.items():
        recs.sort()
        boundary.add(recs[0][1] if has else recs[-1][1])
    for ekey in [k for k, ev in state["evidence"].items()
                 if gone(ev["data"]["build"]) and k not in refs and k not in boundary]:
        del state["evidence"][ekey]
    for key in [k for k in state["scopes"] if k.startswith("firmware:build:") and gone(k[len("firmware:build:"):])]:
        del state["scopes"][key]
    for wid in [w for w, q in state["queue"].items() if gone(q["build"]) and q["status"] in ("done", "unsupported")
                and q.get("evidence") not in state["evidence"]]:
        del state["queue"][wid]


EVENT_TITLES = {
    "guide-pdf": "Platform Security guide PDF changed",
    "guide-revisions": "Platform Security guide revision history: {title}",
    "security-blog": "Apple Security Research post: {title}",
    "guide-footnotes": "Platform Security runtime-protection footnotes changed",
}


def reconcile(state: dict, data: Data, config: dict, ignore: dict, *, ignore_exceptions: bool = False) -> dict:
    """{"topics": {fp: Topic}, "covered": [...], "refs": evidence keys still needed}."""
    gap = lambda fp, title, label, cols, guide: Topic(fp, "gap", title, ["watch", label], cols, guide)  # noqa: E731
    sptm = gap("v1:gap/sptm", "Firmware boots SPTM/TXM where documented-matrix.json disagrees", "watch:firmware",
               ["chip", "os", "first seen", "latest", "app shows"], G_SPTM)
    soc = gap("v1:gap/soc-map", "soc-map.json is missing chips or names seen upstream", "watch:firmware",
              ["subject", "upstream", "source"], G_SOC)
    caps = gap("v1:gap/caps-bits", "caps-bits.json is behind the SDK or XNU headers", "watch:headers",
               ["subject", "upstream", "data", "source"], G_CAPS)
    fam = gap("v1:gap/cpufamily", "cpufamily-names.json is behind the SDK or XNU headers", "watch:headers",
              ["subject", "upstream", "source"], G_CPUFAMILY)
    keys = gap("v1:gap/known-keys", "known-keys.json lacks keys seen in results, XNU or kernelcaches",
               "watch:results", ["subject", "note", "source"], G_KEYS)
    kc = Topic("v1:gap/kernelcache", "gap", "Kernelcache strings name features known-keys.json lacks (heuristic)",
               ["watch", "watch:kernelcache", "heuristic"], ["subject", "note", "source"], G_KC)
    guide = gap("v1:gap/guide-table", "Apple's Platform Security table differs from documented-matrix.json",
                "watch:docs", ["subject", "upstream", "data"], G_GUIDE)
    covered, refs = [], set()
    _sptm(sptm, data, state, ignore_exceptions, covered, refs)
    _soc_map(soc, data, state, config)
    _caps_and_families(caps, fam, data, state)
    _keys(keys, kc, data, state)
    _guide(guide, data, state, config)
    topics = [sptm, soc, caps, fam, keys, kc, guide]

    for eid, ev in sorted(state["events"].items()):
        title = EVENT_TITLES[ev["kind"]].format(title=str(ev["data"].get("title", "")) if isinstance(ev["data"], dict) else "")
        t = Topic(eid, "event", title, ["watch", "watch:docs"], ["subject", "upstream"], G_EVENT)
        t.event_id = eid
        d = ev["data"]
        if ev["kind"] == "security-blog":
            t.add("event", {"link": d["link"]}, {"subject": d["title"], "upstream": d["link"]})
        elif ev["kind"] == "guide-revisions":
            t.add("event", d, {"subject": d["title"], "upstream": "section " + d["id"]})
        else:
            t.add("event", d, {"subject": ev["kind"], "upstream": "changed; see the guide"})
        topics.append(t)

    by_detector: dict[str, Topic] = {}
    for item_id, rec in sorted(health.open_items(state).items()):
        det = health.detector_of(item_id)
        t = by_detector.setdefault(det, Topic(f"v1:health/{det}", "health",
                                              f"Upstream watcher: the {det} detector needs attention",
                                              ["watch", f"watch:{det}", "watch:health"], ["subject", "kind", "since", "error"],
                                              G_HEALTH))
        t.add(item_id, {"item": item_id, "kind": rec["kind"]},
              {"subject": item_id, "kind": rec["kind"], "since": rec["since"], "error": rec.get("error", "")})
    topics += [by_detector[d] for d in sorted(by_detector)]

    for t in topics:
        for key in [k for k in t.items if f"{t.fp}#{k}" in ignore]:
            t.ignored[key] = ignore[f"{t.fp}#{key}"]
            del t.items[key]
    return {"topics": {t.fp: t for t in topics}, "covered": sorted(set(covered)), "refs": refs}
