# CK Client

Windows x64 VPN client for the SSH Plus panel: **SSH tunnel + BadVPN UDPGW**.

- **VPN mode** – creates a virtual adapter (Wintun), routes all TCP/UDP traffic through the SSH server. UDP (games, calls, DNS) goes through UDPGW.
- **Proxy mode** – local SOCKS5 on `127.0.0.1:<port>` (TCP + UDP ASSOCIATE via UDPGW) and sets the Windows system proxy.
- SSH over plain TCP or **TLS with custom SNI**, password or private-key login.
- Auto-reconnect with keep-alive; VPN routes stay in place while reconnecting (no leak to the open internet).
- Server host key pinned on first connect (trust-on-first-use); a changed key is refused.

## Use
1. Download `wintun.dll` (amd64) from <https://www.wintun.net> and put it next to `ck-client.exe` (VPN mode only).
2. Run `ck-client.exe` (accepts the UAC prompt – needed to create the adapter and routes).
3. Add a profile: server, SSH port, user/password, keep **UDPGW** on with `127.0.0.1:7300` (the panel default), press Connect.

Closing the window disconnects and restores routes/proxy settings.

## Build (any OS with Go)
```
./build.sh        # tests + cross-compile -> dist/ck-client.exe
```

## Notes / limits
- Profiles (including passwords) are stored in `%APPDATA%\CKClient\profiles.json`, readable by your Windows user only by file permissions – not encrypted.
- Windows may still send DNS queries to other adapters in parallel (smart multi-homed resolution); if DNS leaks matter, disable it in group policy or use proxy mode with DoH.
- Only IPv4 server routing is set up around the SSH host; IPv6 traffic is sent into the tunnel and falls back to IPv4 if the server has no IPv6.
- Verified on Linux (unit + in-process SSH end-to-end tests for SSH, SOCKS5 and UDPGW framing). The Windows-specific parts (Wintun adapter, routes, UAC) are compiled but **must be tried on a real Windows machine**.
