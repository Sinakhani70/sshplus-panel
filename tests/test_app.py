"""Unit tests for the pure helpers of panel/app.py (no root, no services needed).

run:  python3 -m unittest discover -s tests -v
"""
import importlib.util
import json
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
        threading.Thread(target=lambda: [self.srv.accept() for _ in range(5)], daemon=True).start()
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
