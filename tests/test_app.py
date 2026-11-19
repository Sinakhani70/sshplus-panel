"""Unit tests for the pure helpers of panel/app.py (no root, no services needed).

run:  python3 -m unittest discover -s tests -v
"""
import importlib.util
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("panel_app", os.path.join(ROOT, "panel", "app.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class PortMapping(unittest.TestCase):
    def test_free_ports_keep_their_number(self):
        self.assertEqual(app.rev_map_calc([442, 444], set()), {442: 442, 444: 444})

    def test_busy_port_is_moved_not_dropped(self):
        m = app.rev_map_calc([442, 444], {442})
        self.assertEqual(m[444], 444)
        self.assertNotEqual(m[442], 442)
        self.assertEqual(m[442], 10442)               # p + 10000 first

    def test_port_22_of_the_exit_server_is_never_used(self):
        self.assertNotIn(22, app.rev_map_calc([22, 2222], set()).values())

    def test_mapped_ports_never_collide(self):
        m = app.rev_map_calc([442, 10442, 444], {442, 10442})
        self.assertEqual(len(set(m.values())), len(m))
        self.assertTrue(set(m.values()).isdisjoint({442, 10442}))

    def test_unknown_listeners_are_tolerated(self):
        self.assertEqual(app.rev_map_calc([8443], None), {8443: 8443})


class SubscriptionLinks(unittest.TestCase):
    X = {"u": "shop1", "pw": "p@ss word", "host": "203.0.113.5", "db": [442, 444], "ssh": [22, 442]}

    def test_one_link_per_port_without_duplicates(self):
        links = app.ssh_uris(self.X)
        self.assertEqual(len(links), 3)                         # 442, 444, 22  (442 only once)
        self.assertTrue(all(l.startswith("ssh://shop1:") for l in links))

    def test_password_is_url_encoded(self):
        self.assertIn("p%40ss%20word", app.ssh_uris(self.X)[0])

    def test_remark_names_the_port(self):
        self.assertTrue(app.ssh_uris(self.X)[0].endswith("#CK.VPN-shop1-442"))

    def test_base64_userinfo_variant(self):
        import base64
        from urllib.parse import unquote, urlsplit
        u = urlsplit(app.ssh_uris(self.X, True)[0])
        self.assertEqual(base64.b64decode(unquote(u.username)).decode(), "shop1:p@ss word")


class Validation(unittest.TestCase):
    def test_tunnel_params_accepts_a_normal_request(self):
        p, err = app.tunnel_params({"host": "10.0.0.2", "port": 22, "user": "root", "pw": "x"})
        self.assertIsNone(err)
        self.assertEqual(p, ("10.0.0.2", 22, "root", "x"))

    def test_tunnel_params_rejects_option_injection_and_junk(self):
        for bad in ({"host": "-oProxyCommand=x"}, {"host": "a b"}, {"host": "ok", "port": 99999}, {"host": "ok", "user": "Root!"}, {"host": "ok", "pw": ""}):
            d = {"host": "10.0.0.2", "port": 22, "user": "root", "pw": "x"}
            d.update(bad)
            self.assertIsNotNone(app.tunnel_params(d)[1], bad)

    def test_account_names(self):
        for good in ("user1", "_x", "a-b_c"):
            self.assertTrue(app.NAME_RE.match(good), good)
        for bad in ("1user", "a b", "x" * 40, "a;b", "<img src=x>"):
            self.assertFalse(app.NAME_RE.match(bad), bad)

    def test_to_port(self):
        self.assertEqual(app.to_port("443"), 443)
        self.assertEqual(app.to_port("0"), 0)
        self.assertEqual(app.to_port("70000"), 0)
        self.assertEqual(app.to_port("abc"), 0)


class Formatting(unittest.TestCase):
    def test_fmt_bytes(self):
        self.assertEqual(app.fmt_bytes(0), "0 B")
        self.assertEqual(app.fmt_bytes(1536), "1.5 KB")
        self.assertEqual(app.fmt_bytes(5 * 1024 ** 3), "5.0 GB")

    def test_traffic_text(self):
        self.assertEqual(app.fmt_traffic(0), "0 MB")
        self.assertEqual(app.fmt_traffic(1073741824 * 2), "2.0 GB")
        self.assertEqual(app.fmt_traffic(5 * 1048576), "5.0 MB")


@unittest.skipUnless(app.HAVE_FERNET, "python3-cryptography not installed")
class Secrets(unittest.TestCase):
    def setUp(self):
        self._old = app.SECRETK
        self._tmp = tempfile.mkdtemp()
        app.SECRETK = os.path.join(self._tmp, "secret.key")
        app._FER[0] = None

    def tearDown(self):
        app.SECRETK = self._old
        app._FER[0] = None

    def test_encrypt_roundtrip_and_not_plaintext(self):
        e = app.enc("SecretPw1")
        self.assertTrue(e.startswith("enc:"))
        self.assertNotIn("SecretPw1", e)
        self.assertEqual(app.dec(e), "SecretPw1")

    def test_plaintext_is_passed_through(self):
        self.assertEqual(app.dec("old-plain"), "old-plain")

    def test_garbage_does_not_crash(self):
        self.assertEqual(app.dec("enc:not-a-token"), "")

    def test_key_file_is_private(self):
        app.enc("x")
        self.assertEqual(oct(os.stat(app.SECRETK).st_mode & 0o777), "0o600")

    def test_backup_rejects_foreign_data_and_wrong_passphrase(self):
        code, _ = app.restore_backup(b"not a backup at all", "abcdef")
        self.assertEqual(code, 400)
        salt = b"s" * 16
        fake = app.BK_MAGIC + salt + app.Fernet(app.bk_key("right-pass", salt)).encrypt(b"{}")
        code, r = app.restore_backup(fake, "wrong-pass")
        self.assertEqual((code, r["ok"]), (400, 0))


class Translations(unittest.TestCase):
    """the English UI: every Persian key must have a non-empty English value and sane placeholders"""
    def test_dictionary_shape(self):
        import json, re
        with open(os.path.join(ROOT, "panel", "ui.js"), encoding="utf-8") as f:
            html = f.read()
        m = re.search(r"const EN=(\{.*?\}), ENP=", html, re.S)
        self.assertIsNotNone(m)
        en = json.loads(m.group(1))
        self.assertGreater(len(en), 100)
        for fa, e in en.items():
            self.assertTrue(e.strip(), fa)
            self.assertFalse(re.search(r"[؀-ۿ]", e), "Persian left in the English value of: " + fa)


if __name__ == "__main__":
    unittest.main()
