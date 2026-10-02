"""Durable work queues: manifest reads and kernelcache extractions.

Discovery creates `pending` items; only an applied outcome changes an item's status, so a crashed
or capped run leaves its work for the next one. Scheduling is a pure function of the state and the
run date. Backoff is expressed in dates, never in counters that would change on every run.
"""
from __future__ import annotations

import math

from . import health, versions

BACKOFF_DAYS = (1, 2, 4, 8)
MAX_ATTEMPTS = 5
BACKLOG_DAYS = 7


def _build_order(q: dict):
    t, letter, num, suffix = versions.build_key(versions.split_index_key(q["build"])[1])
    return (-t, -ord(letter or " "), -num, -(ord(suffix) if suffix else 0))


def priority(chips, representatives, beta: bool) -> list[int]:
    return [0 if set(chips) & set(representatives) else 1, 1 if beta else 0]


_REFRESH = ("url", "device", "chips", "version", "beta", "source_fp", "priority")


def derive_manifests(state: dict, config: dict, run_date: str) -> None:
    """Queue a manifest read for every candidate of every tracked build.

    - Unfinished work is replaced when anything about its candidate or build changed (a new URL, a
      corrected version, a changed source fingerprint), so it never runs with stale metadata.
    - Finished work keeps its evidence (the manifest of one build does not change), but a corrected
      version or beta flag is carried into the queue entry and its evidence record.
    - Unfinished work whose candidate disappeared is dropped."""
    reps = set(config["kernelcache"]["representatives"].values())
    for key, scope in state["scopes"].items():
        if not key.startswith("firmware:build:") or not scope["data"].get("track"):
            continue
        b = scope["data"]
        wanted = {}
        for c in b["candidates"]:
            wid = f"manifest:{b['key']};{c.get('id', c['device'])}"
            wanted[wid] = ({"kind": "manifest", "build": b["key"], "os": b["os"], "version": b["version"],
                            "beta": b["beta"], "url": c["url"], "device": c["device"], "chips": c["chips"],
                            "source_fp": b["source_fp"], "priority": priority(c["chips"], reps, b["beta"])},
                           c.get("unsupported"))
        for wid, (base, unsupported) in wanted.items():
            q = state["queue"].get(wid)
            fresh = {**base, "status": "unsupported" if unsupported else "pending", "reason": unsupported,
                     "attempts": 0, "not_before": None, "evidence": None}
            if q is None:
                state["queue"][wid] = {**fresh, "discovered": run_date}
            elif q["status"] != "done":
                if any(q.get(f) != base[f] for f in _REFRESH):
                    state["queue"][wid] = {**fresh, "discovered": q["discovered"]}
            elif (q["version"], q["beta"]) != (base["version"], base["beta"]):
                q.update(version=base["version"], beta=base["beta"])
                ev = state["evidence"].get(q.get("evidence") or "")
                if ev:
                    ev["data"] = {**ev["data"], "version": base["version"], "beta": base["beta"]}
        for wid in [w for w, q in state["queue"].items()
                    if q["kind"] == "manifest" and q["build"] == b["key"] and w not in wanted and q["status"] != "done"]:
            del state["queue"][wid]


def derive_kernelcaches(state: dict, config: dict, run_date: str) -> None:
    """Queue one kernelcache extraction per build whose manifest includes the OS's representative chip."""
    reps = config["kernelcache"]["representatives"]
    for ev in state["evidence"].values():
        d = ev["data"]
        if d.get("type") != "manifest" or d["os"] not in reps:
            continue
        paths = sorted({r["kernelcache"] for r in d["rows"] if r["chip"] == reps[d["os"]] and r.get("kernelcache")},
                       key=lambda p: (0 if "release" in p else 1, p))
        wid = f"kc:{d['build']}"
        if not paths or wid in state["queue"]:
            continue
        state["queue"][wid] = {"kind": "kernelcache", "build": d["build"], "os": d["os"], "version": d["version"],
                               "beta": d["beta"], "url": d["url"], "member": d.get("prefix", "") + paths[0], "chips": [reps[d["os"]]],
                               "source_fp": ev["source_fp"], "priority": [0, 1 if d["beta"] else 0],
                               "status": "pending", "reason": None, "attempts": 0, "not_before": None,
                               "evidence": None, "discovered": run_date}


def schedule(state: dict, kind: str, cap: int, run_date: str) -> list[str]:
    eligible = [(wid, q) for wid, q in state["queue"].items() if q["kind"] == kind and (
        q["status"] == "pending" or (q["status"] == "retryable" and (q["not_before"] or "") <= run_date))]
    eligible.sort(key=lambda wq: (wq[1]["priority"], _build_order(wq[1]), wq[0]))
    return [wid for wid, _ in eligible[:cap]]


def apply_outcome(state: dict, scope: dict, run_date: str, *, replay: bool) -> None:
    wid = scope["work_id"]
    q = state["queue"].get(wid)
    if q is None:
        return   # superseded since it was scheduled
    if scope["status"] == "done":
        ekey = f"{wid}@{scope['source_fp']}"
        old = state["evidence"].get(ekey)
        if old is None or old["data"] != scope["data"]:
            state["evidence"][ekey] = {"work_id": wid, "source_fp": scope["source_fp"], "data": scope["data"],
                                       "first_seen": old["first_seen"] if old else run_date, "changed_on": run_date}
        q.update({"status": "done", "evidence": ekey, "attempts": 0, "not_before": None, "reason": None})
        health.clear(state, f"scope/work:{wid}")
    elif scope["status"] == "unsupported":
        q.update({"status": "unsupported", "reason": scope.get("error", "unsupported")[:120],
                  "source_fp": scope["source_fp"], "not_before": None})
    else:   # retryable: earlier done evidence, if any, stays where it is
        if q["status"] == "done" or replay:
            return
        q["attempts"] += 1
        q["status"] = "retryable"
        q["not_before"] = versions.add_days(run_date, BACKOFF_DAYS[min(q["attempts"], len(BACKOFF_DAYS)) - 1])
        if q["attempts"] >= MAX_ATTEMPTS:
            health.flag(state, f"scope/work:{wid}", "retries",
                        f"{q['attempts']} failed attempts; last: {scope.get('error', '')}", run_date)


def check_backlog(state: dict, run_date: str) -> None:
    for kind in ("manifest", "kernelcache"):
        oldest = min((q["discovered"] for q in state["queue"].values()
                      if q["kind"] == kind and q["status"] in ("pending", "retryable")), default=None)
        item = f"scope/backlog:{kind}"
        if oldest and versions.add_days(oldest, BACKLOG_DAYS) < run_date:
            health.flag(state, item, "backlog", f"{kind} work pending since {oldest}", run_date)
        else:
            health.clear(state, item)


def rotation(keys: list[str], run_date: str, floor: int = 25, ceiling: int = 100, days: int = 7) -> list[str]:
    """Today's slice of `keys` for re-fetching. Sorted by hash so the slices are stable; with a stable
    set every key comes round at least once every ceil(N/C) days, which is at most `days` while
    N <= ceiling * days. No cursor is stored."""
    import hashlib
    ordered = sorted(set(keys), key=lambda k: (hashlib.sha256(k.encode()).hexdigest(), k))
    n = len(ordered)
    if n == 0:
        return []
    c = min(ceiling, max(floor, math.ceil(n / days)))
    p = math.ceil(n / c)
    start = (versions.ordinal(run_date) % p) * c
    return ordered[start:start + c]
