"""Detector health, per producer and per scope.

An item clears only when its own producer or scope reports success again, so one runner's success
never hides another runner's failure. Counters advance at most once per application id: callers pass
`replay=True` when the envelope was already applied.
"""
from __future__ import annotations

IMMEDIATE = {"parse", "artifact", "coverage", "retries", "backlog"}


def detector_of(item_id: str) -> str:
    """"producer/headers@xcode-27" → headers; "scope/firmware:index:iOS" → firmware;
    "scope/work:manifest:…" → firmware; "scope/work:kc:…" → kernelcache."""
    kind, _, rest = item_id.partition("/")
    if kind == "producer":
        return rest.split("@", 1)[0]
    if rest.startswith("work:kc:"):
        return "kernelcache"
    if rest.startswith("work:"):
        return "firmware"
    return rest.split("@", 1)[0].split(":", 1)[0].split("/", 1)[0]


def fail(state: dict, item_id: str, kind: str, error: str, run_date: str, *, replay: bool, threshold: int) -> None:
    if replay:
        return
    rec = state["health"].setdefault(item_id, {"count": 0, "open": False, "since": run_date})
    rec["count"] += 1
    rec["kind"] = kind
    rec["error"] = str(error)[:200]
    if kind in IMMEDIATE or rec["count"] >= threshold:
        rec["open"] = True


def flag(state: dict, item_id: str, kind: str, error: str, run_date: str) -> None:
    """Open a condition that is not a counter (missing coverage, a stuck queue). Idempotent."""
    rec = state["health"].setdefault(item_id, {"count": 0, "open": True, "since": run_date})
    rec.update({"kind": kind, "error": str(error)[:200], "open": True})


def clear(state: dict, item_id: str) -> None:
    state["health"].pop(item_id, None)


def clear_prefix(state: dict, prefix: str) -> None:
    for key in [k for k in state["health"] if k.startswith(prefix)]:
        del state["health"][key]


def open_items(state: dict) -> dict[str, dict]:
    return {k: v for k, v in state["health"].items() if v.get("open")}
