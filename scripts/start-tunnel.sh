#!/bin/bash
[ -f /etc/SSHPlus/tunnel.conf ] && . /etc/SSHPlus/tunnel.conf || { echo "tunnel.conf missing"; exit 1; }
: "${TUN_DEV:=tun99}" "${TUN_ID:=99}" "${TUN_REMOTE:=10.99.0.2}"
O=(-F /dev/null -i /etc/SSHPlus/tunnel_key -p "$TUN_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes
   -o UserKnownHostsFile=/etc/SSHPlus/tunnel_known_hosts -o GlobalKnownHostsFile=/dev/null
   -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o ConnectTimeout=15)
/usr/local/bin/sshplus-tunnel-net down
ssh "${O[@]}" -N -w "${TUN_ID}:${TUN_ID}" "${TUN_USER}@${TUN_HOST}" &
SP=$!
trap 'kill $SP 2>/dev/null; exit 0' TERM INT
for i in $(seq 1 30); do
  ip link show "$TUN_DEV" >/dev/null 2>&1 && break
  kill -0 $SP 2>/dev/null || { echo "ssh exited before the tunnel came up"; exit 1; }
  sleep 1
done
ip link show "$TUN_DEV" >/dev/null 2>&1 || { echo "tunnel device did not appear"; kill $SP; exit 1; }
/usr/local/bin/sshplus-tunnel-net up || { kill $SP; exit 1; }
ssh "${O[@]}" "${TUN_USER}@${TUN_HOST}" "ip addr replace ${TUN_REMOTE}/30 dev ${TUN_DEV} && ip link set ${TUN_DEV} mtu 1400 up" \
  || { echo "failed to configure the remote end"; kill $SP; exit 1; }
wait $SP
