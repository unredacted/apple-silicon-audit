#!/usr/bin/env python3
"""Upstream change watcher (SPEC §15). Maintainer notes: Tools/upstream-watch/README.md.

    watch.py observe --producer observe --out DIR          # one producer's envelope (CI or local)
    watch.py merge --artifacts DIR [--state-dir DIR]       # fold envelopes into a state dir (local)
    watch.py reconcile [--state-dir DIR] [--ignore-exceptions]
    watch.py publish-job --artifacts DIR --event E ...     # the workflow's write job (or --dry-run)
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from upstream_watch import envelope, events, merge, publish, reconcile, render, statefile  # noqa: E402
from upstream_watch.datafiles import Data  # noqa: E402
from upstream_watch.http import Client  # noqa: E402

ROOT = HERE.parents[1]
STATE = HERE / "state"
OBSERVE_DETECTORS = ("firmware", "docs", "xnu")


def load_config() -> dict:
    return json.loads((HERE / "config/watch.json").read_text())


def load_ignore() -> dict:
    return json.loads((HERE / "config/ignore.json").read_text()).get("items", {})


def families(detectors: str | None) -> set[str]:
    allf = set(OBSERVE_DETECTORS) | {"headers", "kernelcache"}
    if not detectors or detectors.strip() == "all":
        return allf
    return {d.strip() for d in detectors.split(",") if d.strip()} & allf


def expected_producers(event: str, schedule: str, detectors: str, observe_env, config: dict) -> list[str]:
    """Which producers this run must have heard from. Missing ones are failures."""
    fams = families(detectors)
    if event == "push":
        return []
    if event == "schedule":
        if schedule == config["schedules"]["weekly"]:
            return list(config["headers"]["producers"])
        exp, fams = ["observe"], set(OBSERVE_DETECTORS) | {"kernelcache"}
    elif event == "workflow_dispatch":
        exp = (["observe"] if fams & set(OBSERVE_DETECTORS) else []) + \
              (list(config["headers"]["producers"]) if "headers" in fams else [])
    else:
        return []
    if "observe" in exp and observe_env and observe_env.get("kernelcache_scheduled") and "kernelcache" in fams:
        exp.append("kernelcache")
    return exp


# ------------------------------------------------------------------------------------- observe
def cmd_observe(a) -> int:
    from upstream_watch.detectors import docs, firmware, headers, kernelcache, xnu
    config = load_config()
    state = statefile.load(pathlib.Path(a.state_dir))
    b = envelope.Builder(a.producer, a.run_id, a.run_attempt, a.run_date)
    client = Client(token=os.environ.get("GITHUB_TOKEN") or None)
    limits = config["limits"]

    def guarded(name, fn):
        try:
            fn()
        except Exception as e:   # an unexpected crash becomes a health item, not a lost envelope
            b.failed(f"{name}:run", f"{type(e).__name__}: {e}", "parse")

    if a.producer == "observe":
        fams = families(a.detectors)
        if "firmware" in fams:
            kc_cap = limits["kernelcaches"] if "kernelcache" in fams else 0
            guarded("firmware", lambda: firmware.observe(client, state, config, b, a.run_date, limits["manifests"], kc_cap))
        if "docs" in fams:
            guarded("docs", lambda: docs.observe(client, b))
        if "xnu" in fams:
            guarded("xnu", lambda: xnu.observe(client, state, b))
    elif a.producer.startswith("headers@"):
        guarded("headers", lambda: headers.observe(a.producer, b))
    elif a.producer == "kernelcache":
        scheduled = json.loads(a.scheduled or os.environ.get("KERNELCACHE_QUEUE") or "[]")
        guarded("kernelcache", lambda: kernelcache.observe(client, scheduled, a.ipsw, b))
    else:
        sys.exit(f"unknown producer {a.producer}")
    path = b.write(pathlib.Path(a.out))
    print(f"wrote {path} ({len(b.doc['scopes'])} scopes)")
    if a.producer == "observe" and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"kernelcache_queue={json.dumps(b.doc['kernelcache_scheduled'], separators=(',', ':'))}\n")
    return 0


# -------------------------------------------------------------------------- local merge / reconcile
def cmd_merge(a) -> int:
    state_dir = pathlib.Path(a.state_dir)
    state = statefile.load(state_dir)
    info = merge.merge(state, pathlib.Path(a.artifacts), [], load_config(), run_id=a.run_id,
                       run_attempt=a.run_attempt, run_date=a.run_date)
    print(json.dumps({k: v for k, v in info.items() if k != "fresh"}, indent=1))
    print("changed:", statefile.save(state_dir, state))
    return 0


def summary_text(rec: dict, info: dict | None, result: dict | None) -> str:
    lines = ["## Upstream watcher", ""]
    if info:
        lines += [f"- Producers applied: {', '.join(info['applied']) or 'none'}",
                  f"- Producer failures: {', '.join(f'{p} ({r})' for p, r in info['failed'].items()) or 'none'}",
                  f"- Scopes confirmed this run: {len(info['fresh'])}", ""]
    for t in rec["topics"].values():
        if t.items:
            lines.append(f"- `{t.fp}`: {len(t.items)} item(s): {', '.join(sorted(t.items)[:12])}")
    lines += ["", f"Covered by exceptions ({len(rec['covered'])}):", ""] + [f"- {c}" for c in rec["covered"][:60]]
    if result:
        lines += ["", "Planned issue operations:", ""]
        lines += [f"- {op['op']} `{op['fp']}`" + (f" #{op['number']}" if op.get("number") else "") for op in result["ops"]] or ["- none"]
        if result["deferred"]:
            lines += ["", "Deferred by caps: " + ", ".join(result["deferred"])]
    return "\n".join(lines) + "\n"


def cmd_reconcile(a) -> int:
    state = statefile.load(pathlib.Path(a.state_dir))
    rec = reconcile.reconcile(state, Data(ROOT), load_config(), load_ignore(), ignore_exceptions=a.ignore_exceptions)
    if a.json:
        print(json.dumps({fp: {"items": {k: v["row"] for k, v in t.items.items()}, "labels": sorted(t.labels)}
                          for fp, t in rec["topics"].items() if t.items} | {"covered": rec["covered"]}, indent=1))
    else:
        print(summary_text(rec, None, None))
        if a.bodies:
            for t in rec["topics"].values():
                if t.items:
                    print(f"\n### {render.title(t)}\n\n{render.body(t)}")
    return 0


# ------------------------------------------------------------------------------------ publish job
class Git:
    def __init__(self, root: pathlib.Path, runner=None):
        self.root = root
        self.runner = runner or (lambda args: subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True))

    def commit_push(self, path: pathlib.Path, message: str) -> bool:
        """True once `path` is committed and pushed (or had nothing to commit); False if the push was rejected."""
        self.runner(["add", "--", str(path)])
        if self.runner(["diff", "--cached", "--quiet"]).returncode == 0:
            return True
        if self.runner(["commit", "-q", "-m", message]).returncode != 0:
            raise RuntimeError("git commit failed")
        return self.runner(["push", "-q", "origin", "HEAD:main"]).returncode == 0

    def reset_to_origin(self) -> None:
        for args in (["fetch", "-q", "origin", "main"], ["reset", "-q", "--hard", "origin/main"]):
            if self.runner(args).returncode != 0:
                raise RuntimeError(f"git {' '.join(args)} failed")

    def head(self) -> str:
        return self.runner(["rev-parse", "--short=12", "HEAD"]).stdout.strip()


def publish_job(a, git: Git, gh: publish.GH, state_dir: pathlib.Path = STATE, root: pathlib.Path = ROOT) -> int:
    config, ignore = load_config(), load_ignore()
    artifacts = pathlib.Path(a.artifacts)
    for attempt in range(4):
        state = statefile.load(state_dir)
        obs, _ = envelope.load(artifacts, "observe")
        expected = expected_producers(a.event, a.schedule, a.detectors, obs, config)
        info = merge.merge(state, artifacts, expected, config, run_id=a.run_id, run_attempt=a.run_attempt,
                           run_date=a.run_date)
        if state["heartbeat"].get("month") != a.run_date[:7]:
            state["heartbeat"] = {"month": a.run_date[:7]}
        rec = reconcile.reconcile(state, Data(root), config, ignore)
        reconcile.prune(state, rec["refs"])
        if a.dry_run:
            break
        statefile.save(state_dir, state)
        if git.commit_push(state_dir, "watch: update upstream state"):
            break
        git.reset_to_origin()   # main moved: rebuild on it, so findings match the new data files
    else:
        raise RuntimeError("could not push watcher state after 4 attempts")

    idx = publish.index(gh)
    result = publish.plan(rec["topics"], idx, lambda n: publish.closed_by(gh, n), config["limits"], git.head())
    text = summary_text(rec, info, result)
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(text)
    if a.plan_out:
        pathlib.Path(a.plan_out).write_text(json.dumps({"summary": text, "ops": result["ops"],
                                                        "deferred": result["deferred"]}, indent=1))
    if a.dry_run:
        print(text)
        return 0

    acks, errors = publish.execute(gh, result)
    for attempt in range(4):   # second commit: publication acknowledgements only
        state = statefile.load(state_dir)
        for eid, number in acks:
            events.acknowledge(state, eid, number, a.run_date)
        statefile.save(state_dir, state)
        if git.commit_push(state_dir, "watch: acknowledge published events"):
            break
        git.reset_to_origin()
    else:
        raise RuntimeError("could not push event acknowledgements after 4 attempts")
    for e in errors:
        print(f"::error::{e}")
    return 1 if errors else 0


def cmd_publish_job(a) -> int:
    if not a.dry_run and os.environ.get("GITHUB_REF") not in (None, "refs/heads/main"):
        sys.exit("publish-job writes only from main; use --dry-run elsewhere")
    return publish_job(a, Git(ROOT), publish.GH(a.repo, dry_run=a.dry_run))


def main(argv=None) -> int:
    today = datetime.date.today().isoformat()
    ap = argparse.ArgumentParser(description="Silicon Audit upstream change watcher")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def run_args(p):
        p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "0"))
        p.add_argument("--run-attempt", default=os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
        p.add_argument("--run-date", default=today)

    p = sub.add_parser("observe")
    p.add_argument("--producer", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--state-dir", default=str(STATE))
    p.add_argument("--detectors", default="all")
    p.add_argument("--scheduled", help="kernelcache work as JSON (default: $KERNELCACHE_QUEUE)")
    p.add_argument("--ipsw", default="ipsw")
    run_args(p)
    p.set_defaults(fn=cmd_observe)

    p = sub.add_parser("merge")
    p.add_argument("--artifacts", required=True)
    p.add_argument("--state-dir", default=str(STATE))
    run_args(p)
    p.set_defaults(fn=cmd_merge)

    p = sub.add_parser("reconcile")
    p.add_argument("--state-dir", default=str(STATE))
    p.add_argument("--ignore-exceptions", action="store_true", help="evaluate SPTM as if no exceptions existed")
    p.add_argument("--json", action="store_true")
    p.add_argument("--bodies", action="store_true", help="also print rendered issue bodies")
    p.set_defaults(fn=cmd_reconcile)

    p = sub.add_parser("publish-job")
    p.add_argument("--artifacts", required=True)
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "unredacted/apple-silicon-audit"))
    p.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"))
    p.add_argument("--schedule", default="")
    p.add_argument("--detectors", default="all")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    p.add_argument("--plan-out")
    run_args(p)
    p.set_defaults(fn=cmd_publish_job)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
