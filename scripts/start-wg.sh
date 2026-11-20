#!/bin/bash
# WireGuard variant of the tunnel (tunnel.conf TUN_MODE=wg): same device name, addresses and routing as the SSH tunnel, but over UDP,
# so the user's TCP is not carried inside another TCP connection (which collapses under packet loss / high latency).
. /etc/SSHPlus/tunnel.conf
: "${TUN_DEV:=tun99}" "${TUN_LOCAL:=10.99.0.1}" "${WG_PORT:=51820}"
[ -s /etc/SSHPlus/wg_private ] || { echo "SSHPLUS-TUNNEL: /etc/SSHPlus/wg_private is missing"; exit 1; }
[ -n "$WG_EXIT_PUB" ] || { echo "SSHPLUS-TUNNEL: WG_EXIT_PUB is missing in tunnel.conf"; exit 1; }
/usr/local/bin/sshplus-tunnel-net down
ip link del "$TUN_DEV" 2>/dev/null
if ip link add "$TUN_DEV" type wireguard 2>/dev/null; then :
elif command -v wireguard-go >/dev/null 2>&1; then wireguard-go "$TUN_DEV" >/dev/null 2>&1; sleep 1
else echo "SSHPLUS-TUNNEL: no WireGuard support here (kernel module or wireguard-go)"; exit 1; fi
ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "SSHPLUS-TUNNEL: could not create the WireGuard interface $TUN_DEV"; exit 1; }
trap 'ip link del "$TUN_DEV" 2>/dev/null; exit 0' TERM INT
wg set "$TUN_DEV" private-key /etc/SSHPlus/wg_private peer "$WG_EXIT_PUB" endpoint "${TUN_HOST}:${WG_PORT}" allowed-ips 0.0.0.0/0 persistent-keepalive 15 \
  || { echo "SSHPLUS-TUNNEL: wg set failed"; ip link del "$TUN_DEV"; exit 1; }
/usr/local/bin/sshplus-tunnel-net up || { echo "SSHPLUS-TUNNEL: sshplus-tunnel-net up failed"; ip link del "$TUN_DEV"; exit 1; }
echo "SSHPLUS-TUNNEL: WireGuard up to ${TUN_HOST}:${WG_PORT}"
# watchdog: after a grace period the last handshake must stay fresh (keepalive is 15 s); otherwise let systemd restart the unit
T0=$(date +%s)
while true; do
  sleep 10 & wait $!
  now=$(date +%s); hs=$(wg show "$TUN_DEV" latest-handshakes 2>/dev/null | awk '{print $2}')
  [ -n "$hs" ] || { echo "SSHPLUS-TUNNEL: the WireGuard interface vanished"; exit 1; }
  if [ "$hs" -gt 0 ]; then [ $((now-hs)) -le 180 ] || { echo "SSHPLUS-TUNNEL: no WireGuard handshake for 3 minutes"; exit 1; }
  elif [ $((now-T0)) -gt 90 ]; then echo "SSHPLUS-TUNNEL: no WireGuard handshake after 90 seconds (UDP ${WG_PORT} blocked?)"; exit 1; fi
done
