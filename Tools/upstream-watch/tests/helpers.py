"""Shared test helpers: real config and data files, synthetic envelopes, fake HTTP and fake gh."""
from __future__ import annotations

import io
import json
import pathlib
import sys

WATCH = pathlib.Path(__file__).resolve().parents[1]
ROOT = WATCH.parents[1]
FIXTURES = WATCH / "tests/fixtures"
sys.path.insert(0, str(WATCH))
sys.path.insert(0, str(ROOT / "Tools/gen-data"))

from upstream_watch import statefile  # noqa: E402
from upstream_watch.datafiles import Data  # noqa: E402

DATE = "2026-10-05"


def config() -> dict:
    return json.loads((WATCH / "config/watch.json").read_text())


def data() -> Data:
    return Data(ROOT)


def fresh_state() -> dict:
    return statefile.empty()


def env(producer: str, scopes: list, run: str = "1.1", date: str = DATE, scheduled=None) -> dict:
    return {"schema": 1, "producer": producer, "application_id": f"{run}.{producer}", "run_date": date,
            "scopes": scopes, "kernelcache_scheduled": scheduled or []}


def snap(key, data):
    return {"key": key, "kind": "snapshot", "status": "ok", "data": data}


def failed(key, kind="network", error="boom"):
    return {"key": key, "kind": "snapshot", "status": "failed", "error_kind": kind, "error": error}


def build(key, version, candidates, fp="fp1", beta=False, track=True):
    os_, build_ = key.split(";", 1)
    return snap(f"firmware:build:{key}", {"key": key, "os": os_, "build": build_.split("-")[0], "version": version,
                                          "beta": beta, "released": None, "track": track, "source_fp": fp,
                                          "candidates": candidates})


def cand(device, chips, url=None, unsupported=None):
    return {"device": device, "url": url or f"https://updates.cdn-apple.com/x/{device}.ipsw", "type": "ipsw",
            "chips": chips, "unsupported": unsupported}


def outcome(work_id, status="done", fp="fp1", data=None, error=""):
    s = {"key": f"work:{work_id}", "kind": "outcome", "work_id": work_id, "source_fp": fp, "status": status}
    if data is not None:
        s["data"] = data
    if error:
        s["error"] = error
    return s


def manifest_data(key, version, rows, beta=False, url=None):
    os_ = key.split(";", 1)[0]
    return {"type": "manifest", "os": os_, "build": key, "version": version, "beta": beta,
            "url": url or "https://updates.cdn-apple.com/x/a.ipsw", "device": "d", "prefix": "", "rows": rows}


def row(chip, sptm=True, txm=None, kc="kernelcache.release.x"):
    txm = sptm if txm is None else txm
    return {"chip": chip, "board": "b", "sptm": f"sptm.{chip.lower()}.release.im4p" if sptm else None,
            "txm": "txm.release.im4p" if txm else None, "kernelcache": kc}


def write_envs(directory: pathlib.Path, *envs) -> pathlib.Path:
    directory.mkdir(parents=True, exist_ok=True)
    for f in directory.glob("*.json"):
        f.unlink()
    for e in envs:
        (directory / f"{e['producer'].replace('@', '_')}.json").write_text(json.dumps(e))
    return directory


# ------------------------------------------------------------------------------------- fake HTTP
class FakeResponse:
    def __init__(self, status, body=b"", headers=None):
        self.status = status
        self.headers = _Headers(headers or {})
        self._body = io.BytesIO(body)

    def read(self, n=-1):
        return self._body.read(n)

    def close(self):
        pass

    def getcode(self):
        return self.status


class _Headers(dict):
    def get(self, k, default=None):
        for key, v in self.items():
            if key.lower() == k.lower():
                return v
        return default


class FakeServer:
    """Serves `files` {url: bytes}, honouring Range unless `ignore_range`; records requests."""

    def __init__(self, files=None, ignore_range=False, bad_range=False, redirects=None):
        self.files = files or {}
        self.ignore_range, self.bad_range = ignore_range, bad_range
        self.redirects = redirects or {}
        self.requests = []

    def __call__(self, request, timeout):
        url = request.full_url
        self.requests.append((url, dict(request.header_items())))
        if url in self.redirects:
            return FakeResponse(302, headers={"Location": self.redirects[url]})
        if url not in self.files:
            return FakeResponse(404)
        body = self.files[url]
        rng = request.get_header("Range")
        if rng and not self.ignore_range:
            start, end = (int(x) for x in rng.split("=")[1].split("-"))
            end = min(end, len(body) - 1)
            shown = f"bytes {start + (1 if self.bad_range else 0)}-{end}/{len(body)}"
            return FakeResponse(206, body[start:end + 1], {"Content-Range": shown})
        return FakeResponse(200, body)


# --------------------------------------------------------------------------------------- fake gh
class FakeGH:
    """Enough of `gh` for the publisher: issues, timelines, labels. `runner` records every call."""

    def __init__(self, repo="o/r"):
        self.repo = repo
        self.issues = {}        # number -> issue dict
        self.timelines = {}     # number -> [events]
        self.labels = set()
        self.calls = []
        self.fail_after_create = False
        self.next = 1

    def add_issue(self, body, state="open", labels=("watch",), closed_by=None):
        n = self.next
        self.next += 1
        self.issues[n] = {"number": n, "state": state, "body": body, "labels": [{"name": l} for l in labels]}
        if closed_by:
            self.timelines[n] = [{"event": "closed", "actor": {"login": closed_by}}]
        return n

    def __call__(self, args):
        self.calls.append(args)
        if args[0] == "api":
            path = args[-1]
            if "/timeline" in path:
                n = int(path.split("/issues/")[1].split("/")[0])
                return json.dumps([self.timelines.get(n, [])])
            issues = sorted(self.issues.values(), key=lambda i: i["number"])
            return json.dumps([issues[i:i + 30] for i in range(0, len(issues), 30)] or [[]])
        if args[:2] == ["label", "list"]:
            return json.dumps([{"name": n} for n in sorted(self.labels)])
        if args[:2] == ["label", "create"]:
            self.labels.add(args[2])
            return ""
        body = None
        if "--body-file" in args:
            body = pathlib.Path(args[args.index("--body-file") + 1]).read_text()
        if args[:2] == ["issue", "create"]:
            labels = [args[i + 1] for i, a in enumerate(args) if a == "--label"]
            n = self.add_issue(body, labels=labels)
            if self.fail_after_create:
                raise OSError("connection reset after create")
            return f"https://github.com/{self.repo}/issues/{n}\n"
        n = int(args[2])
        issue = self.issues[n]
        if args[1] == "edit":
            issue["body"] = body
            for i, a in enumerate(args):
                if a == "--add-label":
                    issue["labels"].append({"name": args[i + 1]})
        elif args[1] == "close":
            issue["state"] = "closed"
            self.timelines.setdefault(n, []).append({"event": "closed", "actor": {"login": "github-actions[bot]"}})
        elif args[1] == "reopen":
            issue["state"] = "open"
        return ""

    def writes(self):
        return [c for c in self.calls if c[0] == "issue" or c[:2] == ["label", "create"]]
