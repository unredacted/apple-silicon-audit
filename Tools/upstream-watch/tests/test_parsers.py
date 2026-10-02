import copy
import unittest

from helpers import FIXTURES, config, data, fresh_state, snap

import sdk_headers
from upstream_watch import reconcile
from upstream_watch.detectors import docs, xnu


class HeaderParsers(unittest.TestCase):
    def test_caps_bits_nb_gaps_and_aliases(self):
        nb, entries = sdk_headers.parse_caps_bits((FIXTURES / "cpu_capabilities_public.h").read_text())
        self.assertEqual(nb, 97)
        self.assertEqual([e["bit"] for e in entries], [0, 16, 51, 91])   # gaps stay gaps
        self.assertNotIn("CRC32", [e["name"] for e in entries])          # an alias is not a bit

    def test_cpufamily_new_families(self):
        fams, subs = sdk_headers.parse_cpufamily((FIXTURES / "machine.h").read_text())
        names = {f["name"]: f["value"] for f in fams}
        self.assertEqual(names["CPUFAMILY_ARM_NEVIS"], "0x37652b0c")
        self.assertIn("CPUFAMILY_ARM_BORNEO", names)
        self.assertIn("CPUFAMILY_ARM_KOMODO", names)
        self.assertEqual(next(f for f in fams if f["name"] == "CPUFAMILY_INTEL_PENRYN")["arch"], "x86_64")
        self.assertEqual(subs[1], {"value": 1, "name": "CPUSUBFAMILY_ARM_HP"})

    def test_arm_features(self):
        names = sdk_headers.parse_arm_features((FIXTURES / "arm_features.inc").read_text())
        self.assertEqual(names, ["FEAT_CRC32", "FEAT_NEWTHING", "FEAT_PAuth", "SME_F32F32"])

    def test_empty_headers_raise(self):
        for fn in (sdk_headers.parse_caps_bits, sdk_headers.parse_cpufamily, sdk_headers.parse_arm_features):
            with self.assertRaises(ValueError):
                fn("nothing here")

    def test_xnu_snapshot_shape(self):
        texts = {"features": (FIXTURES / "arm_features.inc").read_text(),
                 "caps": (FIXTURES / "cpu_capabilities_public.h").read_text(),
                 "machine": (FIXTURES / "machine.h").read_text()}
        d = xnu.parse("xnu-1.2.3", texts)
        self.assertEqual(d["cap_bit_nb"], 97)
        self.assertEqual(d["cpufamily"]["CPUFAMILY_ARM_KOMODO"], "0x6d0ccb0c")


class GuideTable(unittest.TestCase):
    def setUp(self):
        self.page = (FIXTURES / "guide.html").read_text()

    def topic(self, guide, matrix_data=None):
        state = fresh_state()
        state["scopes"]["docs:guide"] = {"data": guide, "first_seen": "x", "changed_on": "x"}
        d = matrix_data or data()
        t = reconcile.Topic("v1:gap/guide-table", "gap", "t", [], [], [])
        reconcile._guide(t, d, state, config())
        return t

    def test_parses_merged_columns_footnotes_and_malformed_anchor(self):
        g = docs.parse_guide(self.page)
        self.assertEqual(g["columns"], ["A10", "A11, S3", "A12-A14 | S4-S10", "A15-A18", "M1", "M2-M4", "A19 | M5"])
        self.assertEqual(g["rows"]["Page Protection Layer"], ["N", "Y", "Y", "N^1", "Y^2", "N", "N"])
        self.assertEqual(g["published"], "2026-01-28")
        self.assertEqual(set(g["footnotes"]), {"1", "2"})

    def test_real_matrix_matches(self):
        self.assertEqual(self.topic(docs.parse_guide(self.page)).items, {})

    def test_old_ppl_read_one_column_off_is_caught(self):
        d = data()
        d.matrix = copy.deepcopy(d.matrix)
        next(e for e in d.matrix["entries"] if e["id"] == "ppl")["columns_present"] = ["A12-A14", "S4-S10", "A15-A18"]
        items = self.topic(docs.parse_guide(self.page), d).items
        self.assertEqual(sorted(items), ["cell/ppl/A11-S3", "cell/ppl/A15-A18", "cell/ppl/M1"])

    def test_new_column_and_row(self):
        page = self.page.replace("<p><strong>A19</strong></p><p><strong>M5</strong></p>",
                                 "<p><strong>A19</strong></p><p><strong>M5</strong></p></td><td><p><strong>A20</strong></p>", 1)
        with self.assertRaises(docs.ParseError):   # rows now have fewer cells than columns
            docs.parse_guide(page)
        g = docs.parse_guide(self.page)
        g["columns"][-1] = "A19 | M5 | A20"
        g["rows"]["Exclave Monitor"] = ["N"] * 7
        items = self.topic(g).items
        self.assertIn("columns", items)
        self.assertIn("row/Exclave-Monitor", items)

    def test_unknown_icon_and_missing_table_are_parse_errors(self):
        with self.assertRaises(docs.ParseError):
            docs.parse_guide(self.page.replace("IL_red_x.png", "IL_partial.png", 1))
        with self.assertRaises(docs.ParseError):
            docs.parse_guide("<html><body><p>Published Date: January 28, 2026</p></body></html>")

    def test_published_date_mismatch(self):
        g = docs.parse_guide(self.page.replace("January 28, 2026", "October 2, 2026"))
        self.assertIn("published", self.topic(g).items)


class OtherDocs(unittest.TestCase):
    def test_revisions(self):
        r = docs.parse_revisions((FIXTURES / "revisions.html").read_text())
        self.assertEqual([s["title"] for s in r["sections"]], ["August 2026", "March 2026"])
        with self.assertRaises(docs.ParseError):
            docs.parse_revisions("<html></html>")

    def test_blog_keeps_only_security_apple_links(self):
        b = docs.parse_blog((FIXTURES / "feed.rss").read_bytes())
        self.assertEqual([i["link"] for i in b["items"]],
                         ["https://security.apple.com/blog/post-one", "https://security.apple.com/blog/post-two"])
        with self.assertRaises(docs.ParseError):
            docs.parse_blog(b"not xml")


if __name__ == "__main__":
    unittest.main()
