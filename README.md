SSH Plus Panel (web panel branded CK.VPN)

One-command installer for an SSH tunnel server on Ubuntu: OpenSSH + Dropbear (6 ports) + BadVPN UDPGW + BBR, with a lightweight web panel for managing users.

English | فارسی

<a name="english"></a>

English

Features

	•	OpenSSH direct access (ports 22 and 2222 by default; any extra SSH port you configured yourself, such as a custom main port, is never touched).
	•	Dropbear on up to 6 configurable ports.
	•	BadVPN UDPGW (default 127.0.0.1:7300) for UDP traffic such as online games, DNS and calls through the SSH tunnel.
	•	BBR congestion control, installed automatically and switchable from the panel.
	•	Web panel (port 2053):
	•	create, edit, delete users
	•	traffic quota (GB), expiry date, simultaneous-login limit
	•	live online-user count, CPU / RAM / network stats
	•	change SSH, Dropbear and BadVPN ports
	•	turn BBR on/off
	•	one-click copy of a user's connection info
	•	Login rate limit on the panel (5 failed attempts per 5 minutes).
	•	Tunnel (v1.1.0): one-click SSH tunnel to a second exit server; each account is either Direct or Tunnel.
	•	Safe to re-run: existing users, ports and settings are kept.

Requirements

	•	Ubuntu 22.04 or 24.04 (fresh server recommended)
	•	Root access
	•	Internet access (packages and BadVPN are downloaded and compiled during install)

Install

bash <(curl -Ls https://raw.githubusercontent.com/Sinakhani70/sshplus-panel/main/install.sh)

If curl is missing:

apt-get update && apt-get install -y curl

At the end of the install you should see something like:

Panel:     active
Dropbear:  active
BadVPN:    active
SSH:       active
BBR:       bbr / fq
Panel URL: http://YOUR_SERVER_IP:2053  (admin / admin)

After install

	1.	Open http://YOUR_SERVER_IP:2053.
	2.	Log in with admin / admin and change the password immediately (Settings tab).
	3.	Create a user.
	4.	In your SSH client, connect to the server IP using one of the Dropbear or SSH ports shown in the panel.
	5.	Set the UDPGW address in your client to 127.0.0.1:7300 (or the port you chose in the panel).

Useful commands

# change the panel admin login from the terminal
sshplus-pass NEWUSER NEWPASSWORD

# set up / replace the tunnel from the terminal
sshplus-tunnel-setup EXIT_IP [PORT] [USER]

# service status
systemctl status sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel badvpn

# logs
journalctl -u sshplus-dropbear -n 50 --no-pager
tail -50 /var/log/sshplus/install.log

# listening ports
ss -tlnp | grep -E 'dropbear|badvpn|sshd'

# check BBR
sysctl net.ipv4.tcp_congestion_control

Files

Path	Purpose
/opt/sshplus-panel/	panel (app.py, index.html)
/etc/SSHPlus/	settings (panel.json, ports.json, badvpn.conf, meta.json, tunnel.conf, tunnel_key)
/etc/ssh/sshd_config.d/00-sshplus.conf	OpenSSH settings managed by the panel
/var/log/sshplus/install.log	install log

Tunnel (new in v1.1.0)

Send selected accounts out through a second "exit" server. Users still connect to THIS server: "Tunnel" accounts reach the internet with the exit server's IP, "Direct" accounts with this server's IP.

	•	Panel → Tunnel tab → enter the exit server's IP, SSH port and root password → "Install & connect". One click does everything on both servers: installs a key-based SSH login, prepares the exit server (PermitTunnel, IP forwarding, NAT) and brings up an SSH layer-3 tunnel (ssh -w, device tun99, 10.99.0.0/30). The password is used once and never stored.
	•	Terminal alternative (the password never goes through the panel's plain HTTP): sshplus-tunnel-setup EXIT_IP [PORT] [USER]
	•	Create user → "Account type": Direct or Tunnel (can be changed later when editing the user).
	•	Tunnel accounts work on the OpenSSH ports and on dedicated "Tunnel Dropbear" ports (default 2087 and 2096, changeable in Settings). The normal Dropbear ports accept only Direct accounts; the tunnel Dropbear ports accept only Tunnel accounts.
	•	Fail-closed: if the tunnel is down, Tunnel accounts get no connectivity at all (they never leak out through this server's IP). The tunnel reconnects automatically.
	•	Bidirectional by default (v1.3.0): nothing to configure in the Tunnel tab. When you create or edit an account you pick "In" (which server the user connects to: server 1 = this server, server 2 = the exit server) and "Out" (whose IP the user leaves with). All four combinations work: 1→1 (Direct), 1→2 (Tunnel), 2→1, 2→2. For "In = server 2" the exit server forwards this server's ports through the tunnel; port 22 and every port the exit server already listens on are never taken over, so admin access to both servers and the panel stays open. Open the forwarded ports in the exit server's firewall; users' real IPs are not visible on this server when they enter through server 2.
	•	UDPGW (BadVPN, games/calls) works on all four In/Out combinations. For "Out = server 2" it goes through the tunnel: a second badvpn instance (UDP port+1) runs in the tunnel path and connections to 127.0.0.1:7300 are redirected to it transparently, so clients keep the same setting.
	•	Port coordination and firewalls (v1.4.0): the installer and the panel skip/replace Dropbear ports that another program already listens on; a port that is busy on the exit server is published there under another number (e.g. 442 → 10442) instead of being dropped, so this server's ports and existing client configs do not change. The ufw/firewalld rules of BOTH servers are updated for the ports. The Tunnel tab shows the port table and has a "check & fix conflicts" button; the check also runs automatically on panel start, tunnel install and every port change.
	•	Limits: the tunnel is IPv4-only (IPv6 is blocked for Tunnel accounts); the tunnel runs over TCP/SSH so keep BBR on for both servers; one exit server at a time; the exit server must be Linux with systemd and allow root SSH login with a password for the one-time setup; needs cgroup v2 (Ubuntu 22.04/24.04).

Security notes

	•	The panel runs over plain HTTP with default login admin/admin. Change the password right away. For better protection, restrict port 2053 with a firewall or access it through an SSH tunnel.
	•	User passwords are stored in plain text in /etc/SSHPlus/meta.json (root-only, mode 600) so the panel can display them.
	•	Traffic accounting is approximate (based on per-process I/O counters); do not rely on it for exact billing.
	•	Dropbear connections are briefly dropped when ports are changed from the panel.
	•	Tunnel: the panel is plain HTTP, so the exit server's password typed in the Tunnel tab travels unencrypted unless you reach the panel through an SSH tunnel; use sshplus-tunnel-setup in the terminal instead if in doubt. The tunnel's SSH key (/etc/SSHPlus/tunnel_key) gives this server root access to the exit server, so protect this server. The exit server's host key is trusted on first connection.
	•	PermitRootLogin yes is enabled for compatibility. Consider using SSH keys for root and disabling password login for it.

Uninstall

systemctl disable --now sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel sshplus-tunnel-net badvpn badvpn-t
/usr/local/bin/sshplus-tunnel-net clean
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/sshplus-dropbear-t.service /etc/systemd/system/sshplus-tunnel.service /etc/systemd/system/sshplus-tunnel-net.service /etc/systemd/system/badvpn.service /etc/systemd/system/badvpn-t.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-pass /usr/local/bin/sshplus-shell-t /usr/local/bin/sshplus-tunnel-net /usr/local/bin/start-tunnel.sh /usr/local/bin/sshplus-tunnel-setup /usr/local/bin/badvpn-udpgw

Tunnel users stay on the system; remove them with userdel USERNAME. Make sure you still have another way into the server (for example port 22) before deleting /etc/ssh/sshd_config.d/00-sshplus.conf.

Disclaimer

Use this software only on servers you own or administer, and in accordance with the laws that apply to you. It is provided as-is, without warranty.

<div dir="rtl">

<a name="فارسی"></a>

فارسی

امکانات

	•	OpenSSH مستقیم (پیش‌فرض پورت‌های ۲۲ و ۲۲۲۲). پورت SSH اختصاصی خودت (مثلاً یک پورت اصلی دلخواه) که بیرون از پنل تنظیم کرده‌ای هرگز دست نمی‌خورد.
	•	Dropbear با حداکثر ۶ پورت قابل تنظیم.
	•	BadVPN UDPGW (پیش‌فرض 127.0.0.1:7300) برای عبور ترافیک UDP مثل بازی آنلاین، DNS و تماس از داخل تونل SSH.
	•	BBR که خودکار نصب می‌شود و از پنل قابل روشن/خاموش شدن است.
	•	پنل وب (پورت 2053):
	•	ساخت، ویرایش و حذف کاربر
	•	سهمیه‌ی حجم (GB)، تاریخ انقضا، محدودیت اتصال همزمان
	•	نمایش زنده‌ی کاربران آنلاین و مصرف CPU / RAM / شبکه
	•	تغییر پورت‌های SSH، Dropbear و BadVPN
	•	روشن/خاموش کردن BBR
	•	کپی سریع مشخصات اتصال هر کاربر
	•	محدودیت تلاش ورود به پنل (۵ تلاش ناموفق در ۵ دقیقه).
	•	تانل (نسخه ۱.۱.۰): تانل SSH با یک کلیک به یک سرور خروجی؛ هر اکانت یا مستقیم است یا تانل.
	•	اجرای دوباره‌ی اسکریپت امن است: کاربران، پورت‌ها و تنظیمات موجود حفظ می‌شوند.

پیش‌نیازها

	•	اوبونتو ۲۲.۰۴ یا ۲۴.۰۴ (ترجیحاً سرور تازه)
	•	دسترسی root
	•	اینترنت (بسته‌ها و BadVPN هنگام نصب دانلود و کامپایل می‌شوند)

نصب

bash <(curl -Ls https://raw.githubusercontent.com/Sinakhani70/sshplus-panel/main/install.sh)

اگر curl نصب نبود:

apt-get update && apt-get install -y curl

در پایان نصب باید خروجی‌ای شبیه این ببینی:

Panel:     active
Dropbear:  active
BadVPN:    active
SSH:       active
BBR:       bbr / fq
Panel URL: http://YOUR_SERVER_IP:2053  (admin / admin)

بعد از نصب

۱. آدرس http://IP_SERVER:2053 را در مرورگر باز کن.
۲. با admin / admin وارد شو و همان لحظه رمز را عوض کن (تب تنظیمات).
۳. یک کاربر بساز.
۴. در کلاینت SSH با IP سرور و یکی از پورت‌های Dropbear یا SSH که در پنل نمایش داده می‌شود وصل شو.
۵. آدرس UDPGW را در کلاینت 127.0.0.1:7300 بگذار (یا پورتی که در پنل انتخاب کرده‌ای).

دستورات کاربردی

# تغییر نام کاربری و رمز ادمین پنل از ترمینال
sshplus-pass NEWUSER NEWPASSWORD

# نصب/تعویض تانل از ترمینال
sshplus-tunnel-setup EXIT_IP [PORT] [USER]

# وضعیت سرویس‌ها
systemctl status sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel badvpn

# لاگ‌ها
journalctl -u sshplus-dropbear -n 50 --no-pager
tail -50 /var/log/sshplus/install.log

# پورت‌های در حال گوش دادن
ss -tlnp | grep -E 'dropbear|badvpn|sshd'

# بررسی BBR
sysctl net.ipv4.tcp_congestion_control

مسیر فایل‌ها

مسیر	کاربرد
/opt/sshplus-panel/	پنل (app.py و index.html)
/etc/SSHPlus/	تنظیمات (panel.json، ports.json، badvpn.conf، meta.json، tunnel.conf، tunnel_key)
/etc/ssh/sshd_config.d/00-sshplus.conf	تنظیمات OpenSSH که پنل مدیریت می‌کند
/var/log/sshplus/install.log	لاگ نصب

تانل (جدید در نسخه ۱.۱.۰)

اکانت‌های انتخابی را از طریق یک سرور دوم («خروجی») به اینترنت وصل کن. کاربران همچنان به همین سرور وصل می‌شوند: اکانت «تانل» با IP سرور خروجی و اکانت «مستقیم» با IP همین سرور به اینترنت می‌رسد.

	•	پنل ← تب «تانل» ← IP، پورت SSH و رمز root سرور خروجی را بده ← «نصب و برقراری تانل». با یک کلیک روی هر دو سرور انجام می‌شود: نصب ورود با کلید SSH، آماده‌سازی سرور خروجی (PermitTunnel، فوروارد IP، NAT) و برقراری تانل لایه‌ی ۳ روی SSH (ssh -w، کارت tun99، شبکه‌ی 10.99.0.0/30). رمز فقط یک بار استفاده می‌شود و ذخیره نمی‌شود.
	•	روش ترمینالی (رمز از مسیر HTTP ساده‌ی پنل رد نمی‌شود): sshplus-tunnel-setup EXIT_IP [PORT] [USER]
	•	ساخت کاربر ← «نوع اکانت»: مستقیم (Direct) یا تانل (Tunnel). بعداً هم در ویرایش کاربر قابل تغییر است.
	•	اکانت تانل روی پورت‌های OpenSSH و پورت‌های اختصاصی «Dropbear تانل» (پیش‌فرض ۲۰۸۷ و ۲۰۹۶؛ از تب تنظیمات قابل تغییر) کار می‌کند. پورت‌های Dropbear معمولی فقط اکانت مستقیم می‌پذیرند و پورت‌های Dropbear تانل فقط اکانت تانل.
	•	Fail-closed: اگر تانل قطع شود، اکانت‌های تانل اصلاً اینترنت ندارند (هرگز با IP همین سرور نشت نمی‌کنند). تانل خودکار دوباره وصل می‌شود.
	•	دوطرفه از پایه (نسخه ۱.۳.۰): در تب تانل چیزی برای تنظیم نیست. موقع ساخت یا ویرایش اکانت، «In» (کاربر به کدام سرور وصل شود؛ سرور ۱ = همین سرور، سرور ۲ = سرور خروجی) و «Out» (با IP کدام سرور خارج شود) را انتخاب می‌کنی. هر چهار ترکیب کار می‌کند: ۱←۱ (مستقیم)، ۱←۲ (تانل)، ۲←۱ و ۲←۲. برای «In = سرور ۲»، سرور دوم پورت‌های همین سرور را از داخل تانل فوروارد می‌کند؛ پورت ۲۲ و هر پورتی که سرور دوم خودش رویش گوش می‌دهد هرگز دست نمی‌خورد، پس دسترسی ادمین به هر دو سرور و پنل باز می‌ماند. فایروال سرور دوم باید پورت‌های فوروارد‌شده را باز کند؛ وقتی کاربر از سرور ۲ وارد می‌شود IP واقعی‌اش روی این سرور دیده نمی‌شود.
	•	UDPGW (بازی/تماس) روی هر چهار ترکیب In/Out کار می‌کند. برای «Out = سرور ۲» از داخل تانل می‌گذرد: یک نمونه‌ی دوم badvpn روی پورت UDPGW به‌علاوه‌ی ۱ در مسیر تانل اجرا می‌شود و اتصال به 127.0.0.1:7300 شفاف به آن هدایت می‌شود؛ پس تنظیم کلاینت عوض نمی‌شود.
	•	هماهنگی پورت‌ها و فایروال (نسخه ۱.۴.۰): نصب‌کننده و پنل پورت‌های Dropbear را که برنامه‌ی دیگری رویشان گوش می‌دهد رد یا عوض می‌کنند؛ پورتی که روی سرور خروجی مشغول است با شماره‌ی دیگری منتشر می‌شود (مثلاً ۴۴۲ ← ۱۰۴۴۲) و حذف نمی‌شود، پس پورت‌های همین سرور و کانفیگ کلاینت‌های فعلی تغییر نمی‌کند. قوانین ufw/firewalld هر دو سرور برای پورت‌ها به‌روز می‌شود. تب تانل جدول پورت‌ها و دکمه‌ی «بررسی و رفع تداخل» دارد؛ این بررسی با هر راه‌اندازی پنل، نصب تانل و تغییر پورت هم خودکار انجام می‌شود.
	•	محدودیت‌ها: تانل فقط IPv4 است (IPv6 برای اکانت تانل بسته است)؛ تانل روی TCP/SSH است پس BBR را روی هر دو سرور روشن نگه دار؛ فعلاً یک سرور خروجی؛ سرور خروجی باید لینوکس با systemd باشد و برای نصب یک‌باره ورود root با رمز را بپذیرد؛ به cgroup v2 نیاز دارد (اوبونتو ۲۲.۰۴/۲۴.۰۴).
نکات امنیتی

	•	پنل روی HTTP ساده و با رمز پیش‌فرض admin/admin بالا می‌آید. رمز را فوراً عوض کن. برای امنیت بیشتر، پورت 2053 را با فایروال محدود کن یا از طریق تونل SSH واردش شو.
	•	رمز کاربران برای نمایش در پنل به‌صورت متن ساده در /etc/SSHPlus/meta.json ذخیره می‌شود (فقط root، دسترسی ۶۰۰).
	•	شمارش ترافیک تقریبی است (بر پایه‌ی شمارنده‌های I/O هر پروسه) و برای صورتحساب دقیق قابل اتکا نیست.
	•	با تغییر پورت از پنل، اتصال‌های فعال Dropbear لحظه‌ای قطع می‌شوند.
	•	تانل: پنل روی HTTP ساده است و رمز سرور خروجی که در تب تانل وارد می‌کنی بدون رمزنگاری می‌رود، مگر اینکه از طریق تونل SSH به پنل وصل شده باشی؛ اگر شک داری در ترمینال از sshplus-tunnel-setup استفاده کن. کلید SSH تانل (/etc/SSHPlus/tunnel_key) به این سرور دسترسی root روی سرور خروجی می‌دهد؛ پس از این سرور محافظت کن. کلید هاست سرور خروجی در اولین اتصال پذیرفته می‌شود.
	•	برای سازگاری، PermitRootLogin yes فعال است. بهتر است برای root از کلید SSH استفاده کنی و ورود با رمز را ببندی.

حذف

systemctl disable --now sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel sshplus-tunnel-net badvpn badvpn-t
/usr/local/bin/sshplus-tunnel-net clean
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/sshplus-dropbear-t.service /etc/systemd/system/sshplus-tunnel.service /etc/systemd/system/sshplus-tunnel-net.service /etc/systemd/system/badvpn.service /etc/systemd/system/badvpn-t.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-pass /usr/local/bin/sshplus-shell-t /usr/local/bin/sshplus-tunnel-net /usr/local/bin/start-tunnel.sh /usr/local/bin/sshplus-tunnel-setup /usr/local/bin/badvpn-udpgw

کاربران تونل روی سیستم می‌مانند؛ با userdel USERNAME پاکشان کن. قبل از حذف /etc/ssh/sshd_config.d/00-sshplus.conf مطمئن شو راه دیگری برای ورود به سرور داری (مثلاً پورت ۲۲).

سلب مسئولیت

این نرم‌افزار را فقط روی سرورهایی که مالک یا مدیر آن‌ها هستی و مطابق قوانین کشور خودت استفاده کن. نرم‌افزار «همان‌طور که هست» و بدون هیچ ضمانتی ارائه می‌شود.

</div>