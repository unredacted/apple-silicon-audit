import argparse
import contextlib
import io
import pathlib
import shutil
import tempfile
import unittest
from unittest import mock

from helpers import DATE, ROOT, FakeGH, config, env, fresh_state, snap, write_envs

import watch
from upstream_watch import events, merge, publish, reconcile, render, statefile
from upstream_watch.datafiles import Data

CFG = config()
LIMITS = CFG["limits"]


def topic(fp="v1:gap/x", items=("a",), kind="gap"):
    t = reconcile.Topic(fp, kind, "Title", ["watch", "watch:firmware"], ["subject"], ["guide"])
    for i in items:
        t.add(i, {"i": i}, {"subject": i})
    return t


class Publisher(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGH()
        self.gh = publish.GH("o/r", runner=self.fake)

    def run_once(self, topics, sha="abc"):
        idx = publish.index(self.gh)
        result = publish.plan(topics, idx, lambda n: publish.closed_by(self.gh, n), LIMITS, sha)
        return publish.execute(self.gh, result), result

    def test_discovery_reads_every_page_and_skips_prs(self):
        for i in range(35):
            self.fake.add_issue(render.body(topic(f"v1:gap/t{i}")))
        pr = self.fake.add_issue(render.body(topic("v1:gap/pr")))
        self.fake.issues[pr]["pull_request"] = {}
        idx = publish.index(self.gh)
        self.assertEqual(len(idx), 35)
        self.assertIn("v1:gap/t34", idx)
        self.assertNotIn("v1:gap/pr", idx)

    def test_create_then_identical_rerun_makes_no_calls(self):
        t = {"v1:gap/x": topic()}
        self.run_once(t, sha="aaa")
        writes = len(self.fake.writes())
        self.run_once({"v1:gap/x": topic()}, sha="bbb")    # main moved, new run: same findings
        self.assertEqual(len(self.fake.writes()), writes)

    def test_material_change_comments_and_evidence_change_edits_silently(self):
        self.run_once({"v1:gap/x": topic(items=("a",))})
        t = topic(items=("a",))
        t.items["a"]["row"]["subject"] = "new evidence"
        self.run_once({"v1:gap/x": t})
        self.assertFalse(any(c[:2] == ["issue", "comment"] for c in self.fake.calls))
        self.assertTrue(any(c[:2] == ["issue", "edit"] for c in self.fake.calls))
        self.run_once({"v1:gap/x": topic(items=("a", "b"))})
        self.assertTrue(any(c[:2] == ["issue", "comment"] for c in self.fake.calls))

    def test_resolved_closes_and_bot_closed_reopens(self):
        self.run_once({"v1:gap/x": topic(items=("a",))})
        self.run_once({"v1:gap/x": topic(items=())}, sha="def")
        self.assertEqual(self.fake.issues[1]["state"], "closed")
        self.run_once({"v1:gap/x": topic(items=("a",))})
        self.assertEqual(self.fake.issues[1]["state"], "open")

    def test_human_close_reopens_only_for_new_items(self):
        self.run_once({"v1:gap/x": topic(items=("a",))})
        self.run_once({"v1:gap/x": topic(items=())})                # bot closes
        self.run_once({"v1:gap/x": topic(items=("a",))})            # bot reopens
        self.fake.issues[1]["state"] = "closed"                     # a human closes it
        self.fake.timelines[1].append({"event": "closed", "actor": {"login": "maintainer"}})
        self.run_once({"v1:gap/x": topic(items=("a",))})
        self.assertEqual(self.fake.issues[1]["state"], "closed")
        self.run_once({"v1:gap/x": topic(items=("a", "b"))})
        self.assertEqual(self.fake.issues[1]["state"], "open")

    def test_caps_defer(self):
        topics = {f"v1:gap/t{i}": topic(f"v1:gap/t{i}") for i in range(9)}
        _, result = self.run_once(topics)
        self.assertEqual(len([o for o in result["ops"] if o["op"] == "create"]), LIMITS["new_issues"])
        self.assertEqual(len(result["deferred"]), 3)

    def test_dry_run_writes_nothing(self):
        gh = publish.GH("o/r", runner=self.fake, dry_run=True)
        result = publish.plan({"v1:gap/x": topic()}, publish.index(gh), lambda n: "bot", LIMITS, "x")
        publish.execute(gh, result)
        self.assertEqual(self.fake.writes(), [])
        self.assertTrue(gh.writes)


class Events(unittest.TestCase):
    def setUp(self):
        self.fake = FakeGH()
        self.gh = publish.GH("o/r", runner=self.fake)

    def event_topics(self, state):
        return {fp: t for fp, t in reconcile.reconcile(state, Data(ROOT), CFG, {})["topics"].items() if t.kind == "event"}

    def blog_state(self, links):
        state = fresh_state()
        merge.apply(state, env("observe", [snap("docs:blog", {"items": [{"link": "https://security.apple.com/blog/a", "title": "A"}]})],
                               run="1.1"), CFG)
        merge.apply(state, env("observe", [snap("docs:blog", {"items": [{"link": l, "title": l[-1]} for l in links]})],
                               run="2.1"), CFG)
        return state

    def test_first_baseline_is_silent_then_new_post_is_pending(self):
        state = self.blog_state(["https://security.apple.com/blog/a", "https://security.apple.com/blog/b"])
        self.assertEqual([e["status"] for e in state["events"].values()], ["pending"])

    def test_failure_after_state_push_keeps_event_pending(self):
        state = self.blog_state(["https://security.apple.com/blog/a", "https://security.apple.com/blog/b"])
        self.fake.fail_after_create = True        # gh created the issue, then the connection reset
        result = publish.plan(self.event_topics(state), publish.index(self.gh), lambda n: "bot", LIMITS, "x")
        acks, errors = publish.execute(self.gh, result)
        self.assertEqual(acks, [])
        self.assertTrue(errors)
        self.assertEqual(list(state["events"].values())[0]["status"], "pending")
        self.fake.fail_after_create = False       # next run: found by fingerprint, acknowledged, no duplicate
        result = publish.plan(self.event_topics(state), publish.index(self.gh), lambda n: "bot", LIMITS, "x")
        acks, _ = publish.execute(self.gh, result)
        self.assertEqual(len(self.fake.issues), 1)
        for eid, n in acks:
            events.acknowledge(state, eid, n, DATE)
        self.assertEqual(list(state["events"].values())[0]["status"], "published")

    def test_cap_keeps_events_pending(self):
        links = ["https://security.apple.com/blog/a"] + [f"https://security.apple.com/blog/p{i}" for i in range(8)]
        state = self.blog_state(links)
        result = publish.plan(self.event_topics(state), publish.index(self.gh), lambda n: "bot", LIMITS, "x")
        acks, _ = publish.execute(self.gh, result)
        self.assertEqual(len(acks), LIMITS["new_issues"])
        for eid, n in acks:
            events.acknowledge(state, eid, n, DATE)
        self.assertEqual(sum(e["status"] == "pending" for e in state["events"].values()), 2)

    def test_prune_after_thirty_days(self):
        state = self.blog_state(["https://security.apple.com/blog/a", "https://security.apple.com/blog/b"])
        eid = next(iter(state["events"]))
        events.acknowledge(state, eid, 7, DATE)
        events.prune(state, "2026-11-03")
        self.assertIn(eid, state["events"])
        events.prune(state, "2026-11-05")
        self.assertNotIn(eid, state["events"])


class FakeGit:
    """Rejects the first push once; on reset, swaps in `after_reset` data (a concurrent curation merge)."""

    def __init__(self, reject_first=False, on_reset=None):
        self.reject_first, self.on_reset = reject_first, on_reset
        self.commits = []

    def commit_push(self, path, message):
        files = {p.name: p.read_text() for p in path.glob("*.json")}
        if self.commits and self.commits[-1][1] == files:
            return True
        if self.reject_first:
            self.reject_first = False
            return False
        self.commits.append((message, files))
        return True

    def reset_to_origin(self):
        if self.on_reset:
            self.on_reset()

    def head(self):
        return "abc123"


class PublishJob(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = pathlib.Path(self.tmp.name)
        self.root = base / "repo"
        shutil.copytree(ROOT / "Sources/SiliconAuditCore/Resources", self.root / "Sources/SiliconAuditCore/Resources")
        shutil.copytree(ROOT / "results", self.root / "results")
        self.state = base / "state"
        self.art = base / "art"
        write_envs(self.art, env("observe", [snap("docs:pdf", {"etag": "a"})], run="7.1"))
        self.fake = FakeGH()

    def tearDown(self):
        self.tmp.cleanup()

    def args(self, dry=False):
        return argparse.Namespace(artifacts=str(self.art), event="workflow_dispatch", schedule="", detectors="docs",
                                  run_id="7", run_attempt="1", run_date=DATE, dry_run=dry, summary=None, plan_out=None)

    def test_reset_after_rejected_push_re_reconciles_against_new_main(self):
        def curation_merge():   # someone curated every reported key while we were pushing
            import json
            kk = self.root / "Sources/SiliconAuditCore/Resources/known-keys.json"
            doc = json.loads(kk.read_text())
            for key in Data(self.root).result_unrecognized_keys():
                doc["entries"].append({"id": key[12:], "key": key, "display_name": key, "category": "isa_misc",
                                       "kind": "flag", "format": "I", "security_relevant": False, "description": "x"})
            kk.write_text(json.dumps(doc))
        git = FakeGit(reject_first=True, on_reset=curation_merge)
        watch.publish_job(self.args(), git, publish.GH("o/r", runner=self.fake), state_dir=self.state, root=self.root)
        self.assertEqual([i for i in self.fake.issues.values() if "known-keys" in i["body"]], [],
                         "no stale finding was published after the reset")

    def test_second_commit_holds_only_acknowledgements_and_rerun_is_quiet(self):
        git = FakeGit()
        watch.publish_job(self.args(), git, publish.GH("o/r", runner=self.fake), state_dir=self.state, root=self.root)
        first_commits = len(git.commits)
        writes = len(self.fake.writes())
        write_envs(self.art, env("observe", [snap("docs:pdf", {"etag": "a"})], run="8.1"))
        watch.publish_job(self.args(), git, publish.GH("o/r", runner=self.fake), state_dir=self.state, root=self.root)
        self.assertEqual(len(git.commits), first_commits, "unchanged upstream: no commit")
        self.assertEqual(len(self.fake.writes()), writes, "unchanged upstream: no issue calls")

    def test_dry_run_persists_nothing(self):
        git = FakeGit()
        with contextlib.redirect_stdout(io.StringIO()):
            watch.publish_job(self.args(dry=True), git, publish.GH("o/r", runner=self.fake, dry_run=True),
                              state_dir=self.state, root=self.root)
        self.assertEqual(git.commits, [])
        self.assertEqual(self.fake.writes(), [])
        self.assertFalse(self.state.exists())


class ExpectedProducers(unittest.TestCase):
    def test_events(self):
        obs = {"kernelcache_scheduled": [{"work_id": "kc:x"}]}
        self.assertEqual(watch.expected_producers("schedule", CFG["schedules"]["daily"], "all", obs, CFG),
                         ["observe", "kernelcache"])
        self.assertEqual(watch.expected_producers("schedule", CFG["schedules"]["weekly"], "all", None, CFG),
                         CFG["headers"]["producers"])
        self.assertEqual(watch.expected_producers("push", "", "all", obs, CFG), [])
        self.assertEqual(watch.expected_producers("workflow_dispatch", "", "headers", None, CFG), CFG["headers"]["producers"])
        self.assertEqual(watch.expected_producers("workflow_dispatch", "", "docs", obs, CFG), ["observe"])
        self.assertEqual(watch.expected_producers("workflow_dispatch", "", "kernelcache", obs, CFG),
                         ["observe", "kernelcache"], "a kernelcache-only dispatch still runs observe to schedule")

    def test_kernelcache_only_observe_schedules_from_the_committed_queue(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            state = fresh_state()
            state["queue"]["kc:iOS;24A446"] = {"kind": "kernelcache", "build": "iOS;24A446", "os": "iOS", "version": "27.0.1",
                                               "beta": False, "url": "https://updates.cdn-apple.com/x.ipsw",
                                               "member": "kernelcache.release.x", "source_fp": "f", "status": "pending",
                                               "attempts": 0, "not_before": None, "priority": [0, 0], "discovered": DATE,
                                               "evidence": None, "chips": ["T8150"], "reason": None}
            statefile.save(base / "state", state)
            with contextlib.redirect_stdout(io.StringIO()):
                watch.main(["observe", "--producer", "observe", "--detectors", "kernelcache", "--state-dir",
                            str(base / "state"), "--out", str(base / "art"), "--run-date", DATE])
            doc = json.loads((base / "art/observe.json").read_text())
            self.assertEqual([k["work_id"] for k in doc["kernelcache_scheduled"]], ["kc:iOS;24A446"])


if __name__ == "__main__":
    unittest.main()
