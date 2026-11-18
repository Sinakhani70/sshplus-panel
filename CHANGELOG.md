# Changelog

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
