# Changelog

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
