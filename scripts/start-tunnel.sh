#!/bin/bash
F=/etc/SSHPlus/tunnel.conf
[ -f "$F" ] || { echo "SSHPLUS-TUNNEL: $F is missing (the tunnel was removed or its setup failed)"; exit 1; }
. "$F" || { echo "SSHPLUS-TUNNEL: $F could not be read"; exit 1; }
[ "${TUN_MODE:-ssh}" = wg ] && exec /usr/local/bin/start-wg.sh
: "${TUN_DEV:=tun99}" "${TUN_ID:=99}" "${TUN_REMOTE:=10.99.0.2}"
O=(-F /dev/null -i /etc/SSHPlus/tunnel_key -p "$TUN_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes
   -o UserKnownHostsFile=/etc/SSHPlus/tunnel_known_hosts -o GlobalKnownHostsFile=/dev/null
   -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o ConnectTimeout=15)
/usr/local/bin/sshplus-tunnel-net down
# a usable /dev/net/tun is required for "ssh -w" (not available on OpenVZ / some LXC VPS unless TUN/TAP is enabled by the provider)
if [ ! -c /dev/net/tun ]; then modprobe tun 2>/dev/null; mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null; chmod 600 /dev/net/tun 2>/dev/null; fi
python3 -c 'import os,sys
try: os.close(os.open("/dev/net/tun",os.O_RDWR))
except Exception as e:
    print("SSHPLUS-TUNNEL: this server cannot open /dev/net/tun (%s) - on OpenVZ/LXC VPS enable TUN/TAP in the provider panel"%e); sys.exit(1)' || exit 1
echo "SSHPLUS-TUNNEL: starting ssh -w to ${TUN_USER}@${TUN_HOST}:${TUN_PORT}"
ssh "${O[@]}" -N -w "${TUN_ID}:${TUN_ID}" "${TUN_USER}@${TUN_HOST}" &
SP=$!
trap 'kill $SP 2>/dev/null; exit 0' TERM INT
for i in $(seq 1 30); do
  ip link show "$TUN_DEV" >/dev/null 2>&1 && break
  kill -0 $SP 2>/dev/null || { echo "SSHPLUS-TUNNEL: ssh exited before the tunnel device came up (see the ssh message just above)"; exit 1; }
  sleep 1
done
ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "SSHPLUS-TUNNEL: tunnel device did not appear"; kill $SP; exit 1; }
/usr/local/bin/sshplus-tunnel-net up || { echo "SSHPLUS-TUNNEL: sshplus-tunnel-net up failed (ip/route error above)"; kill $SP; exit 1; }
ssh "${O[@]}" "${TUN_USER}@${TUN_HOST}" "ip addr replace ${TUN_REMOTE}/30 dev ${TUN_DEV} && ip link set ${TUN_DEV} mtu 1400 up" \
  || { echo "SSHPLUS-TUNNEL: failed to configure the remote end (tun device on the exit server)"; kill $SP; exit 1; }
wait $SP
