import pathlib
import tempfile
import unittest

from helpers import (DATE, build, cand, config, env, failed, fresh_state, manifest_data, outcome, row, snap,
                     write_envs)

from upstream_watch import health, merge, queue, statefile, versions

CFG = config()


def builds(n, os_="iOS", train=24):
    """n tracked builds, one candidate each."""
    return [build(f"{os_};{train}A{100 + i}", f"27.0.{i}", [cand(f"iPhone{i},1", [f"T{8000 + i}"])]) for i in range(n)]


def work_id(scope):
    d = scope["data"]
    return f"manifest:{d['key']};{d['candidates'][0]['device']}"


class IncrementalEvidence(unittest.TestCase):
    def test_capped_batches_then_an_empty_run_keep_everything(self):
        state = fresh_state()
        scopes = builds(45)
        merge.apply(state, env("observe", scopes, run="1.1"), CFG)
        first = queue.schedule(state, "manifest", 40, DATE)
        self.assertEqual(len(first), 40)
        done = [outcome(w, data=manifest_data(state["queue"][w]["build"], "27.0", [row("T8030")])) for w in first]
        merge.apply(state, env("observe", done, run="2.1"), CFG)
        second = queue.schedule(state, "manifest", 40, DATE)
        self.assertEqual(len(second), 5, "the 41st onward waited for the next run")
        self.assertFalse(set(first) & set(second))
        merge.apply(state, env("observe", [outcome(w, data=manifest_data(state["queue"][w]["build"], "27.0",
                                                                          [row("T8030")])) for w in second], run="3.1"), CFG)
        evidence = dict(state["evidence"])
        merge.apply(state, env("observe", [], run="4.1"), CFG)       # a run with no work
        self.assertEqual(state["evidence"], evidence)
        self.assertEqual(len(evidence), 45)

    def test_index_refresh_makes_no_manifest_scope_fresh(self):
        state = fresh_state()
        fresh = merge.apply(state, env("observe", [snap("firmware:index:iOS", {"keys": ["iOS;24A446"]})]), CFG)
        self.assertEqual(fresh, {"firmware:index:iOS"})

    def test_retryable_never_deletes_done_evidence(self):
        state = fresh_state()
        s = builds(1)[0]
        merge.apply(state, env("observe", [s], run="1.1"), CFG)
        w = work_id(s)
        merge.apply(state, env("observe", [outcome(w, data=manifest_data("iOS;24A100", "27.0", [row("T8030")]))], run="2.1"), CFG)
        merge.apply(state, env("observe", [outcome(w, "retryable", error="timeout")], run="3.1"), CFG)
        self.assertEqual(len(state["evidence"]), 1)
        self.assertEqual(state["queue"][w]["status"], "done")


class ProducersAndHealth(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.art = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def headers_env(self, label, run, sdks=("macosx27.0", "iphoneos27.0")):
        p = f"headers@{label}"
        key = f"{p}:/Applications/Xcode.app"
        data = {"xcode": "Xcode 27.0", "sdks": {s.rstrip("0123456789."): {"name": s, "cap_bit_nb": 97, "caps": {},
                                                                          "cpufamily": {}, "cpusubfamily": {}} for s in sdks}}
        return env(p, [snap(key, data), {"key": p, "kind": "producer-set", "status": "ok", "members": [key]}], run=run)

    def run_merge(self, state, envs, run, expected=("headers@macos-26", "headers@xcode-27")):
        write_envs(self.art, *envs)
        return merge.merge(state, self.art, list(expected), CFG, run_id=run, run_attempt="1", run_date=DATE)

    def test_one_runner_never_clears_the_other(self):
        state = fresh_state()
        self.run_merge(state, [self.headers_env("macos-26", "1.1", ("macosx26.0",)),
                               self.headers_env("xcode-27", "1.1")], "1")
        before = {k for k in state["scopes"] if k.startswith("headers@")}
        self.run_merge(state, [self.headers_env("macos-26", "2.1", ("macosx26.0",))], "2")   # xcode-27 missing
        self.assertTrue(state["health"]["producer/headers@xcode-27"]["open"])
        self.assertEqual({k for k in state["scopes"] if k.startswith("headers@")}, before, "evidence kept")
        self.run_merge(state, [self.headers_env("macos-26", "3.1", ("macosx26.0",))], "3")
        self.assertIn("producer/headers@xcode-27", state["health"], "the other runner's ok did not clear it")
        self.run_merge(state, [self.headers_env("macos-26", "4.1", ("macosx26.0",)), self.headers_env("xcode-27", "4.1")], "4")
        self.assertNotIn("producer/headers@xcode-27", state["health"])

    def test_missing_required_sdk_opens_health_immediately(self):
        state = fresh_state()
        self.run_merge(state, [self.headers_env("macos-26", "1.1", ("macosx26.0",)),
                               self.headers_env("xcode-27", "1.1", ("macosx26.4",))], "1")
        items = health.open_items(state)
        self.assertIn("scope/headers@xcode-27/missing-sdk:macosx27*", items)
        self.assertIn("scope/headers@xcode-27/missing-sdk:iphoneos27*", items)
        self.run_merge(state, [self.headers_env("macos-26", "2.1", ("macosx26.0",)), self.headers_env("xcode-27", "2.1")], "2")
        self.assertEqual(health.open_items(state), {})

    def test_successful_job_with_invalid_artifact_is_a_failure(self):
        state = fresh_state()
        write_envs(self.art)
        (self.art / "observe.json").write_text('{"schema": 1, "producer": "observe"}')
        info = merge.merge(state, self.art, ["observe"], CFG, run_id="9", run_attempt="1", run_date=DATE)
        self.assertIn("observe", info["failed"])
        self.assertTrue(state["health"]["producer/observe"]["open"])

    def test_crashed_kernelcache_job_leaves_work_and_opens_health(self):
        state = fresh_state()
        state["queue"]["kc:iOS;24A446"] = {"kind": "kernelcache", "build": "iOS;24A446", "status": "pending",
                                           "attempts": 0, "not_before": None, "priority": [0, 0], "discovered": DATE,
                                           "source_fp": "f", "evidence": None}
        self.run_merge(state, [], "1", expected=["kernelcache"])
        self.assertEqual(state["queue"]["kc:iOS;24A446"]["status"], "pending")
        self.assertTrue(state["health"]["producer/kernelcache"]["open"])

    def test_three_network_failures_open_then_recovery_closes(self):
        state = fresh_state()
        for run in ("1.1", "2.1"):
            merge.apply(state, env("observe", [failed("docs:pdf")], run=run), CFG)
        self.assertFalse(state["health"]["scope/docs:pdf"]["open"])
        merge.apply(state, env("observe", [failed("docs:pdf")], run="3.1"), CFG)
        self.assertTrue(state["health"]["scope/docs:pdf"]["open"])
        merge.apply(state, env("observe", [snap("docs:pdf", {"etag": "x"})], run="4.1"), CFG)
        self.assertNotIn("scope/docs:pdf", state["health"])

    def test_parse_failure_opens_at_once_and_keeps_old_snapshot(self):
        state = fresh_state()
        merge.apply(state, env("observe", [snap("docs:guide", {"published": "2026-01-28"})], run="1.1"), CFG)
        merge.apply(state, env("observe", [failed("docs:guide", "parse")], run="2.1"), CFG)
        self.assertTrue(state["health"]["scope/docs:guide"]["open"])
        self.assertEqual(state["scopes"]["docs:guide"]["data"], {"published": "2026-01-28"})

    def test_skipped_producer_changes_nothing(self):
        state = fresh_state()
        merge.apply(state, env("observe", builds(2), run="1.1"), CFG)
        before = statefile.snapshot(state)
        self.run_merge(state, [], "2", expected=[])
        self.assertEqual(statefile.snapshot(state), before)


class Idempotence(unittest.TestCase):
    def test_same_failed_envelope_twice_counts_once(self):
        state = fresh_state()
        e = env("observe", [failed("docs:pdf")], run="5.1")
        merge.apply(state, e, CFG)
        merge.apply(state, e, CFG)
        self.assertEqual(state["health"]["scope/docs:pdf"]["count"], 1)

    def test_lost_push_response_then_reset_counts_once(self):
        state = fresh_state()
        s = builds(1)[0]
        merge.apply(state, env("observe", [s], run="1.1"), CFG)
        w = work_id(s)
        e = env("observe", [outcome(w, "retryable", error="timeout"), failed("docs:pdf")], run="2.1")
        merge.apply(state, e, CFG)
        pushed = statefile.clone(state)        # the push landed; its response was lost
        merge.apply(pushed, e, CFG)            # the retry loop resets to origin and re-merges
        self.assertEqual(pushed["queue"][w]["attempts"], 1)
        self.assertEqual(pushed["health"]["scope/docs:pdf"]["count"], 1)
        self.assertEqual(statefile.snapshot(pushed), statefile.snapshot(state))

    def test_new_run_attempt_is_a_new_outcome(self):
        state = fresh_state()
        merge.apply(state, env("observe", [failed("docs:pdf")], run="5.1"), CFG)
        merge.apply(state, env("observe", [failed("docs:pdf")], run="5.2"), CFG)
        self.assertEqual(state["health"]["scope/docs:pdf"]["count"], 2)

    def test_clean_runs_are_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            state = fresh_state()
            scopes = [snap("docs:pdf", {"etag": "a"}), snap("xnu:latest", {"tag": "xnu-1"})]
            merge.apply(state, env("observe", scopes, run="1.1"), CFG)
            statefile.save(d, state)
            again = statefile.load(d)
            merge.apply(again, env("observe", scopes, run="2.1", date=versions.add_days(DATE, 1)), CFG)
            self.assertEqual(statefile.save(d, again), [], "no file changed, so no commit")


class ReviewFixes(unittest.TestCase):
    def test_replaying_an_applied_envelope_overwrites_nothing(self):
        state = fresh_state()
        old = env("observe", [snap("docs:pdf", {"etag": "old"}), snap("docs:blog", {"items": []})], run="1.1")
        merge.apply(state, old, CFG)
        merge.apply(state, env("observe", [snap("docs:pdf", {"etag": "new"}), failed("docs:blog", "parse")], run="2.1"), CFG)
        before = statefile.snapshot(state)
        merge.apply(state, old, CFG)   # a retry that meets newer state
        self.assertEqual(statefile.snapshot(state), before)
        self.assertEqual(state["scopes"]["docs:pdf"]["data"], {"etag": "new"})
        self.assertTrue(state["health"]["scope/docs:blog"]["open"])

    def test_observe_is_applied_before_kernelcache(self):
        with tempfile.TemporaryDirectory() as tmp:
            art = pathlib.Path(tmp)
            s = build("iOS;24A446", "27.0.1", [cand("iPhone18,2", ["T8150"])])
            w = work_id(s)
            observe = env("observe", [s, outcome(w, data=manifest_data("iOS;24A446", "27.0.1", [row("T8150")]))], run="3.1")
            kc = env("kernelcache", [outcome("kc:iOS;24A446", data={"type": "kernelcache", "os": "iOS", "build": "iOS;24A446",
                                                                    "version": "27.0.1", "beta": False, "tokens": [],
                                                                    "target": "T8150", "xnu": None})], run="3.1")
            write_envs(art, observe, kc)
            state = fresh_state()
            merge.merge(state, art, ["observe", "kernelcache"], CFG, run_id="3", run_attempt="1", run_date=DATE)
            self.assertEqual(state["queue"]["kc:iOS;24A446"]["status"], "done", "the same-run extraction was kept")

    def test_metadata_changes_refresh_unfinished_work_and_correct_finished_evidence(self):
        state = fresh_state()
        merge.apply(state, env("observe", [build("iOS;24A1", "27.0", [cand("a", ["T1"])]),
                                           build("iOS;24A2", "27.0", [cand("b", ["T2"])])], run="1.1"), CFG)
        w1, w2 = "manifest:iOS;24A1;a", "manifest:iOS;24A2;b"
        merge.apply(state, env("observe", [outcome(w2, data=manifest_data("iOS;24A2", "27.0", [row("T2")]))], run="2.1"), CFG)
        merge.apply(state, env("observe", [build("iOS;24A1", "27.0.1", [cand("a", ["T1"])]),
                                           build("iOS;24A2", "27.0.1", [cand("b", ["T2"])])], run="3.1"), CFG)
        self.assertEqual(state["queue"][w1]["version"], "27.0.1")
        self.assertEqual(state["queue"][w2]["status"], "done")
        self.assertEqual(state["evidence"][state["queue"][w2]["evidence"]]["data"]["version"], "27.0.1")

    def test_a_detector_crash_clears_when_it_completes_again(self):
        state = fresh_state()
        merge.apply(state, env("observe", [failed("firmware:run", "parse", "KeyError: 'sources'")], run="1.1"), CFG)
        self.assertTrue(state["health"]["scope/firmware:run"]["open"])
        merge.apply(state, env("observe", [snap("firmware:run", {"completed": True})], run="2.1"), CFG)
        self.assertNotIn("scope/firmware:run", state["health"])


class Queues(unittest.TestCase):
    def test_order_is_deterministic_and_prioritises_representatives_then_releases(self):
        state = fresh_state()
        merge.apply(state, env("observe", [
            build("iOS;24A100", "27.0", [cand("iPhone1,1", ["T8000"])]),
            build("iOS;24B5000a", "27.1", [cand("iPhone2,1", ["T8001"])], beta=True),
            build("iOS;24A200", "27.0.1", [cand("iPhone18,1", ["T8150"])]),
        ]), CFG)
        order = queue.schedule(state, "manifest", 10, DATE)
        self.assertEqual(order, ["manifest:iOS;24A200;iPhone18,1", "manifest:iOS;24A100;iPhone1,1",
                                 "manifest:iOS;24B5000a;iPhone2,1"])
        self.assertEqual(order, queue.schedule(statefile.clone(state), "manifest", 10, DATE))

    def test_date_backoff(self):
        state = fresh_state()
        s = builds(1)[0]
        merge.apply(state, env("observe", [s], run="1.1"), CFG)
        w = work_id(s)
        merge.apply(state, env("observe", [outcome(w, "retryable")], run="2.1"), CFG)
        self.assertEqual(state["queue"][w]["not_before"], versions.add_days(DATE, 1))
        self.assertEqual(queue.schedule(state, "manifest", 5, DATE), [])
        self.assertEqual(queue.schedule(state, "manifest", 5, versions.add_days(DATE, 1)), [w])
        merge.apply(state, env("observe", [outcome(w, "retryable")], run="3.1"), CFG)
        self.assertEqual(state["queue"][w]["not_before"], versions.add_days(DATE, 2))

    def test_source_change_requeues_unsupported_and_keys_new_evidence(self):
        state = fresh_state()
        aea = cand("AppleTV14,1", ["T8110"], url="https://updates.cdn-apple.com/x/u.aea", unsupported="aea-encrypted")
        merge.apply(state, env("observe", [build("tvOS;24J361", "27.0", [aea], fp="old")], run="1.1"), CFG)
        w = "manifest:tvOS;24J361;AppleTV14,1"
        self.assertEqual(state["queue"][w]["status"], "unsupported")
        merge.apply(state, env("observe", [build("tvOS;24J361", "27.0", [cand("AppleTV14,1", ["T8110"])], fp="new")],
                               run="2.1"), CFG)
        self.assertEqual(state["queue"][w]["status"], "pending")
        merge.apply(state, env("observe", [outcome(w, fp="new", data=manifest_data("tvOS;24J361", "27.0", [row("T8110")]))],
                               run="3.1"), CFG)
        self.assertIn(f"{w}@new", state["evidence"])

    def test_superseded_unfinished_work_is_dropped(self):
        state = fresh_state()
        merge.apply(state, env("observe", [build("iOS;24A1", "27.0", [cand("a", ["T1"])], fp="1")], run="1.1"), CFG)
        merge.apply(state, env("observe", [build("iOS;24A1", "27.0", [cand("b", ["T1"])], fp="2")], run="2.1"), CFG)
        self.assertEqual(sorted(state["queue"]), ["manifest:iOS;24A1;b"])


class Rotation(unittest.TestCase):
    def test_every_build_comes_round(self):
        keys = [f"iOS;24A{i}" for i in range(60)]
        seen, day = set(), DATE
        for _ in range(7):
            today = queue.rotation(keys, day, floor=25)
            self.assertLessEqual(len(today), 25)
            seen |= set(today)
            day = versions.add_days(day, 1)
        self.assertEqual(seen, set(keys))

    def test_slice_is_stable(self):
        keys = [f"iOS;24A{i}" for i in range(60)]
        self.assertEqual(queue.rotation(keys, DATE), queue.rotation(list(reversed(keys)), DATE))


class Retention(unittest.TestCase):
    def test_prune_keeps_boundaries_and_referenced(self):
        from upstream_watch import reconcile
        state = fresh_state()
        state["scopes"]["firmware:index:iOS"] = {"data": {"keys": ["iOS;25A1"]}, "first_seen": DATE, "changed_on": DATE}
        for key, sptm in (("iOS;23A1", False), ("iOS;23A2", False), ("iOS;24A1", True), ("iOS;24A2", True)):
            state["evidence"][f"manifest:{key};d@f"] = {"work_id": f"manifest:{key};d", "source_fp": "f",
                                                       "data": manifest_data(key, "1.0", [row("T8030", sptm)]),
                                                       "first_seen": DATE, "changed_on": DATE}
        reconcile.prune(state, refs={"manifest:iOS;24A2;d@f"})
        self.assertEqual(sorted(state["evidence"]), ["manifest:iOS;23A2;d@f", "manifest:iOS;24A1;d@f",
                                                     "manifest:iOS;24A2;d@f"])


if __name__ == "__main__":
    unittest.main()
