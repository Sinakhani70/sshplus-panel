# CK Client

Native Windows x64 desktop app (no browser, no web UI) for the SSH Plus panel: **SSH tunnel + BadVPN UDPGW**. Dark theme with the CK.VPN panel colours and logo, system-tray icon.

- **VPN mode** – creates a virtual adapter (Wintun), routes all TCP/UDP traffic through the SSH server. UDP (games, calls, DNS) goes through UDPGW.
- **Proxy mode** – local SOCKS5 on `127.0.0.1:<port>` (TCP + UDP ASSOCIATE via UDPGW) and sets the Windows system proxy.
- SSH over plain TCP or **TLS with custom SNI**, password or private-key login.
- Live **ping** on the main card (TCP connect time to a target of your choice through the tunnel, default 1.1.1.1:443; set the profile's ping target to `off` to time the SSH server only). Green < 120 ms, yellow < 300 ms, red above.
- Auto-reconnect with keep-alive; VPN routes stay in place while reconnecting (no leak to the open internet).
- Server host key pinned on first connect (trust-on-first-use); a changed key is refused.

## Install
Run `CK-Client-Setup.exe`: choose the language, **pick any install folder** (default `C:\Program Files\CK Client`), optionally add a desktop shortcut. Uninstall from Windows Settings → Apps (it never deletes anything but its own files).

Portable use also works: just run `ck-client.exe`.

## Use
1. VPN mode needs `wintun.dll`: the app downloads the official build (SHA-256 checked) on first connect; if that fails, get the amd64 DLL from <https://www.wintun.net> and put it next to `ck-client.exe`.
2. Run `ck-client.exe` (Windows asks for Administrator – needed to create the adapter and routes).
3. **Fastest:** in the CK.VPN panel copy an account's link (🔗 / *SSH link*, a list of links, or the *subscription link* `https://HOST:2053/s/<token>`), then press **Import** in CK Client – the profile (server, port, user, password, TLS/SNI) is created automatically. Importing the same account again just updates its password.
   Or add a profile by hand: server, SSH port, user/password, keep **UDPGW** on with `127.0.0.1:7300` (the panel default), press Connect.

Closing the window while connected hides it to the tray (right-click the tray icon → Exit to quit); exiting restores routes/proxy settings.

## Build (any OS with Go)
```
./build.sh        # tests + cross-compile -> dist/ck-client.exe
```

## Notes / limits
- Profiles (including passwords) are stored in `%APPDATA%\CKClient\profiles.json`, readable by your Windows user only by file permissions – not encrypted.
- Windows may still send DNS queries to other adapters in parallel (smart multi-homed resolution); if DNS leaks matter, disable it in group policy or use proxy mode with DoH.
- Only IPv4 server routing is set up around the SSH host; IPv6 traffic is sent into the tunnel and falls back to IPv4 if the server has no IPv6.
- Verified on Linux (unit + in-process SSH end-to-end tests for SSH, SOCKS5 and UDPGW framing). The Windows-specific parts (window, Wintun adapter, routes, tray) are compiled but **must be tried on a real Windows machine**.
