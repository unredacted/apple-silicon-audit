"""Turn topics into GitHub issue operations, with `gh` and the workflow's GITHUB_TOKEN.

- Discovery reads every `watch` issue (paginated REST; `gh issue list` stops at 30) and indexes it
  by the fingerprint marker in its body.
- Who closed an issue comes from its timeline: the latest `closed` event's actor.
- A topic whose rendered body equals the issue's body makes no call at all.
- `gh` always gets an argument list and `--body-file`; nothing goes through a shell.
"""
from __future__ import annotations

import json
import re
import subprocess
import tempfile

from . import render
from .reconcile import Topic

BOT = "github-actions[bot]"
LABELS = {
    "watch": ("5319e7", "Upstream watcher finding (automated evidence)"),
    "heuristic": ("fbca04", "Signal that needs corroboration before acting"),
}
DETECTOR_LABEL = ("c5def5", "Upstream watcher detector")
ORDER = ["health", "gap", "event"]


class GH:
    """`runner(args) -> stdout` runs `gh`; tests pass a fake. Writes are recorded in `writes`."""

    def __init__(self, repo: str, runner=None, dry_run: bool = False):
        self.repo, self.dry_run = repo, dry_run
        self.runner = runner or self._run
        self.writes: list[list[str]] = []

    @staticmethod
    def _run(args: list[str]) -> str:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=120).stdout

    def read(self, args: list[str]) -> str:
        return self.runner(args)

    def write(self, args: list[str], body: str | None = None) -> str:
        if body is not None:
            with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
                f.write(body)
            args = args + ["--body-file", f.name]
        self.writes.append(args)
        return "" if self.dry_run else self.runner(args)

    def paginate(self, path: str) -> list:
        pages = json.loads(self.read(["api", "--paginate", "--slurp", path]) or "[]")
        return [x for page in pages for x in (page if isinstance(page, list) else [page])]


def index(gh: GH) -> dict[str, dict]:
    issues = gh.paginate(f"repos/{gh.repo}/issues?labels=watch&state=all&per_page=100")
    out = {}
    for issue in sorted((i for i in issues if "pull_request" not in i), key=lambda i: i["number"]):
        fp, items = render.parse_markers(issue.get("body"))
        if fp and fp not in out:   # the oldest issue with a fingerprint owns it
            out[fp] = {"number": issue["number"], "state": issue["state"], "body": issue.get("body") or "",
                       "items": items, "labels": {l["name"] for l in issue.get("labels", [])}}
    return out


def closed_by(gh: GH, number: int) -> str:
    events = gh.paginate(f"repos/{gh.repo}/issues/{number}/timeline?per_page=100")
    closes = [e for e in events if e.get("event") == "closed"]
    actor = ((closes[-1].get("actor") or {}).get("login")) if closes else None
    return "bot" if actor == BOT else "human"


def ensure_labels(gh: GH, needed: set[str]) -> None:
    existing = {l["name"] for l in json.loads(gh.read(["label", "list", "--repo", gh.repo, "--json", "name", "--limit", "500"]) or "[]")}
    for name in sorted(needed - existing):
        color, desc = LABELS.get(name, DETECTOR_LABEL)
        gh.write(["label", "create", name, "--repo", gh.repo, "--color", color, "--description", desc])


def plan(topics: dict[str, Topic], idx: dict[str, dict], closer, limits: dict, main_sha: str) -> dict:
    """Operations, deferrals and event acknowledgements, without performing anything."""
    ops, deferred, acks = [], [], []
    created = {"gap": 0, "event": 0, "health": 0}
    comments = 0
    for topic in sorted(topics.values(), key=lambda t: (ORDER.index(t.kind), t.fp)):
        issue = idx.get(topic.fp)
        hashes = topic.hashes()
        if topic.kind == "event":
            if issue:
                acks.append((topic.event_id, issue["number"]))
                continue
        if issue is None:
            if not topic.items:
                continue
            cap = limits["health_issues"] if topic.kind == "health" else limits["new_issues"]
            pool = "health" if topic.kind == "health" else "other"
            used = created["health"] if pool == "health" else created["gap"] + created["event"]
            if used >= cap:
                deferred.append(topic.fp)
                continue
            created["health" if pool == "health" else topic.kind] += 1
            ops.append({"op": "create", "fp": topic.fp, "title": render.title(topic), "body": render.body(topic),
                        "labels": sorted(topic.labels), "event_id": topic.event_id})
            continue
        body = render.body(topic)
        missing_labels = sorted(topic.labels - issue["labels"])
        material = hashes != issue["items"]
        if issue["state"] == "open":
            if not topic.items and topic.kind != "event":
                if comments >= limits["comments"]:
                    deferred.append(topic.fp)
                    continue
                comments += 1
                ops.append({"op": "close", "fp": topic.fp, "number": issue["number"],
                            "comment": f"Resolved as of main@{main_sha}.\n\n" + render.delta(issue["items"], hashes)})
            elif material:
                if comments >= limits["comments"]:
                    deferred.append(topic.fp)
                    continue
                comments += 1
                ops.append({"op": "update", "fp": topic.fp, "number": issue["number"], "body": body,
                            "comment": render.delta(issue["items"], hashes), "labels": missing_labels})
            elif render.normalize(body) != render.normalize(issue["body"]) or missing_labels:
                ops.append({"op": "update", "fp": topic.fp, "number": issue["number"], "body": body,
                            "comment": None, "labels": missing_labels})
        elif topic.items and topic.kind != "event":
            new_keys = set(hashes) - set(issue["items"])
            if closer(issue["number"]) == "bot" or new_keys:
                if comments >= limits["comments"]:
                    deferred.append(topic.fp)
                    continue
                comments += 1
                ops.append({"op": "reopen", "fp": topic.fp, "number": issue["number"], "body": body,
                            "comment": "Findings are back.\n\n" + render.delta(issue["items"], hashes),
                            "labels": missing_labels})
    return {"ops": ops, "deferred": deferred, "acks": acks}


def execute(gh: GH, result: dict) -> tuple[list[tuple[str, int]], list[str]]:
    """Perform the planned operations. Returns (event acknowledgements, errors). Acknowledgements
    cover pre-existing issues plus issues this run created, only after `gh` confirmed them; a failed
    operation is reported and the rest still run, so confirmed work is never forgotten."""
    acks, errors = list(result["acks"]), []
    labels = {l for op in result["ops"] for l in op.get("labels", [])}
    if labels:
        ensure_labels(gh, labels)
    for op in result["ops"]:
        try:
            _perform(gh, op, acks)
        except (subprocess.SubprocessError, OSError) as e:
            errors.append(f"{op['op']} {op['fp']}: {e}")
    return acks, errors


def _perform(gh: GH, op: dict, acks: list) -> None:
    n = str(op.get("number", ""))
    if op["op"] == "create":
        args = ["issue", "create", "--repo", gh.repo, "--title", op["title"]]
        for label in op["labels"]:
            args += ["--label", label]
        out = gh.write(args, op["body"])
        m = re.search(r"/issues/(\d+)\s*$", out.strip())
        if op["event_id"] and m:
            acks.append((op["event_id"], int(m.group(1))))
    elif op["op"] == "close":
        gh.write(["issue", "close", n, "--repo", gh.repo, "--reason", "completed", "--comment", op["comment"]])
    else:
        if op["op"] == "reopen":
            gh.write(["issue", "reopen", n, "--repo", gh.repo, "--comment", op["comment"]])
        elif op["comment"]:
            gh.write(["issue", "comment", n, "--repo", gh.repo], op["comment"])
        args = ["issue", "edit", n, "--repo", gh.repo]
        for label in op.get("labels", []):
            args += ["--add-label", label]
        gh.write(args, op["body"])
