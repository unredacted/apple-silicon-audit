"""Fold producer envelopes into the committed state, scope by scope.

- A `snapshot` scope replaces only its own key; a `producer-set` is the only whole replacement, and
  only of that producer's members.
- An `outcome` lands in the evidence store under (work id, source fingerprint), never replacing
  other records; retryable and unsupported outcomes touch the queue entry only.
- Scopes an envelope does not mention are untouched, so failures, skips and runs without work keep
  all earlier evidence.
- An application id that changed the state is remembered in `applied`; applying it again (a retry
  after a push whose response was lost) is a no-op, so nothing it set is overwritten and no counter
  advances twice. An envelope that changed nothing is not remembered, and applying it again still
  changes nothing: runs are serialized, so the state it meets on a retry is its own run's.
- No per-run metadata is written: a run that saw nothing new leaves the state byte-identical.
"""
from __future__ import annotations

import fnmatch

from . import envelope, events, health, queue, statefile

APPLIED_KEEP = 200


def _set_snapshot(state: dict, key: str, data, run_date: str) -> None:
    old = state["scopes"].get(key)
    if old is not None and old["data"] == data:
        return
    if key.startswith("docs:"):
        events.detect(state, key, old["data"] if old else None, data, run_date)
    state["scopes"][key] = {"data": data, "first_seen": old["first_seen"] if old else run_date, "changed_on": run_date}


def _required(state: dict, producer: str, members: list[str], config: dict, run_date: str) -> None:
    """Required coverage per producer, for example the Xcode 27 SDKs on the xcode-27 runner."""
    patterns = config.get("required", {}).get(producer, [])
    names = set()
    for m in members:
        scope = state["scopes"].get(m)
        if scope:
            names.update(scope["data"].get("sdks", {}).keys())
            names.update(s.get("name", "") for s in scope["data"].get("sdks", {}).values())
    for pattern in patterns:
        item = f"scope/{producer}/missing-sdk:{pattern}"
        if any(fnmatch.fnmatch(n, pattern) for n in names):
            health.clear(state, item)
        else:
            health.flag(state, item, "coverage",
                        f"no SDK matching {pattern} on runner {producer.split('@', 1)[-1]}: check the runner label in watch.yml",
                        run_date)


def _confirmed(env: dict) -> set[str]:
    return {s["key"] for s in env["scopes"]
            if (s["kind"] == "snapshot" and s["status"] == "ok") or s["kind"] == "producer-set"
            or (s["kind"] == "outcome" and s["status"] == "done")}


def apply(state: dict, env: dict, config: dict, *, scratch: bool = False) -> set[str]:
    """Apply one valid envelope. Returns the scope keys and work ids it freshly confirmed.
    `scratch` is for a throwaway copy (a detector previewing its own envelope): it neither checks nor
    records the application id."""
    app_id, run_date, producer = env["application_id"], env["run_date"], env["producer"]
    if not scratch and app_id in state["applied"]:
        return _confirmed(env)   # already applied: a true no-op
    threshold = config["limits"]["health_threshold"]
    before = statefile.snapshot(state)
    fresh = set()
    health.clear(state, f"producer/{producer}")
    scopes = env["scopes"]
    for s in scopes:
        if s["kind"] == "snapshot" and s["status"] == "ok":
            _set_snapshot(state, s["key"], s["data"], run_date)
            health.clear(state, f"scope/{s['key']}")
            fresh.add(s["key"])
        elif s["kind"] == "snapshot":
            health.fail(state, f"scope/{s['key']}", s["error_kind"], s["error"], run_date,
                        replay=False, threshold=threshold)
    for s in scopes:
        if s["kind"] == "producer-set":
            members = set(s["members"])
            for key in [k for k in state["scopes"] if k.startswith(s["key"] + ":") and k not in members]:
                del state["scopes"][key]
                health.clear(state, f"scope/{key}")
            _required(state, producer, s["members"], config, run_date)
            fresh.add(s["key"])
    queue.derive_manifests(state, config, run_date)
    for s in scopes:
        if s["kind"] == "outcome":
            queue.apply_outcome(state, s, run_date, replay=False)
            if s["status"] == "done":
                fresh.add(s["key"])
    queue.derive_kernelcaches(state, config, run_date)
    if not scratch and statefile.snapshot(state) != before:
        state["applied"] = (state["applied"] + [app_id])[-APPLIED_KEEP:]
    return fresh


def _order(producer: str):
    """observe first (it creates the queue entries other producers' outcomes belong to), kernelcache last."""
    return (0 if producer == "observe" else 2 if producer == "kernelcache" else 1, producer)


def merge(state: dict, artifacts, expected: list[str], config: dict, *, run_id: str, run_attempt: str,
          run_date: str) -> dict:
    """Validate and apply every expected producer's envelope (plus any extra valid ones).

    `artifacts` is a directory. A missing or invalid envelope for an expected producer is a producer
    failure, whatever the job's reported result. Returns {"fresh", "failed", "applied"}."""
    fresh, failed, applied = set(), {}, []
    names = sorted(set(expected) | {p.stem.replace("_", "@", 1) for p in artifacts.glob("*.json")}, key=_order)
    for producer in names:
        env, reason = envelope.load(artifacts, producer)
        if env is None:
            if producer in expected:
                app_id = f"{run_id}.{run_attempt}.{producer}"
                replay = app_id in state["applied"]
                before = statefile.snapshot(state)
                health.fail(state, f"producer/{producer}", "artifact", reason, run_date, replay=replay, threshold=1)
                if statefile.snapshot(state) != before and not replay:
                    state["applied"] = (state["applied"] + [app_id])[-APPLIED_KEEP:]
                failed[producer] = reason
            continue
        fresh |= apply(state, env, config)
        applied.append(producer)
    queue.check_backlog(state, run_date)
    events.prune(state, run_date)
    return {"fresh": sorted(fresh), "failed": failed, "applied": applied}
