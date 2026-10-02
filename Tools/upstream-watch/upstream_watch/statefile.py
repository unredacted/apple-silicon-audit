"""Committed watcher state: one deterministic JSON file per section, no per-run metadata.

Writing the same state twice produces byte-identical files, so a run that learned nothing new
leaves git clean and makes no commit.
"""
from __future__ import annotations

import copy
import json
import pathlib

SCHEMA = 1
SECTIONS = ("scopes", "evidence", "queue", "health", "events", "applied", "heartbeat")


def dumps(obj) -> str:
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def empty() -> dict:
    return {"scopes": {}, "evidence": {}, "queue": {}, "health": {}, "events": {}, "applied": [], "heartbeat": {}}


def load(directory: pathlib.Path) -> dict:
    state = empty()
    for section in SECTIONS:
        path = directory / f"{section}.json"
        if path.exists():
            doc = json.loads(path.read_text())
            if doc.get("schema") != SCHEMA:
                raise ValueError(f"{path}: unsupported schema {doc.get('schema')!r}")
            state[section] = doc["data"]
    return state


def save(directory: pathlib.Path, state: dict) -> list[str]:
    """Write every section; returns the names of files whose bytes changed."""
    directory.mkdir(parents=True, exist_ok=True)
    changed = []
    for section in SECTIONS:
        path = directory / f"{section}.json"
        text = dumps({"schema": SCHEMA, "data": state[section]})
        if not path.exists() or path.read_text() != text:
            path.write_text(text)
            changed.append(path.name)
    return changed


def snapshot(state: dict) -> str:
    """A canonical string for change detection."""
    return dumps(state)


def clone(state: dict) -> dict:
    return copy.deepcopy(state)
