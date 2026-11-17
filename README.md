SSH Plus Panel

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

# service status
systemctl status sshplus-panel sshplus-dropbear badvpn

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
/etc/SSHPlus/	settings (panel.json, ports.json, badvpn.conf, meta.json)
/etc/ssh/sshd_config.d/00-sshplus.conf	OpenSSH settings managed by the panel
/var/log/sshplus/install.log	install log

Security notes

	•	The panel runs over plain HTTP with default login admin/admin. Change the password right away. For better protection, restrict port 2053 with a firewall or access it through an SSH tunnel.
	•	User passwords are stored in plain text in /etc/SSHPlus/meta.json (root-only, mode 600) so the panel can display them.
	•	Traffic accounting is approximate (based on per-process I/O counters); do not rely on it for exact billing.
	•	Dropbear connections are briefly dropped when ports are changed from the panel.
	•	PermitRootLogin yes is enabled for compatibility. Consider using SSH keys for root and disabling password login for it.

Uninstall

systemctl disable --now sshplus-panel sshplus-dropbear badvpn
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/badvpn.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-pass /usr/local/bin/badvpn-udpgw

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

# وضعیت سرویس‌ها
systemctl status sshplus-panel sshplus-dropbear badvpn

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
/etc/SSHPlus/	تنظیمات (panel.json، ports.json، badvpn.conf، meta.json)
/etc/ssh/sshd_config.d/00-sshplus.conf	تنظیمات OpenSSH که پنل مدیریت می‌کند
/var/log/sshplus/install.log	لاگ نصب

نکات امنیتی

	•	پنل روی HTTP ساده و با رمز پیش‌فرض admin/admin بالا می‌آید. رمز را فوراً عوض کن. برای امنیت بیشتر، پورت 2053 را با فایروال محدود کن یا از طریق تونل SSH واردش شو.
	•	رمز کاربران برای نمایش در پنل به‌صورت متن ساده در /etc/SSHPlus/meta.json ذخیره می‌شود (فقط root، دسترسی ۶۰۰).
	•	شمارش ترافیک تقریبی است (بر پایه‌ی شمارنده‌های I/O هر پروسه) و برای صورتحساب دقیق قابل اتکا نیست.
	•	با تغییر پورت از پنل، اتصال‌های فعال Dropbear لحظه‌ای قطع می‌شوند.
	•	برای سازگاری، PermitRootLogin yes فعال است. بهتر است برای root از کلید SSH استفاده کنی و ورود با رمز را ببندی.

حذف

systemctl disable --now sshplus-panel sshplus-dropbear badvpn
rm -f /etc/systemd/system/sshplus-panel.service /etc/systemd/system/sshplus-dropbear.service /etc/systemd/system/badvpn.service
systemctl daemon-reload
rm -rf /opt/sshplus-panel /etc/SSHPlus
rm -f /usr/local/bin/start-dropbear.sh /usr/local/bin/start-badvpn.sh /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-pass /usr/local/bin/badvpn-udpgw

کاربران تونل روی سیستم می‌مانند؛ با userdel USERNAME پاکشان کن. قبل از حذف /etc/ssh/sshd_config.d/00-sshplus.conf مطمئن شو راه دیگری برای ورود به سرور داری (مثلاً پورت ۲۲).

سلب مسئولیت

این نرم‌افزار را فقط روی سرورهایی که مالک یا مدیر آن‌ها هستی و مطابق قوانین کشور خودت استفاده کن. نرم‌افزار «همان‌طور که هست» و بدون هیچ ضمانتی ارائه می‌شود.

</div>