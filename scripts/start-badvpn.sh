#!/bin/bash
# usage: start-badvpn.sh [direct|tunnel]   (tunnel = second instance on UDP_PORT+1, runs in the tunnel routing path)
MODE="${1:-direct}"
UDP_PORT=7300; BIND_ADDR=127.0.0.1; UDP_MTU=1200; MAX_CLIENTS=1000; MAX_CONN=64; SEND_BUFFER=65536; MSS_CLAMP=1
[ -f /etc/SSHPlus/badvpn.conf ] && . /etc/SSHPlus/badvpn.conf
[ "$MODE" = tunnel ] && { UDP_PORT=$((UDP_PORT+1)); BIND_ADDR=127.0.0.1; }
if [ "${MSS_CLAMP:-1}" = "1" ]; then
  for CMD in iptables ip6tables; do
    command -v "$CMD" >/dev/null 2>&1 || continue
    "$CMD" -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    "$CMD" -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
  done
fi
exec /usr/local/bin/badvpn-udpgw --listen-addr ${BIND_ADDR:-127.0.0.1}:${UDP_PORT:-7300} \
  --udp-mtu ${UDP_MTU:-1200} --max-clients ${MAX_CLIENTS:-1000} \
  --max-connections-for-client ${MAX_CONN:-64} --client-socket-sndbuf ${SEND_BUFFER:-65536} --loglevel warning
