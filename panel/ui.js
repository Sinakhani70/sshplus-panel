const $=id=>document.getElementById(id);
// ---- language: fa (default) / en. Static labels: EN dictionary; paragraphs: data-th blocks; JS sentences: L(fa,en)
let LANG="fa"; try{LANG=localStorage.getItem("lang")==="en"?"en":"fa"}catch(e){}
const L=(fa,en)=>LANG==="en"?en:fa;
const EN={"👥 کاربران": "👥 Users", "🌐 تانل": "🌐 Tunnel", "📈 آمار": "📈 Statistics", "⚙️ تنظیمات سرور": "⚙️ Server settings", "ورود / Login": "Login", "بستن": "Close", "ذخیره": "Save", "💾 ذخیره": "💾 Save", "ذخیره و ادامه": "Save and continue", "(ذخیره شده)": "(saved)", "وضعیت": "Status", "نوع": "Type", "فعال": "Active", "غیرفعال": "Disabled", "آنلاین / کل کاربران": "Online / Total users", "تانل / Dropbear تانل": "Tunnel / Tunnel Dropbear", "BBR / منابع": "BBR / Resources", "🔌 پورت‌های فعال:": "🔌 Active ports:", "رمز عبور": "Password", "🔐 تغییر رمز پیش‌فرض": "🔐 Change the default password", "رمز پیش‌فرض (admin) امن نیست. برای ادامه یک رمز جدید انتخاب کن (حداقل ۸ کاراکتر).": "The default password (admin) is not secure. Choose a new one to continue (at least 8 characters).", "رمز جدید": "New password", "تکرار رمز": "Repeat password", "➕ ساخت کاربر جدید": "➕ Create new user", "قالب:": "Template:", "— بدون قالب —": "— No template —", "💾 ذخیره فرم به‌عنوان قالب": "💾 Save form as template", "نام کاربری (انگلیسی)": "Username (English letters)", "پورت پیشنهادی": "Suggested port", "پورت پیشنهادی (فقط برای نمایش/کپی)": "Suggested port (display/copy only)", "حجم (GB | 0=نامحدود)": "Quota (GB | 0 = unlimited)", "روز اعتبار": "Validity (days)", "کاربر همزمان": "Concurrent users", "— به کدام سرور وصل شود": "— which server the user connects to", "— با IP کدام سرور خارج شود": "— whose IP the user leaves with", "سرور ۱": "Server 1", "سرور ۲": "Server 2", "سرور ۱ (این سرور)": "Server 1 (this server)", "سرور ۲ (سرور تانل)": "Server 2 (tunnel server)", "سرور ۲ (تانل نصب نیست)": "Server 2 (tunnel not installed)", "ایجاد اکانت": "Create account", "همه پورت‌ها": "All ports", "📦 ساخت دسته‌ای اکانت": "📦 Bulk account creation", "پیشوند نام": "Name prefix", "تعداد (۱ تا ۲۰۰)": "Count (1 to 200)", "شروع شماره": "Start number", "رمز (خالی = تصادفی برای هر اکانت)": "Password (empty = random per account)", "ایجاد اکانت‌ها": "Create accounts", "📋 لیست کاربران": "📋 Users", "📋 کپی": "📋 Copy", "⬇️ دانلود CSV": "⬇️ Download CSV", "ویرایش کاربر": "Edit user", "رمز جدید (خالی = بدون تغییر)": "New password (empty = unchanged)", "تمدید: اعتبار از امروز (روز) — خالی/۰ = بدون تغییر": "Renew: validity from today (days) — empty/0 = unchanged", "صفر کردن ترافیک مصرفی": "Reset used traffic", "با تغییر In/Out اتصال‌های فعال این کاربر قطع می‌شوند.": "Changing In/Out cuts this user's active connections.", "لینک اشتراک و QR": "Subscription link & QR", "📋 کپی لینک اشتراک": "📋 Copy subscription link", "🔗 باز کردن": "🔗 Open", "🌐 وضعیت تانل": "🌐 Tunnel status", "🚀 نصب و اتصال تانل (یک کلیک)": "🚀 Install & connect the tunnel (one click)", "IP یا دامنه‌ی سرور جدید (خروجی)": "IP or domain of the new (exit) server", "پورت SSH": "SSH port", "کاربر (باید root باشد)": "User (must be root)", "رمز SSH سرور جدید": "SSH password of the new server", "⚡ نصب و برقراری تانل": "⚡ Install & connect the tunnel", "♻️ نصب مجدد / تغییر سرور": "♻️ Reinstall / change server", "⏳ در حال نصب...": "⏳ Installing...", "🔍 تست خروجی": "🔍 Test exit", "🔄 ری‌استارت تانل": "🔄 Restart tunnel", "🗑️ حذف تانل": "🗑️ Remove tunnel", "تانل نصب نشده": "Tunnel not installed", "🟢 متصل": "🟢 Connected", "🔴 قطع / در حال اتصال": "🔴 Down / connecting", "هنوز تانلی تنظیم نشده. فرم کناری را پر کن.": "No tunnel is configured yet. Fill in the form beside this.", "↔️ مسیر دوطرفه (همیشه فعال)": "↔️ Two-way routing (always on)", "🔌 هماهنگی پورت‌ها و فایروال دو سرور": "🔌 Port coordination & firewalls (both servers)", "پورت سرور ۱": "Port on server 1", "پورت روی سرور ۲": "Port on server 2", "Dropbear تانل": "Tunnel Dropbear", "SSH دوم": "2nd SSH", "هم‌شماره": "Same number", "جابه‌جا شد (مشغول بود)": "Moved (port was busy)", "منتشر نشد": "Not published", "هنوز پورتی منتشر نشده": "No port published yet", "اگر پورت Dropbear این سرور را برنامه‌ی دیگری گرفته باشد، خودکار با پورت آزاد عوض می‌شود. اگر پورتی روی سرور ۲ مشغول باشد، با شماره‌ی دیگری روی سرور ۲ منتشر می‌شود (پورت‌های این سرور و کانفیگ کلاینت‌های فعلی تغییر نمی‌کنند). فایروال (ufw یا firewalld) هر دو سرور برای پورت‌ها باز می‌شود. همین بررسی خودکار هم با هر راه‌اندازی پنل، نصب تانل و تغییر پورت انجام می‌شود.": "If another program has taken this server's Dropbear port, it is replaced by a free one automatically. If a port is busy on server 2, it is published there under another number (this server's ports and existing client configs do not change). The firewall (ufw or firewalld) of both servers is opened for the ports. The same check also runs automatically on every panel start, tunnel install and port change.", "🔍 بررسی و رفع تداخل + به‌روزرسانی فایروال هر دو سرور": "🔍 Check & fix conflicts + update the firewalls of both servers", "📜 مراحل نصب": "📜 Installation steps", "هنوز نصبی انجام نشده.": "No installation has been run yet.", "🌐 وضعیت تانل (۲۴ ساعت گذشته)": "🌐 Tunnel status (last 24 hours)", "خط آبی: تأخیر (ms) · نوار قرمز: تانل قطع بوده": "Blue line: latency (ms) · red bar: the tunnel was down", "🖥️ بار سرور (۲۴ ساعت)": "🖥️ Server load (24 h)", "آبی: CPU · نارنجی: RAM": "Blue: CPU · orange: RAM", "📊 مصرف روزانه‌ی کل (۱۴ روز)": "📊 Total daily traffic (14 days)", "🏆 پرمصرف‌ترین کاربران (۷ روز)": "🏆 Top users (7 days)", "تانلی تنظیم نشده یا هنوز نمونه‌ای ثبت نشده (هر دقیقه ثبت می‌شود).": "No tunnel configured or no sample recorded yet (one sample per minute).", "هنوز داده‌ای ثبت نشده": "No data recorded yet", "داده‌ای ثبت نشده": "No data recorded", "🚀 BBR (کنترل ازدحام TCP)": "🚀 BBR (TCP congestion control)", "الگوریتم فعلی": "Current algorithm", "کرنل پشتیبانی نمی‌کند": "Kernel does not support it", "⛔ خاموش کردن BBR": "⛔ Turn BBR off", "🚀 روشن کردن BBR": "🚀 Turn BBR on", "روی اتصال‌های جدید اثر می‌گذارد؛ اتصال‌های فعلی تا اتصال مجدد با الگوریتم قبلی می‌مانند.": "Applies to new connections; existing connections keep the previous algorithm until they reconnect.", "👤 نام کاربری و رمز ادمین پنل": "👤 Panel admin username & password", "نام کاربری ادمین": "Admin username", "رمز جدید ادمین": "New admin password", "🔌 پورت‌های OpenSSH و Dropbear (حداکثر ۶ پورت)": "🔌 OpenSSH & Dropbear ports (max 6)", "پورت SSH دوم": "Second SSH port", "پورت SSH اصلی (پنل)": "Main SSH port (panel)", "🌐 پورت‌های Dropbear مخصوص اکانت تانل (حداکثر ۴)": "🌐 Dropbear ports for tunnel accounts (max 4)", "ذخیره پورت‌ها (اتصال‌های Dropbear لحظه‌ای قطع می‌شوند)": "Save ports (Dropbear connections are briefly dropped)", "پورت (TCP داخل تونل)": "Port (TCP inside the tunnel)", "0.0.0.0 (عمومی)": "0.0.0.0 (public)", "127.0.0.1 (امن)": "127.0.0.1 (safe)", "ذخیره و ری‌استارت BadVPN": "Save and restart BadVPN", "🔒 HTTPS و گواهی": "🔒 HTTPS & certificate", "پنل روی همین پورت HTTPS است (آدرس http قدیمی خودکار به https می‌رود). گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد. اگر دامنه داری، گواهی معتبر (مثلاً از Let's Encrypt) را اینجا بگذار.": "The panel is served over HTTPS on this port (an old http address is redirected to https automatically). The default certificate is self-signed, so the browser warns. If you have a domain, put a valid certificate (for example from Let's Encrypt) here.", "گواهی (fullchain، فرمت PEM)": "Certificate (fullchain, PEM format)", "کلید خصوصی (PEM)": "Private key (PEM)", "آپلود گواهی": "Upload certificate", "💾 بکاپ و بازیابی": "💾 Backup & restore", "کاربران، حجم‌ها، تنظیمات، پورت‌ها، کلید تانل و تلگرام در یک فایل رمزنگاری‌شده. پسفریز را گم نکن؛ بدون آن فایل قابل بازیابی نیست.": "Users, quotas, settings, ports, the tunnel key and Telegram in one encrypted file. Do not lose the passphrase; without it the file cannot be restored.", "پسفریز (حداقل ۶ کاراکتر)": "Passphrase (at least 6 characters)", "⬇️ دانلود بکاپ": "⬇️ Download backup", "بازیابی از فایل بکاپ (.ckbk)": "Restore from backup file (.ckbk)", "⬆️ بازیابی (پنل ری‌استارت می‌شود)": "⬆️ Restore (the panel restarts)", "🤖 ربات و هشدار تلگرام": "🤖 Telegram bot & alerts", "توکن ربات": "Bot token", "پسفریز بکاپ خودکار": "Automatic backup passphrase", "ساعت بکاپ روزانه (۰ تا ۲۳)": "Daily backup hour (0 to 23)", "قطع/وصل تانل": "Tunnel down/up", "۹۰٪ و پر شدن حجم": "90% and quota full", "نزدیک/پایان انقضا": "Expiry near/reached", "فشار CPU/RAM": "High CPU/RAM load", "بکاپ روزانه به تلگرام": "Daily backup to Telegram", "📨 پیام آزمایشی": "📨 Test message", "🔎 پیدا کردن Chat ID": "🔎 Find Chat ID", "💾 ارسال بکاپ همین حالا": "💾 Send a backup now", "ℹ️ نحوه‌ی کار": "ℹ️ How it works", "رمز باید حداقل ۸ کاراکتر و غیر از admin باشد": "The password must be at least 8 characters and not 'admin'", "تکرار رمز یکسان نیست": "The passwords do not match", "تلاش‌های ناموفق زیاد؛ ۵ دقیقه صبر کنید": "Too many failed attempts; wait 5 minutes", "نام کاربری یا رمز عبور اشتباه است": "Wrong username or password", "پورت‌ها ذخیره شد": "Ports saved", "BadVPN به‌روز شد": "BadVPN updated", "نام کاربری یا رمز جدید را وارد کنید": "Enter a new username or password", "مشخصات ورود تغییر کرد": "Login details changed", "IP و رمز سرور جدید را وارد کن": "Enter the IP and password of the new server", "گواهی جدید فعال شد (اتصال‌های بعدی از آن استفاده می‌کنند)": "New certificate activated (new connections will use it)", "پسفریز حداقل ۶ کاراکتر": "The passphrase must be at least 6 characters", "فایل بکاپ را انتخاب کن": "Choose the backup file", "پسفریز را وارد کن": "Enter the passphrase", "بازیابی تنظیمات و کاربران فعلی را بازنویسی می‌کند. ادامه؟": "Restore will overwrite the current settings and users. Continue?", "ذخیره شد": "Saved", "پیام ارسال شد": "Message sent", "ارسال نشد: توکن/Chat ID یا دسترسی به تلگرام (مستقیم و از مسیر تانل) را بررسی کن": "Not sent: check the token/Chat ID or the connection to Telegram (direct and through the tunnel)", "پیامی پیدا نشد. اول به ربات پیام /start بده و دوباره امتحان کن": "No message found. First send /start to the bot, then try again", "بکاپ به تلگرام ارسال شد": "Backup sent to Telegram", "نام قالب:": "Template name:", "پیشوند نام را وارد کن": "Enter a name prefix", "⏳ در حال ساخت...": "⏳ Creating...", "لینک هنوز ساخته نشده؛ چند ثانیه بعد دوباره امتحان کن": "The link has not been created yet; try again in a few seconds", "QR در دسترس نیست": "QR unavailable", "ری‌استارت شد؛ چند ثانیه بعد وضعیت را ببین": "Restarted; check the status in a few seconds", "تانل حذف شود؟ اکانت‌های تانل به «مستقیم» تبدیل می‌شوند.": "Remove the tunnel? Tunnel accounts will become “Direct”.", "✔ تانل برقرار شد. در «ساخت کاربر» برای Out گزینه‌ی «سرور ۲» را انتخاب کن.": "✔ The tunnel is up. In “Create new user” choose “Server 2” for Out.", "✖ نصب ناموفق بود؛ تغییری روی کاربران فعلی اعمال نشد.": "✖ Installation failed; no change was made to existing users.", "تانل سالم است": "Tunnel is healthy", "بررسی ابزارهای لازم": "Checking the required tools", "ساخت کلید SSH مخصوص تانل": "Creating the tunnel's SSH key", "تست ورود با کلید": "Testing the key login", "آماده‌سازی سرور مقصد (PermitTunnel / فوروارد / NAT)": "Preparing the exit server (PermitTunnel / forwarding / NAT)", "راه‌اندازی تانل روی این سرور": "Starting the tunnel on this server", "انتظار برای برقراری تانل": "Waiting for the tunnel to come up", "تست خروجی اینترنت از مسیر تانل": "Testing internet access through the tunnel", "خطای داخلی": "Internal error", "رمز عبور یا نام کاربری اشتباه است (wrong password/user)": "Wrong password or username", "کاربر باید root باشد (برای ساخت کارت شبکه تانل)": "The user must be root (needed to create the tunnel network device)", "کلید SSH روی سرور مقصد نصب شد (رمز ذخیره نمی‌شود)": "SSH key installed on the exit server (the password is not stored)", "PermitTunnel + ip_forward + NAT روی سرور مقصد فعال شد": "PermitTunnel + ip_forward + NAT enabled on the exit server", "تانل برقرار است ولی تست اینترنت از مسیر تانل جواب نداد (سرور مقصد اینترنت دارد؟)": "The tunnel is up but the internet test through it got no answer (does the exit server have internet?)", "📋 لینک اشتراک (برای برنامه‌ها)": "📋 Subscription link (for apps)", "📋 متن ساده": "📋 Plain-text list", "📋 لینک SSH": "📋 SSH link", "📋 لینک SSH (base64)": "📋 SSH link (base64 login)", "🔗 باز کردن صفحه": "🔗 Open the page", "اگر برنامه‌ی تانل لینک را نپذیرفت، یکی از حالت‌های دیگر را امتحان کن. برنامه‌هایی که گواهی self-signed را رد می‌کنند به گواهی معتبر نیاز دارند، یا لینک اشتراک را روی HTTP ساده فعال کن (تنظیمات ← HTTPS).": "If a tunnel app does not accept the link, try one of the other formats. Apps that reject a self-signed certificate need a valid certificate, or enable the subscription link over plain HTTP (Settings → HTTPS).", "اجازه‌ی لینک اشتراک روی HTTP ساده (برای برنامه‌هایی که گواهی self-signed را نمی‌پذیرند)": "Allow the subscription link over plain HTTP (for apps that do not accept a self-signed certificate)", "⚠️ رمز اکانت داخل لینک است و روی HTTP ساده در مسیر قابل شنود است. فقط در صورت نیاز روشن کن؛ بقیه‌ی پنل همیشه HTTPS می‌ماند.": "⚠️ The account password is inside the link and can be sniffed on the way over plain HTTP. Turn it on only if you need it; the rest of the panel always stays HTTPS.", "🔒 TLS و دامنه": "🔒 TLS & Domain", "نوع اتصال": "Connection type", "فقط TLS": "TLS only", "🔒 SSH روی TLS": "🔒 SSH over TLS", "فعال‌سازی SSH روی TLS": "Enable SSH over TLS", "پورت(های) TLS اکانت‌های معمولی (با کاما جدا کن)": "TLS port(s) for normal accounts (comma-separated)", "پورت(های) TLS اکانت‌های تانل": "TLS port(s) for tunnel accounts", "💾 ذخیره‌ی پورت‌ها": "💾 Save ports", "📜 گواهی فعلی": "📜 Current certificate", "↩️ بازگشت به گواهی self-signed": "↩️ Back to a self-signed certificate", "🌍 دامنه و گواهی (یک‌کلیک)": "🌍 Domain and certificate (one click)", "منبع دامنه": "Domain source", "دامنه‌ی رایگان (خودکار)": "Free domain (automatic)", "دامنه‌ی خودم را دارم": "I have my own domain", "ایمیل (اختیاری؛ برای هشدار انقضا از Let's Encrypt)": "E-mail (optional; Let's Encrypt expiry warnings)", "سرویس دامنه‌ی رایگان": "Free-domain service", "sslip.io — بدون ثبت‌نام": "sslip.io — no sign-up", "nip.io — بدون ثبت‌نام": "nip.io — no sign-up", "DuckDNS — زیردامنه‌ی ثابت (حساب رایگان لازم است)": "DuckDNS — fixed sub-domain (free account needed)", "سرویس wildcard-DNS دیگر (خودت وارد کن)": "Another wildcard-DNS service (enter it yourself)", "نام زیردامنه در DuckDNS": "DuckDNS sub-domain name", "توکن DuckDNS": "DuckDNS token", "پسوند سرویس (مثلاً sslip.io)": "Service suffix (e.g. sslip.io)", "دامنه‌ی شما": "Your domain", "⚡ دریافت دامنه و گواهی": "⚡ Get domain and certificate", "⏳ در حال دریافت...": "⏳ Working...", "⬆️ آپلود گواهی دلخواه (PEM)": "⬆️ Upload your own certificate (PEM)", "دامنه‌ی این گواهی (برای لینک‌ها و SNI)": "Domain of this certificate (used in links and SNI)", "🔒 رفتن به تب TLS و دامنه": "🔒 Go to the TLS & Domain tab", "پنل روی همین پورت HTTPS است (آدرس http قدیمی خودکار به https می‌رود). گواهی و دامنه در تب «TLS و دامنه» مدیریت می‌شود (یک گواهی برای HTTPS پنل و SSH روی TLS)؛ گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد.": "The panel uses HTTPS on this same port (an old http address redirects to https automatically). The certificate and domain are managed in the “TLS & Domain” tab (one certificate for the panel's HTTPS and for SSH over TLS); the default certificate is self-signed and the browser shows a warning.", "خاموش": "Off", "🟢 فعال": "🟢 Active", "🔴 سرویس بالا نیست": "🔴 Service is not running", "دامنه را وارد کن": "Enter the domain", "به گواهی self-signed برگردیم؟ دامنه‌ی فعلی پاک می‌شود.": "Go back to a self-signed certificate? The current domain will be cleared.", "معمولی + TLS": "Normal + TLS", "فقط معمولی": "Normal only", "🔄 تمدید گواهی": "🔄 Renew certificate", "گواهی همین حالا از Let's Encrypt دوباره صادر شود؟ (تمدید خودکار هم هر روز بررسی می‌شود؛ این دکمه برای تمدید فوری است.)": "Re-issue the certificate from Let's Encrypt right now? (Automatic renewal is also checked every day; this button is for an immediate renewal.)", "حداکثر اتصال هم‌زمان از هر IP روی پورت‌های TLS (۰ = بدون محدودیت)": "Max simultaneous connections per IP on the TLS ports (0 = no limit)", "حالت آزمایشی Let's Encrypt (staging): برای امتحان کردن مراحل بدون مصرف سقف؛ گواهی آن معتبر نیست": "Let's Encrypt test mode (staging): to try the steps without using the rate limit; its certificate is not trusted", "📋 مشخصات TLS (ورود دستی)": "📋 TLS details (manual entry)"}, ENP=[["ویرایش: {0}", "Edit: {0}"], ["پورت‌های فعال sshd: {0} (پورت‌هایی که بیرون از پنل تعریف شده‌اند، مثل پورت اصلی شما، دست نمی‌خورند)", "Active sshd ports: {0} (ports defined outside the panel, such as your own main port, are never touched)"], ["دسترس‌پذیری ۲۴ ساعت: {0}٪ · میانگین تأخیر: {1} ms · {2} نمونه قطع", "24 h availability: {0}% · average latency: {1} ms · {2} samples down"], ["بازیابی انجام شد ({0} کاربر). پنل چند ثانیه دیگر ری‌استارت می‌شود؛ دوباره وارد شو.", "Restore finished ({0} users). The panel restarts in a few seconds; log in again."], ["ارسال نشد: {0}", "Not sent: {0}"], ["قالب «{0}» حذف شود؟", "Delete template “{0}”?"], ["{0} اکانت با پیشوند {1} ساخته شود؟", "Create {0} accounts with prefix {1}?"], ["تانل سالم است. IP خروجی: {0}", "The tunnel is healthy. Exit IP: {0}"], ["تانل حذف شد. اکانت‌های تبدیل‌شده به مستقیم: {0}", "Tunnel removed. Accounts converted to Direct: {0}"], ["اتصال به {0}:{1} با رمز و نصب کلید", "Connecting to {0}:{1} with the password and installing the key"], ["اتصال SSH برقرار نشد: {0}", "SSH connection failed: {0}"], ["ورود با کلید ناموفق: {0}", "Key login failed: {0}"], ["تداخل پورت روی این سرور رفع شد: {0}", "Port conflicts on this server were fixed: {0}"], ["تانل بالا نیامد: {0}", "The tunnel did not come up: {0}"], ["IP خروجی تانل: {0}", "Tunnel exit IP: {0}"]], HT={"tnNote": "The password is only used to install an SSH key and is not stored; after that the link uses the key.<br>⚠️ If you prefer not to type the server's password into the web page, run this in a terminal on this server:<br><code dir=\"ltr\">sshplus-tunnel-setup IP_SERVER [PORT] [USER]</code>", "biNote": "When creating an account the admin has two choices, <bdi dir=\"ltr\"><b>In</b></bdi> and <bdi dir=\"ltr\"><b>Out</b></bdi>: <bdi dir=\"ltr\"><b>In</b></bdi> is which server's IP the user connects to and <bdi dir=\"ltr\"><b>Out</b></bdi> is which server's IP the user reaches the internet with. All four combinations (<span dir=\"ltr\">1→1</span>, <span dir=\"ltr\">1→2</span>, <span dir=\"ltr\">2→1</span>, <span dir=\"ltr\">2→2</span>) are active and UDPGW (games/calls) works on all of them. No separate mode needs to be configured.", "how": "<bdi dir=\"ltr\"><b>In</b></bdi> is the server whose IP the user connects to and <bdi dir=\"ltr\"><b>Out</b></bdi> is the server whose IP is seen on the internet. “Server 1” is this server and “Server 2” is the tunnel server.<br>\n    1) When <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 2”, the traffic goes through the tunnel. This account works on the <b>SSH (OpenSSH)</b> ports and the <b>tunnel Dropbear</b> ports; the normal Dropbear ports are only for accounts whose <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 1”. Ports can be changed in the Settings tab.<br>\n    2) When <bdi dir=\"ltr\"><b>In</b></bdi> is “Server 2”, this server's ports are opened on server 2 and forwarded through the tunnel to this server. Port 22 and any port server 2 itself listens on are never touched, so admin access to both servers and to the panel always stays open. The firewall of server 2 must allow these ports and the real IP of the user is not visible on this server.<br>\n    3) If the tunnel goes down, every path that goes through it is <b>blocked</b> (instead of leaking out through the direct IP). It reconnects automatically.<br>\n    4) UDPGW (games/calls) works on all four combinations. When <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 2” it goes through the tunnel. The client keeps using <span dir=\"ltr\">127.0.0.1:7300</span>.<br>\n    5) The tunnel runs over SSH (TCP); for better speed keep BBR on for both servers.", "tgNote": "First create a bot in Telegram with @BotFather and paste the token here; then send <span dir=\"ltr\">/start</span> to the bot and press “Find Chat ID”. If Telegram cannot be reached from this server, the panel automatically sends through the tunnel.", "tgCmd": "Bot commands (only from the configured Chat ID): <span dir=\"ltr\">/status /users /online /backup</span>", "tlsNote": "SSH is wrapped inside a TLS connection, for apps or networks that want TLS/SNI.<br>• A “Normal only” account cannot log in on a TLS port, and a “TLS only” account cannot log in on the plain Dropbear ports.<br>• A “TLS only” account is also refused on the OpenSSH ports (such as 22); “Normal only” and “Both” accounts can log in there.<br>• Tunnel accounts have their own TLS port (they exit through the tunnel).<br>• The <span dir=\"ltr\">ssh://</span> link format for TLS is not standardised; if your app does not accept it, enter the address, port and SNI by hand.", "tlsShared": "This same certificate and domain are also used for the panel's own HTTPS; nothing else needs to be set up elsewhere."};
const FAre=/[؀-ۿ]/, nrm=s=>String(s).replace(/\s+/g," ").trim(), ATTRS=["placeholder","title","aria-label"];
const PATRE=ENP.map(p=>new RegExp("^"+nrm(p[0]).split(/(\{\d+\})/).map(x=>/^\{\d+\}$/.test(x)?"(.+?)":x.replace(/[.*+?^$()|[\]\\]/g,"\\$&")).join("")+"$","s"));
function tr(s){
  const k=nrm(s); if(!FAre.test(k)) return null;
  const r=EN[k]; if(r!==undefined) return r;
  for(let i=0;i<PATRE.length;i++){const m=k.match(PATRE[i]); if(m) return ENP[i][1].replace(/\{(\d+)\}/g,(_,j)=>m[+j+1])}
  return null;
}
const inTH=n=>{for(let e=n.parentElement;e;e=e.parentElement){if(e.dataset&&e.dataset.th)return true}return false};
function trText(n){
  const v=n.nodeValue; if(!FAre.test(v)) return; const e=tr(v); if(e===null) return;
  n.__fa=v; n.__en=v.match(/^\s*/)[0]+e+v.match(/\s*$/)[0]; n.nodeValue=n.__en;
}
function trEl(el){ATTRS.forEach(a=>{const v=el.getAttribute(a); if(v&&FAre.test(v)){const e=tr(v); if(e!==null){el["__fa_"+a]=v; el.setAttribute(a,e)}}})}
function trTree(root){
  if(root.nodeType===3){ if(!inTH(root)) trText(root); return }
  if(root.nodeType!==1||/^(SCRIPT|STYLE)$/.test(root.tagName)) return;
  if(root.dataset&&root.dataset.th&&HT[root.dataset.th]!==undefined){ if(root.__fa===undefined) root.__fa=root.innerHTML; root.innerHTML=HT[root.dataset.th]; return }
  trEl(root); Array.from(root.childNodes).forEach(trTree);
}
function revert(){
  document.querySelectorAll("[data-th]").forEach(el=>{if(el.__fa!==undefined){el.innerHTML=el.__fa; el.__fa=undefined}});
  const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT); let n;
  while((n=w.nextNode())){if(n.__fa!==undefined&&n.nodeValue===n.__en) n.nodeValue=n.__fa; n.__fa=undefined}
  document.querySelectorAll("*").forEach(el=>ATTRS.forEach(a=>{if(el["__fa_"+a]!==undefined){el.setAttribute(a,el["__fa_"+a]); el["__fa_"+a]=undefined}}));
}
const MOopt={childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:ATTRS};
const MO=new MutationObserver(ms=>{
  if(LANG!=="en") return; MO.disconnect();
  try{ms.forEach(m=>{
    if(m.type==="childList") m.addedNodes.forEach(trTree);
    else if(m.type==="characterData"){const n=m.target; if(n.nodeValue!==n.__en&&!inTH(n)){n.__fa=undefined; trText(n)}}
    else if(m.type==="attributes") trEl(m.target);
  })}finally{MO.observe(document.body,MOopt)}
});
const _al=window.alert.bind(window), _cf=window.confirm.bind(window), _pr=window.prompt.bind(window);
const trMsg=m=>{if(LANG!=="en") return m; const e=tr(String(m)); return e===null?m:e};
window.alert=m=>_al(trMsg(m)); window.confirm=m=>_cf(trMsg(m)); window.prompt=(m,d)=>_pr(trMsg(m),d);
function setLang(l,init){
  LANG=l; try{localStorage.setItem("lang",l)}catch(e){}
  const h=document.documentElement; h.lang=l; h.dir=l==="en"?"ltr":"rtl";
  MO.disconnect();
  if(l==="en"){trTree(document.body); MO.observe(document.body,MOopt)} else revert();
  document.querySelectorAll(".langBtn").forEach(b=>b.textContent=l==="en"?"FA":"EN");
  if(!init&&tok&&$("lBox").classList.contains("hid")){
    load(1); if(!$("secT").classList.contains("hid")) loadTun(); if(!$("secL").classList.contains("hid")) loadTls(true); if(!$("secH").classList.contains("hid")) loadHist(); if(!$("secS").classList.contains("hid")){loadCert();loadTg()}
  }
}
function toggleLang(){setLang(LANG==="en"?"fa":"en")}
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let tnCfg={};
let tok=localStorage.getItem("tok")||"", ul=[], pCfg={ssh:22,ssh2:0,db:[]}, bv={}, bbrOn=false, lastSig="", tlsB={}, tlsS={};
function swTab(t){
  const T={u:"secU",t:"secT",l:"secL",h:"secH",s:"secS"}, B={u:"bTabU",t:"bTabT",l:"bTabL",h:"bTabH",s:"bTabS"};
  Object.keys(T).forEach(k=>{$(T[k]).classList.toggle("hid",k!==t); $(B[k]).classList.toggle("act",k===t)});
  if(t==="t") loadTun();
  if(t==="l") loadTls(true);
  if(t==="h") loadHist();
  if(t==="s"){loadCert();loadTg()}
}
function srvName(v){return v==="B"?"S2":"S1"}
function revMap(){const m={};(tnCfg.rev_map||[]).forEach(r=>{m[r.a]=r.b});return m}
function routeBadge(x){
  const inH=x.en==="B"?(tnCfg.host||"S2"):location.hostname, outH=x.tm==="tunnel"?(tnCfg.exit||tnCfg.host||"S2"):location.hostname;
  return `<span class="bdg ${(x.en==="B"||x.tm==="tunnel")?"wn":"ok"}" title="In: ${esc(inH)} | Out: ${esc(outH)}">${srvName(x.en)} → ${srvName(x.tm==="tunnel"?"B":"A")}</span>`+cxBadge(x);
}
function cxBadge(x){
  const c=x.cx||"both", t=c==="tls"?L("فقط TLS","TLS only"):(c==="normal"?L("فقط معمولی","Normal only"):L("معمولی + TLS","Normal + TLS"));
  return ` <span class="bdg ${c==="both"?"ok":"wn"}" title="${esc(t)}">${c==="tls"?"TLS":(c==="normal"?"Normal":"N+TLS")}</span>`;
}
function cxHint(en,cx){
  const w=[]; if(cx!=="normal"&&!tlsB.on) w.push(L("⚠️ SSH روی TLS هنوز روشن نیست (تب «TLS و دامنه»)؛ تا آن موقع اکانت «فقط TLS» جایی وارد نمی‌شود.","⚠️ SSH over TLS is not switched on yet (TLS & Domain tab); until then a TLS-only account cannot log in on a Dropbear port."));
  return w.join("<br>");
}
function fillSrv(){
  ["nen","nex","een","eex","bu_en","bu_ex"].forEach(id=>{
    const o=$(id).options; o[0].text="سرور ۱"; o[0].title=location.hostname;
    o[1].text=tnCfg.conf?"سرور ۲":"سرور ۲ (تانل نصب نیست)"; o[1].title=tnCfg.host||""; o[1].disabled=!tnCfg.conf;
    if(!tnCfg.conf&&$(id).value==="B") $(id).value="A";
  });
}
function fillPorts(cn,ce){
  const sk=tnCfg.rev_skipped||[];
  const mk=(en,ex,cx)=>{
    const db=(ex==="B"?(pCfg.tdb||[]):(pCfg.db||[]));
    const tl0=(cx!=="normal"&&tlsB.on)?(ex==="B"?(tlsB.tports||[]):(tlsB.ports||[])):[];
    if(en==="B"){const mp=revMap(), s2=(pCfg.ssh2&&pCfg.ssh2!=22)?[pCfg.ssh2]:[], tl2=tl0.map(p=>mp[p]).filter(Boolean), only2=cx==="tls"&&tl2.length>0; return portOpts(only2?[]:s2.map(p=>mp[p]).filter(Boolean),only2?[]:db.map(p=>mp[p]).filter(Boolean),tl2)}
    const tl=tl0, only=cx==="tls"&&tl.length>0;
    return portOpts(only?[]:((pCfg.ssh_all&&pCfg.ssh_all.length)?pCfg.ssh_all:[22]),only?[]:db,tl);
  };
  const n=cn!==undefined?cn:$("npt").value, e=ce!==undefined?ce:$("ept").value;
  $("npt").innerHTML=mk($("nen").value,$("nex").value,$("ncx").value); $("ept").innerHTML=mk($("een").value,$("eex").value,$("ecx").value);
  $("nCx").innerHTML=cxHint($("nen").value,$("ncx").value); $("eCx").innerHTML=cxHint($("een").value,$("ecx").value);
  if([...$("npt").options].some(o=>o.value===n)) $("npt").value=n;
  if([...$("ept").options].some(o=>o.value===e)) $("ept").value=e;
  const ip=v=>v==="B"?(tnCfg.host||"سرور ۲"):location.hostname, xp=v=>v==="B"?(tnCfg.exit||tnCfg.host||"سرور ۲"):location.hostname;
  const hint=(en,ex)=>L(`کاربر به <b dir="ltr">${esc(ip(en))}</b> وصل می‌شود و با IP <b dir="ltr">${esc(xp(ex))}</b> به اینترنت می‌رسد.`,`The user connects to <b dir="ltr">${esc(ip(en))}</b> and reaches the internet with the IP <b dir="ltr">${esc(xp(ex))}</b>.`);
  $("nHint").innerHTML=hint($("nen").value,$("nex").value); $("eHint").innerHTML=hint($("een").value,$("eex").value);
}
async function api(u,m="GET",b=null){
  const o={method:m,headers:{"Authorization":"Bearer "+tok}};
  if(b){o.headers["Content-Type"]="application/json";o.body=JSON.stringify(b)}
  const r=await fetch(u,o);
  if(r.status===401){localStorage.removeItem("tok");$("lBox").classList.remove("hid");throw new Error("401")}
  const j=await r.json().catch(()=>({}));
  if(r.status===403&&j.err==="must_change"){showFp();throw new Error("must_change")}
  return j;
}
function showFp(){$("fpBox").classList.remove("hid")}
async function saveFp(){
  const a=$("fp1").value, b=$("fp2").value;
  if(a.length<8||a==="admin"){alert("رمز باید حداقل ۸ کاراکتر و غیر از admin باشد");return}
  if(a!==b){alert("تکرار رمز یکسان نیست");return}
  const r=await fetch("/api/admin",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+tok},body:JSON.stringify({p:a})});
  const j=await r.json();
  if(j.ok){tok=j.tok;localStorage.setItem("tok",tok);$("fpBox").classList.add("hid");$("fp1").value="";$("fp2").value="";$("lp").value="";load(1);loadTpl().catch(()=>{})}else alert(j.msg||"Error");
}
async function login(){
  const r=await fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({u:$("lu").value.trim(),p:$("lp").value.trim()})});
  if(r.status===429){alert("تلاش‌های ناموفق زیاد؛ ۵ دقیقه صبر کنید");return}
  const j=await r.json();
  if(j.tok){tok=j.tok;localStorage.setItem("tok",tok);$("lBox").classList.add("hid");if(j.chg)showFp();else{load(1);loadTpl().catch(()=>{})}}else alert("نام کاربری یا رمز عبور اشتباه است");
}
function portOpts(sp,db,tl){
  let o='<option value="All">همه پورت‌ها</option>';
  sp.forEach(p=>o+=`<option value="SSH:${p}">SSH: ${p}</option>`);
  db.forEach(p=>o+=`<option value="Dropbear:${p}">Dropbear: ${p}</option>`);
  (tl||[]).forEach(p=>o+=`<option value="TLS:${p}">TLS: ${p}</option>`);
  return o;
}
async function load(force){
  let d; try{d=await api("/api/overview")}catch(e){return}
  ul=d.users||[]; pCfg=d.ports||pCfg; bv=d.bv||{}; const bb=d.bbr||{};
  bbrOn=!!bb.on;
  const sp=(pCfg.ssh_all&&pCfg.ssh_all.length)?pCfg.ssh_all:[22];
  const db=pCfg.db||[];
  $("stU").innerText=d.st.on_tot+" / "+ul.length;
  const tn=d.tun||{}; tnCfg=tn; tlsB=d.tls||{}; fillSrv(); ovExtra(d);
  $("stTn").innerHTML=(tn.conf?(tn.up?`<span class="bdg ok">TUNNEL UP</span> <span style="font-size:.75rem;color:var(--mu)">${esc(tn.exit||"")}</span>`:`<span class="bdg er">TUNNEL DOWN</span>`):`<span class="bdg wn">OFF</span>`)
    +" "+(d.st.dbt?`<span class="bdg ok">DB-T (${(pCfg.tdb||[]).join(",")})</span>`:`<span class="bdg er">DB-T STOPPED</span>`);
  $("stDb").innerHTML=(d.st.db?`<span class="bdg ok">ACTIVE (${db.join(",")})</span>`:`<span class="bdg er">STOPPED</span>`)+(tlsB.on?" "+(tlsB.up?`<span class="bdg ok">TLS (${(tlsB.ports||[]).concat(tlsB.tports||[]).join(",")})</span>`:`<span class="bdg er">TLS ✖</span>`):"");
  $("stBv").innerHTML=(d.st.bvt?"":'<span class="bdg er">UDPGW-T ✖</span> ')+(d.st.bv?`<span class="bdg ok">UDPGW ${esc(bv.BIND_ADDR||"")}:${esc(bv.UDP_PORT||7300)}</span>`:`<span class="bdg er">STOPPED</span>`);
  $("stBbr").innerHTML=bbrOn?`<span class="bdg ok">BBR ON</span>`:`<span class="bdg wn">${esc(bb.cc||"?")}</span>`;
  $("stRes").innerText=`CPU:${d.st.cpu}% | RAM:${d.st.mem}% | ↓${d.st.rx}M ↑${d.st.tx}M`;
  $("pBan").innerText=`OpenSSH: ${sp.join(", ")} | Dropbear: ${db.join(", ")} | Tunnel-Dropbear: ${(pCfg.tdb||[]).join(", ")} | UDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`+(tlsB.on?` | TLS: ${(tlsB.ports||[]).join(", ")} / ${(tlsB.tports||[]).join(", ")}`:"");
  $("bbrCc").value=bb.cc||""; $("bbrQd").value=bb.qdisc||"";
  $("bbrSt").innerHTML=bbrOn?`<span class="bdg ok">فعال</span>`:(bb.avail?`<span class="bdg wn">غیرفعال</span>`:`<span class="bdg er">کرنل پشتیبانی نمی‌کند</span>`);
  $("bbrBtn").innerText=bbrOn?"⛔ خاموش کردن BBR":"🚀 روشن کردن BBR";
  $("bbrBtn").className="btn "+(bbrOn?"btn-e":"btn-o");
  const sig=sp.join(",")+"|"+db.join(",")+"|"+JSON.stringify(bv)+"|"+pCfg.ssh+"|"+pCfg.ssh2+"|"+(pCfg.tdb||[]).join(",");
  if(force||sig!==lastSig){
    lastSig=sig;
    const cn=$("npt").value, ce=$("ept").value;
    $("s1").value=pCfg.ssh||22; $("s2").value=pCfg.ssh2||0;
    for(let i=1;i<=6;i++) $("d"+i).value=db[i-1]||"";
    for(let i=1;i<=4;i++) $("td"+i).value=(pCfg.tdb||[])[i-1]||"";
    $("bp").value=bv.UDP_PORT||7300; $("bm").value=bv.UDP_MTU||1200; $("bc").value=bv.MAX_CLIENTS||1000;
    $("bn").value=bv.MAX_CONN||64; $("bb").value=bv.BIND_ADDR||"127.0.0.1";
    $("sshAll").innerText="پورت‌های فعال sshd: "+sp.join(", ")+" (پورت‌هایی که بیرون از پنل تعریف شده‌اند، مثل پورت اصلی شما، دست نمی‌خورند)";
    if(!$("au").value && document.activeElement!==$("au")) $("au").value=d.adm||"admin";
    fillPorts(cn,ce);
  }
  $("tb").innerHTML=ul.map(x=>`<tr>
    <td><b>${esc(x.u)}</b><div style="font-size:.75rem;color:var(--mu)">🔑 ${esc(x.pw||"***")}</div></td>
    <td>${routeBadge(x)}</td>
    <td><span class="bdg ok">${esc(x.pt)}</span></td>
    <td><b>${x.on}</b> / ${x.lim}${(x.ips||[]).length?`<div dir="ltr" style="font-size:.7rem;color:var(--mu);max-width:150px;overflow-wrap:anywhere">${esc(x.ips.join(", "))}</div>`:""}</td>
    <td><b>${esc(x.ugb)}</b> / ${x.q>0?x.q+" GB":"∞"}</td>
    <td>${esc(x.exp)}</td>
    <td><span class="bdg ${x.qfull||x.expd?'er':'ok'}">${x.qfull?'Quota Full':x.expd?'Expired':'Active'}</span></td>
    <td style="display:flex;gap:.3rem;flex-wrap:wrap">
      <button class="btn btn-s" onclick="editU('${esc(x.u)}')">✏️</button>
      <button class="btn btn-s btn-w" onclick="copyU('${esc(x.u)}')">📋</button>
      <button class="btn btn-s" onclick="subU('${esc(x.u)}')" title="لینک اشتراک و QR">🔗</button>
      <button class="btn btn-s btn-e" onclick="delU('${esc(x.u)}')">🗑️</button>
    </td></tr>`).join("");
}
function editU(u){
  const x=ul.find(i=>i.u===u); if(!x) return;
  $("eTit").innerText="ویرایش: "+x.u; $("eu").value=x.u; $("epw").value=x.pw||"";
  fillSrv(); $("een").value=x.en==="B"?"B":"A"; $("eex").value=x.tm==="tunnel"?"B":"A"; $("ecx").value=x.cx||"both"; fillPorts(undefined,x.pt);
  $("eq").value=x.q||0; $("el").value=x.lim||1; $("ed").value=""; $("erst").checked=false; $("eBox").classList.remove("hid");
}
async function saveUser(edit){
  const b=edit?{edit:1,u:$("eu").value,pw:$("epw").value,pt:$("ept").value,en:$("een").value,tm:$("eex").value==="B"?"tunnel":"direct",cx:$("ecx").value,q:$("eq").value,l:$("el").value,d:$("ed").value,rst:$("erst").checked}
              :{edit:0,u:$("nu").value,pw:$("npw").value,pt:$("npt").value,en:$("nen").value,tm:$("nex").value==="B"?"tunnel":"direct",cx:$("ncx").value,q:$("nq").value,l:$("nl").value,d:$("nd").value};
  const r=await api("/api/user/save","POST",b);
  if(r.ok){$("eBox").classList.add("hid");$("nu").value="";$("npw").value="";load(0); if(r.warn==="tls_off") alert(L("حساب ذخیره شد، ولی SSH روی TLS هنوز روشن نیست (تب «TLS و دامنه»).","Account saved, but SSH over TLS is not switched on yet (TLS & Domain tab)."))}else alert(r.msg||"Error");
}
async function delU(u){if(confirm("Delete "+u+"?")){await api("/api/user/del","POST",{u});load(0)}}
async function savePorts(){
  const r=await api("/api/ports","POST",{ssh:$("s1").value,ssh2:$("s2").value,db:[1,2,3,4,5,6].map(i=>$("d"+i).value),tdb:[1,2,3,4].map(i=>$("td"+i).value)});
  if(!r.ok){alert(r.msg||"Error");return}
  alert(L("پورت‌ها ذخیره شد","Ports saved")+(r.dropped&&r.dropped.length?L("\nنادیده گرفته شد (تکراری/رزرو): ","\nIgnored (duplicate/reserved): ")+r.dropped.join(", "):""));
  load(1);
}
async function saveBv(){
  const r=await api("/api/badvpn","POST",{p:$("bp").value,m:$("bm").value,c:$("bc").value,n:$("bn").value,b:$("bb").value});
  alert(r.ok?"BadVPN به‌روز شد":(r.msg||"Error")); load(1);
}
async function toggleBbr(){
  const r=await api("/api/bbr","POST",{on:!bbrOn});
  if(!r.ok) alert(r.msg||"Error"); load(1);
}
async function saveAdm(){
  const u=$("au").value.trim(), p=$("ap").value.trim();
  if(!u&&!p){alert("نام کاربری یا رمز جدید را وارد کنید");return}
  const r=await api("/api/admin","POST",{u,p});
  if(r.ok){tok=r.tok;localStorage.setItem("tok",tok);$("au").value=r.u;$("ap").value="";$("lu").value=r.u;$("lp").value=r.p;alert("مشخصات ورود تغییر کرد")}
  else alert(r.msg||"Error");
}
function copyU(u){
  const x=ul.find(i=>i.u===u); if(!x) return;
  const out=x.tm==="tunnel", inB=x.en==="B", sk=tnCfg.rev_skipped||[];
  const host=inB?(tnCfg.host||"?"):location.hostname;
  const exitIp=out?(tnCfg.exit||tnCfg.host||"server 2"):location.hostname;
  let ssh=pCfg.ssh_all||[22], dbl=out?(pCfg.tdb||[]):(pCfg.db||[]);
  if(inB){const mp=revMap(); ssh=((pCfg.ssh2&&pCfg.ssh2!=22)?[pCfg.ssh2]:[]).map(p=>mp[p]).filter(Boolean); dbl=dbl.map(p=>mp[p]).filter(Boolean)}
  const cx=x.cx||"both"; let tp=(cx!=="normal"&&tlsB.on)?(out?tlsB.tports:tlsB.ports)||[]:[];
  if(inB){const mp=revMap(); tp=tp.map(p=>mp[p]).filter(Boolean)}
  const useTls=tp.length>0;
  if(useTls&&cx==="tls"){ssh=[]; dbl=[]}
  const tlsTxt=useTls?`\nTLS Ports: ${tp.join(", ")}${tlsB.dom?"\nSNI / TLS Host: "+tlsB.dom:""}`:"";
  const t=`Host/IP: ${host}\nIn: ${inB?"Server 2":"Server 1"} | Out: ${out?"Server 2":"Server 1"} (exit IP: ${exitIp})\nSSH Ports: ${ssh.join(", ")||"-"}\nDropbear Ports: ${dbl.join(", ")||"-"}${tlsTxt}\nUser: ${x.u}\nPass: ${x.pw}\nLimit: ${x.lim}\nQuota: ${x.q>0?x.q+" GB":"Unlimited"}\nUDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`;
  copyText(t);
}
async function loadTun(){
  let d; try{d=await api("/api/tunnel")}catch(e){return}
  const sp=d.setup||{steps:[]}; const run=!!sp.run;
  $("tnStat").innerHTML=!d.conf?'<span class="bdg wn">تانل نصب نشده</span>':(d.up?'<span class="bdg ok">🟢 متصل</span>':'<span class="bdg er">🔴 قطع / در حال اتصال</span>');
  $("tnInfo").innerHTML=d.conf?L(`سرور خروجی: <b dir="ltr">${esc(d.user)}@${esc(d.host)}:${esc(d.port)}</b><br>IP خروجی: <b dir="ltr">${esc(d.exit||"—")}</b><br>پورت‌های Dropbear تانل: <b dir="ltr">${esc((d.tdb||[]).join(", ")||"—")}</b><br>اکانت‌های تانل: <b>${(d.users||[]).length}</b>`,`Exit server: <b dir="ltr">${esc(d.user)}@${esc(d.host)}:${esc(d.port)}</b><br>Exit IP: <b dir="ltr">${esc(d.exit||"—")}</b><br>Tunnel Dropbear ports: <b dir="ltr">${esc((d.tdb||[]).join(", ")||"—")}</b><br>Tunnel accounts: <b>${(d.users||[]).length}</b>`):"هنوز تانلی تنظیم نشده. فرم کناری را پر کن.";
  $("tnBtns").classList.toggle("hid",!d.conf);
  $("tnBiBox").classList.toggle("hid",!d.conf);
  $("tnPortBox").classList.toggle("hid",!d.conf);
  if(d.conf){
    const kind=p=>(pCfg.tdb||[]).includes(p)?"Dropbear تانل":((pCfg.db||[]).includes(p)?"Dropbear":(((tlsB.ports||[]).concat(tlsB.tports||[])).includes(p)?"TLS":"SSH دوم"));
    const rows=(d.rev_map||[]).map(r=>`<tr><td dir="ltr">${r.a}</td><td>${kind(r.a)}</td><td dir="ltr">${r.b}</td><td>${r.a===r.b?'<span class="bdg ok">هم‌شماره</span>':'<span class="bdg wn">جابه‌جا شد (مشغول بود)</span>'}</td></tr>`)
      .concat((d.rev_skipped||[]).map(p=>`<tr><td dir="ltr">${p}</td><td>${kind(p)}</td><td>—</td><td><span class="bdg er">منتشر نشد</span></td></tr>`)).join("");
    $("tnPorts").innerHTML=`<table><thead><tr><th>پورت سرور ۱</th><th>نوع</th><th>پورت روی سرور ۲</th><th>وضعیت</th></tr></thead><tbody>${rows||'<tr><td colspan="4" style="color:var(--mu)">هنوز پورتی منتشر نشده</td></tr>'}</tbody></table>`;
  }
  if(d.conf){
    const me=location.hostname;
    $("tnBi").innerHTML=L(`<div>سرور ۱ (این سرور): <b dir="ltr">${esc(me)}</b> &nbsp;|&nbsp; سرور ۲: <b dir="ltr">${esc(d.host)}</b> <span style="color:var(--mu)">(IP خروجی: <span dir="ltr">${esc(d.exit||d.host)}</span>)</span></div>`,`<div>Server 1 (this server): <b dir="ltr">${esc(me)}</b> &nbsp;|&nbsp; Server 2: <b dir="ltr">${esc(d.host)}</b> <span style="color:var(--mu)">(exit IP: <span dir="ltr">${esc(d.exit||d.host)}</span>)</span></div>`)
      +L(`<div>پورت‌هایی که روی سرور ۲ به این سرور فوروارد شده‌اند: <b dir="ltr">${esc((d.rev_map||[]).map(r=>r.b).join(", ")||"—")}</b></div>`,`<div>Ports forwarded from server 2 to this server: <b dir="ltr">${esc((d.rev_map||[]).map(r=>r.b).join(", ")||"—")}</b></div>`)
      +((d.rev_skipped||[]).length?L(`<div style="color:var(--wn)">⚠️ این پورت‌ها روی سرور ۲ از قبل مشغول‌اند و فوروارد نشدند: <b dir="ltr">${esc(d.rev_skipped.join(", "))}</b></div>`,`<div style="color:var(--wn)">⚠️ These ports are already in use on server 2 and were not forwarded: <b dir="ltr">${esc(d.rev_skipped.join(", "))}</b></div>`):"");
  }
  $("tnGo").disabled=run; $("tnGo").innerText=run?"⏳ در حال نصب...":(d.conf?"♻️ نصب مجدد / تغییر سرور":"⚡ نصب و برقراری تانل");
  if(sp.steps.length){
    const ic={run:"⏳",ok:"✅",err:"❌",warn:"⚠️"}, cl={err:"var(--er)",warn:"var(--wn)"};
    $("tnLog").innerHTML=sp.steps.map(x=>`<div><span>${ic[x.s]||""}</span> <span>${esc(x.m)}</span>${x.d?`<div style="font-size:.78rem;padding-inline-start:1.5rem;color:${cl[x.s]||"var(--mu)"}">${esc(x.d)}</div>`:""}</div>`).join("")
      +(!run&&sp.ok===true?'<div style="color:var(--ok);margin-top:.5rem"><b>✔ تانل برقرار شد. در «ساخت کاربر» برای Out گزینه‌ی «سرور ۲» را انتخاب کن.</b></div>':"")
      +(!run&&sp.ok===false?'<div style="color:var(--er);margin-top:.5rem"><b>✖ نصب ناموفق بود؛ تغییری روی کاربران فعلی اعمال نشد.</b></div>':"");
  }
}
async function tunSetup(){
  if(!$("tnH").value.trim()||!$("tnW").value){alert("IP و رمز سرور جدید را وارد کن");return}
  const r=await api("/api/tunnel/setup","POST",{host:$("tnH").value.trim(),port:$("tnP").value,user:$("tnU").value.trim(),pw:$("tnW").value});
  if(!r.ok){alert(r.msg||"Error");return}
  $("tnW").value=""; loadTun();
}
async function tunPorts(){
  const r=await api("/api/tunnel/ports","POST",{}); const m=[];
  (r.a_changes||[]).forEach(c=>m.push(L(`سرور ۱: پورت ${c.from} (مشغول توسط ${c.by||"برنامه‌ی دیگر"}) ← ${c.to}`,`Server 1: port ${c.from} (in use by ${c.by||"another program"}) → ${c.to}`)));
  (r.map||[]).filter(x=>x.a!==x.b).forEach(x=>m.push(L(`سرور ۲: پورت ${x.a} مشغول بود ← منتشر شد روی ${x.b}`,`Server 2: port ${x.a} was busy → published on ${x.b}`)));
  if(!m.length) m.push(L("تداخلی پیدا نشد.","No conflicts found."));
  m.push(L(`فایروال سرور ۱: ${r.fw_a||"-"} | سرور ۲: ${r.fw_b||"-"}`,`Firewall server 1: ${r.fw_a||"-"} | server 2: ${r.fw_b||"-"}`));
  if(r.err) m.push(L("خطا: ","Error: ")+r.err);
  alert(m.join("\n")); load(1); loadTun();
}
// ---- version / feature warnings
function ovExtra(d){
  if($("ver")&&d.ver) $("ver").innerText="v"+d.ver;
  const w=[]; if(!d.fer) w.push(L("python3-cryptography نصب نیست: رمزها رمزنگاری نمی‌شوند و بکاپ کار نمی‌کند.","python3-cryptography is not installed: passwords are not encrypted and backups do not work.")); if(!d.qr) w.push(L("python3-qrcode نصب نیست: QR نمایش داده نمی‌شود.","python3-qrcode is not installed: QR codes are not shown."));
  $("bkWarn").innerText=w.join(" ");
}
// ---- HTTPS
async function savePlainSub(){const r=await api("/api/plainsub","POST",{on:$("plainSub").checked}); if(!r.ok) alert("Error")}
async function loadCert(){const d=await api("/api/cert"); $("plainSub").checked=!!d.plain_sub; $("certInfo").innerText=(d.https?"HTTPS: ON":L("HTTPS: OFF (HTTP ساده)","HTTPS: OFF (plain HTTP)"))+"\n"+(d.info||"")}
async function saveCert(){
  const dom=$("tlsUpDom").value.trim();
  const r=await api("/api/cert","POST",{cert:$("certPem").value,key:$("certKey").value});
  if(!r.ok){alert(r.msg||"Error");return}
  if(dom){const r2=await api("/api/tls/save","POST",{domain:dom}); if(!r2.ok) alert(r2.msg||"Error")}
  alert("گواهی جدید فعال شد (اتصال‌های بعدی از آن استفاده می‌کنند)"); $("certPem").value="";$("certKey").value="";$("tlsUpDom").value=""; loadCert(); loadTls(true);
}
// ---- SSH over TLS tab
const lst=s=>String(s||"").split(/[\s,;]+/).filter(Boolean);
function tlsSrcUi(){
  const own=$("tlsSrc").value==="own", pv=$("tlsProv").value;
  $("tlsFree").classList.toggle("hid",own); $("tlsOwnB").classList.toggle("hid",!own);
  $("tlsDuckN").classList.toggle("hid",pv!=="duckdns"); $("tlsDuckT").classList.toggle("hid",pv!=="duckdns"); $("tlsSufB").classList.toggle("hid",pv!=="custom");
  const N={sslip:L("نام دامنه از IP سرور ساخته می‌شود (مثل <bdi dir='ltr'>1-2-3-4.sslip.io</bdi>). بدون ثبت‌نام؛ ولی سقف گواهی Let's Encrypt بین همه‌ی کاربران این سرویس مشترک است و گاهی ممکن است رد شود. اگر رد شد سرویس دیگری را امتحان کن.","The name is built from the server IP (e.g. <bdi dir='ltr'>1-2-3-4.sslip.io</bdi>). No sign-up, but the Let's Encrypt certificate limit is shared by everyone using this service and it can occasionally refuse. If it does, try another service."),
    nip:L("نام دامنه از IP سرور ساخته می‌شود (مثل <bdi dir='ltr'>1-2-3-4.nip.io</bdi>). بدون ثبت‌نام؛ سقف گواهی Let's Encrypt بین همه‌ی کاربران این سرویس مشترک است. اگر رد شد sslip.io یا سرویس دیگری را امتحان کن.","The name is built from the server IP (e.g. <bdi dir='ltr'>1-2-3-4.nip.io</bdi>). No sign-up; the Let's Encrypt certificate limit is shared by everyone using this service. If it refuses, try sslip.io or another service."),
    duckdns:L("یک زیردامنه‌ی ثابت مثل <bdi dir='ltr'>name.duckdns.org</bdi>. در <bdi dir='ltr'>duckdns.org</bdi> حساب رایگان بساز، یک زیردامنه اضافه کن و توکن را از صفحه‌ی حساب اینجا بگذار؛ پنل خودش آن را به IP این سرور وصل می‌کند.","A fixed sub-domain such as <bdi dir='ltr'>name.duckdns.org</bdi>. Create a free account on <bdi dir='ltr'>duckdns.org</bdi>, add a sub-domain and paste the token from the account page; the panel points it to this server itself."),
    custom:L("هر سرویس wildcard-DNS که نام «IP-با-خط‌تیره.پسوند» را به همان IP حل کند. پنل قبل از درخواست گواهی بررسی می‌کند که نام واقعاً به این سرور اشاره کند.","Any wildcard-DNS service that resolves “IP-with-dashes.suffix” to that IP. Before asking for a certificate the panel checks that the name really points to this server."),
    own:L("یک رکورد A از دامنه‌ات به IP این سرور بزن (اگر Cloudflare داری روی «DNS only» بگذار). پنل قبل از درخواست گواهی همین را بررسی می‌کند.","Point an A record of your domain to this server's IP (with Cloudflare, set it to “DNS only”). The panel checks this before asking for the certificate.")};
  $("tlsProvNote").innerHTML=N[own?"own":pv]+"<br>"+(L("پورت 80 این سرور باید آزاد و از بیرون باز باشد (Let's Encrypt از آن تأیید می‌کند).","Port 80 of this server must be free and reachable from the internet (Let's Encrypt validates through it)."));
}
async function loadTls(init){
  let d; try{d=await api("/api/tls")}catch(e){return}
  tlsS=d; const c=d.cfg, m=d.cert||{}, j=d.job||{steps:[]};
  if(init){
    $("tlsOn").checked=!!c.on; $("tlsP1").value=(c.ports||[]).join(","); $("tlsP2").value=(c.tports||[]).join(","); $("tlsPerIp").value=c.perip; $("tlsStaging").checked=!!c.staging;
    $("tlsSrc").value=c.mode==="own"?"own":"free"; if(["sslip","nip","duckdns","custom"].includes(c.prov)) $("tlsProv").value=c.prov;
    $("tlsDom").value=c.mode==="own"?c.domain:""; $("tlsMail").value=c.email||""; $("tlsDuckName").value=c.duckname||""; $("tlsSuf").value=c.suffix||"";
    $("tlsDuckSet").innerText=c.duck?"(ذخیره شده)":""; tlsSrcUi();
  } else $("tlsOn").checked=!!c.on;
  const sv=Object.keys(d.svc||{}).filter(k=>!d.svc[k]).map(k=>k.replace("sshplus-",""));
  $("tlsStat").innerHTML=!c.on?'<span class="bdg wn">خاموش</span>':(d.up?'<span class="bdg ok">🟢 فعال</span>':'<span class="bdg er">🔴 سرویس بالا نیست</span> <span style="font-size:.75rem;color:var(--mu)" dir="ltr">'+esc(sv.join(", "))+'</span>')
    +(c.on?` <span class="bdg ok" dir="ltr">${esc((c.ports||[]).join(","))}</span> <span class="bdg wn" dir="ltr">${esc((c.tports||[]).join(","))}</span>`:"")
    +(!d.installed.stunnel?` <span class="bdg wn">${L("stunnel نصب نیست؛ با روشن‌کردن خودکار نصب می‌شود","stunnel is not installed; it is installed when you switch TLS on")}</span>`:"");
  const left=m.days, canRenew=!m.self&&(c.mode==="own"||c.mode==="free")&&!!c.domain;
  $("tlsRenewBtn").classList.toggle("hid",!canRenew);
  $("tlsCert").innerHTML=L(`دامنه: <b dir="ltr">${esc(c.domain||"—")}</b><br>گواهی برای: <b dir="ltr">${esc(m.cn||"—")}</b><br>صادرکننده: <span dir="ltr">${esc((m.issuer||"").replace(/^.*CN\s*=\s*/,"")||"—")}</span><br>انقضا: <span dir="ltr">${esc(m.end||"—")}</span>${left!=null?` <span style="color:${left<15?"var(--wn)":"var(--ok)"}">(${left} روز مانده)</span>`:""}<br>${m.self?'<span class="bdg wn">self-signed</span> برنامه‌ها باید «اجازه به گواهی نامعتبر» داشته باشند':(/staging|fake/i.test(m.issuer||"")?'<span class="bdg er">staging</span> گواهی آزمایشی است و برنامه‌ها نمی‌پذیرند':'<span class="bdg ok">معتبر / مورد اعتماد</span>')}`,
    `Domain: <b dir="ltr">${esc(c.domain||"—")}</b><br>Certificate for: <b dir="ltr">${esc(m.cn||"—")}</b><br>Issuer: <span dir="ltr">${esc((m.issuer||"").replace(/^.*CN\s*=\s*/,"")||"—")}</span><br>Expires: <span dir="ltr">${esc(m.end||"—")}</span>${left!=null?` <span style="color:${left<15?"var(--wn)":"var(--ok)"}">(${left} days left)</span>`:""}<br>${m.self?'<span class="bdg wn">self-signed</span> apps must allow an untrusted certificate':(/staging|fake/i.test(m.issuer||"")?'<span class="bdg er">staging</span> a test certificate: apps will not accept it':'<span class="bdg ok">valid / trusted</span>')}`);
  const run=!!j.run; $("tlsGo").disabled=run; $("tlsGo").innerText=run?"⏳ در حال دریافت...":"⚡ دریافت دامنه و گواهی";
  if(j.steps.length){
    const ic={run:"⏳",ok:"✅",err:"❌",warn:"⚠️"}, cl={err:"var(--er)",warn:"var(--wn)"};
    $("tlsLog").innerHTML=j.steps.map(x=>`<div><span>${ic[x.s]||""}</span> <span>${esc(x.m)}</span>${x.d?`<div style="font-size:.78rem;padding-inline-start:1.5rem;color:${cl[x.s]||"var(--mu)"};overflow-wrap:anywhere" dir="ltr">${esc(x.d)}</div>`:""}</div>`).join("")
      +(!run&&j.ok===true?`<div style="color:var(--ok);margin-top:.5rem"><b>${L("✔ دامنه و گواهی آماده شد: ","✔ Domain and certificate are ready: ")}<span dir="ltr">${esc(j.domain)}</span></b></div>`:"")
      +(!run&&j.ok===false?`<div style="color:var(--er);margin-top:.5rem"><b>${L("✖ ناموفق بود؛ چیزی تغییر نکرد.","✖ Failed; nothing was changed.")}</b></div>`:"");
  }
  if(run) setTimeout(()=>{if(!$("secL").classList.contains("hid")) loadTls(false)},2000); else if(tlsS._wasRun){tlsS._wasRun=false; load(1)}
  if(run) tlsS._wasRun=true;
}
async function tlsToggle(){
  const on=$("tlsOn").checked; $("tlsStat").innerHTML="⏳";
  const r=await api("/api/tls/save","POST",{on});
  if(!r.ok){alert(r.msg||"Error"); $("tlsOn").checked=!on}
  loadTls(true); load(1);
}
async function tlsPorts(){
  const r=await api("/api/tls/save","POST",{ports:lst($("tlsP1").value),tports:lst($("tlsP2").value),perip:$("tlsPerIp").value||0});
  if(!r.ok){alert(r.msg||"Error");return}
  alert(L("پورت‌ها ذخیره شد","Ports saved")+(r.dropped&&r.dropped.length?L("\nنادیده گرفته شد (تکراری/رزرو/مشغول): ","\nIgnored (duplicate/reserved/busy): ")+r.dropped.join(", "):""));
  loadTls(true); load(1);
}
async function tlsGo(){
  const own=$("tlsSrc").value==="own", b={mode:own?"own":"free",email:$("tlsMail").value.trim()};
  if(own){b.domain=$("tlsDom").value.trim(); if(!b.domain){alert("دامنه را وارد کن");return}}
  else{b.prov=$("tlsProv").value; b.duckname=$("tlsDuckName").value.trim(); b.duck=$("tlsDuckTok").value.trim(); b.suffix=$("tlsSuf").value.trim()}
  const r=await api("/api/tls/issue","POST",b);
  if(!r.ok){alert(r.msg||"Error");return}
  $("tlsDuckTok").value=""; tlsS._wasRun=true; loadTls(false);
}
async function tlsRenew(){
  if(!confirm("گواهی همین حالا از Let's Encrypt دوباره صادر شود؟ (تمدید خودکار هم هر روز بررسی می‌شود؛ این دکمه برای تمدید فوری است.)")) return;
  const r=await api("/api/tls/renew","POST",{});
  if(!r.ok){alert(r.msg||"Error");return}
  tlsS._wasRun=true; loadTls(false);
}
async function tlsStagingSave(){
  const r=await api("/api/tls/save","POST",{staging:$("tlsStaging").checked}); if(!r.ok) alert(r.msg||"Error"); loadTls(false);
}
async function tlsSelf(){
  if(!confirm("به گواهی self-signed برگردیم؟ دامنه‌ی فعلی پاک می‌شود.")) return;
  const r=await api("/api/tls/self","POST",{}); if(!r.ok) alert(r.msg||"Error"); loadTls(true); load(1);
}
// ---- backup / restore
async function doBackup(){
  const pw=$("bkPass").value; if(pw.length<6){alert("پسفریز حداقل ۶ کاراکتر");return}
  const r=await fetch("/api/backup",{method:"POST",headers:{"Content-Type":"application/json","Authorization":"Bearer "+tok},body:JSON.stringify({pass:pw})});
  if(!r.ok){const j=await r.json().catch(()=>({})); alert(j.msg||"Error"); return}
  const b=await r.blob(), a=document.createElement("a"), cd=r.headers.get("Content-Disposition")||"";
  a.href=URL.createObjectURL(b); a.download=(cd.match(/filename="([^"]+)"/)||[])[1]||"ckvpn.ckbk"; document.body.appendChild(a); a.click(); a.remove();
}
function doRestore(){
  const f=$("bkFile").files[0], pw=$("bkPass").value; if(!f){alert("فایل بکاپ را انتخاب کن");return} if(!pw){alert("پسفریز را وارد کن");return}
  if(!confirm("بازیابی تنظیمات و کاربران فعلی را بازنویسی می‌کند. ادامه؟")) return;
  const rd=new FileReader();
  rd.onload=async()=>{
    const b64=String(rd.result).split(",")[1]||"";
    const r=await api("/api/restore","POST",{data:b64,pass:pw});
    if(r.ok){alert("بازیابی انجام شد ("+r.users+" کاربر). پنل چند ثانیه دیگر ری‌استارت می‌شود؛ دوباره وارد شو.");setTimeout(()=>{localStorage.removeItem("tok");location.reload()},5000)}else alert(r.msg||"Error");
  };
  rd.readAsDataURL(f);
}
// ---- Telegram
async function loadTg(){
  const d=await api("/api/telegram"); $("tgChat").value=d.chat||""; $("tgHour").value=d.hour??3;
  $("tgSet").innerText=d.set?"(ذخیره شده)":""; $("tgBp").innerText=d.bpass?"(ذخیره شده)":"";
  ["tunnel","quota","expiry","res","daily"].forEach(k=>$("tgA_"+k).checked=!!(d.alerts||{})[k]);
}
function tgBody(){const a={};["tunnel","quota","expiry","res","daily"].forEach(k=>a[k]=$("tgA_"+k).checked);return {token:$("tgToken").value,chat:$("tgChat").value,bpass:$("tgBpass").value,hour:$("tgHour").value,alerts:a}}
async function saveTg(){const r=await api("/api/telegram","POST",tgBody()); if(r.ok){$("tgToken").value="";$("tgBpass").value="";alert("ذخیره شد");loadTg()}else alert(r.msg||"Error")}
async function tgTest(){await saveTg(); const r=await api("/api/telegram/test","POST",{}); alert(r.ok?"پیام ارسال شد":"ارسال نشد: توکن/Chat ID یا دسترسی به تلگرام (مستقیم و از مسیر تانل) را بررسی کن")}
async function tgDetect(){
  await saveTg(); const r=await api("/api/telegram/detect","POST",{});
  if(!r.ok){alert(r.msg||"Error");return}
  if(!(r.chats||[]).length){alert("پیامی پیدا نشد. اول به ربات پیام /start بده و دوباره امتحان کن");return}
  $("tgChat").value=r.chats[r.chats.length-1].id; alert(L("Chat ID پیدا شد: ","Chat ID found: ")+r.chats.map(c=>c.id+" ("+c.name+")").join(", ")+L("\nذخیره را بزن.","\nPress Save."));
}
async function tgBackup(){const r=await api("/api/telegram/backup","POST",{}); alert(r.ok?"بکاپ به تلگرام ارسال شد":("ارسال نشد: "+(r.msg||"")))}
// ---- templates
let tpls=[];
async function loadTpl(){tpls=await api("/api/templates"); $("tplSel").innerHTML='<option value="">— بدون قالب —</option>'+tpls.map(t=>`<option value="${esc(t.name)}">${esc(t.name)}</option>`).join("")}
function applyTpl(){
  const t=tpls.find(x=>x.name===$("tplSel").value); if(!t) return;
  $("nd").value=t.d; $("nq").value=t.q; $("nl").value=t.l; $("nen").value=(t.en==="B"&&tnCfg.conf)?"B":"A"; $("nex").value=(t.tm==="tunnel"&&tnCfg.conf)?"B":"A"; $("ncx").value=t.cx||"both"; fillPorts();
}
async function saveTpl(){
  const name=prompt("نام قالب:"); if(!name) return;
  const r=await api("/api/template/save","POST",{name,d:$("nd").value,q:$("nq").value,l:$("nl").value,en:$("nen").value,tm:$("nex").value==="B"?"tunnel":"direct",cx:$("ncx").value});
  if(r.ok){await loadTpl();$("tplSel").value=name}else alert(r.msg||"Error");
}
async function delTpl(){const n=$("tplSel").value; if(!n||!confirm("قالب «"+n+"» حذف شود؟")) return; await api("/api/template/del","POST",{name:n}); loadTpl()}
// ---- bulk creation
async function doBulk(){
  const b={prefix:$("bu_pf").value.trim(),count:$("bu_n").value,start:$("bu_s").value,d:$("bu_d").value,q:$("bu_q").value,l:$("bu_l").value,en:$("bu_en").value,tm:$("bu_ex").value==="B"?"tunnel":"direct",cx:$("bu_cx").value,pw:$("bu_pw").value};
  if(!b.prefix){alert("پیشوند نام را وارد کن");return}
  if(!confirm(b.count+" اکانت با پیشوند "+b.prefix+" ساخته شود؟")) return;
  $("bkRes").innerHTML="⏳ در حال ساخت...";
  const r=await api("/api/user/bulk","POST",b);
  if(!r.ok){$("bkRes").innerHTML="";alert(r.msg||"Error");return}
  const host=location.hostname, lines=r.created.map(x=>x.u+"\t"+x.pw), txt="user\tpassword\n"+lines.join("\n");
  $("bkRes").innerHTML=`<div style="color:var(--ok);margin-bottom:.4rem">${L(`✅ ${r.created.length} اکانت ساخته شد`,`✅ ${r.created.length} accounts created`)}${r.errors.length?` · <span style="color:var(--er)">${r.errors.length} ${L("خطا","errors")}</span>`:""}</div>
    <textarea id="bkOut" rows="6" dir="ltr" readonly>${esc(txt)}</textarea>
    <div style="display:flex;gap:.4rem;flex-wrap:wrap"><button class="btn btn-s" onclick="bulkCopy()">📋 کپی</button><button class="btn btn-s btn-o" onclick="bulkDl()">⬇️ دانلود CSV</button></div>
    ${r.errors.length?`<div style="font-size:.78rem;color:var(--er);margin-top:.4rem">${r.errors.map(e=>esc(e.u+": "+e.msg)).join("<br>")}</div>`:""}`;
  window._bulk=r.created; load(1);
}
function copyText(t){
  const ok=()=>alert("Copied!");
  const fb=()=>{try{const a=document.createElement("textarea"); a.value=t; a.style.cssText="position:fixed;opacity:0"; document.body.appendChild(a); a.focus(); a.select(); a.setSelectionRange(0,t.length); const r=document.execCommand("copy"); a.remove(); if(r){ok();return}}catch(e){} prompt("Copy:",t)};
  if(window.isSecureContext&&navigator.clipboard&&navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(ok,fb); else fb();
}
function bulkCopy(){copyText($("bkOut").value)}
function bulkDl(){
  const rows=["user,password,host"].concat((window._bulk||[]).map(x=>x.u+","+x.pw+","+location.hostname));
  const a=document.createElement("a"); a.href=URL.createObjectURL(new Blob([rows.join("\n")],{type:"text/csv"})); a.download="ckvpn-accounts.csv"; document.body.appendChild(a); a.click(); a.remove();
}
// ---- subscription link + QR
let subUrl="", subSsh=[], subSshB=[], subTls="";
async function subU(u){
  const x=ul.find(i=>i.u===u); if(!x||!x.st){alert("لینک هنوز ساخته نشده؛ چند ثانیه بعد دوباره امتحان کن");return}
  subUrl=location.origin+"/s/"+x.st; subSsh=[]; subSshB=[]; subTls=""; $("subTlsBtn").classList.add("hid"); $("subTit").innerText=u; $("subLink").value=subUrl; $("subQr").innerHTML="⏳";
  try{const L2=await api("/api/sublinks?u="+encodeURIComponent(u)); subSsh=L2.ssh||[]; subSshB=L2.sshb||[]; subTls=L2.tlsinfo||""; $("subTlsBtn").classList.toggle("hid",!subTls); $("subLink").value=subUrl+"\n"+(subSsh[0]||"")}catch(e){}
  $("subBox").classList.remove("hid");
  try{const r=await fetch("/api/qr?u="+encodeURIComponent(u),{headers:{"Authorization":"Bearer "+tok}}); const t=await r.text(); $("subQr").innerHTML=t.indexOf("<svg")>=0?t:"<div style='color:#555;font-size:.8rem'>QR در دسترس نیست</div>"}catch(e){$("subQr").innerHTML=""}
  const sv=$("subQr").querySelector("svg"); if(sv){sv.setAttribute("width","100%");sv.removeAttribute("height")}
}
function subCopy(){copyText(subUrl)}
// ---- statistics
function fmtB(n){n=+n||0; const u=["B","KB","MB","GB","TB"]; let i=0; while(n>=1024&&i<4){n/=1024;i++} return (i?n.toFixed(i>2?2:1):n.toFixed(0))+" "+u[i]}
function cvs(id,h){const c=$(id), dpr=window.devicePixelRatio||1, w=c.clientWidth||300; c.width=w*dpr; c.height=h*dpr; c.style.height=h+"px"; const x=c.getContext("2d"); x.scale(dpr,dpr); x.direction="ltr"; x.textAlign="left"; return [x,w,h]}
function hours(x,w,h,cut,col){x.fillStyle=col; x.font="10px sans-serif"; for(let i=0;i<=4;i++){x.textAlign=i===0?"left":(i===4?"right":"center"); x.fillText(new Date((cut+i*21600)*1000).getHours()+":00",25+i*(w-30)/4,h-2)} x.textAlign="left"}
async function loadHist(){
  let d; try{d=await api("/api/history")}catch(e){return}
  const S=d.s||[], now=Date.now()/1000, cut=now-86400, pts=S.filter(r=>r[0]>=cut);
  const css=getComputedStyle(document.documentElement), C=n=>css.getPropertyValue(n).trim()||"#888";
  // tunnel
  let [x,w,h]=cvs("cTun",130); const T=r=>(r[0]-cut)/86400*(w-30)+25;
  x.fillStyle=C("--mu"); x.font="10px sans-serif"; x.fillText("ms",0,10);
  const tun=pts.filter(r=>r[1]>=0), ups=tun.filter(r=>r[1]===1).length, mx=Math.max(20,...tun.map(r=>r[2]||0));
  tun.forEach(r=>{if(r[1]===0){x.fillStyle="rgba(239,68,68,.35)"; x.fillRect(T(r)-1,0,Math.max(2,(w-30)/1440),h-14)}});
  x.strokeStyle=C("--pr"); x.lineWidth=1.5; x.beginPath(); let st=false;
  tun.forEach(r=>{if(r[1]===1){const X=T(r),Y=h-16-(r[2]/mx)*(h-30); if(!st){x.moveTo(X,Y);st=true}else x.lineTo(X,Y)}else st=false}); x.stroke();
  hours(x,w,h,cut,C("--mu")); x.fillStyle=C("--mu"); x.fillText(mx.toFixed(0),0,22);
  $("hTunSum").innerText=tun.length?`دسترس‌پذیری ۲۴ ساعت: ${(100*ups/tun.length).toFixed(1)}٪ · میانگین تأخیر: ${(tun.filter(r=>r[1]===1).reduce((a,r)=>a+r[2],0)/Math.max(1,ups)).toFixed(0)} ms · ${tun.length-ups} نمونه قطع`:"تانلی تنظیم نشده یا هنوز نمونه‌ای ثبت نشده (هر دقیقه ثبت می‌شود).";
  // load
  [x,w,h]=cvs("cLoad",110); const L=(i,col)=>{x.strokeStyle=col; x.lineWidth=1.5; x.beginPath(); pts.forEach((r,k)=>{const X=(r[0]-cut)/86400*(w-30)+25, Y=h-16-(Math.min(100,r[i])/100)*(h-30); k?x.lineTo(X,Y):x.moveTo(X,Y)}); x.stroke()};
  x.fillStyle=C("--mu"); x.font="10px sans-serif"; x.fillText("100%",0,12); x.fillText("0",8,h-14); L(3,C("--pr")); L(4,C("--wn"));
  hours(x,w,h,cut,C("--mu"));
  // daily traffic
  const days=Object.keys(d.d||{}).sort(), tot=days.map(k=>Object.values(d.d[k]).reduce((a,b)=>a+b,0));
  [x,w,h]=cvs("cDay",150); const m2=Math.max(1,...tot), bw=(w-10)/Math.max(1,days.length);
  x.font="10px sans-serif"; days.forEach((k,i)=>{const bh=(tot[i]/m2)*(h-34); x.fillStyle=C("--pr"); x.fillRect(5+i*bw+3,h-18-bh,bw-6,bh); x.fillStyle=C("--mu"); x.fillText(k.slice(5),5+i*bw+2,h-4); if(tot[i]>0){x.fillStyle=C("--tx"); x.fillText(fmtB(tot[i]),5+i*bw+2,h-22-bh)}});
  if(!days.length){x.fillStyle=C("--mu"); x.fillText("هنوز داده‌ای ثبت نشده",10,20)}
  // top users (7 days)
  const agg={}; days.slice(-7).forEach(k=>Object.entries(d.d[k]).forEach(([u,b])=>agg[u]=(agg[u]||0)+b));
  const top=Object.entries(agg).sort((a,b)=>b[1]-a[1]).slice(0,10), mt=top.length?top[0][1]:1;
  $("hTop").innerHTML=top.length?`<table><tbody>${top.map(([u,b])=>`<tr><td><b>${esc(u)}</b></td><td style="width:55%"><div style="height:8px;border-radius:99px;background:#080c17"><div style="height:100%;width:${Math.max(2,100*b/mt)}%;border-radius:99px;background:var(--pr)"></div></div></td><td dir="ltr">${fmtB(b)}</td></tr>`).join("")}</tbody></table>`:"داده‌ای ثبت نشده";
}
async function tunTest(){const r=await api("/api/tunnel/test","POST",{}); alert(r.ok?("تانل سالم است. IP خروجی: "+r.ip):(r.msg||"Error")); loadTun()}
async function tunRestart(){const r=await api("/api/tunnel/restart","POST",{}); alert(r.ok?"ری‌استارت شد؛ چند ثانیه بعد وضعیت را ببین":(r.msg||"Error")); loadTun()}
async function tunRemove(){
  if(!confirm("تانل حذف شود؟ اکانت‌های تانل به «مستقیم» تبدیل می‌شوند."))return;
  const r=await api("/api/tunnel/remove","POST",{});
  alert(r.ok?("تانل حذف شد. اکانت‌های تبدیل‌شده به مستقیم: "+(r.converted||0)):(r.msg||"Error")); load(1); loadTun();
}
if(LANG==="en") setLang("en",true); else{document.documentElement.lang="fa";document.documentElement.dir="rtl";document.querySelectorAll(".langBtn").forEach(b=>b.textContent="EN")}
if(tok){$("lBox").classList.add("hid");load(1);loadTpl().catch(()=>{})}
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid"))load(0)},4000);
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid")&&!$("secT").classList.contains("hid"))loadTun()},2000);
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid")&&!$("secH").classList.contains("hid"))loadHist()},60000);
