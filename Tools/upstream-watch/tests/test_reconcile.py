import unittest

from helpers import DATE, config, data, fresh_state, manifest_data, row

from upstream_watch import reconcile, render, versions
from upstream_watch.detectors import kernelcache

CFG = config()


def with_manifests(*records):
    """records: (build key, version, [rows], beta)."""
    state = fresh_state()
    for i, (key, version, rows, *beta) in enumerate(records):
        state["evidence"][f"manifest:{key};d{i}@f"] = {
            "work_id": f"manifest:{key};d{i}", "source_fp": "f", "first_seen": DATE, "changed_on": DATE,
            "data": manifest_data(key, version, rows, beta=bool(beta and beta[0]))}
    return state


def run(state, **kw):
    return reconcile.reconcile(state, data(), CFG, {}, **kw)


# The evidence table in docs/evidence/sptm-txm-firmware.md, as observations.
EVIDENCE = [
    ("iOS;23G90", "26.6.2", [row("T8030", False), row("T8101", False)]),
    ("iOS;24A437", "27.0", [row("T8030"), row("T8101")]),
    ("iPadOS;23G90", "26.6.2", [row("T8103", False)]),
    ("iPadOS;24A446", "27.0.1", [row("T8103")]),
    ("macOS;26A434", "27.0.1", [row("T8103"), row("T6000"), row("T6001"), row("T6002")]),
    ("macOS;25D2128", "26.3.1", [row("T6000", False)]),
    ("macOS;25E246", "26.4", [row("T6000")]),
    ("iOS;24A446", "27.0.1", [row("T8110")]),
    ("tvOS;24J361", "27.0", [row("T8020", False)]),
    ("watchOS;23U67", "26.6", [row("T8310"), row("T8301", False)]),
    ("watchOS;24R365", "27.0.1", [row("T8310")]),
]


class SPTM(unittest.TestCase):
    def test_backport_chips_are_covered(self):
        rec = run(with_manifests(*EVIDENCE))
        self.assertEqual(rec["topics"]["v1:gap/sptm"].items, {})
        covered = " ".join(rec["covered"])
        for chip in ("T8030", "T8101", "T8103", "T6000", "T6001", "T6002", "T8310"):
            self.assertIn(chip, covered)

    def test_without_exceptions_they_would_have_been_flagged(self):
        items = run(with_manifests(*EVIDENCE), ignore_exceptions=True)["topics"]["v1:gap/sptm"].items
        self.assertEqual(sorted(items), ["uncovered/T6000/macOS", "uncovered/T6001/macOS", "uncovered/T6002/macOS",
                                         "uncovered/T8030/iOS", "uncovered/T8101/iOS", "uncovered/T8103/iPadOS",
                                         "uncovered/T8103/macOS", "uncovered/T8310/watchOS"])
        self.assertEqual(items["uncovered/T8030/iOS"]["material"]["first"], "27.0 (24A437)")

    def test_overbroad_early_missing_mismatch(self):
        items = run(with_manifests(
            ("iOS;24A500", "27.1", [row("T8030", False)]),            # exception applies, no SPTM
            ("macOS;25C10", "26.2", [row("T6000")]),                   # SPTM before the 26.4 exception
            ("iOS;24A501", "27.1", [row("T8110", False)]),             # table says present, none booted
            ("iOS;24A502", "27.1", [row("T8120", True, False)]),       # SPTM without TXM
        ))["topics"]["v1:gap/sptm"].items
        self.assertIn("overbroad/T8030/iOS", items)
        self.assertIn("early/T6000/macOS", items)
        self.assertIn("missing/T8110/iOS", items)
        self.assertIn("txm-mismatch/T8120/iOS", items)

    def test_platform_divergence(self):
        items = run(with_manifests(("iOS;24A446", "27.0.1", [row("T8103", False)]),
                                   ("macOS;26A434", "27.0.1", [row("T8103")])))["topics"]["v1:gap/sptm"].items
        self.assertIn("platform-divergence/T8103/27.0.1", items)

    def test_latest_is_evidence_not_material(self):
        one = run(with_manifests(("iOS;24A437", "27.0", [row("T8030")])), ignore_exceptions=True)
        two = run(with_manifests(("iOS;24A437", "27.0", [row("T8030")]), ("iOS;24A446", "27.0.1", [row("T8030")])),
                  ignore_exceptions=True)
        self.assertEqual(one["topics"]["v1:gap/sptm"].hashes(), two["topics"]["v1:gap/sptm"].hashes())


class OtherGaps(unittest.TestCase):
    def test_soc_map_chips_names_and_ignores(self):
        state = with_manifests(("iOS;24B5089g", "27.2", [row("T8160"), row("TFE00", False)], True))
        state["scopes"]["firmware:kdk"] = {"data": {"targets": ["T6050", "T8152", "VMAPPLE"]}, "first_seen": DATE, "changed_on": DATE}
        state["scopes"]["firmware:devices"] = {"data": {"devices": {}, "socs": {"T6034": ["M3 Max"], "T8301": ["S6", "S7", "S8"]}},
                                               "first_seen": DATE, "changed_on": DATE}
        items = run(state)["topics"]["v1:gap/soc-map"].items
        self.assertEqual(sorted(items), ["chip/T8152", "chip/T8160", "name/T6034"])

    def test_results_keys_with_security_hint(self):
        items = run(fresh_state())["topics"]["v1:gap/known-keys"].items
        self.assertEqual(items["key/hw.optional.arm.FEAT_PAuth_LR"]["row"]["note"], "possibly security-relevant")
        self.assertEqual(items["key/hw.optional.arm.FEAT_LUT"]["row"]["note"], "")
        self.assertIn("measured", items["key/hw.optional.arm.FEAT_LUT"]["row"]["source"])

    def test_kernelcache_tokens_fold_into_corroborated_keys(self):
        blob = b"\x00FEAT_LUT\x00FEAT_NEWX\x00FEAT_PAuth\x00Darwin Kernel Version 27.0.0: x; root:xnu-13432.1~1/RELEASE_ARM64_T8150\x00"
        found = kernelcache.extract(blob)
        self.assertEqual(found["target"], "T8150")
        self.assertEqual(found["xnu"], "xnu-13432.1")
        self.assertEqual(found["tokens"], ["FEAT_LUT", "FEAT_NEWX", "FEAT_PAuth"])
        state = fresh_state()
        state["evidence"]["kc:iOS;24A446@f"] = {"work_id": "kc:iOS;24A446", "source_fp": "f", "first_seen": DATE,
                                                "changed_on": DATE, "data": {"type": "kernelcache", "os": "iOS",
                                                "build": "iOS;24A446", "version": "27.0.1", "beta": False, **found}}
        topics = run(state)["topics"]
        self.assertIn("kernelcache", topics["v1:gap/known-keys"].items["key/hw.optional.arm.FEAT_LUT"]["row"]["source"])
        self.assertEqual(sorted(topics["v1:gap/kernelcache"].items), ["token/FEAT_NEWX"])
        self.assertIn("heuristic", topics["v1:gap/kernelcache"].labels)

    def test_caps_nb_and_families_from_headers(self):
        state = fresh_state()
        sdk = {"name": "macosx27.0", "cap_bit_nb": 97, "caps": {"FEAT_SVE_B16B16": 91},
               "cpufamily": {"CPUFAMILY_ARM_NEVIS": "0x37652b0c"}, "cpusubfamily": {}}
        state["scopes"]["headers@xcode-27:/Applications/Xcode.app"] = {"data": {"xcode": "Xcode 27.0", "sdks": {"macosx": sdk}},
                                                                     "first_seen": DATE, "changed_on": DATE}
        topics = run(state)["topics"]
        self.assertEqual(topics["v1:gap/caps-bits"].items["nb"]["row"]["upstream"], "97")
        self.assertIn("family/CPUFAMILY_ARM_NEVIS", topics["v1:gap/cpufamily"].items)

    def test_ignore_list(self):
        rec = reconcile.reconcile(fresh_state(), data(), CFG,
                                  {"v1:gap/known-keys#key/hw.optional.arm.FEAT_FP8": {"reason": "tracked elsewhere"}})
        t = rec["topics"]["v1:gap/known-keys"]
        self.assertNotIn("key/hw.optional.arm.FEAT_FP8", t.items)
        self.assertIn("tracked elsewhere", render.body(t))


class VersionsAndRender(unittest.TestCase):
    def test_at_least_mirrors_documented_matrix(self):
        self.assertTrue(versions.at_least("27", "27.0"))
        self.assertFalse(versions.at_least("26.99", "27.0"))
        self.assertTrue(versions.at_least("", "27.0"))
        self.assertTrue(versions.at_least(None, "27.0"))
        self.assertTrue(versions.at_least("10.1", "10.1"))

    def test_build_order(self):
        builds = ["24A446", "24A5279h", "23G90", "24B100"]
        self.assertEqual(sorted(builds, key=versions.build_key), ["23G90", "24A446", "24A5279h", "24B100"])

    def test_escaping_and_markers_round_trip(self):
        t = reconcile.Topic("v1:gap/x", "gap", "Title @someone", ["watch"], ["subject"], ["do it"])
        t.add("key/a.b", {"m": 1}, {"subject": "evil @user #3 | `x` <img>"})
        body = render.body(t)
        self.assertNotIn("@user", body)
        self.assertIn("\\|", body)
        self.assertNotIn("<img>", body)
        fp, items = render.parse_markers(body)
        self.assertEqual(fp, "v1:gap/x")
        self.assertEqual(items, t.hashes())
        self.assertNotIn("@someone", render.title(t))

    def test_links_only_to_allowlisted_hosts(self):
        self.assertIn("](https://security.apple.com/blog/x)", render.cell("https://security.apple.com/blog/x"))
        self.assertNotIn("](", render.cell("https://evil.example/x"))


if __name__ == "__main__":
    unittest.main()
