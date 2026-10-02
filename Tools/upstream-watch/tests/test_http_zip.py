import io
import plistlib
import unittest
import zipfile

from helpers import FakeServer

from upstream_watch import manifest
from upstream_watch.http import Client, FetchError
from upstream_watch.remote_zip import RemoteZip, Unsupported

URL = "https://updates.cdn-apple.com/x/Test_Restore.ipsw"


def make_zip(members, zip64=False):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data, method in members:
            info = zipfile.ZipInfo(name)
            info.compress_type = method
            with z.open(info, "w", force_zip64=zip64) as f:
                f.write(data)
    return buf.getvalue()


def client(server):
    return Client(opener=server, sleep=lambda s: None)


class RemoteZipTests(unittest.TestCase):
    payload = bytes(range(256)) * 400

    def test_stored_and_deflated_members(self):
        server = FakeServer({URL: make_zip([("a.bin", self.payload, zipfile.ZIP_STORED),
                                            ("k.bin", self.payload, zipfile.ZIP_DEFLATED)])})
        z = RemoteZip(client(server), URL)
        for name in ("a.bin", "k.bin"):
            out = io.BytesIO()
            self.assertEqual(z.fetch_member(name, out, max_compressed=1 << 20, max_size=1 << 20), len(self.payload))
            self.assertEqual(out.getvalue(), self.payload)

    def test_zip64(self):
        server = FakeServer({URL: make_zip([("m.bin", self.payload, zipfile.ZIP_DEFLATED)], zip64=True)})
        self.assertEqual(RemoteZip(client(server), URL).read("m.bin", 1 << 20), self.payload)

    def test_server_ignoring_range_is_refused_without_downloading(self):
        server = FakeServer({URL: make_zip([("a", b"x", zipfile.ZIP_STORED)])}, ignore_range=True)
        with self.assertRaises(FetchError) as cm:
            RemoteZip(client(server), URL)
        self.assertTrue(cm.exception.retryable)

    def test_wrong_content_range(self):
        server = FakeServer({URL: make_zip([("a", b"x", zipfile.ZIP_STORED)])}, bad_range=True)
        with self.assertRaises(FetchError):
            RemoteZip(client(server), URL)

    def test_inflation_over_cap(self):
        server = FakeServer({URL: make_zip([("z", b"\0" * 200000, zipfile.ZIP_DEFLATED)])})
        z = RemoteZip(client(server), URL)
        with self.assertRaises(Unsupported):
            z.fetch_member("z", io.BytesIO(), max_compressed=1 << 20, max_size=1000)

    def test_aea_is_unsupported_without_a_request(self):
        server = FakeServer()
        with self.assertRaises(Unsupported):
            RemoteZip(client(server), "https://updates.cdn-apple.com/x/update.aea")
        self.assertEqual(server.requests, [])


class HttpTests(unittest.TestCase):
    def test_redirect_within_allowlist(self):
        target = "https://raw.githubusercontent.com/a/b"
        server = FakeServer({target: b"ok"}, redirects={"https://github.com/a/b": target})
        self.assertEqual(client(server).request("https://github.com/a/b").body, b"ok")

    def test_redirect_off_allowlist_is_refused(self):
        server = FakeServer(redirects={"https://github.com/a/b": "https://evil.example/x"})
        with self.assertRaises(FetchError) as cm:
            client(server).request("https://github.com/a/b")
        self.assertFalse(cm.exception.retryable)

    def test_non_https_refused(self):
        with self.assertRaises(FetchError):
            client(FakeServer()).request("http://updates.cdn-apple.com/x")

    def test_token_only_to_api_github(self):
        server = FakeServer({"https://api.github.com/x": b"{}", "https://api.appledb.dev/y": b"{}"},
                            redirects={"https://api.github.com/r": "https://api.appledb.dev/y"})
        c = Client(token="secret", opener=server, sleep=lambda s: None)
        c.request("https://api.github.com/x")
        c.request("https://api.appledb.dev/y")
        c.request("https://api.github.com/r")
        auth = {url: "Authorization" in h for url, h in server.requests}
        self.assertTrue(auth["https://api.github.com/x"])
        self.assertFalse(auth["https://api.appledb.dev/y"])

    def test_404_is_not_retryable(self):
        with self.assertRaises(FetchError) as cm:
            client(FakeServer()).request("https://api.appledb.dev/missing")
        self.assertFalse(cm.exception.retryable)


class ManifestTests(unittest.TestCase):
    def manifest(self, variant):
        ident = {"ApChipID": "0x8030", "Info": {"Variant": variant, "DeviceClass": "N104AP"},
                 "Manifest": {"Ap,SecurePageTableMonitor": {"Info": {"Path": "Firmware/sptm.t8030.release.im4p"}},
                              "Ap,TrustedExecutionMonitor": {"Info": {"Path": "Firmware/txm.iphoneos.release.im4p"}},
                              "KernelCache": {"Info": {"Path": "kernelcache.release.iphone12b"}}}}
        return {"BuildIdentities": [ident, {**ident, "Info": {"Variant": "Customer Upgrade Install", "DeviceClass": "x"}}]}

    def test_erase_identities_preferred(self):
        rows = manifest.rows(self.manifest("Customer Erase Install (IPSW)"))
        self.assertEqual(rows, [{"chip": "T8030", "board": "n104ap", "sptm": "sptm.t8030.release.im4p",
                                 "txm": "txm.iphoneos.release.im4p", "kernelcache": "kernelcache.release.iphone12b"}])

    def test_ota_falls_back_to_all_identities(self):
        self.assertEqual(len(manifest.rows(self.manifest("Customer Software Update"))), 2)

    def test_ota_manifest_prefix(self):
        bm = plistlib.dumps(self.manifest("Customer Software Update"))
        server = FakeServer({URL: make_zip([("AssetData/boot/BuildManifest.plist", bm, zipfile.ZIP_DEFLATED)])})
        _, parsed, prefix = manifest.read(client(server), URL)
        self.assertEqual(prefix, "AssetData/boot/")
        self.assertEqual(manifest.chip(32816), "T8030")


if __name__ == "__main__":
    unittest.main()
