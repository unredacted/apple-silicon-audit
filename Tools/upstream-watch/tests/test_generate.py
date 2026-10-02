import contextlib
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import helpers  # noqa: F401  (sets sys.path)
import generate


class GenerateCheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = pathlib.Path(self.tmp.name)
        self.patch = mock.patch.object(generate, "OUT", self.out)
        self.patch.start()
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()

    def tearDown(self):
        self.quiet.__exit__(None, None, None)
        self.patch.stop()
        self.tmp.cleanup()

    def committed(self, obj):
        (self.out / "f.json").write_text(json.dumps(obj, indent=2) + "\n")

    def test_dates_alone_pass(self):
        self.committed({"version": "2026-01-01", "verified": "2026-01-01", "entries": [1]})
        self.assertTrue(generate.check("f.json", {"version": "2027-01-01", "verified": "2027-01-01", "entries": [1]}))

    def test_content_change_fails(self):
        self.committed({"version": "2026-01-01", "verified": "2026-01-01", "entries": [1]})
        self.assertFalse(generate.check("f.json", {"version": "2026-01-01", "verified": "2026-01-01", "entries": [2]}))

    def test_write_keeps_dates_when_content_unchanged(self):
        self.committed({"version": "2026-01-01", "verified": "2026-01-01", "entries": [1]})
        generate.write("f.json", {"version": "2027-01-01", "verified": "2027-01-01", "entries": [1]})
        self.assertEqual(json.loads((self.out / "f.json").read_text())["version"], "2026-01-01")
        generate.write("f.json", {"version": "2027-01-01", "verified": "2027-01-01", "entries": [2]})
        self.assertEqual(json.loads((self.out / "f.json").read_text())["version"], "2027-01-01")

    def test_security_hint_key_needs_curation(self):
        extra = generate.observed_keys() | {"hw.optional.arm.FEAT_PAuth_LR"}
        with mock.patch.object(generate, "observed_keys", return_value=extra):
            with self.assertRaises(SystemExit):
                generate.known_keys()
        plain = generate.observed_keys() | {"hw.optional.arm.FEAT_LUT"}
        with mock.patch.object(generate, "observed_keys", return_value=plain), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            keys = generate.known_keys()
        self.assertIn("FEAT_LUT", err.getvalue())
        self.assertIn("hw.optional.arm.FEAT_LUT", {e["key"] for e in keys["entries"]})

    def test_import_looks_up_no_sdk(self):
        import subprocess
        import sys
        r = subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, 'Tools/gen-data'); "
                            "import generate; print(generate._SDK)"], cwd=helpers.ROOT, env={"PATH": "/nonexistent"},
                           capture_output=True, text=True)
        self.assertEqual(r.stdout.strip(), "None", r.stderr)


if __name__ == "__main__":
    unittest.main()
