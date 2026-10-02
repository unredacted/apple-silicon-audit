"""One-off upstream events (the guide's PDF revised, a revision-history entry, a blog post).

An event is detected when a snapshot changes, recorded as `pending` in the same commit as the
snapshot, and marked `published` only after its issue is confirmed. Its id is a hash of its content,
so detecting it again (a retried merge) is a no-op, and it doubles as the issue fingerprint.
"""
from __future__ import annotations

import hashlib
import json

from . import versions

KEEP_PUBLISHED_DAYS = 30


def event_id(kind: str, content) -> str:
    digest = hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()[:12]
    return f"v1:event/{kind}/{digest}"


def _add(state: dict, kind: str, content, run_date: str) -> None:
    eid = event_id(kind, content)
    state["events"].setdefault(eid, {"kind": kind, "data": content, "status": "pending", "issue": None,
                                     "detected": run_date, "published_on": None})


def detect(state: dict, key: str, old, new, run_date: str) -> None:
    """Compare a docs snapshot with its previous value. No previous value means a first baseline."""
    if old is None:
        return
    if key == "docs:pdf" and old != new:
        _add(state, "guide-pdf", {"before": old, "after": new}, run_date)
    elif key == "docs:revisions":
        before = {s["id"]: s for s in old.get("sections", [])}
        for s in new.get("sections", []):
            if before.get(s["id"]) != s:
                _add(state, "guide-revisions", s, run_date)
    elif key == "docs:blog":
        seen = {i["link"] for i in old.get("items", [])}
        for item in new.get("items", []):
            if item["link"] not in seen:
                _add(state, "security-blog", item, run_date)
    elif key == "docs:guide" and old.get("footnotes") != new.get("footnotes"):
        _add(state, "guide-footnotes", {"before": old.get("footnotes"), "after": new.get("footnotes")}, run_date)


def acknowledge(state: dict, eid: str, issue: int, run_date: str) -> None:
    ev = state["events"].get(eid)
    if ev and ev["status"] != "published":
        ev.update({"status": "published", "issue": issue, "published_on": run_date})


def prune(state: dict, run_date: str) -> None:
    for eid in [e for e, ev in state["events"].items() if ev["status"] == "published"
                and versions.add_days(ev["published_on"], KEEP_PUBLISHED_DAYS) < run_date]:
        del state["events"][eid]
