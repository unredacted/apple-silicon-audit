import unittest
from unittest import mock

from helpers import DATE, config, fresh_state

from upstream_watch import envelope, manifest, merge, versions
from upstream_watch.detectors import firmware
from upstream_watch.http import FetchError

CFG = config()
APPLEDB = firmware.APPLEDB


def source(devices, url, kind="ipsw"):
    return {"type": kind, "deviceMap": devices, "links": [{"url": url, "preferred": True, "active": True}]}


class FakeClient:
    def __init__(self, docs):
        self.docs = docs
        self.calls = []

    def get_json(self, url, **kw):
        self.calls.append(url)
        if url not in self.docs:
            raise FetchError(f"{url}: HTTP 404", retryable=False, status=404)
        return self.docs[url]


def build_doc(key, sources):
    os_, b = key.split(";")
    return {"key": key, "osStr": os_, "build": b, "version": "27.0", "beta": False, "sources": sources}


def appledb(keys, sources_for):
    docs = {f"{APPLEDB}/device/main.json": [{"identifier": ["iPhone12,1", "iPhone12,3"], "cpid": "0x8030", "soc": "A13"},
                                            {"identifier": ["AppleTV14,1"], "cpid": "0x8110", "soc": "A15"}],
            firmware.KDK_RELEASES: [], f"{APPLEDB}/ios/iOS/index.json": keys}
    for index in CFG["firmware"]["indexes"]:
        docs.setdefault(f"{APPLEDB}/ios/{index}/index.json", [])
    for k in keys:
        docs[f"{APPLEDB}/ios/{k}.json"] = build_doc(k, sources_for(k))
    return docs


def observe(state, client, date=DATE):
    b = envelope.Builder("observe", "1", "1", date)
    with mock.patch.object(manifest, "read", return_value=(None, {"BuildIdentities": []}, "")):
        firmware.observe(client, state, CFG, b, date, 40, 0)
    return b.doc


class BuildRecords(unittest.TestCase):
    def test_minimal_cover_prefers_ipsw_and_marks_aea(self):
        devices = {"iPhone12,1": "T8030", "iPhone12,3": "T8030", "AppleTV14,1": "T8110"}
        rec = firmware.build_record(build_doc("iOS;24A1", [
            source(["iPhone12,1"], "https://updates.cdn-apple.com/a.ipsw"),
            source(["iPhone12,3"], "https://updates.cdn-apple.com/b.ipsw"),            # same chip: not needed
            source(["iPhone12,1"], "https://updates.cdn-apple.com/d.zip", "ota") | {"prerequisiteBuild": "23A1"},
            source(["AppleTV14,1"], "https://updates.cdn-apple.com/c.aea", "ota"),
        ]), devices)
        self.assertEqual([(c["device"], c["unsupported"]) for c in rec["candidates"]],
                         [("AppleTV14,1", "aea-encrypted"), ("iPhone12,1", None)])

    def test_index_filter_drops_sim_sdk_and_duplicate_rc(self):
        keys = ["iOS;24A446", "iOS;24A446-RC", "iOS;24A94403-27A9269-SDK", "iOS;24A1-sim", "iOS;22A1", "iPadOS;24A446"]
        self.assertEqual(firmware.index_keys(keys, ["iOS", "iPadOS"], 22),
                         {"iOS": ["iOS;24A446"], "iPadOS": ["iPadOS;24A446"]})

    def test_bootstrap_tracks_the_newest_few_releases_and_betas(self):
        keys = ["iOS;23G90", "iOS;24A437", "iOS;24A446", "iOS;24A8428", "iOS;24B5089g", "iOS;24B5080a", "iOS;24B5070a"]
        self.assertEqual(firmware.bootstrap_picks(keys),
                         ["iOS;24A437", "iOS;24A446", "iOS;24A8428", "iOS;24B5080a", "iOS;24B5089g"])


class Observe(unittest.TestCase):
    def test_one_fetch_per_build_however_many_device_work_items(self):
        keys = ["iOS;24A1"]
        docs = appledb(keys, lambda k: [source(["iPhone12,1"], "https://updates.cdn-apple.com/a.ipsw"),
                                        source(["AppleTV14,1"], "https://updates.cdn-apple.com/b.ipsw")])
        state = fresh_state()
        client = FakeClient(docs)
        merge.apply(state, observe(state, client), CFG)                       # bootstrap: discovers and tracks
        self.assertEqual(len([w for w in state["queue"] if w.startswith("manifest:iOS;24A1;")]), 2)
        client.calls.clear()
        observe(state, client, versions.add_days(DATE, 1))
        self.assertLessEqual(client.calls.count(f"{APPLEDB}/ios/iOS;24A1.json"), 1)

    def test_unsupported_build_outside_first_slice_is_requeued_within_a_cycle(self):
        keys = [f"iOS;24A{i}" for i in range(60)]
        aea_only = {k: True for k in keys}
        docs_sources = lambda k: [source(["AppleTV14,1"], f"https://updates.cdn-apple.com/{k}.aea" if aea_only[k]
                                         else f"https://updates.cdn-apple.com/{k}.ipsw", "ota" if aea_only[k] else "ipsw")]
        state = fresh_state()
        state["scopes"]["firmware:index:iOS"] = {"data": {"keys": keys}, "first_seen": DATE, "changed_on": DATE}
        for k in keys:
            rec = firmware.build_record(build_doc(k, docs_sources(k)), {"AppleTV14,1": "T8110"})
            state["scopes"][f"firmware:build:{k}"] = {"data": rec, "first_seen": DATE, "changed_on": DATE}
        merge.apply(state, envelope.Builder("observe", "0", "1", DATE).doc, CFG)
        target = next(k for k in keys if k not in firmware.queue.rotation(keys, DATE))   # not in today's slice
        aea_only[target] = False                                                # an IPSW appears for it
        wid = f"manifest:{target};AppleTV14,1"
        self.assertEqual(state["queue"][wid]["status"], "unsupported")
        day = DATE
        for _ in range(7):
            client = FakeClient(appledb(keys, docs_sources))
            merge.apply(state, observe(state, client, day), CFG)
            day = versions.add_days(day, 1)
            if state["queue"][wid]["status"] != "unsupported":
                break
        self.assertIn(state["queue"][wid]["status"], ("pending", "done"))


if __name__ == "__main__":
    unittest.main()
