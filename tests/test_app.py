"""Unit tests for the pure helpers of panel/app.py (no root, no services needed).

run:  python3 -m unittest discover -s tests -v
"""
import importlib.util
import json
import os
import re
import tempfile
import time
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


class ShellMatrix(unittest.TestCase):
    """account = type (direct/tunnel) x connection (both/normal/tls): the login shell encodes it"""
    def test_roundtrip_and_distinct(self):
        seen = set()
        for tm in ("direct", "tunnel"):
            for cx in ("both", "normal", "tls"):
                sh = app.shell_for(tm, cx)
                self.assertEqual(app.SHELL_OF[sh], (tm, cx))
                seen.add(sh)
        self.assertEqual(len(seen), 6)

    def test_old_accounts_keep_working_on_both(self):
        self.assertEqual(app.SHELL_OF[app.SHELL], ("direct", "both"))           # shells written by v1.2 - v1.6
        self.assertEqual(app.SHELL_OF[app.SHELL_T], ("tunnel", "both"))

    def test_junk_falls_back_to_direct_both(self):
        self.assertEqual(app.shell_for("x", "y"), app.SHELL)

    def test_is_tun(self):
        self.assertTrue(all(app.is_tun(app.shell_for("tunnel", c)) for c in ("both", "normal", "tls")))
        self.assertFalse(any(app.is_tun(app.shell_for("direct", c)) for c in ("both", "normal", "tls")))
        self.assertFalse(app.is_tun("/bin/bash"))

    def test_each_instance_serves_only_its_shells(self):
        d = tempfile.mkdtemp(); old = (app.SHELLS_DIR, app.ETC_SHELLS)
        try:
            app.SHELLS_DIR = d; app.ETC_SHELLS = os.path.join(d, "shells")
            open(app.ETC_SHELLS, "w").write("/bin/sh\n/bin/bash\n" + "\n".join(app.SHELLS.values()) + "\n")
            app.tls_shell_files()
            got = {k: set(open(os.path.join(d, "shells." + k)).read().split()) for k in ("direct", "tunnel", "tlsd", "tlst")}
        finally:
            app.SHELLS_DIR, app.ETC_SHELLS = old
        W = app.shell_for
        self.assertEqual(got["direct"] & set(app.SHELLS.values()), {W("direct", "both"), W("direct", "normal")})
        self.assertEqual(got["tunnel"] & set(app.SHELLS.values()), {W("tunnel", "both"), W("tunnel", "normal")})
        self.assertEqual(got["tlsd"] & set(app.SHELLS.values()), {W("direct", "both"), W("direct", "tls")})
        self.assertEqual(got["tlst"] & set(app.SHELLS.values()), {W("tunnel", "both"), W("tunnel", "tls")})
        self.assertTrue(all("/bin/sh" in v for v in got.values()))


class TlsLinks(unittest.TestCase):
    X = {"u": "u1", "pw": "p w", "host": "1.2.3.4", "db": [442], "ssh": [22], "cx": "both",
         "tls": {"host": "vpn.example.com", "ports": [443], "sni": "vpn.example.com", "insecure": False}}

    def test_plain_and_tls_links_for_both(self):
        links = app.ssh_uris(self.X)
        self.assertEqual(len(links), 3)
        self.assertIn("ssh://u1:p%20w@1.2.3.4:442#CK.VPN-u1-442", links)
        self.assertIn("ssh://u1:p%20w@vpn.example.com:443?security=tls&sni=vpn.example.com#CK.VPN-u1-TLS-443", links)

    def test_self_signed_asks_for_allow_insecure(self):
        x = dict(self.X, tls={"host": "1.2.3.4", "ports": [443, 2096], "sni": "", "insecure": True})
        tls = [l for l in app.ssh_uris(x) if "security=tls" in l]
        self.assertEqual(len(tls), 2)
        self.assertTrue(all("allowInsecure=1" in l and "sni=" not in l for l in tls))
        x["tls"]["sni"] = "d.example.com"                                    # a domain but still a self-signed certificate
        self.assertTrue(all("sni=d.example.com" in l and "allowInsecure=1" in l for l in [l for l in app.ssh_uris(x) if "security=tls" in l]))

    def test_tls_only_account_gets_no_plain_link(self):
        x = dict(self.X, cx="tls", db=[], ssh=[])
        links = app.ssh_uris(x)
        self.assertEqual(len(links), 1); self.assertIn("security=tls", links[0])
        self.assertIn("security=tls", app.ssh_uri(x))                 # QR / single link follows

    def test_no_tls_key_means_old_behaviour(self):
        x = {k: v for k, v in self.X.items() if k != "tls"}
        self.assertEqual(len(app.ssh_uris(x)), 2)
        self.assertNotIn("security=tls", app.ssh_uri(x))

    def test_base64_userinfo_variant_also_for_tls(self):
        import base64
        from urllib.parse import unquote, urlsplit
        l = [l for l in app.ssh_uris(self.X, True) if "security=tls" in l][0]
        self.assertEqual(base64.b64decode(unquote(urlsplit(l).username)).decode(), "u1:p w")


class TlsConfig(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.old = {k: getattr(app, k) for k in ("TLSC", "STUN_CONF", "CERT", "CKEY", "PORTS", "CFG", "BV", "listen_ports", "sshd_ports", "cmd", "have", "cert_meta", "ufw_open", "ensure_cert", "tls_shell_files", "_run")}
        app.TLSC = self.t + "/tls.json"; app.STUN_CONF = self.t + "/stunnel.conf"; app.CERT = self.t + "/c.crt"; app.CKEY = self.t + "/c.key"
        app.PORTS = self.t + "/ports.json"; app.CFG = self.t + "/panel.json"; app.BV = self.t + "/bv.conf"
        with open(app.PORTS, "w") as f: json.dump({"ssh": 22, "ssh2": 2222, "db": [442, 444], "tdb": [2087]}, f)
        app.listen_ports = lambda: {}; app.sshd_ports = lambda: {22, 2222}; app.cmd = lambda *a, **k: (0, "", "")
        app.have = lambda n: True; app.ufw_open = lambda p: "none"; app.ensure_cert = lambda: True; app.tls_shell_files = lambda: None
        app._run = lambda *a, **k: (0, "", "")

    def tearDown(self):
        for k, v in self.old.items(): setattr(app, k, v)

    def test_defaults_are_off(self):
        c = app.tls_cfg()
        self.assertFalse(c["on"]); self.assertEqual((c["ports"], c["tports"], c["mode"]), ([443], [8843], "self"))

    def test_ports_cannot_collide_with_other_listeners(self):
        for bad in (442, 2087, 2222, 22, 80, 2053, 7300, 7301):                    # dropbear, tunnel dropbear, sshd, panel, udpgw
            c, r = app.tls_apply({"on": False, "ports": [bad], "tports": [8843]})
            self.assertEqual(c, 400, bad)
        app.listen_ports = lambda: {8080: {"nginx"}}
        self.assertEqual(app.tls_apply({"on": False, "ports": [8080], "tports": [8843]})[0], 400)       # held by another program
        app.listen_ports = lambda: {8443: {"stunnel"}}
        self.assertEqual(app.tls_apply({"on": False, "ports": [8443], "tports": [8843]})[0], 200)       # our own front may keep its port

    def test_normal_and_tunnel_ports_are_distinct(self):
        c, r = app.tls_apply({"on": False, "ports": [443, 8843], "tports": [8843, 9444]})
        self.assertEqual(c, 200)
        cfg = app.tls_cfg(); self.assertEqual((cfg["ports"], cfg["tports"]), ([443, 8843], [9444]))
        self.assertEqual(r["dropped"], ["8843"])

    def test_both_kinds_need_a_port(self):
        self.assertEqual(app.tls_apply({"on": False, "ports": [], "tports": [8843]})[0], 400)
        self.assertEqual(app.tls_apply({"on": False, "ports": [443], "tports": []})[0], 400)

    def test_domain_is_validated(self):
        self.assertEqual(app.tls_apply({"on": False, "domain": "bad domain;rm"})[0], 400)
        app.cert_meta = lambda: {"self": True}                                   # a domain alone does not make the certificate trusted
        self.assertEqual(app.tls_apply({"on": False, "domain": "VPN.Example.com"})[0], 200)
        self.assertEqual((app.tls_cfg()["domain"], app.tls_cfg()["mode"]), ("vpn.example.com", "self"))
        app.cert_meta = lambda: {"self": False}
        app.tls_apply({"on": False, "domain": "vpn.example.com"}); self.assertEqual(app.tls_cfg()["mode"], "own")
        app.tls_apply({"on": False, "domain": ""}); self.assertEqual(app.tls_cfg()["mode"], "self")

    def test_stunnel_config(self):
        app.stunnel_write(app.tls_cfg())
        with open(app.STUN_CONF) as f: t = f.read()
        n = app.TLS_BACKENDS
        d = "".join("connect = 127.0.0.1:%d\n" % (40100 + i) for i in range(n)); tt = "".join("connect = 127.0.0.1:%d\n" % (40120 + i) for i in range(n))
        self.assertIn("[tls-d-443]\naccept = 0.0.0.0:443\n" + d + "failover = rr", t)        # round-robin over several Dropbear processes
        self.assertIn("[tls-t-8843]\naccept = 0.0.0.0:8843\n" + tt + "failover = rr", t)
        self.assertIn("cert = " + app.CERT, t); self.assertIn("sslVersionMin = TLSv1.2", t)
        self.assertEqual(oct(os.stat(app.STUN_CONF).st_mode & 0o777), "0o600")

    def test_backend_ports_move_if_something_else_listens(self):
        app.listen_ports = lambda: {40103: {"python3"}}                           # inside the first block
        bd, bt = app.tls_backends(app.tls_cfg())
        self.assertNotEqual(bd, 40100)
        self.assertTrue(set(range(bd, bd + app.TLS_BACKENDS)).isdisjoint(range(bt, bt + app.TLS_BACKENDS)))
        app.listen_ports = lambda: {40103: {"dropbear"}}                          # our own instance: keep
        self.assertEqual(app.tls_backends(app.tls_cfg()), (40100, 40120))

    def test_other_features_keep_away_from_tls_ports(self):
        self.assertEqual(app.tls_taken(), {443, 8843} | set(range(40100, 40106)) | set(range(40120, 40126)))


class FreeDomains(unittest.TestCase):
    def test_names_built_from_the_ip(self):
        self.assertEqual(app.free_name("sslip", "1.2.3.4", {}), "1-2-3-4.sslip.io")
        self.assertEqual(app.free_name("nip", "10.0.0.9", {}), "10-0-0-9.nip.io")
        self.assertEqual(app.free_name("custom", "1.2.3.4", {"suffix": "wild.test"}), "1-2-3-4.wild.test")
        self.assertEqual(app.free_name("duckdns", "1.2.3.4", {"duckname": "abc"}), "abc.duckdns.org")
        self.assertEqual(app.free_name("nope", "1.2.3.4", {}), "")

    def test_domain_syntax(self):
        for good in ("vpn.example.com", "1-2-3-4.sslip.io", "a.b.co"):
            self.assertTrue(app.DOM_RE.match(good), good)
        for bad in ("localhost", "a b.com", "x.com;ls", "-a.com", "a..com", "x" * 70 + ".com", "$(id).com", "a.com\n"):    # "\n": `$` would let it through
            self.assertFalse(app.DOM_RE.match(bad), bad)
        self.assertFalse(app.MAIL_RE.match("a@b.co\n"))
        self.assertFalse(app.DUCKTOK_RE.match("aaaaaaaa\n"))

    def test_issue_request_validation(self):
        old = (app.TLSC, app.TJ["run"]); app.TLSC = tempfile.mkdtemp() + "/t.json"
        try:
            for body in ({"mode": "x"}, {"mode": "own", "domain": "no domain"}, {"mode": "own", "domain": "a.example.com", "email": "bad mail"},
                         {"mode": "free", "prov": "zzz"}, {"mode": "free", "prov": "custom", "suffix": "bad suffix"},
                         {"mode": "free", "prov": "duckdns", "duckname": "x", "duck": "not-a-token"}, {"mode": "free", "prov": "duckdns", "duckname": "A B", "duck": "aaaaaaaa-1111"}):
                self.assertEqual(app.tls_issue_start(body)[0], 400, body)
            self.assertFalse(app.TJ["run"])                                   # nothing was started
        finally:
            app.TLSC, app.TJ["run"] = old

    def test_duckdns_update_answers(self):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer
        seen = []
        class H(BaseHTTPRequestHandler):
            def log_message(s, *a): pass
            def do_GET(s):
                seen.append(s.path); b = b"OK" if "token=good-token-1" in s.path else b"KO"
                s.send_response(200); s.send_header("Content-Length", str(len(b))); s.end_headers(); s.wfile.write(b)
        srv = HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
        old = app.DUCK_URL; app.DUCK_URL = "http://127.0.0.1:%d/update" % srv.server_address[1]
        try:
            self.assertTrue(app.duck_update("myname", "good-token-1", "1.2.3.4")[0])
            self.assertFalse(app.duck_update("myname", "bad-token-22", "1.2.3.4")[0])
            self.assertIn("domains=myname&token=good-token-1&ip=1.2.3.4", seen[0])
        finally:
            app.DUCK_URL = old; srv.shutdown()

    def test_wait_dns_stops_when_the_name_resolves(self):
        old = app.dns_ips
        try:
            app.dns_ips = lambda h: ["1.2.3.4"]; self.assertEqual(app.wait_dns("x.example.com", "1.2.3.4", 5), ["1.2.3.4"])
            app.dns_ips = lambda h: []; self.assertEqual(app.wait_dns("x.example.com", "1.2.3.4", 0), [])
        finally:
            app.dns_ips = old


class TlsExtras(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.old = {k: getattr(app, k) for k in ("TLSC", "STUNLOG", "PORTS", "CFG", "cmd", "have", "ufw_open", "ensure_cert", "tls_shell_files", "listen_ports", "sshd_ports", "STUN_CONF", "TLSFW")}
        app.TLSC = self.t + "/tls.json"; app.STUNLOG = self.t + "/stunnel.log"; app.PORTS = self.t + "/ports.json"; app.CFG = self.t + "/panel.json"; app.STUN_CONF = self.t + "/st.conf"; app.TLSFW = self.t + "/nofw"
        with open(app.PORTS, "w") as f: json.dump({"ssh": 22, "ssh2": 2222, "db": [442], "tdb": [2087]}, f)
        app.cmd = lambda *a, **k: (0, "", ""); app.have = lambda n: True; app.ufw_open = lambda p: "none"; app.ensure_cert = lambda: True
        app.tls_shell_files = lambda: None; app.listen_ports = lambda: {}; app.sshd_ports = lambda: {22}

    def tearDown(self):
        for k, v in self.old.items(): setattr(app, k, v)
        app._CIP["t"] = 0.0

    def test_per_ip_limit_is_validated_and_stored(self):
        self.assertEqual(app.tls_cfg()["perip"], 100)
        self.assertEqual(app.tls_apply({"on": False, "perip": 0})[0], 200); self.assertEqual(app.tls_cfg()["perip"], 0)
        self.assertEqual(app.tls_apply({"on": False, "perip": "25"})[0], 200); self.assertEqual(app.tls_cfg()["perip"], 25)
        for bad in ("abc", -1, 10001, "1.5"): self.assertEqual(app.tls_apply({"on": False, "perip": bad})[0], 400, bad)
        self.assertEqual(app.tls_cfg()["perip"], 25)                                    # refused values change nothing

    def test_limit_change_does_not_restart_the_front(self):
        calls = []
        app.listen_ports = lambda: {p: {"stunnel" if p in (443, 8843) else "dropbear"} for p in list(range(40000, 40300)) + [443, 8843]}   # our own programs are listening
        app.cmd = lambda c, *a, **k: (calls.append(list(c)) or (0, "active", ""))
        app.tls_apply({"on": True, "ports": [443], "tports": [8843]})
        self.assertTrue(any(c[:2] == ["systemctl", "restart"] for c in calls))          # switching on starts it
        calls.clear()
        app.tls_apply({"perip": 7})
        self.assertFalse(any(c[:2] == ["systemctl", "restart"] for c in calls), calls)   # sessions keep running

    def test_client_addresses_come_from_the_stunnel_log(self):
        with open(app.STUNLOG, "w") as f:
            f.write("""2026.11.19 09:47:23 LOG5[3]: Service [tls-d-443] accepted connection from 203.0.113.7:51000
2026.11.19 09:47:23 LOG5[4]: Service [tls-d-443] accepted connection from 2001:db8::5:52000
2026.11.19 09:47:23 LOG5[3]: s_connect: connected 127.0.0.1:40102
2026.11.19 09:47:23 LOG5[3]: Service [tls-d-443] connected remote server from 127.0.0.1:44346
2026.11.19 09:47:24 LOG5[4]: Service [tls-d-443] connected remote server from 127.0.0.1:44350
2026.11.19 09:47:25 LOG5[9]: Service [tls-d-443] connected remote server from 127.0.0.1:44360
""")
        self.assertEqual(app.tls_client_ips(), {44346: "203.0.113.7", 44350: "2001:db8::5"})   # [9] has no matching accept line: ignored

    def test_missing_or_garbled_log_is_harmless(self):
        self.assertEqual(app.tls_client_ips(), {}); app._CIP["t"] = 0.0
        with open(app.STUNLOG, "wb") as f: f.write(b"\xff\xfe not a log \x00")
        self.assertEqual(app.tls_client_ips(), {})

    def test_log_is_trimmed_when_big(self):
        with open(app.STUNLOG, "wb") as f: f.truncate(9 * 1048576)
        app.stunnel_log_trim(); self.assertEqual(os.path.getsize(app.STUNLOG), 0)

    def test_manual_details_for_apps(self):
        x = {"u": "u1", "pw": "pw", "tls": {"host": "vpn.example.com", "ports": [443, 2096], "sni": "vpn.example.com", "insecure": False}}
        t = app.tls_manual_text(x)
        self.assertIn("TLS port(s): 443, 2096", t); self.assertIn("SNI: vpn.example.com", t); self.assertIn("Allow untrusted certificate: no", t)
        self.assertIn('ProxyCommand="openssl s_client -quiet -connect vpn.example.com:443 -servername vpn.example.com"', t)
        x["tls"].update({"sni": "", "insecure": True, "host": "1.2.3.4"})
        t = app.tls_manual_text(x); self.assertIn("yes (self-signed)", t); self.assertNotIn("-servername", t)
        self.assertEqual(app.tls_manual_text({"u": "u1", "pw": "pw", "tls": None}), "")


class SecurityHardening(unittest.TestCase):
    def test_anchors_refuse_trailing_newline(self):
        for rx, ok in ((app.NAME_RE, "alice"), (app.HOST_RE, "1.2.3.4"), (app.TUSER_RE, "root"), (app.IP_RE, "10.0.0.1")):
            self.assertTrue(rx.match(ok)); self.assertIsNone(rx.match(ok + "\n"))
        self.assertIsNone(app.sub_find("a" * 24 + "\n"))

    def test_request_length_is_checked_before_reading(self):
        self.assertEqual(app.req_len("12", "/api/login"), (12, 0))
        self.assertEqual(app.req_len(None, "/api/login"), (0, 0))
        self.assertEqual(app.req_len("-1", "/api/login"), (0, 400))
        self.assertEqual(app.req_len("abc", "/api/login"), (0, 400))
        self.assertEqual(app.req_len(str(2 << 20), "/api/login"), (0, 413))
        self.assertEqual(app.req_len(str(2 << 20), "/api/restore"), (2 << 20, 0))
        self.assertEqual(app.req_len(str(64 << 20), "/api/restore"), (0, 413))

    def test_allowlist(self):
        self.assertTrue(app.ip_allowed("8.8.8.8", []))
        al = app.allow_parse(["203.0.113.7", " 10.0.0.0/8 ", "203.0.113.7", "", "2001:db8::/32"])
        self.assertEqual(al, ["203.0.113.7/32", "10.0.0.0/8", "2001:db8::/32"])
        self.assertTrue(app.ip_allowed("10.1.2.3", al)); self.assertTrue(app.ip_allowed("203.0.113.7", al))
        self.assertFalse(app.ip_allowed("203.0.113.8", al)); self.assertFalse(app.ip_allowed("not-an-ip", al))
        self.assertTrue(app.ip_allowed("::ffff:10.1.2.3", al))                         # IPv4 seen through a dual-stack socket
        with self.assertRaises(ValueError): app.allow_parse(["1.2.3.4; rm -rf /"])
        with self.assertRaises(ValueError): app.allow_parse(["10.0.0.%d" % i for i in range(60)])

    def test_allowlist_cannot_lock_out_the_caller(self):
        with tempfile.TemporaryDirectory() as d:
            old = app.CFG; app.CFG = os.path.join(d, "panel.json")
            try:
                c, r = app.allow_save({"list": "203.0.113.9"}, "198.51.100.1"); self.assertEqual(c, 400); self.assertFalse(os.path.exists(app.CFG))
                c, r = app.allow_save({"list": "203.0.113.9, 198.51.100.0/24"}, "198.51.100.1"); self.assertEqual(c, 200)
                self.assertEqual(json.load(open(app.CFG))["allow"], ["203.0.113.9/32", "198.51.100.0/24"])
                c, r = app.allow_save({"list": []}, "198.51.100.1"); self.assertEqual((c, json.load(open(app.CFG))["allow"]), (200, []))
            finally: app.CFG = old

    def test_prune_auth(self):
        app.TOK.clear(); app.FAIL.clear(); now = time.time()
        app.TOK.update({"old": now - 5, "new": now + 500}); app.FAIL.update({"1.1.1.1": [now - 400], "2.2.2.2": [now - 10]})
        app.prune_auth()
        self.assertEqual(list(app.TOK), ["new"]); self.assertEqual(list(app.FAIL), ["2.2.2.2"])
        app.TOK.clear(); app.FAIL.clear()


class ConnectionLimit(unittest.TestCase):
    def test_extra_devices_are_cut_oldest_stay(self):
        sip = {10: "1.1.1.1", 11: "1.1.1.1", 12: "1.1.1.1", 20: "2.2.2.2", 30: "3.3.3.3", 31: "3.3.3.3"}
        start = {10: 100, 11: 105, 12: 110, 20: 200, 30: 300, 31: 301}
        vic, dips = app.limit_victims(list(sip), 2, sip, start)
        self.assertEqual(sorted(vic), [30, 31]); self.assertEqual(dips, ["3.3.3.3"])        # the working devices are untouched, the newest IP goes
        self.assertEqual(app.limit_victims(list(sip), 3, sip, start), ([], []))
        self.assertEqual(app.limit_victims(list(sip), 1, sip, start)[1], ["2.2.2.2", "3.3.3.3"])
        self.assertEqual(len(app.limit_groups(list(sip), sip)), 3)                          # three devices, six connections

    def test_pid_numbers_do_not_decide_who_is_oldest(self):
        sip = {5: "9.9.9.9", 900: "8.8.8.8"}                                               # a low pid can belong to the newer session (pid wrap)
        vic, dips = app.limit_victims([5, 900], 1, sip, {5: 500, 900: 50})
        self.assertEqual((vic, dips), ([5], ["9.9.9.9"]))

    def test_unknown_addresses_count_one_by_one(self):
        sip = {1: "", 2: "", 3: "4.4.4.4"}
        self.assertEqual(len(app.limit_groups([1, 2, 3], sip)), 3)
        vic, dips = app.limit_victims([1, 2, 3], 2, sip, {1: 10, 2: 20, 3: 30})
        self.assertEqual((vic, dips), ([3], ["4.4.4.4"]))
        vic, dips = app.limit_victims([1, 2], 1, {1: "", 2: ""}, {1: 10, 2: 20}); self.assertEqual((vic, dips), ([2], []))

    def test_limit_is_never_below_one(self):
        self.assertEqual(app.limit_victims([1, 2], 0, {1: "a", 2: "b"}, {1: 1, 2: 2}), ([2], ["b"]))

    def test_pid_start_and_ss_parse(self):
        self.assertLess(app.pid_start(os.getpid()), 1 << 60); self.assertEqual(app.pid_start(2 ** 30), 1 << 62)
        out = ('0 0 10.0.0.1:442 203.0.113.7:50111 users:(("dropbear",pid=1871,fd=3))\n'
               '0 0 10.0.0.1:22 [::ffff:198.51.100.2]:4000 users:(("sshd",pid=300,fd=4),("sshd",pid=250,fd=4))\n')
        keep = app.cmd
        try:
            app.cmd = lambda c, *a, **k: (0, out, ""); m = app.ss_peers()
        finally: app.cmd = keep
        self.assertEqual(m[1871], ("203.0.113.7", 50111)); self.assertEqual(m[300], ("198.51.100.2", 4000)); self.assertEqual(m[250], m[300])

    def test_dropped_ips_are_pruned_and_listed(self):
        app.DROP.clear(); now = time.time(); app.DROP["bob"] = {"1.2.3.4": now - 1000, "5.6.7.8": now - 10}
        app.prune_auth(); self.assertEqual(app.DROP, {"bob": {"5.6.7.8": app.DROP["bob"]["5.6.7.8"]}}); app.DROP.clear()


class NetMonitor(unittest.TestCase):
    PING = """PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=50.0 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=60.0 ms
64 bytes from 1.1.1.1: icmp_seq=4 ttl=57 time=55.0 ms

--- 1.1.1.1 ping statistics ---
4 packets transmitted, 3 received, 25% packet loss, time 601ms
"""
    def test_sample_math(self):
        t, avg, jit, loss, mx = app.nm_sample(self.PING)
        self.assertEqual((avg, loss, mx), (55.0, 25.0, 60.0))
        self.assertEqual(jit, 7.5)                                   # mean(|60-50|, |55-60|) = 7.5: consecutive replies, not the standard deviation
        self.assertEqual(app.nm_sample("ping: connect: Network is unreachable")[1:], [-1, 0, 100.0, -1])
        self.assertEqual(app.nm_sample("4 packets transmitted, 0 received, 100% packet loss")[3], 100.0)

    def test_targets_are_validated(self):
        for ok in ("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "example.com", " Example.COM "): self.assertTrue(app.nm_target(ok), ok)
        for bad in ("-c1", "--help", "a;b.com", "x y.com", "localhost", "1.1.1.1\n-f", "", "a" * 120 + ".com"): self.assertEqual(app.nm_target(bad), "", bad)
        with tempfile.TemporaryDirectory() as d:
            old = app.NETMON_CF; app.NETMON_CF = os.path.join(d, "nm.json")
            try:
                self.assertEqual(app.netmon_save({"on": True, "targets": "1.1.1.1, 8.8.8.8"})[0], 200)
                self.assertEqual(app.netmon_cfg(), {"on": True, "targets": ["1.1.1.1", "8.8.8.8"]})
                self.assertEqual(app.netmon_save({"targets": ["1.1.1.1", "9.9.9.9", "8.8.4.4", "4.4.4.4"]})[0], 400)
                self.assertEqual(app.netmon_save({"targets": ["-c1"]})[0], 400)
                self.assertEqual(app.netmon_cfg()["targets"], ["1.1.1.1", "8.8.8.8"])      # a refused save changes nothing
            finally: app.NETMON_CF = old

    def test_session_stats_parser(self):
        out = ("0      0      10.0.0.1:442      203.0.113.7:50111\n\t cubic rtt:180.5/60 cwnd:10 retrans:0/3 unacked:2\n"
               "0      0      10.0.0.1:442      198.51.100.9:40000\n\t cubic rtt:35/4 cwnd:10\n"
               "0      0      127.0.0.1:40100      127.0.0.1:60000\n\t cubic rtt:0.1/0.05\n"
               "0      0      10.0.0.1:9999      203.0.113.8:1\n\t cubic rtt:500/1\n")
        keep = {n: getattr(app, n) for n in ("cmd", "sshd_ports", "rjson", "tls_cfg", "IPS")}
        try:
            app.cmd = lambda c, *a, **k: (0, out, ""); app.sshd_ports = lambda: {22}
            app.rjson = lambda p, d=None: {"db": [442]} if p == app.PORTS else (d if d is not None else {})
            app.tls_cfg = lambda: {"on": False, "ports": [], "tports": []}; app.IPS = {"alice": ["203.0.113.7"]}
            r = app.net_sessions()
        finally:
            for n, v in keep.items(): setattr(app, n, v)
        self.assertEqual(r["n"], 2)                                   # port 9999 is not ours, 127.0.0.1 (TLS back end) is skipped
        self.assertEqual([x["peer"] for x in r["rows"]], ["203.0.113.7", "198.51.100.9"])   # worst RTT first
        self.assertEqual((r["rows"][0]["user"], r["rows"][0]["retrans"], r["with_retrans"], r["median"]), ("alice", 3, 1, 180.5))


class GameAccounts(unittest.TestCase):
    def test_shell_matrix_has_a_direct_only_game_shell(self):
        g = app.shell_for("direct", "game")
        self.assertTrue(g.endswith("-g")); self.assertEqual(app.SHELL_OF[g], ("direct", "game"))
        self.assertEqual(app.shell_for("tunnel", "game"), g)                    # never a tunnel shell
        self.assertFalse(app.is_tun(g))
        self.assertEqual(len(set(app.SHELLS.values())), len(app.SHELLS))        # every combination has its own shell

    def test_game_accounts_are_direct_only_and_need_a_port(self):
        with tempfile.TemporaryDirectory() as d:
            old = app.PORTS; app.PORTS = os.path.join(d, "ports.json")
            try:
                json.dump({"db": [442], "tdb": [2087], "gdb": [4455]}, open(app.PORTS, "w"))
                c, r = app.user_save({"u": "gx1", "pw": "abc12345", "tm": "tunnel", "cx": "game"})
                self.assertEqual(c, 400); self.assertIn("direct-only", r["msg"])
                json.dump({"db": [442], "tdb": [2087]}, open(app.PORTS, "w"))
                c, r = app.user_save({"u": "gx2", "pw": "abc12345", "tm": "direct", "cx": "game"})
                self.assertEqual(c, 400); self.assertIn("game Dropbear port", r["msg"])
                self.assertEqual(app.game_ports(), [])
                json.dump({"gdb": [4455, 4466, 4477, "x", 0]}, open(app.PORTS, "w")); self.assertEqual(app.game_ports(), [4455, 4466])
            finally: app.PORTS = old

    def test_game_ports_are_part_of_the_reverse_entry_list(self):
        with tempfile.TemporaryDirectory() as d:
            old = app.PORTS; app.PORTS = os.path.join(d, "ports.json")
            try:
                json.dump({"db": [442], "tdb": [2087], "gdb": [4455], "ssh2": 2222}, open(app.PORTS, "w"))
                self.assertIn(4455, app.rev_ports())
            finally: app.PORTS = old


class GameProfile(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); d = self.d.name
        self.keep = {n: getattr(app, n) for n in ("GAMEF", "GAME_SYSF", "BBRF", "cmd", "sysctl_get", "wan_dev", "root_qdisc", "bbr_state", "PORTS")}
        app.GAMEF = os.path.join(d, "game.json"); app.GAME_SYSF = os.path.join(d, "sys.conf"); app.BBRF = os.path.join(d, "bbr.conf"); app.PORTS = os.path.join(d, "ports.json")
        self.k = {"net.core.default_qdisc": "fq_codel", "net.ipv4.tcp_congestion_control": "cubic", "net.ipv4.tcp_notsent_lowat": "4294967295", "net.ipv4.tcp_slow_start_after_idle": "1"}
        self.q = ["fq_codel"]; self.calls = []
        def cmd(c, *a, **kw):
            self.calls.append(c)
            if c[0] == "sysctl" and c[1] == "-w": k, v = c[2].split("="); self.k[k] = v
            if c[:3] == ["tc", "qdisc", "replace"]: self.q[0] = c[-1]
            if c[:3] == ["tc", "qdisc", "del"]: self.q[0] = "fq_codel"
            return 0, "", ""
        app.cmd = cmd; app.sysctl_get = lambda k: self.k.get(k, ""); app.wan_dev = lambda: "eth0"; app.root_qdisc = lambda dev: self.q[0]
        app.bbr_state = lambda: {"avail": True, "on": False, "cc": self.k["net.ipv4.tcp_congestion_control"], "qdisc": ""}
    def tearDown(self):
        for n, v in self.keep.items(): setattr(app, n, v)
        self.d.cleanup()
    def test_enable_applies_and_disable_restores_the_previous_values(self):
        before = dict(self.k)
        c, r = app.game_apply(True); self.assertEqual(c, 200)
        self.assertEqual((self.k["net.core.default_qdisc"], self.k["net.ipv4.tcp_congestion_control"], self.k["net.ipv4.tcp_notsent_lowat"], self.k["net.ipv4.tcp_slow_start_after_idle"]), ("fq", "bbr", "16384", "0"))
        self.assertEqual(self.q[0], "fq"); self.assertIn("tcp_notsent_lowat = 16384", open(app.GAME_SYSF).read())
        app.game_apply(True)                                                              # a second "on" must not overwrite the saved originals
        c, r = app.game_apply(False)
        self.assertEqual(self.k, before); self.assertEqual(self.q[0], "fq_codel"); self.assertFalse(os.path.exists(app.GAME_SYSF))
        self.assertFalse(json.load(open(app.GAMEF))["on"])
    def test_missing_keys_and_no_bbr_are_reported_not_invented(self):
        del self.k["net.ipv4.tcp_notsent_lowat"]
        app.bbr_state = lambda: {"avail": False, "on": False, "cc": "cubic", "qdisc": ""}
        c, r = app.game_apply(True)
        self.assertEqual(self.k["net.ipv4.tcp_congestion_control"], "cubic")
        self.assertTrue(any("tcp_notsent_lowat" in n for n in r["notes"])); self.assertTrue(any("BBR" in n for n in r["notes"]))
        self.assertNotIn("tcp_notsent_lowat", open(app.GAME_SYSF).read())
    def test_sshd_text_scopes_ipqos_to_the_panel_ports(self):
        open(app.PORTS, "w").write(json.dumps({"ssh": 22, "ssh2": 2222}))
        t = app.game_sshd_text(False)
        self.assertIn("Match LocalPort 22\n  IPQoS lowdelay", t); self.assertIn("Match LocalPort 2222\n  IPQoS lowdelay", t)
        self.assertIsNone(re.search(r"(?m)^Ciphers ", t)); self.assertNotIn("9011", t)
        self.assertIsNotNone(re.search(r"(?m)^Ciphers chacha20-poly1305@openssh.com,aes128-gcm@openssh.com$", app.game_sshd_text(True)))
        self.assertTrue(t.rstrip().endswith("IPQoS lowdelay"))                            # Match blocks last: nothing after them is swallowed


class ExitUpdate(unittest.TestCase):
    def test_needs_a_tunnel_and_keeps_route_mode(self):
        src = open(os.path.join(os.path.dirname(__file__), "..", "panel", "app.py"), encoding="utf-8").read()
        self.assertIn('"/api/tunnel/exit-update"', src)
        self.assertIn('tunnel_route_apply("forward" if c.get("ROUTE")=="forward" else "both")', src)


class ExitRevScope(unittest.TestCase):
    def test_reverse_dnat_only_for_traffic_to_this_server(self):
        # runs the real exit script (iptables/ss/sysctl stubbed): a DNAT on bare --dport would hijack tunnel users' own outgoing
        # https (:443, the SSH-TLS port) and break the internet through the tunnel
        import subprocess
        m = re.search(r"cat > /usr/local/bin/sshplus-exit.sh <<'XEOF'\n(.*?)\nXEOF", app.REMOTE_SCRIPT, re.S)
        self.assertTrue(m)
        with tempfile.TemporaryDirectory() as d:
            for n, body in (("iptables", 'echo "$@" >> %s/log; case " $* " in *" -C "*) exit 1;; esac' % d), ("ss", "exit 0"), ("sysctl", "exit 0")):
                f = os.path.join(d, n); open(f, "w").write("#!/bin/sh\n" + body + "\n"); os.chmod(f, 0o755)
            ports = os.path.join(d, "ports"); open(ports, "w").write("443,8443:18443\n")
            script = os.path.join(d, "exit.sh"); open(script, "w").write(m.group(1).replace("/etc/sshplus-exit.ports", ports))
            r = subprocess.run(["bash", script], env={"PATH": d + ":/usr/bin:/bin"}, capture_output=True, text=True)
            self.assertIn("REV_OK:443:443 8443:18443", r.stdout)
            dnat = [l for l in open(os.path.join(d, "log")).read().splitlines() if "DNAT" in l]
            self.assertEqual(len(dnat), 2)
            for l in dnat:
                self.assertIn("! -i tun99", l); self.assertIn("--dst-type LOCAL", l)


class TunnelDiag(unittest.TestCase):
    def test_systemd_chatter_is_dropped_and_the_real_error_is_kept(self):
        j = """SSHPLUS-TUNNEL: starting ssh -w to root@155.103.69.51:22
Tunnel device open failed.
Could not request tunnel forwarding.
SSHPLUS-TUNNEL: ssh exited before the tunnel device came up (see the ssh message just above)
sshplus-tunnel.service: Main process exited, code=exited, status=1/FAILURE
sshplus-tunnel.service: Failed with result 'exit-code'.
Stopped sshplus-tunnel.service - SSH Plus Tunnel (link to the exit server).
Started sshplus-tunnel.service - SSH Plus Tunnel (link to the exit server)."""
        txt, hint = app.tun_diag(j)
        self.assertIn("Tunnel device open failed.", txt); self.assertIn("Could not request tunnel forwarding.", txt)
        self.assertNotIn("Started", txt); self.assertNotIn("Failed with result", txt)
        self.assertTrue(hint)                                                   # a hint for the usual cause

    def test_known_causes_get_a_hint(self):
        for line, word in (("SSHPLUS-TUNNEL: this server cannot open /dev/net/tun (No such device)", "TUN"),
                           ("Host key verification failed.", "host key"), ("root@1.2.3.4: Permission denied (publickey).", "key"),
                           ("ssh: connect to host 1.2.3.4 port 22: Connection timed out", "reach")):
            h = app.tun_diag(line)[1]; self.assertTrue(h and word.lower() in h.lower(), (line, h))

    def test_only_noise_gives_empty_text(self):
        self.assertEqual(app.tun_diag("Started sshplus-tunnel.service - x\nsshplus-tunnel.service: Failed with result 'exit-code'.")[0], "")


class TunnelProbe(unittest.TestCase):
    def setUp(self):
        import socket, threading
        self.old = (app.cmd, app.TUN_LOCAL, app.TUN_REMOTE, app.tconf, dict(app._TP))
        self.srv = socket.socket(); self.srv.bind(("127.0.0.1", 0)); self.srv.listen(5); self.port = self.srv.getsockname()[1]
        def accept_loop():
            try:
                for _ in range(5): self.srv.accept()
            except OSError: pass                                                      # closed by tearDown
        threading.Thread(target=accept_loop, daemon=True).start()
        app.TUN_LOCAL = "127.0.0.1"; app.TUN_REMOTE = "127.0.0.1"; app.tconf = lambda: {"TUN_PORT": str(self.port)}; app._TP["t"] = 0.0

    def tearDown(self):
        app.cmd, app.TUN_LOCAL, app.TUN_REMOTE, app.tconf = self.old[:4]; app._TP.update(self.old[4]); self.srv.close()

    def test_icmp_is_used_when_it_works(self):
        app.cmd = lambda c, *a, **k: (0, "64 bytes from x: time=1.5 ms", "")
        self.assertEqual(app.tun_probe(True), (True, 1.5))

    def test_blocked_ping_falls_back_to_tcp(self):
        app.cmd = lambda c, *a, **k: (1, "", "")                                   # the exit server drops ICMP echo
        ok, ms = app.tun_probe(True); self.assertTrue(ok); self.assertGreaterEqual(ms, 0)

    def test_down_when_neither_works(self):
        app.cmd = lambda c, *a, **k: (1, "", ""); app.tconf = lambda: {"TUN_PORT": "1"}
        self.assertEqual(app.tun_probe(True), (False, 0.0))

    def test_result_is_cached_for_a_few_seconds(self):
        n = []
        app.cmd = lambda c, *a, **k: (n.append(1) or (0, "time=2 ms", ""))
        app.tun_probe(True); app.tun_probe(); app.tun_probe(); self.assertEqual(len(n), 1)


class WireGuardMode(unittest.TestCase):
    def setUp(self):
        self.old = {k: getattr(app, k) for k in ("cmd", "_run", "WGPRIV", "WGPUB", "TCONF", "shutil")}
        self.t = tempfile.mkdtemp(); app.WGPRIV = self.t + "/priv"; app.WGPUB = self.t + "/pub"; app.TCONF = self.t + "/tunnel.conf"

    def tearDown(self):
        for k, v in self.old.items(): setattr(app, k, v)

    def test_key_pair_is_created_once_and_private(self):
        calls = []
        def run(c, inp=None, **k):
            calls.append(c[1]); return (0, "PRIVKEY" if c[1] == "genkey" else "PUBKEY", "")
        app._run = run
        self.assertEqual(app.wg_keys(), ("PUBKEY", ""))
        self.assertEqual(oct(os.stat(app.WGPRIV).st_mode & 0o777), "0o600")
        self.assertEqual(app.wg_keys(), ("PUBKEY", "")); self.assertEqual(calls, ["genkey", "pubkey"])        # second call reuses the files

    def test_key_errors_are_reported(self):
        app._run = lambda c, inp=None, **k: (1, "", "wg: not found")
        self.assertEqual(app.wg_keys()[0], ""); self.assertIn("not found", app.wg_keys()[1])

    def test_handshake_parsing(self):
        for out, want in (("PEERKEY\t0", False), ("PEERKEY\t1795169243", True), ("", False)):
            app.cmd = lambda c, *a, **k: (0, out, ""); self.assertEqual(app.wg_handshake(), want, out)
        app.cmd = lambda c, *a, **k: (1, "", "No such device"); self.assertFalse(app.wg_handshake())

    def test_local_support_kernel_go_or_none(self):
        app.cmd = lambda c, *a, **k: (0, "", ""); self.assertEqual(app.wg_local_support(), "kernel")      # `ip link add ... type wireguard` works
        app.cmd = lambda c, *a, **k: (1, "", "Operation not supported")
        class SH:
            @staticmethod
            def which(n, path=None): return "/usr/bin/wireguard-go" if n == "wireguard-go" else None
        app.shutil = SH; self.assertIn(app.wg_local_support(), ("go", ""))                                  # go only if /dev/net/tun exists
        class NO:
            @staticmethod
            def which(n, path=None): return None
        app.shutil = NO; self.assertEqual(app.wg_local_support(), "")

    def test_status_reports_the_mode_and_old_installs_are_ssh(self):
        self.assertEqual(app.tunnel_status(False)["mode"], "ssh")
        app.tconf_write({"TUN_HOST": "1.2.3.4", "TUN_MODE": "wg"}); self.assertEqual(app.tunnel_status(False)["mode"], "wg")

    def test_setup_start_passes_a_valid_mode(self):
        import threading
        got = []
        class T:
            def __init__(s, target=None, args=(), daemon=None): got.append(args)
            def start(s): pass
        old = threading.Thread; threading.Thread = T
        try:
            for m, want in (("wg", "wg"), ("WG", "wg"), ("ssh", "ssh"), ("junk", "ssh"), (None, "ssh")):
                app.TS["run"] = False; got.clear()
                body = {"host": "1.2.3.4", "port": 22, "user": "root", "pw": "x"}
                if m is not None: body["mode"] = m
                self.assertEqual(app.tunnel_setup_start(body)[0], 200); self.assertEqual(got[0][-1], want, m)
        finally:
            threading.Thread = old; app.TS["run"] = False

    def test_remote_script_has_the_pieces_the_panel_relies_on(self):
        s = app.REMOTE_WG
        for needle in ("WG_EXIT_PUB:", "WG_PORT:", "SSHPLUS_WG_OK", "allowed-ips 10.99.0.1/32", "ip addr replace 10.99.0.2/30", "ufw allow", "firewall-cmd"):
            self.assertIn(needle, s, needle)

    def test_scripts_are_valid_bash(self):
        import subprocess
        for f in ("start-wg.sh", "start-tunnel.sh", "sshplus-tunnel-net"):
            self.assertEqual(subprocess.run(["bash", "-n", os.path.join(ROOT, "scripts", f)]).returncode, 0, f)
        self.assertIn("TUN_MODE", open(os.path.join(ROOT, "scripts", "start-tunnel.sh")).read())


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

    def test_every_static_persian_text_has_an_english_translation(self):
        """index.html: each Persian text node / placeholder / title needs an EN entry (or ENP pattern); data-th blocks need an HT entry"""
        import json, re
        from html.parser import HTMLParser
        with open(os.path.join(ROOT, "panel", "ui.js"), encoding="utf-8") as f: js = f.read()
        en = json.loads(re.search(r"const EN=(\{.*?\}), ENP=", js, re.S).group(1))
        enp = json.loads(re.search(r", ENP=(\[.*?\]), HT=", js, re.S).group(1))
        ht = json.loads(re.search(r", HT=(\{.*\});", js).group(1))
        pats = [re.compile("^" + "".join("(.+?)" if re.fullmatch(r"\{\d+\}", x) else re.escape(x) for x in re.split(r"(\{\d+\})", p[0])) + "$", re.S) for p in enp]
        nrm = lambda s: re.sub(r"\s+", " ", s).strip()
        FA = re.compile(r"[؀-ۿ]")
        missing = []
        VOID = {"input", "br", "img", "meta", "link", "hr"}
        class P(HTMLParser):
            def __init__(s): super().__init__(); s.stack = []; s.skip = 0
            def handle_starttag(s, tag, attrs):
                a = dict(attrs)
                for k in ("placeholder", "title", "aria-label"):
                    if a.get(k) and FA.search(a[k]) and not s.skip and "Language /" not in a[k]: s.need(a[k])
                if tag in VOID: return
                th = a.get("data-th")
                if th is not None and th not in ht: missing.append("data-th=" + th)
                s.stack.append((tag, bool(th) or tag in ("script", "style"))); s.skip += 1 if s.stack[-1][1] else 0
            def handle_startendtag(s, tag, attrs):
                for k, v in attrs:
                    if k in ("placeholder", "title", "aria-label") and v and FA.search(v) and not s.skip and "Language /" not in v: s.need(v)
            def handle_endtag(s, tag):
                if tag in VOID or not s.stack: return
                _, skip = s.stack.pop(); s.skip -= 1 if skip else 0
            def handle_data(s, d):
                if not s.skip and FA.search(d) and "Language /" not in d: s.need(d)
            def need(s, text):
                k = nrm(text)
                if k not in en and not any(p.match(k) for p in pats): missing.append(k[:90])
        with open(os.path.join(ROOT, "panel", "index.html"), encoding="utf-8") as f: P().feed(f.read())
        self.assertEqual(missing, [], "Persian text without an English translation")


if __name__ == "__main__":
    unittest.main()
