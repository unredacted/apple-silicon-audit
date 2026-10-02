"""The app's bundled data files and the community results, as the watcher compares against them."""
from __future__ import annotations

import json
import pathlib
import re

from . import versions

RESOURCES = pathlib.Path("Sources/SiliconAuditCore/Resources")
_RESULT_KEY = re.compile(r"^hw\.[A-Za-z0-9_.]+$")


class Data:
    def __init__(self, root: pathlib.Path):
        res = root / RESOURCES
        load = lambda name: json.loads((res / name).read_text())   # noqa: E731
        self.known_keys = load("known-keys.json")
        self.caps_bits = load("caps-bits.json")
        self.cpufamily = load("cpufamily-names.json")
        self.matrix = load("documented-matrix.json")
        self.soc_map = load("soc-map.json")
        self.root = root

    # known-keys
    def keys(self) -> set[str]:
        return {e["key"] for e in self.known_keys["entries"]}

    def leaves(self) -> set[str]:
        return {e["key"].rsplit(".", 1)[-1] for e in self.known_keys["entries"]}

    # caps-bits / cpufamily
    def cap_bit_nb(self) -> int:
        return self.caps_bits["cap_bit_nb"]

    def cap_bits(self) -> dict[str, int]:
        return {e["name"]: e["bit"] for e in self.caps_bits["entries"]}

    def cpufamily_names(self) -> set[str]:
        return {e["name"] for e in self.cpufamily["entries"]}

    def cpufamily_values(self) -> set[str]:
        return {e["value"] for e in self.cpufamily["entries"]}

    def cpusubfamily_names(self) -> set[str]:
        return {e["name"] for e in self.cpufamily.get("subfamilies", [])}

    # soc-map
    def soc(self, soc_id: str) -> dict | None:
        return next((e for e in self.soc_map["entries"] if e["soc_id"] == soc_id), None)

    def soc_ids(self) -> set[str]:
        return {e["soc_id"] for e in self.soc_map["entries"]}

    # documented-matrix
    def entry(self, entry_id: str) -> dict:
        return next(e for e in self.matrix["entries"] if e["id"] == entry_id)

    def documented(self, entry_id: str, soc_id: str, os_version: str | None) -> tuple[str, dict | None]:
        """What the app shows for `entry_id` on this chip and OS: ("present" | "not_present" |
        "unknown", the exception that applied or None). Mirrors DocumentedMatrix.facts."""
        e = self.entry(entry_id)
        for ex in e.get("exceptions", []):
            if soc_id in ex["soc_ids"] and versions.at_least(os_version, ex["min_os_version"]):
                return "unknown", ex
        soc = self.soc(soc_id)
        if soc is None or soc["security_guide_column"] not in self.matrix["columns"]:
            return "unknown", None
        return ("present" if soc["security_guide_column"] in e["columns_present"] else "not_present"), None

    def exception_for(self, entry_id: str, soc_id: str) -> dict | None:
        return next((ex for ex in self.entry(entry_id).get("exceptions", []) if soc_id in ex["soc_ids"]), None)

    # results/
    def results(self) -> list[tuple[str, dict]]:
        out = []
        for path in sorted((self.root / "results").glob("*/*.json")):
            try:
                out.append((str(path.relative_to(self.root)), json.loads(path.read_text())))
            except (ValueError, OSError):
                continue   # results.yml validates these; a broken file is not the watcher's finding
        return out

    def result_unrecognized_keys(self) -> dict[str, list[str]]:
        """key → result files that report it, for keys the inventory does not annotate."""
        known, found = self.keys(), {}
        for rel, doc in self.results():
            for fact in doc.get("unrecognized_keys", []):
                key = (fact.get("raw") or {}).get("key", "")
                if _RESULT_KEY.match(key) and key not in known:
                    found.setdefault(key, []).append(rel)
        return found
