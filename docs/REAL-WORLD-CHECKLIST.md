# Real-world checklist — what the lab could not test / چک‌لیست آزمون روی سرور واقعی

The lab (no internet to Let's Encrypt / DuckDNS, no real client apps) checked everything else. These five steps close the gap on a real server. Do them once after installing v1.7.0.

## English

1. **Staging first (no rate limit used).** Panel → *TLS & Domain* → tick *Let's Encrypt test mode (staging)*, choose your domain (or a free service) and press **Get domain and certificate**. Expected: all steps green, the certificate card shows the red *staging* badge. Untick staging afterwards.
   - If it fails at "Checking that ... points to this server": the DNS name does not point to this server yet (Cloudflare: set the record to *DNS only*).
   - If it fails at "Preparing port 80": something else listens on port 80.
2. **Real certificate.** Press **Get domain and certificate** again with staging off. Expected: green steps, badge *valid / trusted*, expiry about 90 days.
   - Free `sslip.io` / `nip.io` names share Let's Encrypt limits with everybody: if refused, try the other service, DuckDNS, or your own domain.
3. **Renewal.** Press **Renew certificate**. Expected: green steps, new expiry. Check the timer exists: `systemctl list-timers | grep certbot` and `ls /etc/letsencrypt/renewal-hooks/deploy/ckvpn.sh`.
4. **From a client.**
   - Computer: `openssl s_client -connect YOUR_DOMAIN:443 -servername YOUR_DOMAIN -verify_return_error </dev/null` must end with `Verify return code: 0 (ok)`.
   - SSH: `ssh -o ProxyCommand="openssl s_client -quiet -connect YOUR_DOMAIN:443 -servername YOUR_DOMAIN" USER@YOUR_DOMAIN` (the 🔗 dialog has a *TLS details* button that copies this).
   - Phone app: enter host, TLS port, SNI by hand (the `ssh://...?security=tls` link is a convention that apps may not import). Tell us which app and which fields it needs and the link format can be added.
5. **Shows who is connected.** Open an account over TLS from your phone: the *Online* column in the users table should show your phone's public IP (not 127.0.0.1).

If something fails: `journalctl -u sshplus-stunnel -n 50`, `journalctl -u sshplus-dropbear-s -n 50`, `journalctl -u sshplus-panel -n 50`, and the install log `/var/log/sshplus/install.log`.

## فارسی

۱. **اول staging (بدون مصرف سقف).** پنل ← تب «TLS و دامنه» ← تیک «حالت آزمایشی Let's Encrypt (staging)» را بزن، دامنه‌ات (یا سرویس رایگان) را انتخاب کن و «دریافت دامنه و گواهی» را بزن. انتظار: همه‌ی مراحل سبز و در کارت گواهی نشان قرمز *staging*. بعد تیک را بردار.
   - اگر در «Checking that ... points to this server» خطا داد: نام DNS هنوز به این سرور اشاره نمی‌کند (در Cloudflare رکورد را روی *DNS only* بگذار).
   - اگر در «Preparing port 80» خطا داد: برنامه‌ی دیگری روی پورت ۸۰ گوش می‌دهد.
۲. **گواهی واقعی.** همان دکمه را با staging خاموش بزن. انتظار: مراحل سبز، نشان *معتبر*، انقضا حدود ۹۰ روز. نام‌های رایگان `sslip.io` و `nip.io` سقف Let's Encrypt را با همه شریک‌اند؛ اگر رد شد سرویس دیگر، DuckDNS یا دامنه‌ی خودت.
۳. **تمدید.** «تمدید گواهی» را بزن؛ انتظار: مراحل سبز و تاریخ جدید. وجود تایمر را چک کن: `systemctl list-timers | grep certbot` و `ls /etc/letsencrypt/renewal-hooks/deploy/ckvpn.sh`.
۴. **از سمت کلاینت.** روی کامپیوتر: `openssl s_client -connect دامنه:443 -servername دامنه -verify_return_error </dev/null` باید به `Verify return code: 0 (ok)` برسد. در برنامه‌ی گوشی آدرس، پورت TLS و SNI را دستی وارد کن (دکمه‌ی «مشخصات TLS» در پنجره‌ی 🔗 همه را کپی می‌کند). اگر برنامه لینک `ssh://...?security=tls` را نپذیرفت، نام برنامه و فیلدهایش را بگو تا فرمت لینک اضافه شود.
۵. **نمایش IP.** یک اکانت را از گوشی با TLS وصل کن: ستون «آنلاین» در جدول کاربران باید IP عمومی گوشی را نشان بدهد (نه 127.0.0.1).

اگر چیزی خراب بود: `journalctl -u sshplus-stunnel -n 50` و `journalctl -u sshplus-dropbear-s -n 50` و `journalctl -u sshplus-panel -n 50`.

## Tunnel checks (after installing v1.7.1 and pressing "Update exit server")
1. On the exit server `iptables -t nat -S SSHPLUS_REV` — every line contains `! -i tun99` and `--dst-type LOCAL`.
2. On the panel server `curl -sS -m 8 --interface 10.99.0.1 https://api.ipify.org` prints the exit server's IP (HTTPS on :443 must pass through the tunnel).
3. Speed test with a tunnel account (SSH type, then WireGuard type if UDP is open between the servers).
4. Known limit: entering via the exit server, all users reach the panel's Dropbear from one source IP (10.99.0.2); Dropbear accepts only 5 *simultaneous unauthenticated* connections per IP, so a burst of more than 5 logins in the same instant (e.g. mass reconnect) is partly refused until clients retry. Logins spaced by >= 50 ms all pass.
