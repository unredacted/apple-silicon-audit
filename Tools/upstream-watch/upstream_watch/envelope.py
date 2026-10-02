"""Result envelopes: what one producer (job instance) observed in one run.

A producer writes exactly one envelope. The publish job validates every expected producer's
envelope; a missing or invalid one is a producer failure even when the job reported success.
"""
from __future__ import annotations

import json
import pathlib
import re

SCHEMA = 1
KINDS = {"snapshot", "producer-set", "outcome"}
SNAPSHOT_STATUS = {"ok", "failed"}
OUTCOME_STATUS = {"done", "retryable", "unsupported"}
ERROR_KINDS = {"network", "parse"}
_PRODUCER = re.compile(r"^(observe|kernelcache|headers@[A-Za-z0-9._-]{1,40})$")
_APP_ID = re.compile(r"^\d+\.\d+\.[A-Za-z0-9@._-]+$")
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_KEY = re.compile(r"^[A-Za-z0-9@._:;,/ +()-]{1,300}$")


class Builder:
    """Collects one producer's scope results."""

    def __init__(self, producer: str, run_id: str, run_attempt: str, run_date: str):
        self.doc = {"schema": SCHEMA, "producer": producer,
                    "application_id": f"{run_id}.{run_attempt}.{producer}", "run_date": run_date,
                    "scopes": [], "kernelcache_scheduled": []}

    def snapshot(self, key: str, data) -> None:
        self.doc["scopes"].append({"key": key, "kind": "snapshot", "status": "ok", "data": data})

    def failed(self, key: str, error: str, kind: str = "network") -> None:
        self.doc["scopes"].append({"key": key, "kind": "snapshot", "status": "failed",
                                   "error_kind": kind, "error": str(error)[:300]})

    def producer_set(self, key: str, members: list[str]) -> None:
        self.doc["scopes"].append({"key": key, "kind": "producer-set", "status": "ok", "members": sorted(members)})

    def outcome(self, work_id: str, source_fp: str, status: str, data=None, error: str = "") -> None:
        scope = {"key": f"work:{work_id}", "kind": "outcome", "work_id": work_id, "source_fp": source_fp,
                 "status": status}
        if data is not None:
            scope["data"] = data
        if error:
            scope["error"] = str(error)[:300]
        self.doc["scopes"].append(scope)

    def write(self, directory: pathlib.Path) -> pathlib.Path:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{self.doc['producer'].replace('@', '_')}.json"
        path.write_text(json.dumps(self.doc, indent=1, sort_keys=True))
        return path


def validate(doc, producer: str | None = None) -> str | None:
    """None when `doc` is a well-formed envelope (for `producer`, if given); else the reason."""
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return "not a schema-1 envelope"
    p = doc.get("producer")
    if not isinstance(p, str) or not _PRODUCER.match(p):
        return f"bad producer {p!r}"
    if producer is not None and p != producer:
        return f"producer {p!r} where {producer!r} was expected"
    if not isinstance(doc.get("application_id"), str) or not _APP_ID.match(doc["application_id"]) \
            or not doc["application_id"].endswith("." + p):
        return "bad application_id"
    if not isinstance(doc.get("run_date"), str) or not _DATE.match(doc["run_date"]):
        return "bad run_date"
    if not isinstance(doc.get("scopes"), list) or not isinstance(doc.get("kernelcache_scheduled", []), list):
        return "bad scopes"
    for s in doc["scopes"]:
        if not isinstance(s, dict) or s.get("kind") not in KINDS or not isinstance(s.get("key"), str) \
                or not _KEY.match(s["key"]):
            return f"bad scope {str(s)[:80]}"
        if s["kind"] == "snapshot":
            if s.get("status") not in SNAPSHOT_STATUS:
                return f"bad status in {s['key']}"
            if s["status"] == "ok" and "data" not in s:
                return f"no data in {s['key']}"
            if s["status"] == "failed" and s.get("error_kind") not in ERROR_KINDS:
                return f"bad error_kind in {s['key']}"
        elif s["kind"] == "producer-set":
            if not isinstance(s.get("members"), list) or not all(isinstance(m, str) for m in s["members"]):
                return f"bad members in {s['key']}"
        else:
            if s.get("status") not in OUTCOME_STATUS or not isinstance(s.get("work_id"), str) \
                    or not isinstance(s.get("source_fp"), str):
                return f"bad outcome {s['key']}"
            if s["status"] == "done" and "data" not in s:
                return f"no data in {s['key']}"
    return None


def load(directory: pathlib.Path, producer: str):
    """(envelope, None) or (None, reason) for `producer`'s artifact in `directory`."""
    path = directory / f"{producer.replace('@', '_')}.json"
    if not path.exists():
        return None, "artifact missing"
    try:
        doc = json.loads(path.read_text())
    except (ValueError, OSError) as e:
        return None, f"artifact unreadable: {e}"
    reason = validate(doc, producer)
    return (None, f"artifact invalid: {reason}") if reason else (doc, None)


def producer_detector(producer: str) -> str:
    return producer.split("@", 1)[0]
