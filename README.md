# CK.VPN — SSH Plus Panel

One-command installer for an SSH tunnel server on Ubuntu: **OpenSSH + Dropbear + BadVPN UDPGW + BBR**, a **two-server tunnel**, and a web panel (**CK.VPN**) for managing accounts.

**Language: [English](#english) | [فارسی](#فارسی)**

---

<a name="english"></a>

## English

### Features

**Core**
- OpenSSH direct access (ports 22 and 2222 by default; any extra SSH port you configured yourself is never touched).
- Dropbear on up to 6 configurable ports.
- BadVPN UDPGW (default `127.0.0.1:7300`) for UDP traffic such as online games, DNS and calls through the SSH tunnel.
- BBR congestion control, installed automatically and switchable from the panel.

**Web panel (HTTPS, port 2053)**
- Create, edit, delete accounts; traffic quota (GB), expiry date, simultaneous-login limit.
- Account **templates** and **bulk creation** (1–200 accounts, random or shared passwords, CSV export).
- Per-account **subscription page + QR code**.
- **English / Persian interface**: the language button (top right, also on the login screen) switches the whole panel and its direction; the choice is remembered. The subscription page has the same switch (`?lang=en`).
- Live online users, CPU / RAM / network, **statistics tab** (tunnel health, load, daily traffic, top users).
- Change SSH, Dropbear and BadVPN ports, turn BBR on/off, one-click copy of connection info.

**SSH over TLS (new in 1.7)**
- **TLS & Domain tab**: one switch turns on SSH inside TLS (stunnel in front of two local Dropbear instances). Ports: normal accounts (default 443) and tunnel accounts (default 8843).
- **Per account connection type** (create, edit, bulk, templates): *Normal + TLS*, *Normal only*, *TLS only*. A TLS-only account is refused on the plain Dropbear ports and on OpenSSH (port 22 ...); a normal-only account is refused on the TLS ports. Entry via the second server works with TLS as well (the TLS ports are forwarded).
- **Domain and certificate in one click**: your own domain, or a free one chosen by the admin — `sslip.io`, `nip.io` (no sign-up), `DuckDNS` (free account + token) or any other wildcard-DNS suffix. The panel checks that the name points to this server, installs certbot, gets a Let's Encrypt certificate (HTTP-01 on port 80) and renews it automatically. Without a domain a self-signed certificate is used (apps must allow an untrusted certificate).
- Hardening and visibility: per-IP connection limit on the TLS ports, real client addresses in the *Online* column, a *TLS details* button for apps without an import link, a Let's Encrypt *staging* switch. See [docs/REAL-WORLD-CHECKLIST.md](docs/REAL-WORLD-CHECKLIST.md) for the five steps to verify on a real server.
- The same certificate and domain also serve the panel's own HTTPS (one place to manage them). Subscription links and the subscription page list the TLS ports and SNI.

**Tunnel (two servers)**
- One-click SSH tunnel to a second "exit" server.
- Per account choose **In** (which server the user connects to) and **Out** (whose IP the user leaves with): `1→1`, `1→2`, `2→1`, `2→2`.
- UDPGW works on all four combinations; fail-closed when the tunnel is down; automatic reconnect.
- Port conflict detection/repair on both servers and firewall (ufw / firewalld) updates on both.

**Security and operations**
- HTTPS with automatic self-signed certificate (upload your own in Settings), forced change of the default password at first login, login rate limit (5 failures / 5 minutes).
- Passwords shown in the panel are encrypted at rest.
- Encrypted backup / restore.
- Telegram bot: alerts and daily backup.
- Safe to re-run: existing users, ports, tunnel and settings are kept.

### CK Client (Windows desktop client)

Native Windows x64 desktop app (not web-based) with the panel's colours and logo; SSH + UDPGW VPN client for this panel's servers.

**[⬇ Download ck-client.exe](https://github.com/Sinakhani70/sshplus-panel/raw/claude/fervent-einstein-ffsqxa/ck-client/dist/ck-client.exe)** · **[⬇ Installer (choose install folder)](https://github.com/Sinakhani70/sshplus-panel/raw/claude/fervent-einstein-ffsqxa/ck-client/dist/CK-Client-Setup.exe)** · [details](ck-client/README.md)

- **VPN mode** (all apps, via a Wintun adapter) or **SOCKS5 proxy mode**; UDP (games, calls, DNS) goes through UDPGW (`127.0.0.1:7300`).
- SSH over TCP or TLS/SNI, password or key login, auto-reconnect, host-key pinning.
- Needs `wintun.dll` (amd64, from <https://www.wintun.net>) next to the exe for VPN mode, and Administrator rights.
- The Windows-specific parts (adapter, routes) have not been tested on real Windows yet; unsigned binary, so SmartScreen/antivirus may warn.
- Build yourself: `cd ck-client && ./build.sh`

### Requirements
- Ubuntu 22.04 or 24.04 (fresh server recommended), root access.
- Internet access (packages and BadVPN are downloaded/compiled during install).
- For the tunnel: a second Linux server (Debian/Ubuntu with systemd) where root can log in with a password **once** during setup.

### Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Sinakhani70/sshplus-panel/main/install.sh)
```

If curl is missing: `apt-get update && apt-get install -y curl`

Run it **only on the panel server** ("server 1"). The exit server is configured by the panel over SSH — never run the installer there.

At the end you should see something like:

```
Panel:     active
Dropbear:  active   (tunnel instance: active)
Tunnel:    not set up (Panel -> Tunnel tab, or: sshplus-tunnel-setup EXIT_IP)
BadVPN:    active   (tunnel instance: active)
SSH:       active
BBR:       bbr / fq
Version:   1.6.0
Panel URL: https://YOUR_SERVER_IP:2053  (first login: admin / admin, you must change it)
```

### After install
1. Open `https://YOUR_SERVER_IP:2053`. The default certificate is self-signed, so the browser warns once — continue. (An old `http://` address is redirected to `https://`.)
2. Log in with `admin` / `admin`. The panel asks for a new password (8+ characters) and stays locked until you set it.
3. Create an account. In your SSH client connect to the server IP using one of the Dropbear / SSH ports shown in the panel.
4. Set the UDPGW address in your client to `127.0.0.1:7300`.
5. Settings → **Backup**: download a backup and keep the passphrase safe. Optionally connect Telegram (see below).

The version is shown next to the logo, so you always know what is installed.

### Updating
Run the same install command again on server 1. Users, ports, tunnel, passwords and settings are kept. The panel re-applies the exit-server side by itself a few seconds after it starts. After updating from a version older than 1.5 the panel address is `https://`.

### Tunnel

Users connect to this server (server 1). The exit server (server 2) is only used for the traffic you send through it.

**Set up** — Panel → **Tunnel** tab → exit server IP, SSH port, root password → **Install & connect**. One click installs a key-based SSH login, prepares the exit server (`PermitTunnel`, IP forwarding, NAT, firewall) and brings up an SSH layer-3 tunnel (`ssh -w`, device `tun99`, `10.99.0.0/30`). The password is used once and never stored. Terminal alternative (nothing typed into the web page): `sshplus-tunnel-setup EXIT_IP [PORT] [USER]`.

**In / Out per account** — when you create or edit an account:

| In | Out | Meaning |
|----|-----|---------|
| server 1 | server 1 | normal "Direct" account |
| server 1 | server 2 | "Tunnel" account: user connects to server 1, leaves with server 2's IP |
| server 2 | server 1 | user connects to server 2's IP, leaves with server 1's IP |
| server 2 | server 2 | user connects to and leaves with server 2's IP |

- Out = server 2 accounts work on the OpenSSH ports and the dedicated **tunnel Dropbear** ports (default 2087, 2096); the normal Dropbear ports accept only Out = server 1 accounts.
- In = server 2: this server's ports are published on the exit server and forwarded through the tunnel. Port 22 and every port the exit server already listens on are never taken over, so admin access to both servers stays open. Entry via server 2 is *published*, not enforced (the same account can also connect straight to server 1); the Out side is enforced.
- **Fail-closed:** if the tunnel is down, every path that goes through it is blocked instead of leaking out through the wrong IP (IPv6 is blocked for tunnel accounts). The tunnel reconnects automatically.
- **UDPGW** (games/calls) works on all combinations; for Out = server 2 a second badvpn instance (UDP port + 1) runs in the tunnel path and connections to `127.0.0.1:7300` are redirected to it transparently, so clients keep the same setting.

**Port coordination and firewalls** — the installer and the panel never pick ports that another program (nginx, x-ui, …) already listens on; a configured port that gets taken is replaced by a free one. On the exit server a busy port is published under another number (e.g. 442 → 10442) so this server's ports and client configs do not change. ufw / firewalld of **both** servers are updated. The Tunnel tab shows the port table and a **Check & fix conflicts** button; the check also runs on panel start, tunnel install and every port change. Your cloud provider's own firewall / security group must still allow the published ports.

**Limits** — the tunnel is IPv4-only and runs over TCP/SSH (keep BBR on for both servers); one exit server at a time; users entering through server 2 are seen by server 1 with the exit server's address.

### Panel features
- **CK Client card on the main page**: download links for the Windows app (installer / portable) with a note to use it to connect to the server over SSH + UDPGW.

**Subscription page and QR** — every account has a secret link `https://HOST:2053/s/<token>` (button 🔗 in the account list): a login-free page with expiry, usage, connection info (follows In/Out and port mapping), an `ssh://` link and a QR code. Wrong tokens are rate-limited per IP. The same link also works for **apps**: browsers get the page, apps get the standard subscription list (base64 of `ssh://` links, with usage/expiry headers); force a format with `?fmt=plain|b64|html` (`?auth=b64` for the base64-login variant). If an app rejects the self-signed certificate, install a real certificate or enable the optional plain-HTTP subscription URL in Settings → HTTPS (the password is inside the link, so use it only if needed).

**Templates and bulk creation** — save the create form as a template and apply it later. *Bulk creation*: prefix + count (1–200) + days/quota/limit/In/Out; random passwords (or one shared password); copy or download the result as CSV; name collisions are reported per account.

**Statistics tab** — every minute the panel records tunnel state and latency, CPU/RAM and per-user traffic: tunnel availability (24 h), server load (24 h), daily traffic (14 days), top users (7 days).

**Backup and restore** — Settings → Backup. One file with users (including password hashes and expiry), quota/usage, ports, tunnel configuration and SSH key, Telegram settings, templates and history, encrypted with a passphrase you choose. Restore re-creates missing Linux accounts, re-applies the tunnel and restarts the panel. Without the passphrase the file cannot be opened.

**Telegram** — Settings → Telegram:
1. Create a bot with `@BotFather` and paste the token.
2. Send `/start` to the bot and press **Find chat id**, then Save.
3. Choose the alerts: tunnel down/up, quota 90% / full, account expiring (3 days) / expired, CPU/RAM high for 3 minutes (each alert is sent once, no spam), daily encrypted backup (needs a backup passphrase and an hour).
4. Bot commands (only from the configured chat): `/status`, `/users`, `/online`, `/backup`.

If Telegram cannot be reached from the server (it is often blocked), the panel automatically falls back to the tunnel and remembers what worked.

**HTTPS** — Settings → HTTPS shows the current certificate. To use a real certificate (for example from Let's Encrypt, if you have a domain) paste the full chain and the private key there; they are checked before being activated.

### Useful commands

```bash
# change the panel admin login from the terminal (also the way back in if you forget it)
sshplus-pass NEWUSER NEWPASSWORD

# set up / replace the tunnel from the terminal
sshplus-tunnel-setup EXIT_IP [PORT] [USER]

# service status
systemctl status sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel badvpn badvpn-t

# logs
journalctl -u sshplus-dropbear -n 50 --no-pager
journalctl -u sshplus-tunnel -n 50 --no-pager
tail -50 /var/log/sshplus/install.log

# listening ports
ss -tlnp | grep -E 'dropbear|badvpn|sshd'

# check BBR
sysctl net.ipv4.tcp_congestion_control
```

### Files

| Path | Purpose |
|------|---------|
| `/opt/sshplus-panel/` | panel (`app.py`, `index.html`) |
| `/etc/SSHPlus/panel.json` | panel login and port |
| `/etc/SSHPlus/ports.json`, `badvpn.conf` | SSH / Dropbear / tunnel-Dropbear ports, UDPGW settings |
| `/etc/SSHPlus/meta.json` | per-account data (encrypted passwords, quota, usage, subscription token) |
| `/etc/SSHPlus/secret.key` | key for the encrypted values (root only) |
| `/etc/SSHPlus/panel.crt`, `panel.key` | certificate + key (panel HTTPS **and** SSH over TLS) |
| `/etc/SSHPlus/tls.json`, `stunnel.conf`, `shells.*` | SSH-over-TLS settings, generated stunnel config, per-instance shell lists |
| `/etc/SSHPlus/tunnel.conf`, `tunnel_key`, `tunnel_known_hosts` | tunnel configuration and its SSH key |
| `/etc/SSHPlus/telegram.json`, `templates.json`, `history.json` | Telegram settings, account templates, statistics |
| `/etc/ssh/sshd_config.d/00-sshplus.conf` | OpenSSH settings managed by the panel |
| `/var/log/sshplus/install.log` | install log |

### Security notes
- The panel is served over HTTPS on port 2053 (self-signed certificate by default, so the browser warns; upload your own in Settings). The default `admin/admin` must be changed at the first login; the panel is locked until then.
- Passwords shown in the panel are encrypted at rest (Fernet) in `meta.json`. The key `/etc/SSHPlus/secret.key` lives on the same server (root only), so this protects copies of the file and backups, **not** a compromised root. The real account passwords are only hashes in `/etc/shadow`, as usual.
- Backups contain the tunnel's private key and password hashes — they are encrypted, but keep the file and the passphrase apart.
- Traffic accounting is approximate (per-process I/O counters); do not rely on it for exact billing.
- Dropbear connections are briefly dropped when ports are changed from the panel.
- Tunnel: the exit server's password typed in the Tunnel tab goes over the panel's HTTPS; with the self-signed certificate make sure you really reached your own panel (check the certificate once) or use `sshplus-tunnel-setup`. The tunnel's SSH key gives server 1 root access to the exit server, so protect server 1. The exit server's host key is trusted on first connection.
- `PermitRootLogin yes` is enabled for compatibility. Consider SSH keys for root and disabling password login for it.
- SSH over TLS: behind stunnel Dropbear sees every TLS client as `127.0.0.1`, so the per-client address is not available for TLS sessions (and TLS uses 6 Dropbear processes per account type to avoid Dropbear's 5-unauthenticated-connections-per-IP limit). Port 80 is opened for Let's Encrypt and must stay free (renewals use it). Free wildcard-DNS names (`sslip.io`, `nip.io`) share Let's Encrypt rate limits with everyone who uses them: if a request is refused, use another service or your own domain. The `ssh://` link for TLS (`?security=tls&sni=...`) is a convention, not a standard: if an app does not accept it, enter host, port and SNI by hand. A restored backup brings the certificate files but not certbot's renewal data: request the certificate again with one click.

### Uninstall

Remove the tunnel in the panel first (it also takes the forwarded ports back from the exit server), then:

```bash
systemctl disable --now sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-dropbear-s sshplus-dropbear-ts sshplus-stunnel sshplus-tunnel sshplus-tunnel-net badvpn badvpn-t
/usr/local/bin/sshplus-tunnel-net clean
/usr/local/bin/sshplus-tls-fw clean
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/sshplus-dropbear-t.service /etc/systemd/system/sshplus-dropbear-s.service /etc/systemd/system/sshplus-dropbear-ts.service /etc/systemd/system/sshplus-stunnel.service /etc/systemd/system/sshplus-tunnel.service /etc/systemd/system/sshplus-tunnel-net.service /etc/systemd/system/badvpn.service /etc/systemd/system/badvpn-t.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-shell-{t,n,tn,s,ts} /usr/local/bin/sshplus-tls-fw /usr/local/bin/sshplus-pass /usr/local/bin/sshplus-tunnel-net /usr/local/bin/start-tunnel.sh /usr/local/bin/sshplus-tunnel-setup /usr/local/bin/badvpn-udpgw
```

Accounts stay on the system; remove them with `userdel USERNAME`. Make sure you still have another way into the server (for example port 22) before deleting `/etc/ssh/sshd_config.d/00-sshplus.conf`.

On the exit server (only if you did not remove the tunnel in the panel): `systemctl disable --now sshplus-exit; rm -f /usr/local/bin/sshplus-exit.sh /etc/systemd/system/sshplus-exit.service /etc/sshplus-exit.ports /etc/ssh/sshd_config.d/01-sshplus-tunnel.conf`, then reload sshd.

### Development

`install.sh` is what users download, so it stays **one file** — but it is **generated**. Edit the real sources and rebuild:

| Path | What it is |
|------|------------|
| `panel/app.py` | panel backend (Python) |
| `panel/index.html`, `panel/ui.js` | panel UI: markup + CSS, and the JavaScript |
| `scripts/` | helper scripts installed to `/usr/local/bin` |
| `systemd/` | service units |
| `installer/install.sh.in` | installer skeleton (steps, config); each big block is a line `@@INCLUDE path@@` |
| `tests/` | unit tests (`python3 -m unittest discover -s tests -v`) |

```bash
./build.sh          # regenerate install.sh from the sources
./build.sh --check  # fail if install.sh is not up to date (run before every commit)
```

Do not edit `install.sh` by hand; the next build would overwrite it.

### Disclaimer
Use this software only on servers you own or administer, and in accordance with the laws that apply to you. It is provided as-is, without warranty.

---

<div dir="rtl">

<a name="فارسی"></a>

## فارسی

### امکانات

**هسته**
- OpenSSH مستقیم (پیش‌فرض پورت‌های ۲۲ و ۲۲۲۲). پورت SSH اختصاصی خودت که بیرون از پنل تنظیم کرده‌ای هرگز دست نمی‌خورد.
- Dropbear با حداکثر ۶ پورت قابل تنظیم.
- BadVPN UDPGW (پیش‌فرض `127.0.0.1:7300`) برای ترافیک UDP مثل بازی آنلاین، DNS و تماس از داخل تونل SSH.
- BBR که خودکار نصب می‌شود و از پنل قابل روشن/خاموش شدن است.

**پنل وب (HTTPS، پورت ۲۰۵۳)**
- ساخت، ویرایش و حذف اکانت؛ سهمیه‌ی حجم (GB)، تاریخ انقضا، محدودیت اتصال همزمان.
- **قالب** و **ساخت دسته‌ای** اکانت (۱ تا ۲۰۰ اکانت، رمز تصادفی یا مشترک، خروجی CSV).
- **صفحه‌ی اشتراک و QR** برای هر اکانت.
- **رابط انگلیسی / فارسی**: دکمه‌ی زبان (بالا سمت چپ و در صفحه‌ی ورود) کل پنل و جهت صفحه را عوض می‌کند و انتخابت به خاطر سپرده می‌شود. صفحه‌ی اشتراک هم همین دکمه را دارد (`?lang=en`).
- نمایش زنده‌ی کاربران آنلاین و مصرف CPU / RAM / شبکه، **تب آمار** (سلامت تانل، بار سرور، مصرف روزانه، پرمصرف‌ترین‌ها).
- تغییر پورت‌های SSH، Dropbear و BadVPN، روشن/خاموش کردن BBR، کپی سریع مشخصات اتصال.

**SSH روی TLS (جدید در ۱.۷)**
- **تب «TLS و دامنه»**: با یک کلید SSH داخل TLS قرار می‌گیرد (stunnel جلوی دو Dropbear محلی). پورت اکانت‌های معمولی (پیش‌فرض ۴۴۳) و اکانت‌های تانل (پیش‌فرض ۸۸۴۳) جداست.
- **نوع اتصال هر اکانت** (ساخت، ویرایش، دسته‌ای، قالب): *معمولی + TLS*، *فقط معمولی*، *فقط TLS*. این محدودیت روی هر نمونه‌ی Dropbear اعمال می‌شود؛ اکانت «فقط TLS» روی پورت‌های Dropbear معمولی و اکانت «فقط معمولی» روی پورت‌های TLS وارد نمی‌شود. اکانت «فقط TLS» روی OpenSSH (پورت ۲۲ و ...) هم وارد نمی‌شود. ورود از سرور ۲ هم با TLS کار می‌کند (پورت‌های TLS فوروارد می‌شوند).
- **دامنه و گواهی با یک کلیک**: دامنه‌ی خودت، یا یک دامنه‌ی رایگان به انتخاب ادمین — `sslip.io` و `nip.io` (بدون ثبت‌نام)، `DuckDNS` (حساب رایگان + توکن) یا هر پسوند wildcard-DNS دیگر. پنل بررسی می‌کند نام به این سرور اشاره کند، certbot را نصب می‌کند، گواهی Let's Encrypt (تأیید HTTP روی پورت ۸۰) می‌گیرد و خودکار تمدید می‌کند. بدون دامنه گواهی self-signed استفاده می‌شود (برنامه باید گواهی نامعتبر را بپذیرد).
- سخت‌سازی و دید بهتر: محدودیت اتصال به ازای هر IP روی پورت‌های TLS، نمایش IP واقعی کلاینت در ستون «آنلاین»، دکمه‌ی «مشخصات TLS» برای برنامه‌های بدون لینک import و سوییچ staging برای Let's Encrypt. پنج مرحله‌ی آزمون روی سرور واقعی در [docs/REAL-WORLD-CHECKLIST.md](docs/REAL-WORLD-CHECKLIST.md).
- همین گواهی و دامنه برای HTTPS خودِ پنل هم استفاده می‌شود (یک جا برای مدیریت). لینک اشتراک و صفحه‌ی اشتراک پورت‌های TLS و SNI را نشان می‌دهند.

**تانل (دو سرور)**
- تانل SSH با یک کلیک به یک سرور دوم («خروجی»).
- برای هر اکانت **In** (کاربر به کدام سرور وصل شود) و **Out** (با IP کدام سرور خارج شود) را انتخاب می‌کنی: `۱←۱`، `۱←۲`، `۲←۱`، `۲←۲`.
- UDPGW روی هر چهار ترکیب کار می‌کند؛ با قطع تانل مسیر بسته می‌شود (fail-closed)؛ اتصال مجدد خودکار است.
- تشخیص و رفع تداخل پورت روی هر دو سرور و به‌روزرسانی فایروال (ufw / firewalld) هر دو.

**امنیت و عملیات**
- HTTPS با گواهی self-signed خودکار (گواهی خودت را در تنظیمات می‌گذاری)، تغییر اجباری رمز پیش‌فرض در اولین ورود، محدودیت تلاش ورود (۵ تلاش ناموفق در ۵ دقیقه).
- رمزهایی که پنل نشان می‌دهد در حالت ذخیره رمزنگاری می‌شوند.
- بکاپ و بازیابی رمزنگاری‌شده.
- ربات تلگرام: هشدار و بکاپ روزانه.
- اجرای دوباره‌ی اسکریپت امن است: کاربران، پورت‌ها، تانل و تنظیمات حفظ می‌شوند.

### CK Client (کلاینت ویندوز)

برنامه‌ی دسکتاپ بومی ویندوز ۶۴ بیت (نه تحت وب) با رنگ‌بندی و لوگوی پنل؛ کلاینت VPN با SSH و UDPGW برای سرورهای همین پنل.

**[⬇ دانلود ck-client.exe](https://github.com/Sinakhani70/sshplus-panel/raw/claude/fervent-einstein-ffsqxa/ck-client/dist/ck-client.exe)** · **[⬇ نصب‌کننده (انتخاب مسیر نصب)](https://github.com/Sinakhani70/sshplus-panel/raw/claude/fervent-einstein-ffsqxa/ck-client/dist/CK-Client-Setup.exe)** · [توضیحات بیشتر](ck-client/README.md)

- **حالت VPN** (همه برنامه‌ها، با کارت شبکه Wintun) یا **حالت پراکسی SOCKS5**؛ ترافیک UDP (بازی، تماس، DNS) از UDPGW (`127.0.0.1:7300`) رد می‌شود.
- SSH روی TCP یا TLS با SNI، ورود با رمز یا کلید، اتصال مجدد خودکار و ذخیره اثر انگشت کلید سرور.
- برای حالت VPN فایل `wintun.dll` (نسخه amd64 از <https://www.wintun.net>) باید کنار exe باشد و برنامه با دسترسی Administrator اجرا شود.
- بخش‌های مخصوص ویندوز (کارت شبکه و مسیرها) هنوز روی ویندوز واقعی تست نشده‌اند؛ فایل امضای دیجیتال ندارد و ممکن است SmartScreen یا آنتی‌ویروس هشدار بدهد.
- ساخت از سورس: `cd ck-client && ./build.sh`

### پیش‌نیازها
- اوبونتو ۲۲.۰۴ یا ۲۴.۰۴ (ترجیحاً سرور تازه) و دسترسی root.
- اینترنت (بسته‌ها و BadVPN هنگام نصب دانلود و کامپایل می‌شوند).
- برای تانل: یک سرور لینوکس دوم (دبیان/اوبونتو با systemd) که root آن **فقط یک بار** هنگام نصب با رمز وارد شود.

### نصب

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Sinakhani70/sshplus-panel/main/install.sh)
```

اگر curl نصب نبود: `apt-get update && apt-get install -y curl`

دستور را **فقط روی سرور پنل** («سرور ۱») اجرا کن. سرور خروجی را خودِ پنل از طریق SSH تنظیم می‌کند؛ آنجا هرگز نصب‌کننده را اجرا نکن.

در پایان نصب باید خروجی‌ای شبیه این ببینی:

```
Panel:     active
Dropbear:  active   (tunnel instance: active)
Tunnel:    not set up (Panel -> Tunnel tab, or: sshplus-tunnel-setup EXIT_IP)
BadVPN:    active   (tunnel instance: active)
SSH:       active
BBR:       bbr / fq
Version:   1.6.0
Panel URL: https://YOUR_SERVER_IP:2053  (first login: admin / admin, you must change it)
```

### بعد از نصب
۱. آدرس `https://IP_SERVER:2053` را باز کن. گواهی پیش‌فرض self-signed است و مرورگر یک بار هشدار می‌دهد؛ ادامه بده. (آدرس قدیمی `http://` خودکار به `https://` می‌رود.)
۲. با `admin` / `admin` وارد شو. پنل رمز جدید (حداقل ۸ کاراکتر) می‌خواهد و تا آن موقع قفل می‌ماند.
۳. یک اکانت بساز. در کلاینت SSH با IP سرور و یکی از پورت‌های Dropbear یا SSH که در پنل نمایش داده می‌شود وصل شو.
۴. آدرس UDPGW را در کلاینت `127.0.0.1:7300` بگذار.
۵. تنظیمات ← **بکاپ**: یک بکاپ بگیر و پسفریز را جای امن نگه دار. اگر خواستی تلگرام را وصل کن (پایین‌تر).

نسخه‌ی نصب‌شده کنار لوگو نمایش داده می‌شود.

### آپدیت
همان دستور نصب را دوباره روی سرور ۱ اجرا کن. کاربران، پورت‌ها، تانل، رمزها و تنظیمات حفظ می‌شوند. چند ثانیه بعد از بالا آمدن پنل، سمت سرور خروجی را خودش دوباره اعمال می‌کند. بعد از آپدیت از نسخه‌های قدیمی‌تر از ۱.۵، آدرس پنل `https://` است.

### تانل

کاربران به این سرور (سرور ۱) وصل می‌شوند. سرور خروجی (سرور ۲) فقط برای ترافیکی است که از آن عبور می‌دهی.

**راه‌اندازی** — پنل ← تب **تانل** ← IP، پورت SSH و رمز root سرور خروجی ← **نصب و برقراری تانل**. با یک کلیک ورود با کلید SSH نصب، سرور خروجی آماده (`PermitTunnel`، فوروارد IP، NAT، فایروال) و تانل لایه‌ی ۳ روی SSH (`ssh -w`، کارت `tun99`، شبکه‌ی `10.99.0.0/30`) برقرار می‌شود. رمز فقط یک بار استفاده می‌شود و ذخیره نمی‌شود. روش ترمینالی (چیزی داخل صفحه‌ی وب تایپ نمی‌شود): `sshplus-tunnel-setup EXIT_IP [PORT] [USER]`.

**In / Out برای هر اکانت** — موقع ساخت یا ویرایش اکانت:

| In | Out | معنی |
|----|-----|------|
| سرور ۱ | سرور ۱ | اکانت «مستقیم» معمولی |
| سرور ۱ | سرور ۲ | اکانت «تانل»: کاربر به سرور ۱ وصل می‌شود و با IP سرور ۲ خارج می‌شود |
| سرور ۲ | سرور ۱ | کاربر به IP سرور ۲ وصل می‌شود و با IP سرور ۱ خارج می‌شود |
| سرور ۲ | سرور ۲ | کاربر به IP سرور ۲ وصل می‌شود و با همان IP هم خارج می‌شود |

- اکانت‌های Out = سرور ۲ روی پورت‌های OpenSSH و پورت‌های اختصاصی **Dropbear تانل** (پیش‌فرض ۲۰۸۷ و ۲۰۹۶) کار می‌کنند؛ پورت‌های Dropbear معمولی فقط اکانت‌های Out = سرور ۱ را می‌پذیرند.
- In = سرور ۲: پورت‌های این سرور روی سرور خروجی منتشر و از داخل تانل فوروارد می‌شوند. پورت ۲۲ و هر پورتی که سرور خروجی خودش رویش گوش می‌دهد هرگز دست نمی‌خورد، پس دسترسی ادمین به هر دو سرور باز می‌ماند. ورود از سرور ۲ «منتشر» می‌شود، نه اجباری (همان اکانت می‌تواند مستقیم به سرور ۱ هم وصل شود)؛ سمت Out اجباری است.
- **Fail-closed:** اگر تانل قطع شود، هر مسیری که از آن می‌گذرد بسته می‌شود، نه اینکه با IP اشتباه خارج شود (IPv6 برای اکانت‌های تانل بسته است). تانل خودکار دوباره وصل می‌شود.
- **UDPGW** (بازی/تماس) روی همه‌ی ترکیب‌ها کار می‌کند؛ برای Out = سرور ۲ یک نمونه‌ی دوم badvpn (پورت UDPGW به‌علاوه‌ی ۱) در مسیر تانل اجرا می‌شود و اتصال به `127.0.0.1:7300` شفاف به آن هدایت می‌شود؛ پس تنظیم کلاینت عوض نمی‌شود.

**هماهنگی پورت‌ها و فایروال** — نصب‌کننده و پنل هیچ‌وقت پورتی را که برنامه‌ی دیگری (nginx، x-ui، …) رویش گوش می‌دهد انتخاب نمی‌کنند؛ پورت تنظیم‌شده‌ای که بعداً گرفته شود با پورت آزاد عوض می‌شود. روی سرور خروجی پورت مشغول با شماره‌ی دیگری منتشر می‌شود (مثلاً ۴۴۲ ← ۱۰۴۴۲) تا پورت‌های این سرور و کانفیگ کلاینت‌ها تغییر نکند. ufw / firewalld **هر دو** سرور به‌روز می‌شود. تب تانل جدول پورت‌ها و دکمه‌ی **بررسی و رفع تداخل** دارد؛ این بررسی با هر راه‌اندازی پنل، نصب تانل و تغییر پورت هم انجام می‌شود. فایروال خودِ ارائه‌دهنده‌ی VPS (security group) را باید خودت برای پورت‌های منتشرشده باز کنی.

**محدودیت‌ها** — تانل فقط IPv4 است و روی TCP/SSH اجرا می‌شود (BBR را روی هر دو سرور روشن نگه دار)؛ فعلاً یک سرور خروجی؛ کاربری که از سرور ۲ وارد می‌شود، روی سرور ۱ با آدرس سرور خروجی دیده می‌شود.

### امکانات پنل
- **کارت CK Client در صفحه‌ی اصلی**: لینک دانلود برنامه‌ی ویندوز (نصب‌کننده / قابل‌حمل) به‌همراه توضیح استفاده از آن برای اتصال به سرور با SSH و UDPGW.

**صفحه‌ی اشتراک و QR** — هر اکانت یک لینک مخصوص `https://HOST:2053/s/<token>` دارد (دکمه‌ی 🔗 در لیست): صفحه‌ای بدون نیاز به ورود با انقضا، مصرف، اطلاعات اتصال (مطابق In/Out و نگاشت پورت)، لینک `ssh://` و QR. توکن غلط برای هر IP محدودیت تعداد دارد. همین لینک برای **برنامه‌ها** هم کار می‌کند: مرورگر صفحه را می‌گیرد و برنامه فهرست استاندارد اشتراک را (base64 از لینک‌های `ssh://` همراه سربرگ مصرف/انقضا)؛ با `?fmt=plain|b64|html` قالب را اجباری کن (`?auth=b64` برای حالت base64 در بخش ورود). اگر برنامه گواهی self-signed را رد کرد، گواهی معتبر نصب کن یا گزینه‌ی اختیاری «لینک اشتراک روی HTTP ساده» را در تنظیمات ← HTTPS روشن کن (رمز داخل لینک است؛ فقط در صورت نیاز).

**قالب و ساخت دسته‌ای** — فرم ساخت اکانت را به‌عنوان قالب ذخیره و بعداً اعمال کن. *ساخت دسته‌ای*: پیشوند + تعداد (۱ تا ۲۰۰) + روز/حجم/همزمان/In/Out؛ رمز تصادفی (یا یک رمز مشترک)؛ نتیجه قابل کپی و دانلود CSV است؛ تداخل نام برای هر اکانت جداگانه گزارش می‌شود.

**تب آمار** — هر دقیقه وضعیت و تأخیر تانل، CPU/RAM و مصرف هر کاربر ثبت می‌شود: دسترس‌پذیری تانل (۲۴ ساعت)، بار سرور (۲۴ ساعت)، مصرف روزانه (۱۴ روز) و پرمصرف‌ترین کاربران (۷ روز).

**بکاپ و بازیابی** — تنظیمات ← بکاپ. یک فایل شامل کاربران (با hash رمز و انقضا)، حجم/مصرف، پورت‌ها، تنظیمات تانل و کلید SSH آن، تنظیمات تلگرام، قالب‌ها و تاریخچه، رمزنگاری‌شده با پسفریزی که خودت می‌گذاری. بازیابی اکانت‌های لینوکسیِ ناموجود را دوباره می‌سازد، تانل را دوباره اعمال می‌کند و پنل را ری‌استارت می‌کند. بدون پسفریز فایل باز نمی‌شود.

**تلگرام** — تنظیمات ← تلگرام:
۱. با `@BotFather` یک ربات بساز و توکن را بگذار.
۲. به ربات `/start` بده، «پیدا کردن Chat ID» را بزن و ذخیره کن.
۳. هشدارها را انتخاب کن: قطع/وصل تانل، ۹۰٪ و پر شدن حجم، نزدیک/پایان انقضا (۳ روز)، فشار CPU/RAM به مدت ۳ دقیقه (هر هشدار فقط یک بار می‌آید)، بکاپ روزانه‌ی رمزنگاری‌شده (پسفریز بکاپ و ساعت لازم است).
۴. دستورهای ربات (فقط از Chat ID تنظیم‌شده): `/status`، `/users`، `/online`، `/backup`.

اگر تلگرام از روی سرور باز نشود (معمولاً فیلتر است)، پنل خودکار از مسیر تانل می‌فرستد و مسیر موفق را به خاطر می‌سپارد.

**HTTPS** — تنظیمات ← HTTPS گواهی فعلی را نشان می‌دهد. برای گواهی معتبر (مثلاً Let's Encrypt اگر دامنه داری) زنجیره‌ی کامل و کلید خصوصی را همان‌جا بچسبان؛ قبل از فعال شدن بررسی می‌شوند.

### دستورات کاربردی

```bash
# تغییر نام کاربری و رمز ادمین پنل از ترمینال (راه برگشت اگر رمز را فراموش کردی)
sshplus-pass NEWUSER NEWPASSWORD

# نصب/تعویض تانل از ترمینال
sshplus-tunnel-setup EXIT_IP [PORT] [USER]

# وضعیت سرویس‌ها
systemctl status sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel badvpn badvpn-t

# لاگ‌ها
journalctl -u sshplus-dropbear -n 50 --no-pager
journalctl -u sshplus-tunnel -n 50 --no-pager
tail -50 /var/log/sshplus/install.log

# پورت‌های در حال گوش دادن
ss -tlnp | grep -E 'dropbear|badvpn|sshd'

# بررسی BBR
sysctl net.ipv4.tcp_congestion_control
```

### مسیر فایل‌ها

| مسیر | کاربرد |
|------|--------|
| `/opt/sshplus-panel/` | پنل (`app.py` و `index.html`) |
| `/etc/SSHPlus/panel.json` | ورود و پورت پنل |
| `/etc/SSHPlus/ports.json` و `badvpn.conf` | پورت‌های SSH / Dropbear / Dropbear تانل و تنظیمات UDPGW |
| `/etc/SSHPlus/meta.json` | اطلاعات هر اکانت (رمز رمزنگاری‌شده، حجم، مصرف، توکن اشتراک) |
| `/etc/SSHPlus/secret.key` | کلید مقادیر رمزنگاری‌شده (فقط root) |
| `/etc/SSHPlus/panel.crt` و `panel.key` | گواهی و کلید (HTTPS پنل **و** SSH روی TLS) |
| `/etc/SSHPlus/tls.json` و `stunnel.conf` و `shells.*` | تنظیمات SSH روی TLS، پیکربندی تولیدشده‌ی stunnel، فهرست shell هر نمونه |
| `/etc/SSHPlus/tunnel.conf` و `tunnel_key` و `tunnel_known_hosts` | تنظیمات تانل و کلید SSH آن |
| `/etc/SSHPlus/telegram.json` و `templates.json` و `history.json` | تنظیمات تلگرام، قالب‌ها، آمار |
| `/etc/ssh/sshd_config.d/00-sshplus.conf` | تنظیمات OpenSSH که پنل مدیریت می‌کند |
| `/var/log/sshplus/install.log` | لاگ نصب |

### نکات امنیتی
- پنل روی پورت ۲۰۵۳ با HTTPS بالا می‌آید (گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد؛ در تنظیمات گواهی خودت را بگذار). رمز پیش‌فرض `admin/admin` در اولین ورود باید عوض شود و تا آن موقع پنل قفل است.
- رمزهایی که پنل نمایش می‌دهد در `meta.json` رمزنگاری‌شده (Fernet) ذخیره می‌شوند. کلید `/etc/SSHPlus/secret.key` روی همین سرور است (فقط root)، پس از فایل کپی‌شده و بکاپ محافظت می‌کند، **نه** از دسترسی root. رمز واقعی اکانت‌ها مثل همیشه فقط به‌صورت hash در `/etc/shadow` است.
- بکاپ شامل کلید خصوصی تانل و hash رمزهاست؛ رمزنگاری‌شده است ولی فایل و پسفریز را جدا از هم نگه دار.
- شمارش ترافیک تقریبی است (بر پایه‌ی شمارنده‌های I/O هر پروسه) و برای صورتحساب دقیق قابل اتکا نیست.
- با تغییر پورت از پنل، اتصال‌های فعال Dropbear لحظه‌ای قطع می‌شوند.
- تانل: رمز سرور خروجی که در تب تانل وارد می‌کنی از طریق HTTPS پنل می‌رود؛ با گواهی self-signed مطمئن شو واقعاً به پنل خودت وصل شده‌ای (یک بار گواهی را بررسی کن) یا از `sshplus-tunnel-setup` استفاده کن. کلید SSH تانل به سرور ۱ دسترسی root روی سرور خروجی می‌دهد؛ پس از سرور ۱ محافظت کن. کلید هاست سرور خروجی در اولین اتصال پذیرفته می‌شود.
- برای سازگاری `PermitRootLogin yes` فعال است. بهتر است برای root از کلید SSH استفاده کنی و ورود با رمز را ببندی.
- SSH روی TLS: پشت stunnel، Dropbear هر کلاینت TLS را `127.0.0.1` می‌بیند، پس آدرس واقعی کلاینت برای نشست‌های TLS در دسترس نیست (و برای دور زدن سقف ۵ اتصال احراز‌نشده‌ی Dropbear به ازای هر IP، برای هر نوع اکانت ۶ پروسه‌ی Dropbear اجرا می‌شود). پورت ۸۰ برای Let's Encrypt باز می‌شود و باید آزاد بماند (تمدید هم از آن استفاده می‌کند). نام‌های رایگان wildcard-DNS (`sslip.io` و `nip.io`) سقف درخواست Let's Encrypt را با همه‌ی کاربران خود شریک‌اند؛ اگر رد شد سرویس دیگری یا دامنه‌ی خودت را امتحان کن. لینک `ssh://` برای TLS (`?security=tls&sni=...`) یک قرارداد است نه استاندارد؛ اگر برنامه نپذیرفت مشخصات (آدرس، پورت، SNI) را دستی وارد کن. بکاپ بازیابی‌شده فایل‌های گواهی را برمی‌گرداند ولی داده‌ی تمدید certbot را نه؛ گواهی را دوباره با یک کلیک بگیر.

### حذف

اول تانل را در پنل حذف کن (پورت‌های فوروارد‌شده را هم از سرور خروجی برمی‌دارد)، بعد:

```bash
systemctl disable --now sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-dropbear-s sshplus-dropbear-ts sshplus-stunnel sshplus-tunnel sshplus-tunnel-net badvpn badvpn-t
/usr/local/bin/sshplus-tunnel-net clean
/usr/local/bin/sshplus-tls-fw clean
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/sshplus-dropbear-t.service /etc/systemd/system/sshplus-dropbear-s.service /etc/systemd/system/sshplus-dropbear-ts.service /etc/systemd/system/sshplus-stunnel.service /etc/systemd/system/sshplus-tunnel.service /etc/systemd/system/sshplus-tunnel-net.service /etc/systemd/system/badvpn.service /etc/systemd/system/badvpn-t.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-shell-{t,n,tn,s,ts} /usr/local/bin/sshplus-tls-fw /usr/local/bin/sshplus-pass /usr/local/bin/sshplus-tunnel-net /usr/local/bin/start-tunnel.sh /usr/local/bin/sshplus-tunnel-setup /usr/local/bin/badvpn-udpgw
```

اکانت‌ها روی سیستم می‌مانند؛ با `userdel USERNAME` پاکشان کن. قبل از حذف `/etc/ssh/sshd_config.d/00-sshplus.conf` مطمئن شو راه دیگری برای ورود به سرور داری (مثلاً پورت ۲۲).

روی سرور خروجی (فقط اگر تانل را در پنل حذف نکردی): `systemctl disable --now sshplus-exit; rm -f /usr/local/bin/sshplus-exit.sh /etc/systemd/system/sshplus-exit.service /etc/sshplus-exit.ports /etc/ssh/sshd_config.d/01-sshplus-tunnel.conf` و بعد sshd را reload کن.

### توسعه

`install.sh` همان فایلی است که کاربران دانلود می‌کنند، پس **تک‌فایل** می‌ماند ولی **ساخته می‌شود**. فایل‌های اصلی را ویرایش کن و دوباره build بگیر:

| مسیر | چیست |
|------|------|
| `panel/app.py` | بک‌اند پنل (Python) |
| `panel/index.html` و `panel/ui.js` | رابط پنل: ساختار و CSS، و جاوااسکریپت |
| `scripts/` | اسکریپت‌های کمکی که در `/usr/local/bin` نصب می‌شوند |
| `systemd/` | فایل‌های سرویس |
| `installer/install.sh.in` | اسکلت نصب‌کننده (مراحل و تنظیمات)؛ هر بلوک بزرگ یک خط `@@INCLUDE path@@` است |
| `tests/` | تست‌های واحد (`python3 -m unittest discover -s tests -v`) |

```bash
./build.sh          # ساخت دوباره‌ی install.sh از منابع
./build.sh --check  # اگر install.sh به‌روز نباشد خطا می‌دهد (قبل از هر commit)
```

`install.sh` را دستی ویرایش نکن؛ build بعدی آن را بازنویسی می‌کند.

### سلب مسئولیت
این نرم‌افزار را فقط روی سرورهایی که مالک یا مدیر آن‌ها هستی و مطابق قوانین کشور خودت استفاده کن. نرم‌افزار «همان‌طور که هست» و بدون هیچ ضمانتی ارائه می‌شود.

</div>
