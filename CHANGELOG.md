# Changelog

## v1.8.2 — Certificate flow fixes
### Fixed
- **Renewing or re-issuing the certificate from the panel restarted the panel in the middle of the job.** certbot's deploy hook called `systemctl restart sshplus-panel`, so the running renew job died with it: the page lost its connection, the session token was gone (signed out), the job state vanished and success was never shown, although the certificate had been renewed. The hook now only asks the running panel to reload its certificate (flag file `/etc/SSHPlus/cert.reload`, picked up within 3 s, the HTTPS context is swapped in place); nothing is restarted. Checked in the lab with a certbot stand-in that runs the deploy hook like the real one: the job finishes with all 3 steps, the token stays valid and the new certificate is served.
- **A leftover `-staging` certificate could overwrite the real one.** After trying the staging CA and then switching it off, both certbot lineages existed; at the next automatic renewal of the staging lineage the hook installed the untrusted staging certificate over the production one (clients saw certificate errors every ~60 days). The panel now records which lineage is installed and only that one may replace the certificate (also used by the "Renew certificate" button, which no longer depends on the staging checkbox being unchanged).
- Before asking Let's Encrypt, the panel checks the domain's **AAAA (IPv6) record**: Let's Encrypt tries IPv6 first, so an AAAA record that is not this server made the request fail with an unclear certbot error; it now stops with a clear message.
- An e-mail address can no longer start with `-` (it would have been read as a certbot option).

## v1.8.1 — Connection limit fixed: extra IPs are cut, working ones stay
### Fixed
- **A connection over the limit disrupted the user's working connections.** The monitor cut the *oldest* sessions when an account had more sessions than its limit, so one extra connection killed the connection that was in use (and clients that reconnect kept cycling). Now the limit counts **concurrent IPs** (devices): several connections from the same IP count once, the IPs that were connected first keep working untouched, and every session of the newer IPs is cut. Order is by process start time, not pid. Sessions whose client address is unknown (entry via server 2 shows the tunnel peer, OpenSSH sessions without a visible peer) still count one by one.
- **Connected IPs are shown for every session** (Dropbear, TLS, OpenSSH) from the kernel's socket table (`ss -tnp`) with the auth log as a fallback, so they appear immediately; the Users table shows `devices / limit`, the connection count, each IP with its number of connections and, in red, the IPs that were just cut (kept for 5 minutes). New Dropbear sessions are attributed to their account within 3 s instead of up to 15 s.
- The field is now labelled "Concurrent IPs". Dropbear cannot refuse a login at authentication time, so an extra IP may connect for up to ~3 s (the monitor interval) before it is cut. A user who switches network (Wi-Fi to mobile data) keeps the old connection until it times out and may be turned away meanwhile: give such accounts a limit of 2.

## v1.8.0 — Gaming: stable ping, game accounts, network monitor, hardening
### Added
- **Game Profile** (Settings): one switch applies `net.core.default_qdisc=fq`, `tcp_congestion_control=bbr`, `tcp_notsent_lowat=16384`, `tcp_slow_start_after_idle=0` and replaces the root qdisc of the WAN interface with `fq` (the sysctl only affects qdiscs created later). The previous runtime values are saved and restored exactly when it is switched off. Keys the kernel does not have and a missing BBR/`fq` are reported, never claimed; the BBR toggle is locked while the profile is on. The live state (current value vs. target, qdisc) is shown. Saved in `/etc/sysctl.d/99-sshplus-game.conf` (and `tcp_bbr` is loaded at boot).
- **OpenSSH tuning** (separate, explicit button; reloads sshd once): `Compression no`, `UseDNS no` (both can only be global in sshd, so they also apply to other SSH ports such as a main one), `IPQoS lowdelay` limited to the panel's own SSH ports with `Match LocalPort` (verified: a different port keeps its defaults), and optionally only the light ciphers `chacha20-poly1305` + `aes128-gcm` (global, may break old clients). Dropbear has no such settings (it has no `aes128-gcm` and no runtime cipher option).
- UDPGW settings: **send buffer** (`--client-socket-sndbuf`, 0..16 MB, 0 = system default) next to MTU / max clients / max connections per client.
- **Game accounts** (new connection type *Game*): own Dropbear instance (`sshplus-dropbear-g`, ports.json `gdb`, up to 2 ports, default one free port) with its own `/etc/shells` file, direct accounts only. Wired into every place that knows the account shells/ports: shell matrix and restore, installer (`ALLSH`, shells file, unit, firewall), session detection (journal unit list, so quota and kick work on the game port), watchdog and status, port conflict checks (Dropbear, tunnel, TLS, UDPGW), entry through server 2, subscription links (game port only), templates and bulk creation. The UI blocks "game + exit server 2", suggests a concurrent-user limit of 2 and explains that a separate port helps only if the client uses a separate SSH connection for game traffic.
- **Network monitor** (History tab): status of OpenSSH, Dropbear, game Dropbear and UDPGW plus online users; optional ping from this server to up to 3 targets (10 packets per minute; mean RTT, jitter = mean absolute difference of consecutive replies, loss, max) with 12 h charts; and a table of connected sessions with RTT and retransmits taken from this server's own TCP stack (`ss -ti`), which includes the client's mobile network, so it tells "the server" apart from "the path to the client". Targets are validated (IP or host name, never an option), history is bounded (720 samples per target); monitoring is off until switched on. All panel services already restart automatically (`Restart=always`); `ssh.service` is not touched.
### Security
- **Panel: stalled or oversized requests.** A client that completed the TLS handshake and then stalled was never timed out (a held thread each). Every connection now has a 30 s idle timeout; a negative or non-numeric `Content-Length` is refused (400), bodies above 1 MB (32 MB for `/api/restore`) are refused (413) before anything is read. Checked: the 40 s stall test now ends after 30 s.
- **Optional panel IP allowlist** (Settings): addresses or ranges (IPv4/IPv6); empty = everybody. A list that excludes your own address is refused, users' subscription links (`/s/…`) stay reachable, and `python3 /opt/sshplus-panel/app.py --allow-off` clears it from the server.
- Expired sessions and old failed-login records are pruned every minute; changing the panel password signs out every other session.
- OpenSSH (ports 22/2222): `GatewayPorts no` and `AllowAgentForwarding no` (an account could open a public listener with `-R 0.0.0.0:port`; Dropbear never allowed it). VPN apps only need local forwarding.
- sshd is only reloaded when its configuration really changed (installer, "save ports", and the exit-server script), because it also serves ports the panel does not manage. `Port` lines in `00-sshplus.conf` that the panel does not manage (e.g. a main SSH port such as 9011) are kept when ports are saved. The installer now reloads instead of restarting sshd.
- Input patterns use `\Z` (a trailing newline was accepted by `$`).

## v1.7.1 — WireGuard tunnel type, HTTPS-through-tunnel fix, exit-server update
### Added
- **"Update exit server" button** (Tunnel tab): rewrites the exit server's script and rules with the panel's current version without removing the tunnel (the exit side was only written at setup, so exit-side fixes needed a re-install). Keeps the current routing mode.
- **Tunnel type: WireGuard (fast, UDP) or SSH (compatible).** The `ssh -w` tunnel carries TCP inside a TCP connection, which becomes very slow on long or lossy routes. The new WireGuard type uses the same device name and addresses (`tun99`, `10.99.0.1/.2`), so routing, UDPGW, reverse entry and the kill-switch are unchanged; MTU 1380; keys in `/etc/SSHPlus/wg_private|wg_public` (included in backups); the exit server gets `sshplus-exit-wg` (kernel WireGuard, `wireguard-go` fallback; UDP port 51820+ opened in ufw/firewalld). A handshake watchdog restarts a dead link and setup says clearly when UDP seems blocked. Choose the type in the Tunnel tab; switching back to SSH is one click. UDP between the two servers must be allowed.
- Better tunnel diagnostics: ICMP-then-TCP health probe (many exit servers drop ping), `/dev/net/tun` pre-check, clear `SSHPLUS-TUNNEL` messages and hints for the usual failures, no restart loop when `tunnel.conf` is missing.
### Fixed
- **UDPGW of tunnel accounts could lose datagrams.** The kernel keeps the source address chosen before the tunnel's policy re-route, so a tunnel UDP flow whose 5-tuple equalled a live *direct* flow (same source port to the same destination, e.g. DNS) matched the direct flow's conntrack entry, skipped the MASQUERADE and left the tunnel with this server's own source address (found in the lab: 1–2 % of 300 parallel datagrams). The tunnel UDPGW now has its own conntrack zone (`raw` table, `CT --zone-orig 100`, set together with the routing mark so both follow every restart of the UDPGW or the tunnel Dropbear units); on kernels without `xt_CT` nothing changes. Checked: 0 of 900 datagrams affected after direct runs, with the old rules 4–6 of 300.
- The unit test for the exit-server DNAT scope now runs the real exit script with stubbed `iptables` (it fails against the old unguarded rule); the version is bumped so a re-install is visible in the panel footer.
- Exit server: the "enter via exit server" DNAT rules matched every TCP packet to the forwarded port, so tunnel users' own outgoing HTTPS (:443, the SSH-TLS port) was redirected to the panel server and failed with "wrong version number" (internet test warning, broken HTTPS through the tunnel). The rules now match only connections addressed to the exit server itself (`! -i tun99`, `--dst-type LOCAL`).

## v1.7.0 — SSH over TLS, domain + free certificate, connection type per account
- **New "TLS & Domain" tab.** One switch turns on SSH inside TLS: `stunnel` listens on the public TLS ports and forwards (round-robin) to two groups of Dropbear processes bound to `127.0.0.1` (one group for direct accounts, one for tunnel accounts, so tunnel accounts still leave through the exit server). Each group is 6 processes: Dropbear accepts only 5 unauthenticated connections per source IP, and behind stunnel every TLS client has the source `127.0.0.1`, so a single process would have let any 5 half-open connections block all TLS logins (measured: 5 of 25 simultaneous logins got through; with 6 processes 40 of 40). Ports are configurable (defaults 443 for normal accounts, 8843 for tunnel accounts) and are checked against every other port the panel knows (Dropbear, tunnel Dropbear, sshd, panel, UDPGW, port 80) and against other programs; the firewall (ufw/firewalld) is opened. stunnel is installed on demand if the installer could not.
- **Connection type per account** (create, edit, bulk creation, templates): *Normal + TLS*, *Normal only*, *TLS only*. It is stored in the account's login shell and enforced by each Dropbear instance's own `/etc/shells` (four instances: plain/TLS x direct/tunnel), so a TLS-only account is refused on the plain Dropbear ports and a normal-only account on the TLS ports. Existing accounts keep their old shells = *Normal + TLS*. A *TLS only* account is also refused on the OpenSSH ports (the panel keeps a `DenyUsers` file for sshd in sync: `/etc/ssh/sshd_config.d/02-sshplus-deny.conf`); *Normal only* accounts can use OpenSSH. **Entry via the second server works with TLS too**: the TLS ports are published on the exit server like the Dropbear ports (mapped if busy there), so all four In/Out combinations work over TLS.
- **Domain and certificate, one place.** The old HTTPS certificate box in Settings moved into the new tab and is shared: the same certificate and domain serve the panel's HTTPS and SSH over TLS. Decision: merged (one domain, one renewal) rather than two separate certificates; Settings keeps the plain-HTTP subscription switch and a pointer to the tab.
- **Free domain and Let's Encrypt in one click.** Choose: your own domain, or a free one — `sslip.io`, `nip.io` (no sign-up; the name is built from the server IP), `DuckDNS` (free account: sub-domain + token; the panel points it to the server), or any other wildcard-DNS suffix you type. The panel checks that the name resolves to this server's public IP, installs `certbot`, requests the certificate over HTTP-01 (port 80, opened in the firewall), installs it for the panel and the TLS front and sets a renewal hook; progress is shown step by step with clear errors (DNS not ready, port 80 busy, rate-limited provider). **Renew certificate** button (immediate renewal; the certbot timer renews automatically anyway) and "Back to self-signed" are one click each; a running transfer is not interrupted by a renewal.
- **Links and subscription page** list the TLS ports; the TLS host is the domain when there is one: `ssh://user:pass@domain:443?security=tls&sni=domain#CK.VPN-user-TLS-443` (`allowInsecure=1` is added while the certificate is self-signed). This URI form is a convention, not a standard, and has **not** been tried in Rocket Tunnel / Nova Tunnel — the page also shows host, ports and SNI for manual entry.
- **Per-IP connection limit on the TLS ports** (TLS tab, default 100, 0 = off): an iptables `connlimit` chain of its own (`SSHPLUS_TLSLIM`, created and removed by `sshplus-tls-fw` with the stunnel unit; nothing else is touched). stunnel sees the real client address, so one host can no longer hold the TLS front with half-open connections. Changing the limit does not drop running sessions.
- **Client address per session**: the *Online* column shows the real addresses of connected accounts (plain Dropbear from its log; TLS from stunnel's log, matched by the local source port). The stunnel log is capped at 8 MB.
- **TLS details button (🔗 dialog)** copies host, TLS port, SNI, user, password, "allow untrusted certificate" and an OpenSSH `ProxyCommand` one-liner — for apps that have no import link (no share-link format for these apps is documented anywhere we could find).
- **Let's Encrypt staging switch** (TLS tab): try the whole flow against the test CA without using the rate limit (the certificate is marked *staging*, not trusted). New `docs/REAL-WORLD-CHECKLIST.md` lists the five steps to run once on a real server.
- The panel page is now sent with `Cache-Control: no-cache`, so after an update the browser revalidates it and shows the new tabs (TLS & Domain, connection type) without a hard refresh.
- When the tunnel is up but the internet test through it fails, the warning now says where it stops: a direct-IP request through the tunnel (separates DNS from routing), the route used from the tunnel address, and the exit server's `ip_forward`, NAT and FORWARD rules.
- **Tunnel health no longer depends on ICMP.** Some exit servers drop ping (e.g. `-A INPUT -p icmp --icmp-type 8 -j DROP`), and the panel judged the tunnel by ping only, so a working tunnel was reported as "did not come up". The panel now tries ping and then a TCP connect to the exit server's SSH port through the tunnel (cached for 10 s). Used by the setup wait, the Tunnel tab status, the test button, the statistics history and the alerts. Checked in the lab with ICMP echo dropped on the exit server: setup succeeds, status is up, history records the round trip.
- When the SSH link is up but nothing passes through it, the failure message now includes both ends: this server's `tun99` address, the ping result, and the exit server's `tun99` address, `ufw` status and first INPUT rules (the usual cause is a firewall rule on the exit server).
- **Tunnel setup errors are now explained.** "Tunnel did not come up" used to show only systemd's start/stop lines. The panel now shows the real messages (ssh errors, `SSHPLUS-TUNNEL:` lines), a hint for the usual causes (no `/dev/net/tun` on a container VPS, exit server refusing tunnels, host key / key rejected, unreachable), and the virtualisation type. Both servers are checked for `/dev/net/tun` up front (and `modprobe tun` / `mknod` are tried).
- A tunnel that is not configured (or whose setup failed and was rolled back) no longer sits in a restart loop printing "tunnel.conf missing" every 3 seconds: the unit now has `ConditionPathExists=/etc/SSHPlus/tunnel.conf`, and the start script says clearly whether the file is missing or unreadable.
- Static analysis (bandit, no high findings): the Telegram backup used a predictable `/tmp` file name; it now uses a private 0700 directory and `O_EXCL`. The remaining medium notes are by design (panel/UDPGW bind option, executable certbot hook).
- UDPGW (badvpn) works on every path — checked with the real `badvpn-udpgw` and a client speaking its protocol: In 1/2 x Out 1/2 x plain Dropbear / TLS / OpenSSH, exit IP correct for TCP and UDP in all of them, 1100-byte datagrams, 50 flows on one connection, 300 parallel datagrams, fail-closed (no TCP/UDP leak) when the tunnel is down, recovery after a tunnel flap and after restarting any involved service (routing marks are re-applied).
- Fixes found while testing and reviewing: switching TLS on reported success before all Dropbear back ends were listening (the first logins right after could fail) — it now waits for every back end; a trailing newline slipped through the new domain/e-mail/token patterns (now anchored); a `"` in a password could break the subscription page's copy button (now HTML-escaped); setting a domain without a real certificate no longer marks the certificate as trusted; port 80 is reserved; the tab bar wraps on phones and Settings cards no longer force a minimum width.
- Notes: behind stunnel, Dropbear sees TLS clients as `127.0.0.1` (so the per-IP unauthenticated limit and client addresses in its log do not apply per client). Port 80 stays open and must stay free for renewals. Free wildcard-DNS names share Let's Encrypt rate limits with all their users. A restored backup does not carry certbot's renewal data (request the certificate again).
- How it was checked: unit tests (45); a lab with real Dropbear, stunnel, the real `badvpn-udpgw` and `openssl s_client` as the client, run on a fresh install and again after an in-place upgrade (matrix of 24 In/Out x port-type routes, 0 failures); a second, harsher pass (54 checks): connection limit and traffic quota enforced for TLS sessions (same accounting as plain), expiry, a 95 s idle session, watchdog restarts of stunnel / the Dropbear processes, port-conflict refusals, 200 simultaneous TLS handshakes and 25-40 simultaneous logins, 100 MB transfers intact (TLS costs about 3-4% speed), certificate renewal during a transfer, panel restart during a transfer, backup -> damage -> restore. Earlier checks: login matrix for all connection types on plain and TLS ports (incl. tunnel accounts), data through a TLS forward, tunnel accounts via TLS exit through the second server and are cut (no leak) when the tunnel is down, routing marks and UDPGW redirect cover the new tunnel instance, enable/disable/port validation, the certificate flow with a stand-in `certbot` and stand-in DuckDNS / IP services (own domain, sslip, nip with a missing DNS name, DuckDNS wrong/right token, custom suffix, rate-limit and failure messages, renewal hook, back to self-signed), the full UI in a browser in Persian and English (no untranslated text) and at phone width; a security review of the new code. **Not covered:** real Let's Encrypt, real DuckDNS, real systemd, any specific client app.

## v1.6.0 — English language
- **The "FA / EN" button used to only flip the page direction** (everything stayed Persian and the layout broke). It is now a real language switch: the whole panel — labels, buttons, tables, notes, dialogs (`alert`/`confirm`/`prompt`), the tunnel installation steps sent by the server, charts — is translated, the page switches to LTR and back to RTL, and the choice is remembered in the browser (also on the login screen).
- **Subscription page** (`/s/<token>`) is bilingual: `?lang=en` / `?lang=fa`, a language link on the page, and it follows the panel's choice.
- Texts that were outdated were corrected in Persian too: the tunnel form no longer says the panel is "plain HTTP" (it is HTTPS since 1.5) and the "tunnel is up" message refers to In/Out instead of the old account type.
- Small layout fix: long badges (port lists) wrap inside their card.
- **Subscription link now works for apps** (was: "invalid link" in tunnel apps). The link used to return only an HTML page. Now `/s/<token>` is content-negotiated: a browser (`Accept: text/html`) still gets the page, anything else (tunnel apps, curl) gets the standard subscription list — base64 of one `ssh://user:pass@host:port#remark` line per port — with the usual `Subscription-Userinfo` (used / total / expire) and `Profile-Title` headers. You can force a format: `?fmt=plain|b64|html` and `?auth=b64` (base64 userinfo variant).
- **Subscription dialog (🔗)**: separate copy buttons for the subscription link, the plain-text list, a single `ssh://` link and the base64-login variant, plus a selectable text box and a hint. Copying is now reliable: Clipboard API → `execCommand("copy")` fallback → selectable prompt (the Clipboard API is unavailable in some browsers/contexts, e.g. with an untrusted certificate). The same applies to the other copy buttons and the subscription page.
- **Optional plain-HTTP subscription URL** (Settings → HTTPS, off by default): some apps reject a self-signed certificate. When enabled, only `GET /s/<token>` is answered over plain HTTP; every other plain-HTTP request is still redirected to HTTPS. The account password is inside the link, so only turn it on if you need it (a real certificate is the better fix).
- Notes: Telegram messages and server error messages stay in English; the panel default language is still Persian.
- Repository layout (developers only, no change for users): the panel backend, UI, scripts and units now live in real files (`panel/`, `scripts/`, `systemd/`, `installer/install.sh.in`) and `install.sh` is generated from them with `./build.sh`; the generated file is byte-identical to the previous one. Unit tests added (`tests/`).
- How it was checked: the whole panel was walked in English (all tabs, modals, bulk/template flows, the one-click tunnel setup, the settings actions that raise dialogs) with an automatic scan for any Persian text left — none besides the bilingual language-button label — then switched back to Persian and checked again.

## v1.5.1 — Documentation
- README rewritten for v1.5 with proper Markdown structure (English + Persian): features, install/update, the HTTPS first login, the tunnel with In/Out and port coordination, backup, Telegram, subscription page, statistics, files, security notes and uninstall (including the exit server).
- The installer's final line now prints `https://` and tells you the default password must be changed at the first login.

## v1.5.0 — Security, backups, Telegram, bulk accounts, subscription links, statistics

### 1. HTTPS and forced password change
- The panel is served over **HTTPS on the same port 2053** (self-signed certificate created automatically, TLS 1.2+). Plain `http://` requests are redirected to `https://`, so old bookmarks keep working. You can upload your own certificate + key in Settings (it is checked before it is activated).
- With the default `admin/admin` the whole API is locked until a new password (8+ characters, not "admin") is set in a forced dialog.

### 2. Encrypted backup and restore (Settings)
- One file with users (incl. password hashes and expiry), quota/usage, ports, tunnel configuration and SSH key, Telegram settings, templates and history, encrypted with a passphrase you choose (PBKDF2 + Fernet). Wrong passphrase or a damaged file is refused. Restore re-creates missing Linux accounts, restores everything, re-applies routing/tunnel and restarts the panel.

### 3. Passwords encrypted at rest
- Passwords the panel displays are stored encrypted (Fernet) with a key in a separate root-only file; existing plaintext entries are migrated automatically on start. The Telegram token and backup passphrase are encrypted too.

### 4. Telegram
- Settings: bot token, chat id (with a "find chat id" helper), alert switches, daily backup hour. Alerts: tunnel down/up, quota 90% / full, account expiring (3 days) / expired, CPU/RAM high for 3 minutes (no repeated spam). Daily encrypted backup to the chat. Bot commands (only from the configured chat): `/status /users /online /backup`.
- Telegram is often blocked: the panel tries the direct path first and automatically falls back to the tunnel (and remembers what worked).

### 5. Templates and bulk creation
- Save the create form as a template and apply it later. "Bulk creation": prefix + count (1–200) + template-like fields + In/Out; random passwords (or one shared password); result can be copied or downloaded as CSV; name collisions are reported per account.

### 6. Subscription link and QR
- Every account has a secret link (`/s/<token>`) — a public, login-free page with expiry, usage, connection info (host/ports follow the account's In/Out and port mapping), an `ssh://` link and a QR code. Wrong tokens are rate-limited per IP. The 🔗 button shows the QR and copies the link.

### 7. Statistics tab
- Every minute the panel records tunnel state + latency, CPU/RAM and per-user traffic. The tab draws tunnel availability/latency (24 h), server load (24 h), daily traffic (14 days) and the top users (7 days).

### Notes
- New packages are installed by `install.sh`: `python3-cryptography`, `python3-qrcode`, `openssl`. If they are missing the panel still runs (without encryption/backup/QR) and says so in Settings.
- The encryption key lives on the same server: it protects copies of the files and the backups, not a compromised root.
- With the self-signed certificate the browser warns once; the subscription link opens with the same warning unless you install a real certificate.
- Tested in the two-server lab (HTTPS, forced change, encryption + migration, backup/restore incl. wrong passphrase and a deleted user, Telegram against a stand-in Bot API incl. the tunnel fallback with the direct path blocked, alerts without repetition, templates/bulk, subscription page + rate limit, history with real traffic, full UI in a browser). Not covered: the real Telegram servers, Let's Encrypt, real `badvpn-udpgw`, real systemd, IPv6.

## v1.4.0 — Port coordination and firewalls on both servers

### What the check found (and fixed)
- The installer picked Dropbear ports without looking at what else listens on the server, so a port held by another program (nginx, x-ui, ...) left Dropbear unable to bind it.
- On the exit server a busy port was only skipped, never resolved.
- Only ufw on this server was updated; the exit server's firewall and firewalld were ignored.

### New
- **Conflicts on this server**: installer and panel never choose ports held by other programs; a configured Dropbear/tunnel-Dropbear port that another program holds is replaced by the next free port (Dropbear restarted, firewall opened). Manual port changes containing such a port are refused.
- **Conflicts on the exit server**: a port busy there is published under another number (`p+10000`, else the next free one) — the panel-server port and client configs stay unchanged. Ports 22 and every other listener on the exit server are never taken over. The mapping is stored, shown in the Tunnel tab, used by the copy button and the port list of "In = server 2" accounts.
- **Firewalls of both servers**: ufw (active) and firewalld (running) are updated for this server's ports and for the ports published on the exit server; `install.sh` does the same for firewalld.
- **Tunnel tab**: "Port coordination" card with the port table (server-1 port, type, exit-server port, status) and a "Check & fix conflicts + update firewalls" button. The same check runs automatically on panel start, tunnel install and every port change.

### Notes
- Closing old ports is not done automatically (rules are only added) so nothing you opened yourself is removed.
- With the cloud provider's own firewall / security group (outside the server) you still have to open the published ports yourself.
- firewalld handling is best-effort and was not run for real (the lab used stand-in ufw/firewall-cmd that log the calls).

### How it was tested
Lab with deliberate conflicts: another program on this server's port 8443 before install (skipped), programs on the exit server's 442, 2087 and the exit sshd's 2222 (published as 10442, 12087, 12222), then new conflicts after install (a program taking a configured port on this server → replaced by 8086 and Dropbear listens there; a new program on the exit server → remapped). Clients entering through the remapped ports reach the right accounts with the right exit IP, the exit server's own programs keep answering, and the stand-in firewall logs show the right ports opened on both servers. UI checked in a real browser.

## v1.3.1 — UI polish
- The panel version is shown next to the logo (header and login box), so you can see which version is installed. It is taken from the installer's `VERSION`, so the two can never disagree.
- The "How it works" / bidirectional texts in the Tunnel tab were rewritten for In/Out and no longer scramble in right-to-left layout (`In`/`Out` and the 1→2 style combinations are isolated; no more `=` / `:` that flipped).
- Note: if the Tunnel tab still says "UDPGW still leaves from this server", that server runs an old version — run the install command again.

## v1.3.0 — Bidirectional by default, In/Out per account, CK.VPN UI

### New
- **Bidirectional by default**: setting up the tunnel automatically publishes this server's ports (normal Dropbear, tunnel Dropbear, 2nd OpenSSH port) on the exit server. No routing mode to configure; the "Routing" card of v1.2.0 is gone from the Tunnel tab (it is replaced by a read-only summary of the forwarded ports). Existing installs are migrated automatically when the panel starts.
- **In / Out per account**: when creating or editing an account the admin chooses **In** (server 1 = this server, server 2 = exit server) and **Out** (whose IP the user leaves with). All four combinations work (1→1, 1→2, 2→1, 2→2). A live hint shows the real IPs, the port list follows the choice, the user table has an "In → Out" column, and the copy button gives the right host/ports. Changing In/Out cuts the user's live sessions.
- **UDPGW works on every combination**; for Out = server 2 it goes through the tunnel (as in v1.2.0). Verified for TCP and UDP on all four.
- **CK.VPN branding**: new name and logo in the login box, header, page title and favicon.

### Notes
- Entry via server 2 is "published", not enforced: the same account can also connect straight to server 1's ports (Dropbear cannot filter by source). The Out side is enforced.
- Users entering through server 2 are seen by this server with the exit server's address, and the exit server's firewall must allow the forwarded ports.
- Port 22 and ports the exit server already listens on are never forwarded (admin access stays open).

### How it was tested
Two-server lab: TCP and UDPGW checked on all four In/Out combinations (including the 2→2 hairpin and OpenSSH vs Dropbear ports); the wrong Dropbear instance is still refused; UI checked in a real browser (branding, In/Out selects, hint, ports per choice, table, copy text, no JS errors). Not covered: the real `badvpn-udpgw` binary (stand-in used), real systemd, the IPv6 branch.

## v1.2.0 — Routing and UDPGW in the tunnel

### New
- **Routing** card in the Tunnel tab: choose which IP users connect to and which IP they leave with.
  1. enter with this server's IP, leave with the exit server's IP (Tunnel accounts, as before);
  2. **enter with the exit server's IP, leave with this server's IP**: the exit server forwards this server's Dropbear ports (and the 2nd OpenSSH port) through the tunnel; the accounts are the normal Direct accounts of this panel, so quota, expiry and concurrent-login limits keep working;
  3. both.
  Admin access stays open: port 22 and every port the exit server already listens on are never taken over (they are reported as skipped), the panel is untouched. The forwards follow port changes in Settings automatically, survive an exit-server reboot, and are removed when the tunnel is removed. The "copy" button of a Direct account also shows the exit-server entry address when mode 2/3 is on.
  In mode 2 (only) creating new Tunnel accounts is disabled.
- **UDPGW (BadVPN) for games/calls now goes through the tunnel for Tunnel accounts.** A second badvpn instance (UDP port + 1) runs in the tunnel routing path; connections of Tunnel accounts to `127.0.0.1:7300` are transparently redirected to it (per-user for OpenSSH, per-cgroup for tunnel Dropbear), so clients keep the same UDPGW setting. Fail-closed like everything else: tunnel down = no UDP either. Direct accounts keep using the normal instance.
- Dashboard shows a warning if the tunnel UDPGW instance is stopped; the monitor restarts it.
- Copy button no longer throws when the browser refuses clipboard access (falls back to a prompt).

### Notes
- In mode 2 the real client IP is not visible on this server (it sees the exit server). Open the forwarded ports in the exit server's firewall / security group.
- BadVPN's port+1 is reserved for the tunnel instance; the panel refuses ports that would collide.

### How it was tested
Same two-server lab as v1.1: UDP path checked with a stand-in UDPGW that sends a real UDP datagram to an "internet" echo server (direct accounts leave with this server's IP, Tunnel accounts on OpenSSH and on tunnel Dropbear with the exit server's IP, tunnel down = blocked); mode 2/3: clients entering through the exit server's IP leave with this server's IP, ports busy on the exit server are skipped, admin SSH to the exit server stays reachable, port change re-applies, exit-server reboot restores the rules, tunnel down = refused, mode switch and tunnel removal clean up. The real `badvpn-udpgw` binary was not run in the lab (only the stand-in), and the IPv6 branch is still untested.

## v1.1.1
- Base install: `apt-get update` first, then `curl`, then all other packages.
- Tunnel setup: `apt-get update` now always runs first on both servers (this one and the exit server) before any package is installed.

## v1.1.0 — Tunnel

### New
- **Tunnel tab** in the panel: enter the exit server's IP, SSH port and root password and press one button. The installer logs in once with the password, installs a dedicated SSH key, prepares the exit server (`PermitTunnel`, IP forwarding, NAT, MSS clamp — persistent across reboots) and brings up an SSH layer-3 tunnel (`ssh -w`, `tun99`, `10.99.0.0/30`). Progress is shown step by step; on failure everything is rolled back. The password is never stored.
- **Account type** when creating/editing a user: **Direct** (exits with this server's IP) or **Tunnel** (exits with the exit server's IP). Type can be switched later; live sessions are cut so they reconnect on the right path.
- **Tunnel Dropbear instance** with its own ports (default 2087, 2096; editable in Settings). Tunnel accounts work on OpenSSH ports and tunnel-Dropbear ports; the normal Dropbear ports only accept Direct accounts (and vice versa).
- **Fail-closed routing**: tunnel accounts are routed through a dedicated routing table that always ends in `unreachable`. If the tunnel is down they have no connectivity instead of leaking out through this server (IPv6 is blocked for them as well).
- Auto-reconnect (systemd `Restart=always` + SSH keepalive), tunnel health monitored by the panel, status shown on the dashboard.
- `sshplus-tunnel-setup EXIT_IP [PORT] [USER]` — terminal version of the one-click setup (password typed in the terminal, not sent to the panel over HTTP).
- Removing the tunnel converts all tunnel accounts to Direct, so nobody is locked out.
- `install.sh` now prints its version and is safe to re-run over v1.0 (users, ports, tunnel are kept).

### Notes / limits
- UDPGW (BadVPN) traffic still leaves from this server, not through the tunnel.
- The tunnel is IPv4-only and runs over TCP (SSH): keep BBR enabled on both servers.
- One exit server at a time. Exit server: Linux + systemd, root SSH login with password for the one-time setup.
- Requires cgroup v2 (Ubuntu 22.04 / 24.04).

### How it was tested
Two-server lab with network namespaces (panel server, exit server, "internet" host that echoes the client IP): one-click setup through the panel API and the CLI; Direct vs Tunnel accounts on OpenSSH and on both Dropbear instances (exit IP matches the account type); wrong-instance logins rejected; tunnel down / half-broken / killed → tunnel accounts blocked, never leaked, auto-reconnect; Dropbear restart rebuilds the cgroup rule; type switch, user delete, port change, tunnel removal, and re-running the installer over an existing install; UI checked in a real browser with no JS errors. The IPv6 branch could not be run (no IPv6 in the lab) and was only checked with a mock.

## v1.0.0
Initial release: OpenSSH + Dropbear (6 ports) + BadVPN UDPGW + BBR with a web panel.
