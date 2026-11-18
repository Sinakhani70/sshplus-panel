#!/usr/bin/env bash
# ==============================================================================
#  SSH Plus Panel v1.4.0  -  OpenSSH + Dropbear (6 ports) + BadVPN UDPGW + BBR
#                            + Tunnel (SSH tun to an exit server, one-click)
#  Target: Ubuntu 22.04 / 24.04 (fresh server), run as root.
#
#  Usage:
#     bash install.sh
#  or:
#     bash <(curl -Ls https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh)
#
#  Re-running is safe: existing users, ports and settings are kept.
#  Log: /var/log/sshplus/install.log
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
VERSION="1.4.0"
LOG=/var/log/sshplus/install.log

[ "$(id -u)" = 0 ] || { echo "باید با root اجرا کنی / run as root"; exit 1; }

# ------------------------------------------------------------------------------
step1() {
echo ">>> SSH Plus Panel v$VERSION"
echo ">>> [1/4] Base system, BBR, BadVPN"
mkdir -p /opt/sshplus-panel /etc/SSHPlus /etc/dropbear /var/log/sshplus
echo "== install $(date)" >> $LOG

# 1) package index update (prerequisite)  2) curl  3) everything else
apt-get update -y >>$LOG 2>&1 || echo "WARN: apt-get update ناموفق بود (لاگ: $LOG)"
apt-get install -y curl >>$LOG 2>&1
apt-get install -y python3 git cmake build-essential dropbear-bin openssh-server openssh-client sshpass iptables iproute2 psmisc procps kmod >>$LOG 2>&1
for c in python3 dropbear dropbearkey cmake git sshpass ssh-keygen ip iptables; do
  command -v $c >/dev/null || { echo "FAILED: $c نصب نشد. لاگ: $LOG"; exit 1; }
done

# cleanup of old TLS / WebSocket stack
for s in sshplus-tls sshplus-ws haproxy; do
  systemctl disable --now $s >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/$s.service
done
rm -f /usr/local/bin/start-sshplus-tls.sh /usr/local/bin/sshplus-ws.py /usr/local/bin/sshplus-cert.sh
pkill -f /usr/local/bin/sshplus-ws.py 2>/dev/null || true
systemctl disable --now dropbear >/dev/null 2>&1 || true
for s in sshplus-dropbear sshplus-dropbear-t badvpn badvpn-t sshplus-panel; do systemctl stop $s >/dev/null 2>&1 || true; done

# kernel tuning
cat > /etc/sysctl.d/98-sshplus.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF

# BBR (not re-enabled if it was turned off from the panel)
if [ ! -f /etc/sysctl.d/99-sshplus-bbr.conf ]; then
  modprobe tcp_bbr 2>>$LOG || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo tcp_bbr > /etc/modules-load.d/sshplus-bbr.conf
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-sshplus-bbr.conf
  else
    echo "WARN: این کرنل BBR ندارد"
  fi
fi
sysctl --system >>$LOG 2>&1

# tunnel shell
cat > /usr/local/bin/sshplus-shell <<'EOF'
#!/bin/bash
trap '' INT QUIT TSTP
trap 'kill $! 2>/dev/null; exit 0' HUP TERM
[ -t 1 ] && echo "=== SSH Plus Tunnel Connected ==="
while true; do sleep 3600 & wait $!; done
EOF
chmod 755 /usr/local/bin/sshplus-shell
# tunnel accounts use their own shell (same behaviour); the shell tells which Dropbear instance accepts the account
install -m 755 /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-shell-t
for sh in /usr/local/bin/sshplus-shell /usr/local/bin/sshplus-shell-t; do
  grep -qxF "$sh" /etc/shells || echo "$sh" >> /etc/shells
done
# per-instance /etc/shells (bind-mounted into each Dropbear service): direct instance rejects tunnel accounts and vice versa
grep -vxF /usr/local/bin/sshplus-shell-t /etc/shells > /etc/SSHPlus/shells.direct
grep -vxF /usr/local/bin/sshplus-shell   /etc/shells > /etc/SSHPlus/shells.tunnel

# quick admin password change from terminal
cat > /usr/local/bin/sshplus-pass <<'EOF'
#!/bin/bash
python3 - "${1:-admin}" "${2:-admin}" <<'PY'
import json,os,sys
p="/etc/SSHPlus/panel.json"
d=json.load(open(p)) if os.path.exists(p) else {"port":2053}
d["username"]=sys.argv[1].strip(); d["password"]=sys.argv[2].strip()
json.dump(d,open(p,"w")); print("Admin Updated ->",d["username"],d["password"])
PY
systemctl restart sshplus-panel 2>/dev/null || true
EOF
chmod 755 /usr/local/bin/sshplus-pass

# build BadVPN (UDPGW)
if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
  rm -rf /usr/local/src/badvpn
  git clone --depth 1 https://github.com/ambrop72/badvpn.git /usr/local/src/badvpn >>$LOG 2>&1
  mkdir -p /usr/local/src/badvpn/build && cd /usr/local/src/badvpn/build
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_C_FLAGS="-O2 -fcommon -Wno-error" >>$LOG 2>&1
  make -j"$(nproc)" >>$LOG 2>&1
  install -m 755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw 2>>$LOG
  cd /root
fi
[ -x /usr/local/bin/badvpn-udpgw ] || { echo "FAILED: کامپایل BadVPN. لاگ: $LOG"; exit 1; }

# config files (existing ones are kept)
[ -f /etc/SSHPlus/panel.json ] || echo '{"port":2053,"username":"admin","password":"admin","bind":"0.0.0.0"}' > /etc/SSHPlus/panel.json
[ -f /etc/SSHPlus/badvpn.conf ] || printf "UDP_PORT=7300\nBIND_ADDR=127.0.0.1\nUDP_MTU=1200\nMAX_CLIENTS=1000\nMAX_CONN=64\nSEND_BUFFER=65536\nMSS_CLAMP=1\n" > /etc/SSHPlus/badvpn.conf
[ -f /etc/SSHPlus/meta.json ] || echo '{}' > /etc/SSHPlus/meta.json
touch /root/users.db

# ports.json: create or top-up to 6 Dropbear ports (SSH ports such as 9011 stay reserved)
# + "tdb": Dropbear ports reserved for tunnel accounts
python3 - <<'PY'
import json,os,re,subprocess
p="/etc/SSHPlus/ports.json"
d=json.load(open(p)) if os.path.exists(p) else {}
s1=int(d.get("ssh",22) or 22); s2=int(d.get("ssh2",2222) or 0)
res={22,s1,s2,2053,7300}
try:
    o=subprocess.run(["sshd","-T"],capture_output=True,text=True,timeout=10).stdout
    for l in o.splitlines():
        if l.startswith("port "): res.add(int(l.split()[1]))
except Exception: pass
try:                                   # ports taken by OTHER programs (nginx, x-ui, ...) are not usable for Dropbear
    o=subprocess.run(["ss","-ltnpH"],capture_output=True,text=True,timeout=10).stdout
    for l in o.splitlines():
        f=l.split(); m=re.search(r":(\d+)$",f[3]) if len(f)>=4 else None
        if m and not set(re.findall(r'\("([^"]+)"',l))<={"dropbear","sshd"}: res.add(int(m.group(1)))
except Exception: pass
old_t=[]
for x in d.get("tdb",[]):
    try: v=int(x)
    except Exception: continue
    if 0<v<65536 and v not in res and v not in old_t: old_t.append(v)
db=[]
for x in list(d.get("db",[]))+[442,444,8085,8443,10443,9443,8880,2083]:
    try: v=int(x)
    except Exception: continue
    if 0<v<65536 and v not in res and v not in old_t and v not in db: db.append(v)
db=db[:6]
tdb=old_t[:4]
for v in (2087,2096,4443,8444,2095):
    if len(tdb)>=2: break
    if v not in res and v not in db and v not in tdb: tdb.append(v)
json.dump({"ssh":s1,"ssh2":s2,"db":db,"tdb":tdb},open(p,"w"))
print("Dropbear ports:",db,"| Tunnel Dropbear ports:",tdb)
PY
chmod 600 /etc/SSHPlus/panel.json /etc/SSHPlus/meta.json /root/users.db
echo "=== STEP 1 OK ==="
}

# ------------------------------------------------------------------------------
step2() {
echo ">>> [2/4] OpenSSH, Dropbear, BadVPN services"
mkdir -p /etc/ssh/sshd_config.d
F=/etc/ssh/sshd_config.d/00-sshplus.conf
PORTS=$(grep -hE '^Port ' $F 2>/dev/null | sort -u)
[ -n "$PORTS" ] || PORTS=$'Port 22\nPort 2222'
cp -a $F /root/00-sshplus.conf.bak 2>/dev/null || true
{
echo "$PORTS"
cat <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
UsePAM yes
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
AllowAgentForwarding yes
GatewayPorts yes
PermitTunnel yes
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 10
MaxSessions 100
MaxStartups 100:30:200
EOF
} > $F
if ! sshd -t 2>>$LOG; then
  echo "کانفیگ sshd خطا دارد؛ برگشت به بکاپ"
  [ -f /root/00-sshplus.conf.bak ] && cp /root/00-sshplus.conf.bak $F || rm -f $F
  exit 1
fi
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
if ! systemctl is-active --quiet ssh; then
  echo "WARN: ssh بالا نیامد؛ فعال‌سازی socket"
  systemctl enable --now ssh.socket 2>/dev/null || true
fi

# Dropbear: "direct" instance (ports.json "db", up to 6) and "tunnel" instance (ports.json "tdb")
cat > /usr/local/bin/start-dropbear.sh <<'EOF'
#!/bin/bash
MODE="${1:-direct}"
mkdir -p /etc/dropbear
for t in rsa ecdsa ed25519; do
  f="/etc/dropbear/dropbear_${t}_host_key"
  [ -s "$f" ] || dropbearkey -t "$t" -f "$f" >/dev/null 2>&1
done
P=$(python3 - "$MODE" <<'PY'
import json,sys
mode=sys.argv[1]; key="tdb" if mode=="tunnel" else "db"
dflt="-p 2087" if mode=="tunnel" else "-p 442 -p 444"
try:
    d=json.load(open("/etc/SSHPlus/ports.json")); out=[]
    for x in d.get(key,[]):
        try: v=int(x)
        except Exception: continue
        if 0<v<65536 and v not in (22,2053) and v not in out: out.append(v)
    print(" ".join("-p %d"%p for p in out[:6]) or dflt)
except Exception:
    print(dflt)
PY
)
exec /usr/sbin/dropbear -F -E -w -K 30 \
  -r /etc/dropbear/dropbear_rsa_host_key \
  -r /etc/dropbear/dropbear_ecdsa_host_key \
  -r /etc/dropbear/dropbear_ed25519_host_key $P
EOF
chmod 755 /usr/local/bin/start-dropbear.sh

# ---- Tunnel: network helper (policy routing, fail-closed) ----
# Tunnel accounts are routed into routing table 100:
#   * OpenSSH accounts  -> "ip rule uidrange" (forwarding runs as the user)
#   * Tunnel Dropbear   -> cgroup mark (Dropbear forwards as root, so uid cannot be used)
# Table 100 always holds an "unreachable" default: if the tunnel is down, tunnel
# accounts get NO connectivity instead of silently leaking out of this server.
cat > /usr/local/bin/sshplus-tunnel-net <<'EOF'
#!/bin/bash
# usage: sshplus-tunnel-net boot|base|mark|up|down|sync|clean
# IPv4: tunnel accounts are routed into the tunnel. IPv6: tunnel accounts get an "unreachable" route
# (the tunnel is IPv4-only), so they can never leave through this server's own IPv6 address.
# UDPGW: tunnel accounts that connect to 127.0.0.1:UDP_PORT are transparently redirected to a second
# badvpn instance (UDP_PORT+1) that itself runs in the tunnel routing path.
TBL=100; MARK=0x64; PRIO_MARK=90; PRIO_SRC=91; PRIO_UID=100
CGS="system.slice/sshplus-dropbear-t.service system.slice/badvpn-t.service"
CG_DB="system.slice/sshplus-dropbear-t.service"
UDP_PORT=7300
[ -f /etc/SSHPlus/badvpn.conf ] && . /etc/SSHPlus/badvpn.conf
TUDP=$((UDP_PORT+1))
TUN_DEV=tun99; TUN_LOCAL=10.99.0.1
[ -f /etc/SSHPlus/tunnel.conf ] && . /etc/SSHPlus/tunnel.conf
V6=0; [ -s /proc/net/if_inet6 ] && command -v ip6tables >/dev/null 2>&1 && V6=1
ipt() { local t=$1 c=$2; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -A "$c" "$@"; }
ipt6() { local t=$1 c=$2; shift 2; ip6tables -t "$t" -C "$c" "$@" 2>/dev/null || ip6tables -t "$t" -A "$c" "$@"; }
cgdir() { local b; for b in /sys/fs/cgroup /sys/fs/cgroup/unified; do [ -d "$b/$1" ] && return 0; done; return 1; }

base() {
  ip route replace unreachable default table $TBL metric 9999
  ip rule show | grep -q "fwmark $MARK lookup $TBL" || ip rule add fwmark $MARK lookup $TBL priority $PRIO_MARK
  ip rule show | grep -q "from $TUN_LOCAL lookup $TBL" || ip rule add from $TUN_LOCAL lookup $TBL priority $PRIO_SRC
  iptables -t mangle -N SSHPLUS_TUN 2>/dev/null
  ipt mangle OUTPUT -j SSHPLUS_TUN
  iptables -t nat -N SSHPLUS_UDPGW_U 2>/dev/null; iptables -t nat -N SSHPLUS_UDPGW_C 2>/dev/null
  ipt nat OUTPUT -j SSHPLUS_UDPGW_U
  ipt nat OUTPUT -j SSHPLUS_UDPGW_C
  ipt nat POSTROUTING -o "$TUN_DEV" -j MASQUERADE
  if [ "$V6" = 1 ]; then
    ip -6 route replace unreachable default table $TBL metric 9999
    ip -6 rule show | grep -q "fwmark $MARK lookup $TBL" || ip -6 rule add fwmark $MARK lookup $TBL priority $PRIO_MARK
    ip6tables -t mangle -N SSHPLUS_TUN 2>/dev/null
    ipt6 mangle OUTPUT -j SSHPLUS_TUN
  fi
}
mark() {
  # a cgroup match is bound to the cgroup that exists NOW: re-apply it whenever a tunnel service (re)starts
  iptables -t mangle -N SSHPLUS_TUN 2>/dev/null; iptables -t mangle -F SSHPLUS_TUN
  iptables -t nat -N SSHPLUS_UDPGW_C 2>/dev/null; iptables -t nat -F SSHPLUS_UDPGW_C
  if [ "$V6" = 1 ]; then ip6tables -t mangle -N SSHPLUS_TUN 2>/dev/null; ip6tables -t mangle -F SSHPLUS_TUN; fi
  local cg
  for cg in $CGS; do
    cgdir "$cg" || continue
    iptables -t mangle -A SSHPLUS_TUN -m cgroup --path "$cg" -j MARK --set-xmark $MARK/0xffffffff || return 1
    if [ "$V6" = 1 ]; then ip6tables -t mangle -A SSHPLUS_TUN -m cgroup --path "$cg" -j MARK --set-xmark $MARK/0xffffffff || return 1; fi
  done
  if cgdir "$CG_DB"; then
    iptables -t nat -A SSHPLUS_UDPGW_C -p tcp -d 127.0.0.1 --dport "$UDP_PORT" -m cgroup --path "$CG_DB" \
      -j DNAT --to-destination "127.0.0.1:$TUDP" || return 1
  fi
}
up() {
  ip addr replace "$TUN_LOCAL/30" dev "$TUN_DEV"
  ip link set "$TUN_DEV" mtu 1400 up
  sysctl -qw "net.ipv4.conf.$TUN_DEV.rp_filter=0" 2>/dev/null
  ip route replace default dev "$TUN_DEV" table $TBL metric 1
}
down() { ip route del default dev "$TUN_DEV" table $TBL metric 1 2>/dev/null; return 0; }
sync() {
local out uids u
out=$(python3 - "$TBL" "$PRIO_UID" <<'PY'
import subprocess,sys
tbl,prio=sys.argv[1],sys.argv[2]; SH="/usr/local/bin/sshplus-shell-t"
want=set()
for l in open("/etc/passwd"):
    p=l.rstrip("\n").split(":")
    if len(p)>=7 and p[6]==SH and p[2].isdigit(): want.add(int(p[2]))
for fam in ("-4","-6"):
    r=subprocess.run(["ip",fam,"-o","rule","show"],capture_output=True,text=True)
    if r.returncode!=0: continue                      # IPv6 not available
    have={}
    for l in r.stdout.splitlines():
        t=l.replace("\t"," ").split()
        if t and t[0]==prio+":" and "uidrange" in t and "lookup" in t and t[t.index("lookup")+1]==tbl:
            x=t[t.index("uidrange")+1]; a,_,b=x.partition("-")
            if a==b and a.isdigit(): have[int(a)]=x
    for u in sorted(want-set(have)): subprocess.run(["ip",fam,"rule","add","uidrange","%d-%d"%(u,u),"lookup",tbl,"priority",prio],stdout=2)
    for u in sorted(set(have)-want): subprocess.run(["ip",fam,"rule","del","uidrange",have[u],"lookup",tbl,"priority",prio],stdout=2)
print("UIDS:"+" ".join(str(u) for u in sorted(want)))
PY
)
  uids=$(printf '%s\n' "$out" | sed -n 's/^UIDS://p')
  # UDPGW for OpenSSH tunnel accounts (forwarding runs as the user)
  iptables -t nat -N SSHPLUS_UDPGW_U 2>/dev/null; iptables -t nat -F SSHPLUS_UDPGW_U
  for u in $uids; do
    iptables -t nat -A SSHPLUS_UDPGW_U -p tcp -d 127.0.0.1 --dport "$UDP_PORT" -m owner --uid-owner "$u" \
      -j DNAT --to-destination "127.0.0.1:$TUDP"
  done
}
clean() {
  for F in -4 -6; do
    while ip $F rule del priority $PRIO_UID 2>/dev/null; do :; done
    ip $F rule del priority $PRIO_MARK 2>/dev/null; ip $F rule del priority $PRIO_SRC 2>/dev/null
    ip $F route flush table $TBL 2>/dev/null
  done
  for T in iptables ip6tables; do
    command -v $T >/dev/null 2>&1 || continue
    $T -t mangle -D OUTPUT -j SSHPLUS_TUN 2>/dev/null; $T -t mangle -F SSHPLUS_TUN 2>/dev/null; $T -t mangle -X SSHPLUS_TUN 2>/dev/null
  done
  local c
  for c in SSHPLUS_UDPGW_U SSHPLUS_UDPGW_C; do
    iptables -t nat -D OUTPUT -j $c 2>/dev/null; iptables -t nat -F $c 2>/dev/null; iptables -t nat -X $c 2>/dev/null
  done
  iptables -t nat -D POSTROUTING -o "$TUN_DEV" -j MASQUERADE 2>/dev/null
  return 0
}
case "$1" in
  boot) base; sync ;;
  base) base ;;
  mark) mark ;;
  up) up ;;
  down) down ;;
  sync) base; sync ;;
  clean) clean ;;
  *) echo "usage: $0 boot|base|mark|up|down|sync|clean"; exit 1 ;;
esac
EOF
chmod 755 /usr/local/bin/sshplus-tunnel-net

# ---- Tunnel: SSH tun link to the exit server (L3 tunnel over ssh -w) ----
cat > /usr/local/bin/start-tunnel.sh <<'EOF'
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
EOF
chmod 755 /usr/local/bin/start-tunnel.sh

cat > /usr/local/bin/sshplus-tunnel-setup <<'EOF'
#!/bin/bash
# terminal version of the panel's Tunnel tab (the password is typed here instead of going through the panel's plain HTTP)
# usage: sshplus-tunnel-setup EXIT_SERVER_IP [SSH_PORT] [USER]
[ -n "$1" ] || { echo "usage: sshplus-tunnel-setup EXIT_SERVER_IP [SSH_PORT=22] [USER=root]"; exit 1; }
exec python3 /opt/sshplus-panel/app.py --tunnel-setup "$1" "${2:-22}" "${3:-root}"
EOF
chmod 755 /usr/local/bin/sshplus-tunnel-setup

# BadVPN
cat > /usr/local/bin/start-badvpn.sh <<'EOF'
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
EOF
chmod 755 /usr/local/bin/start-badvpn.sh

# systemd units
cat > /etc/systemd/system/sshplus-dropbear.service <<'EOF'
[Unit]
Description=SSH Plus Dropbear (direct accounts)
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
BindReadOnlyPaths=/etc/SSHPlus/shells.direct:/etc/shells
ExecStart=/usr/local/bin/start-dropbear.sh direct
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-dropbear-t.service <<'EOF'
[Unit]
Description=SSH Plus Dropbear (tunnel accounts)
After=network.target sshplus-tunnel-net.service
Wants=sshplus-tunnel-net.service
StartLimitIntervalSec=0
[Service]
Type=simple
BindReadOnlyPaths=/etc/SSHPlus/shells.tunnel:/etc/shells
ExecStartPre=/usr/local/bin/sshplus-tunnel-net base
ExecStart=/usr/local/bin/start-dropbear.sh tunnel
ExecStartPost=/usr/local/bin/sshplus-tunnel-net mark
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badvpn-t.service <<'EOF'
[Unit]
Description=BadVPN UDPGW (tunnel accounts, routed through the tunnel)
After=network.target sshplus-tunnel-net.service
Wants=sshplus-tunnel-net.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=/usr/local/bin/sshplus-tunnel-net base
ExecStart=/usr/local/bin/start-badvpn.sh tunnel
ExecStartPost=/usr/local/bin/sshplus-tunnel-net mark
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-tunnel-net.service <<'EOF'
[Unit]
Description=SSH Plus tunnel routing rules (fail-closed)
Before=ssh.service sshd.service sshplus-dropbear-t.service badvpn-t.service
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sshplus-tunnel-net boot
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-tunnel.service <<'EOF'
[Unit]
Description=SSH Plus Tunnel (link to the exit server)
After=network-online.target sshplus-tunnel-net.service
Wants=network-online.target sshplus-tunnel-net.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/local/bin/start-tunnel.sh
ExecStopPost=/usr/local/bin/sshplus-tunnel-net down
Restart=always
RestartSec=3
KillMode=control-group
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badvpn.service <<'EOF'
[Unit]
Description=BadVPN UDPGW
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/local/bin/start-badvpn.sh
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-panel.service <<'EOF'
[Unit]
Description=SSH Plus Panel
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=root
WorkingDirectory=/opt/sshplus-panel
ExecStart=/usr/bin/python3 /opt/sshplus-panel/app.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo "=== STEP 2 OK ==="
}

# ------------------------------------------------------------------------------
step3() {
echo ">>> [3/4] Panel backend (app.py)"
cat > /opt/sshplus-panel/app.py <<'PYEOF'
#!/usr/bin/env python3
import os, re, sys, json, time, shutil, getpass, secrets, threading, subprocess
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

CFG="/etc/SSHPlus/panel.json"; DB="/root/users.db"; META="/etc/SSHPlus/meta.json"
PORTS="/etc/SSHPlus/ports.json"; BV="/etc/SSHPlus/badvpn.conf"
BBRF="/etc/sysctl.d/99-sshplus-bbr.conf"; SHELL="/usr/local/bin/sshplus-shell"; SHELL_T="/usr/local/bin/sshplus-shell-t"
HTML="/opt/sshplus-panel/index.html"; SSHCONF="/etc/ssh/sshd_config.d/00-sshplus.conf"
TOK={}; PIDS={}; FAIL={}; DBU={}; DBT={}
STATE={"first":True}; CACHE={"t":0.0,"v":None}; SSHP={"t":0.0,"v":set()}
LOCK=threading.Lock(); ML=threading.RLock()
ENV={"LC_ALL":"C","PATH":"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
NAME_RE=re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,31}$")

def cmd(c,t=15):
  try:
    r=subprocess.run(c,capture_output=True,text=True,timeout=t,env=ENV)
    return r.returncode,r.stdout.strip(),r.stderr.strip()
  except Exception as e: return 1,"",str(e)

def rjson(p,d):
  try:
    with open(p,"r",encoding="utf-8") as f: return json.load(f)
  except Exception: return d

def wjson(p,d):
  t=p+".t"
  with open(t,"w",encoding="utf-8") as f: json.dump(d,f,ensure_ascii=False)
  os.chmod(t,0o600); os.replace(t,p)

def to_port(x):
  try:
    v=int(str(x).strip()); return v if 0<v<65536 else 0
  except Exception: return 0

def sshd_ports():
  if time.time()-SSHP["t"]<30 and SSHP["v"]: return SSHP["v"]
  _,o,_=cmd(["sshd","-T"],10); s=set()
  for l in o.splitlines():
    if l.startswith("port "):
      v=to_port(l.split()[1])
      if v: s.add(v)
  SSHP["t"]=time.time(); SSHP["v"]=s
  return s

def read_bv():
  d={}
  if os.path.exists(BV):
    for l in open(BV):
      if "=" in l:
        k,v=l.strip().split("=",1); d[k]=v
  return d

def fw_kind():
  rc,o,_=cmd(["ufw","status"])
  if rc==0 and o.startswith("Status: active"): return "ufw"
  if cmd(["systemctl","is-active","firewalld"])[0]==0 and cmd(["firewall-cmd","--state"])[0]==0: return "firewalld"
  return "none"

def ufw_open(ports):
  k=fw_kind()
  for p in sorted(ports):
    if k=="ufw": cmd(["ufw","allow",f"{p}/tcp"])
    elif k=="firewalld": cmd(["firewall-cmd","--permanent",f"--add-port={p}/tcp"]); cmd(["firewall-cmd",f"--add-port={p}/tcp"])
  return k

def listen_ports():
  # local TCP listeners: port -> set of process names
  _,o,_=cmd(["ss","-ltnpH"],10); res={}
  for l in o.splitlines():
    f=l.split(); m=re.search(r":(\d+)$",f[3]) if len(f)>=4 else None
    if m: res.setdefault(int(m.group(1)),set()).update(re.findall(r'\("([^"]+)"',l) or ["?"])
  return res

def foreign_ports():
  # ports held by programs other than our own Dropbear/OpenSSH
  return {p for p,n in listen_ports().items() if not n<={"dropbear","sshd"}}

def passwd_map():
  # panel accounts: name -> (uid, shell). shell SHELL = direct account, SHELL_T = tunnel account
  m={}
  try:
    for l in open("/etc/passwd"):
      p=l.strip().split(":")
      if len(p)>=7 and p[2].isdigit() and int(p[2])>=1000 and p[6] in (SHELL,SHELL_T): m[p[0]]=(int(p[2]),p[6])
  except Exception: pass
  return m

def user_uid_map(): return {k:v[0] for k,v in passwd_map().items()}

def shadow_map():
  m={}
  try:
    for l in open("/etc/shadow"):
      p=l.rstrip("\n").split(":")
      if len(p)>=8: m[p[0]]=(p[1],p[7])
  except Exception: pass
  return m

def read_limits_db():
  lim={}
  if os.path.exists(DB):
    for l in open(DB):
      p=l.strip().split()
      if len(p)>=2 and p[1].isdigit(): lim[p[0]]=int(p[1])
  return lim

def write_limits_db(ls):
  open(DB,"w").write("\n".join(f"{k} {v}" for k,v in ls.items())+("\n" if ls else ""))

def newm(l): return {"q":0,"u":0,"pt":"All","pw":"","lim":l}

def fmt_traffic(ub):
  if ub<=0: return "0 MB"
  mb=ub/1048576.0
  if mb<1024: return f"{round(mb,2 if mb<10 else 1)} MB"
  return f"{round(ub/1073741824.0,2)} GB"

# ---------- session detection ----------
def _on_map():
  um=user_uid_map()
  sessions={u:[] for u in um}; io_pids={u:set() for u in um}
  _,o,_=cmd(["ps","-eo","pid,ppid,user:32,comm,args","--no-headers"])
  rows=[]; masters=set()
  for l in o.splitlines():
    p=l.split(None,4)
    if len(p)<4 or not p[0].isdigit() or not p[1].isdigit(): continue
    pid,ppid,usr,comm=int(p[0]),int(p[1]),p[2],p[3]
    args=p[4] if len(p)>4 else ""
    rows.append((pid,ppid,usr,comm,args))
    if ppid==1 and comm in ("sshd","dropbear"): masters.add(pid)

  for pid,ppid,usr,comm,args in rows:
    if usr in um:
      io_pids[usr].add(pid)
      if ppid>1 and ppid not in masters: io_pids[usr].add(ppid)
      if comm.startswith("sshd") or comm=="dropbear":
        sessions[usr].append(pid)
      elif comm.startswith("sshplus-shell"):
        sp=ppid if ppid>1 else pid
        if sp not in sessions[usr]: sessions[usr].append(sp)
    elif usr=="root" and comm.startswith("sshd"):
      for u in um:
        if re.search(rf"sshd(?:-session)?:\s+{re.escape(u)}(\s|\[|@|$)",args):
          io_pids[u].add(pid)
          if "[priv]" in args and pid not in sessions[u]: sessions[u].append(pid)

  # one OpenSSH connection = one session (priv + child)
  for u in um:
    if len(sessions[u])>1:
      ss=set(sessions[u])
      f=[pid for pid,ppid,_,_,_ in rows if pid in ss and ppid not in ss]
      if f: sessions[u]=f

  # Dropbear tunnel-only sessions: find the user from the journal
  workers=[pid for pid,ppid,_,comm,_ in rows if comm=="dropbear" and pid not in masters]
  wset=set(workers); now=time.time()
  for k in [k for k in DBU if k not in wset]: DBU.pop(k,None)
  for k in [k for k in DBT if k not in wset]: DBT.pop(k,None)
  unknown=[p for p in workers if p not in DBU and now-DBT.get(p,0)>15]
  if unknown:
    for p in unknown: DBT[p]=now
    _,j,_=cmd(["journalctl","-u","sshplus-dropbear","-u","sshplus-dropbear-t","-n","3000","--no-pager","-o","cat"],20)
    for jl in j.splitlines():
      mt=re.search(r"\[(\d+)\].*Password auth succeeded for '([^']+)'",jl)
      if mt: DBU[int(mt.group(1))]=mt.group(2)
  for dpid in workers:
    u=DBU.get(dpid)
    if u in um:
      io_pids[u].add(dpid)
      if dpid not in sessions[u]: sessions[u].append(dpid)
  return ({k:v for k,v in sessions.items() if v},{k:list(v) for k,v in io_pids.items() if v})

def on_map(force=False):
  with LOCK:
    now=time.time()
    if not force and CACHE["v"] is not None and now-CACHE["t"]<2: return CACHE["v"]
    v=_on_map(); CACHE["t"]=now; CACHE["v"]=v
    return v

def kill_pid(pid):
  cmd(["pkill","-9","-P",str(pid)]); cmd(["kill","-9",str(pid)])

# ---------- BBR ----------
def sysctl_get(k):
  rc,o,_=cmd(["sysctl","-n",k]); return o if rc==0 else ""

def bbr_state():
  avail=sysctl_get("net.ipv4.tcp_available_congestion_control").split()
  if "bbr" not in avail:
    cmd(["modprobe","tcp_bbr"]); avail=sysctl_get("net.ipv4.tcp_available_congestion_control").split()
  return {"cc":sysctl_get("net.ipv4.tcp_congestion_control"),"qdisc":sysctl_get("net.core.default_qdisc"),
          "avail":"bbr" in avail,"on":sysctl_get("net.ipv4.tcp_congestion_control")=="bbr"}

def bbr_set(on):
  if on:
    if not bbr_state()["avail"]: return False,"BBR is not supported by this kernel"
    os.makedirs("/etc/modules-load.d",exist_ok=True)
    open("/etc/modules-load.d/sshplus-bbr.conf","w").write("tcp_bbr\n")
    open(BBRF,"w").write("net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n")
    cmd(["sysctl","-w","net.core.default_qdisc=fq"]); cmd(["sysctl","-w","net.ipv4.tcp_congestion_control=bbr"])
  else:
    open(BBRF,"w").write("net.core.default_qdisc=fq_codel\nnet.ipv4.tcp_congestion_control=cubic\n")
    cmd(["sysctl","-w","net.core.default_qdisc=fq_codel"]); cmd(["sysctl","-w","net.ipv4.tcp_congestion_control=cubic"])
  return True,""

# ---------- stats & users ----------
def stats():
  try:
    l1=float(open("/proc/loadavg").read().split()[0])
    cpu=min(100.0,round((l1/(os.cpu_count() or 1))*100,1))
  except Exception: cpu=0.0
  try:
    mi={l.split()[0].rstrip(":"):int(l.split()[1]) for l in open("/proc/meminfo") if len(l.split())>=2}
    tot=mi.get("MemTotal",1); mem=round(((tot-mi.get("MemAvailable",0))/tot)*100,1)
  except Exception: mem=0.0
  rx=tx=0
  try:
    for l in open("/proc/net/dev").readlines()[2:]:
      p=l.replace(":"," ").split()
      if p and p[0]!="lo": rx+=int(p[1]); tx+=int(p[9])
  except Exception: pass
  om,_=on_map()
  return {"cpu":cpu,"mem":mem,"rx":round(rx/1048576,1),"tx":round(tx/1048576,1),
          "bv":cmd(["systemctl","is-active","badvpn"])[0]==0,
          "bvt":cmd(["systemctl","is-active","badvpn-t"])[0]==0,
          "db":cmd(["systemctl","is-active","sshplus-dropbear"])[0]==0,
          "dbt":cmd(["systemctl","is-active","sshplus-dropbear-t"])[0]==0,
          "on_tot":sum(len(v) for v in om.values()),"om":{k:len(v) for k,v in om.items()}}

def get_users(om):
  pm=passwd_map(); um=pm; lim=read_limits_db(); meta=rjson(META,{}); sh=shadow_map()
  today=int(time.time()//86400); res=[]
  for u in sorted(um):
    hs,ex=sh.get(u,("",""))
    if ex.isdigit():
      es=(datetime(1970,1,1)+timedelta(days=int(ex))).strftime("%Y-%m-%d"); dl=max(0,int(ex)-today); expd=int(ex)<=today
    else: es="Never"; dl=0; expd=False
    m=meta.get(u,{}); q=float(m.get("q",0)); ub=int(m.get("u",0))
    res.append({"u":u,"pw":m.get("pw",""),"lim":int(m.get("lim",lim.get(u,1))),"on":om.get(u,0),"exp":es,"dl":dl,
                "expd":expd,"q":q,"ugb":fmt_traffic(ub),"qfull":(q>0 and ub>=int(q*1073741824)),
                "pt":str(m.get("pt","All")),"tm":"tunnel" if pm[u][1]==SHELL_T else "direct","en":"B" if m.get("en")=="B" else "A"})
  return res

def refresh_lock(u):
  hs,ex=shadow_map().get(u,("",""))
  m=rjson(META,{}).get(u,{}); q=float(m.get("q",0)); used=int(m.get("u",0))
  over=(q>0 and used>=int(q*1073741824)) or (ex.isdigit() and int(ex)<=int(time.time()//86400))
  if over and not hs.startswith("!"): cmd(["usermod","-L",u])
  if not over and hs.startswith("!"): cmd(["usermod","-U",u])

def user_save(d):
  u=str(d.get("u","")).strip(); pw=str(d.get("pw","")).strip(); edit=bool(d.get("edit"))
  days=int(float(d.get("d") or 0)); lim=max(1,int(float(d.get("l") or 1)))
  q=max(0.0,float(d.get("q") or 0)); pt=str(d.get("pt","All"))[:40]
  if not NAME_RE.match(u) or u in ("root","admin","ubuntu","nobody"): return 400,{"ok":0,"msg":"Invalid username"}
  if ":" in pw or "\n" in pw: return 400,{"ok":0,"msg":"Invalid password"}
  pm=passwd_map(); um=pm
  if edit and u not in um: return 404,{"ok":0,"msg":"User not found"}
  if not edit and not pw: return 400,{"ok":0,"msg":"Password required"}
  if not edit and days<=0: days=30
  cur=pm.get(u,(0,SHELL))[1]; tmq=str(d.get("tm",""))
  shl=SHELL_T if tmq=="tunnel" else (SHELL if tmq=="direct" else cur)       # account type = login shell
  if shl==SHELL_T and cur!=SHELL_T and not tconf().get("TUN_HOST"):
    return 400,{"ok":0,"msg":"Tunnel is not set up yet (open the Tunnel tab first)"}
  enq=str(d.get("en","")).upper()
  en="B" if enq=="B" else ("A" if enq=="A" else rjson(META,{}).get(u,{}).get("en","A"))   # A = this server, B = second server
  if en=="B":
    if not tconf().get("TUN_HOST"): return 400,{"ok":0,"msg":"Entry via the second server needs the tunnel (open the Tunnel tab first)"}
    if tconf().get("ROUTE","both")=="forward":                       # old v1.2.0 install: switch forwarding on
      c2,r2=tunnel_route_apply("both")
      if c2!=200: return 400,{"ok":0,"msg":"Could not enable entry via the second server: "+str(r2.get("msg",""))}
  ea=["-e",(datetime.utcnow()+timedelta(days=days)).strftime("%Y-%m-%d")] if days>0 else []
  if edit: rc,_,er=cmd(["usermod","-s",shl]+ea+[u])
  else: rc,_,er=cmd(["useradd","-M","-s",shl]+ea+[u])
  if rc!=0: return 400,{"ok":0,"msg":er or "Failed"}
  if os.path.exists(TNET): cmd([TNET,"sync"])
  if edit and shl!=cur:                       # type changed: cut live sessions so they reconnect on the right path
    _,io=on_map(True)
    for pid in io.get(u,[]): kill_pid(pid)
  if pw:
    r=subprocess.run(["chpasswd"],input=f"{u}:{pw}\n",text=True,capture_output=True,env=ENV)
    if r.returncode!=0:
      if not edit: cmd(["userdel","-f",u])
      return 400,{"ok":0,"msg":(r.stderr or "chpasswd failed")[:120]}
  with ML:
    ls=read_limits_db(); ls[u]=lim; write_limits_db(ls)
    meta=rjson(META,{}); m=meta.setdefault(u,newm(lim))
    m["q"]=q; m["pt"]=pt; m["lim"]=lim; m["en"]=en
    if pw: m["pw"]=pw
    if d.get("rst"): m["u"]=0
    wjson(META,meta)
  refresh_lock(u)
  return 200,{"ok":1}

def user_del(d):
  u=str(d.get("u","")).strip()
  if u not in user_uid_map(): return 404,{"ok":0,"msg":"User not found"}
  _,io=on_map(True)
  for pid in io.get(u,[]): kill_pid(pid)
  cmd(["pkill","-9","-u",u]); cmd(["userdel","-f",u])
  with ML:
    ls=read_limits_db(); ls.pop(u,None); write_limits_db(ls)
    meta=rjson(META,{}); meta.pop(u,None); wjson(META,meta)
  if os.path.exists(TNET): cmd([TNET,"sync"])
  return 200,{"ok":1}

# ---------- ports & BadVPN ----------
def apply_ports(d):
  old=rjson(PORTS,{"ssh":22,"ssh2":2222,"db":[]})
  s1=to_port(d.get("ssh")) or 22; s2=to_port(d.get("ssh2"))
  ssh_set={22,s1}|({s2} if s2 else set())
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053
  bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  managed={22,to_port(old.get("ssh")),to_port(old.get("ssh2"))}
  extra=sshd_ports()-managed-ssh_set          # e.g. 9011, defined outside the panel
  reserved=ssh_set|extra|{panel,bvp,bvp+1,2053}|foreign_ports()
  db=[]; dropped=[]
  for x in d.get("db",[]):
    if str(x).strip()=="": continue
    v=to_port(x)
    if v and v not in reserved and v not in db: db.append(v)
    else: dropped.append(str(x))
  db=db[:6]
  if not db: return 400,{"ok":0,"msg":"At least one valid Dropbear port is required"}
  tdb=[]                                       # Dropbear ports of the tunnel instance
  for x in (d["tdb"] if "tdb" in d else old.get("tdb",[])):
    if str(x).strip()=="": continue
    v=to_port(x)
    if v and v not in reserved and v not in db and v not in tdb: tdb.append(v)
    else: dropped.append(str(x))
  tdb=tdb[:4]
  if not tdb: return 400,{"ok":0,"msg":"At least one valid tunnel Dropbear port is required"}
  bak=open(SSHCONF).read() if os.path.exists(SSHCONF) else None
  lines=[f"Port {x}" for x in sorted(ssh_set)]+[
    "PasswordAuthentication yes","PermitRootLogin yes","UsePAM yes","AllowTcpForwarding yes",
    "AllowStreamLocalForwarding yes","AllowAgentForwarding yes","GatewayPorts yes","PermitTunnel yes",
    "TCPKeepAlive yes","ClientAliveInterval 30","ClientAliveCountMax 10","MaxSessions 100","MaxStartups 100:30:200"]
  open(SSHCONF,"w").write("\n".join(lines)+"\n")
  rc,_,er=cmd(["sshd","-t"])
  if rc!=0:
    if bak is not None: open(SSHCONF,"w").write(bak)
    return 400,{"ok":0,"msg":"sshd config invalid: "+er[:120]}
  wjson(PORTS,{"ssh":s1,"ssh2":s2,"db":db,"tdb":tdb}); SSHP["t"]=0
  ufw_open(ssh_set|set(db)|set(tdb)|{panel})
  if cmd(["systemctl","reload","ssh"])[0]!=0: cmd(["systemctl","restart","ssh"])
  cmd(["systemctl","restart","sshplus-dropbear"]); cmd(["systemctl","restart","sshplus-dropbear-t"])
  if tconf().get("TUN_HOST"): threading.Thread(target=ports_sync,daemon=True).start()
  return 200,{"ok":1,"db":db,"tdb":tdb,"dropped":dropped}

def save_bv(d):
  p=to_port(d.get("p")) or 7300
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[]})
  used={22,2053,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|set(pc.get("db",[]))|set(pc.get("tdb",[]))|sshd_ports()
  if p in used or p+1 in used or p+1>65535: return 400,{"ok":0,"msg":"Port (or port+1, used by the tunnel UDPGW) is already used by SSH/Dropbear/panel"}
  m=min(max(int(float(d.get("m") or 1200)),576),1500)
  c=min(max(int(float(d.get("c") or 1000)),1),10000)
  n=min(max(int(float(d.get("n") or 64)),1),1000)
  b=str(d.get("b","127.0.0.1")); b=b if b in ("127.0.0.1","0.0.0.0") else "127.0.0.1"
  open(BV,"w").write(f"UDP_PORT={p}\nBIND_ADDR={b}\nUDP_MTU={m}\nMAX_CLIENTS={c}\nMAX_CONN={n}\nSEND_BUFFER=65536\nMSS_CLAMP=1\n")
  if b=="0.0.0.0": ufw_open({p})
  cmd(["systemctl","restart","badvpn"]); cmd(["systemctl","restart","badvpn-t"])
  if os.path.exists(TNET): cmd([TNET,"sync"])          # UDPGW redirect for tunnel accounts follows the new port
  return 200,{"ok":1}

# ---------- tunnel ----------
# Layer-3 SSH tunnel (ssh -w) between this server and an "exit" server.
# Tunnel accounts are routed through it (see sshplus-tunnel-net), direct accounts are not.
TCONF="/etc/SSHPlus/tunnel.conf"; TKEY="/etc/SSHPlus/tunnel_key"; TKH="/etc/SSHPlus/tunnel_known_hosts"
TNET="/usr/local/bin/sshplus-tunnel-net"; TUN_DEV="tun99"; TUN_ID=99; TUN_LOCAL="10.99.0.1"; TUN_REMOTE="10.99.0.2"
TS={"run":False,"steps":[],"ok":None}; TSL=threading.Lock(); CLI=[False]
HOST_RE=re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$"); TUSER_RE=re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
IP_RE=re.compile(r"^[0-9a-fA-F:.]{3,45}$")

# executed on the exit server (stdin of "bash -s")
REMOTE_SCRIPT=r'''set -e
export DEBIAN_FRONTEND=noninteractive
if [ "${SKIP_APT:-0}" != 1 ] && command -v apt-get >/dev/null 2>&1; then apt-get update -y -qq >/dev/null 2>&1 || true; fi
need=""
command -v ip >/dev/null 2>&1 || need="$need iproute2"
command -v iptables >/dev/null 2>&1 || need="$need iptables"
if [ -n "$need" ]; then
  command -v apt-get >/dev/null 2>&1 || { echo "missing:$need (apt-get not found)"; exit 11; }
  apt-get install -y -qq $need >/dev/null 2>&1 || { echo "cannot install:$need"; exit 11; }
fi
mkdir -p /etc/ssh/sshd_config.d
echo "PermitTunnel yes" > /etc/ssh/sshd_config.d/01-sshplus-tunnel.conf
CHK='^permittunnel (yes|point-to-point)'
if ! sshd -T 2>/dev/null | grep -qiE "$CHK"; then
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.sshplus.bak
  sed -i '1i PermitTunnel yes' /etc/ssh/sshd_config
fi
if ! sshd -t 2>/dev/null; then
  rm -f /etc/ssh/sshd_config.d/01-sshplus-tunnel.conf
  [ -f /etc/ssh/sshd_config.sshplus.bak ] && cp -a /etc/ssh/sshd_config.sshplus.bak /etc/ssh/sshd_config
  echo "sshd config invalid after change (rolled back)"; exit 12
fi
sshd -T 2>/dev/null | grep -qiE "$CHK" || { echo "PermitTunnel could not be enabled"; exit 12; }
(systemctl reload ssh || systemctl reload sshd) >/dev/null 2>&1 || true
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/98-sshplus-exit.conf
# ports of THIS server that are forwarded through the tunnel to the panel server ("enter via exit server" routing)
if [ "${REV_PORTS+x}" = x ]; then printf '%s\n' "$REV_PORTS" > /etc/sshplus-exit.ports; fi
cat > /usr/local/bin/sshplus-exit.sh <<'XEOF'
#!/bin/bash
r() { t=$1; c=$2; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$@"; }
sysctl -qw net.ipv4.ip_forward=1
r nat POSTROUTING -s 10.99.0.0/30 ! -o tun99 -j MASQUERADE
r filter FORWARD -i tun99 -j ACCEPT
r filter FORWARD -o tun99 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
r mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# reverse entry: users connect to THIS server's IP, the connection is carried through the tunnel to the panel server
iptables -t nat -N SSHPLUS_REV 2>/dev/null; iptables -t nat -F SSHPLUS_REV
iptables -N SSHPLUS_REVF 2>/dev/null; iptables -F SSHPLUS_REVF
iptables -t nat -C PREROUTING -j SSHPLUS_REV 2>/dev/null || iptables -t nat -I PREROUTING -j SSHPLUS_REV
iptables -C FORWARD -j SSHPLUS_REVF 2>/dev/null || iptables -I FORWARD -j SSHPLUS_REVF
sk=""; ok=""
# entries are "bport:aport" (this server's public port : port on the panel server); a bare number means the same on both
for e in $(tr ',' ' ' < /etc/sshplus-exit.ports 2>/dev/null); do
  case "$e" in *:*) bp=${e%%:*}; ap=${e##*:};; *) bp=$e; ap=$e;; esac
  case "$bp$ap" in ''|*[!0-9]*) continue;; esac
  [ "$bp" -ge 1 ] && [ "$bp" -le 65535 ] && [ "$ap" -ge 1 ] && [ "$ap" -le 65535 ] || continue
  # never take over a port this server itself uses (admin SSH on 22, any service already listening)
  if [ "$bp" = 22 ] || ss -ltnH "sport = :$bp" 2>/dev/null | grep -q .; then sk="$sk $bp:$ap"; continue; fi
  iptables -t nat -A SSHPLUS_REV -p tcp --dport "$bp" -j DNAT --to-destination "10.99.0.1:$ap"
  iptables -A SSHPLUS_REVF -o tun99 -p tcp --dport "$ap" -j ACCEPT
  ok="$ok $bp:$ap"
done
[ -n "$ok" ] && r nat POSTROUTING -o tun99 -j MASQUERADE
echo "REV_OK:${ok# }"; echo "REV_SKIPPED:${sk# }"
XEOF
chmod 755 /usr/local/bin/sshplus-exit.sh
cat > /etc/systemd/system/sshplus-exit.service <<'XEOF'
[Unit]
Description=SSH Plus exit-server NAT for the tunnel
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sshplus-exit.sh
[Install]
WantedBy=multi-user.target
XEOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable sshplus-exit.service >/dev/null 2>&1 || true
EXITOUT=$(/usr/local/bin/sshplus-exit.sh)
printf '%s\n' "$EXITOUT"
# firewall of THIS (exit) server: open the published ports
okp=$(printf '%s\n' "$EXITOUT" | sed -n 's/^REV_OK://p')
FWB=none
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  FWB=ufw; for t in $okp; do ufw allow "${t%%:*}/tcp" >/dev/null 2>&1; done
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  FWB=firewalld; for t in $okp; do firewall-cmd --permanent --add-port="${t%%:*}/tcp" >/dev/null 2>&1; firewall-cmd --add-port="${t%%:*}/tcp" >/dev/null 2>&1; done
fi
echo "FW_B:$FWB"
echo SSHPLUS_REMOTE_OK
'''

def tconf():
  d={}
  try:
    for l in open(TCONF):
      if "=" in l:
        k,v=l.strip().split("=",1); d[k]=v
  except Exception: pass
  return d

def tconf_write(d):
  t=TCONF+".t"
  with open(t,"w") as f: f.write("".join(f"{k}={v}\n" for k,v in d.items()))
  os.chmod(t,0o600); os.replace(t,TCONF)

def tun_users():
  return sorted(u for u,(_,sh) in passwd_map().items() if sh==SHELL_T)

def tunnel_status(full=False):
  c=tconf(); conf=bool(c.get("TUN_HOST"))
  svc=conf and cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0
  up=bool(svc) and cmd(["ip","link","show",TUN_DEV])[0]==0
  r={"conf":conf,"host":c.get("TUN_HOST",""),"port":to_port(c.get("TUN_PORT",22)) or 22,"user":c.get("TUN_USER",""),
     "exit":c.get("EXIT_IP",""),"since":int(c.get("SINCE","0") or 0),"svc":bool(svc),"up":up,
     "route":"both","rev_ports":[int(x) for x in c.get("REV_PORTS","").split(",") if x.isdigit()],
     "rev_skipped":[int(x) for x in c.get("REV_SKIPPED","").split(",") if x.isdigit()],
     "rev_map":[{"a":int(a),"b":int(b)} for a,b in (x.split(":",1) for x in c.get("REV_MAP","").split(",") if ":" in x) if a.isdigit() and b.isdigit()]}
  if full:
    if up:
      r["up"]=cmd(["ping","-c","1","-W","2","-I",TUN_DEV,TUN_REMOTE],6)[0]==0
    r["tdb"]=rjson(PORTS,{}).get("tdb",[]); r["users"]=tun_users(); r["setup"]=ts_snap()
  return r

# --- progress log of the one-click setup
def ts_snap():
  with TSL: return {"run":TS["run"],"ok":TS["ok"],"steps":[dict(x) for x in TS["steps"]]}

def ts_begin(m):
  with TSL: TS["steps"].append({"m":m,"s":"run","d":""})
  if CLI[0]: print("  ... "+m,flush=True)

def ts_end(ok,d=""):
  st={True:"ok",False:"err","warn":"warn"}[ok]
  with TSL:
    if TS["steps"]: TS["steps"][-1]["s"]=st; TS["steps"][-1]["d"]=str(d)[:400]
  if CLI[0]: print(f"      [{st.upper()}] {d}" if d else f"      [{st.upper()}]",flush=True)

def _scrub(t,pw):
  t=str(t or "")
  return t.replace(pw,"***") if pw else t

def _run(c,inp=None,env=None,t=60):
  try:
    r=subprocess.run(c,input=inp,capture_output=True,text=True,timeout=t,env=env or ENV)
    return r.returncode,r.stdout.strip(),r.stderr.strip()
  except Exception as e: return 1,"",str(e)

def _ssh_o(port,key=True):
  o=["-F","/dev/null","-p",str(port),"-o","LogLevel=ERROR","-o","ConnectTimeout=15","-o","ServerAliveInterval=10",
     "-o","GlobalKnownHostsFile=/dev/null","-o","UserKnownHostsFile="+TKH]
  if key: o+=["-i",TKEY,"-o","BatchMode=yes","-o","StrictHostKeyChecking=yes"]
  else: o+=["-o","StrictHostKeyChecking=accept-new","-o","PubkeyAuthentication=no",
            "-o","PreferredAuthentications=password,keyboard-interactive","-o","NumberOfPasswordPrompts=1"]
  return o

def tun_exit_ip():
  urls=[os.environ["SSHPLUS_IPCHECK_URL"]] if os.environ.get("SSHPLUS_IPCHECK_URL") else \
       ["https://api.ipify.org","https://ifconfig.me/ip","https://icanhazip.com"]
  for u in urls:
    rc,o,_=cmd(["curl","-s","--max-time","8","--interface",TUN_LOCAL,u],12)
    if rc==0 and IP_RE.match(o.strip()): return o.strip()
  return ""

def tunnel_rollback():
  cmd(["systemctl","disable","--now","sshplus-tunnel"])
  for f in (TCONF,TKH):
    try: os.remove(f)
    except OSError: pass
  cmd([TNET,"down"])

def tunnel_setup_run(host,port,user,pw):
  with TSL: TS["run"]=True; TS["steps"]=[]; TS["ok"]=None
  tgt=f"{user}@{host}"; ctx={}
  old_route="both"
  def S(m,fn):
    ts_begin(m)
    try: ok,d=fn()
    except Exception as e: ok,d=False,str(e)
    ts_end(ok,_scrub(d,pw)); return ok is not False
  def f_tools():
    need=("ssh","ssh-keygen","sshpass","ip","iptables","curl","ping")
    if shutil.which("apt-get",path=ENV["PATH"]): _run(["apt-get","update","-y"],t=300)   # prerequisite on this server
    if [c for c in need if not shutil.which(c,path=ENV["PATH"])]:
      _run(["apt-get","install","-y","sshpass","openssh-client","iproute2","iptables","curl","iputils-ping"],t=300)
    miss=[c for c in need if not shutil.which(c,path=ENV["PATH"])]
    return (False,"missing: "+", ".join(miss)) if miss else (True,"")
  def f_key():
    if not os.path.exists(TKEY):
      rc,_,er=_run(["ssh-keygen","-q","-t","ed25519","-N","","-f",TKEY,"-C","sshplus-tunnel"])
      if rc!=0: return False,er
    os.chmod(TKEY,0o600); ctx["pub"]=open(TKEY+".pub").read().strip()
    return True,""
  def f_login():
    try: os.remove(TKH)
    except OSError: pass
    env=dict(ENV); env["SSHPASS"]=pw
    rem='K=$(cat); umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF "$K" ~/.ssh/authorized_keys || echo "$K" >> ~/.ssh/authorized_keys; id -u'
    rc,o,er=_run(["sshpass","-e","ssh"]+_ssh_o(port,False)+[tgt,rem],inp=ctx["pub"]+"\n",env=env,t=60)
    if rc==5 or "Permission denied" in er: return False,"رمز عبور یا نام کاربری اشتباه است (wrong password/user)"
    if rc!=0: return False,"اتصال SSH برقرار نشد: "+(er or o or "rc=%d"%rc)[-250:]
    if o.strip().splitlines()[-1:]!=["0"]: return False,"کاربر باید root باشد (برای ساخت کارت شبکه تانل)"
    return True,"کلید SSH روی سرور مقصد نصب شد (رمز ذخیره نمی‌شود)"
  def f_verify():
    rc,o,er=_run(["ssh"]+_ssh_o(port)+[tgt,"echo ok"],t=40)
    return (True,"") if rc==0 and o.endswith("ok") else (False,"ورود با کلید ناموفق: "+(er or o)[-250:])
  def f_remote():
    fixed=ports_autofix(); ufw_open(set(rjson(PORTS,{}).get("db",[]))|set(rjson(PORTS,{}).get("tdb",[])))   # this server first
    mp=rev_map_calc(rev_ports(),remote_listeners(host,port,user))
    ent=",".join("%d:%d"%(b,a) for a,b in sorted(mp.items()))
    rc,o,er=_run(["ssh"]+_ssh_o(port)+[tgt,"bash -s"],inp="export REV_PORTS=%s\n"%ent+REMOTE_SCRIPT,t=400)
    if rc!=0 or "SSHPLUS_REMOTE_OK" not in o: return False,(o.splitlines()[-1:] or [er or "failed"])[0][-250:]
    ctx["okm"]={}; ctx["sk"]=[]
    for l in o.splitlines():
      if l.startswith("REV_OK:"):
        for t in l.split(":",1)[1].split():
          b,_,a=t.partition(":")
          if a.isdigit() and b.isdigit(): ctx["okm"][int(a)]=int(b)
      elif l.startswith("REV_SKIPPED:"): ctx["sk"]=[t.partition(":")[2] for t in l.split(":",1)[1].split()]
    if fixed: return True,"تداخل پورت روی این سرور رفع شد: "+", ".join("%d←%d"%(c["from"],c["to"]) for c in fixed)
    return True,"PermitTunnel + ip_forward + NAT روی سرور مقصد فعال شد"
  def f_local():
    tconf_write({"TUN_HOST":host,"TUN_PORT":port,"TUN_USER":user,"TUN_DEV":TUN_DEV,"TUN_ID":TUN_ID,
                 "TUN_LOCAL":TUN_LOCAL,"TUN_REMOTE":TUN_REMOTE,"SINCE":int(time.time()),"ROUTE":old_route,
                 "REV_PORTS":",".join(map(str,sorted(ctx.get("okm",{})))),
                 "REV_MAP":",".join("%d:%d"%(a,b) for a,b in sorted(ctx.get("okm",{}).items())),
                 "REV_SKIPPED":",".join(ctx.get("sk",[]))})
    cmd([TNET,"sync"]); cmd(["systemctl","daemon-reload"])
    cmd(["systemctl","enable","sshplus-tunnel"]); cmd(["systemctl","restart","sshplus-tunnel"],30)
    return True,""
  def f_wait():
    for _ in range(40):
      if cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0 and \
         cmd(["ping","-c","1","-W","2","-I",TUN_DEV,TUN_REMOTE],6)[0]==0:
        return True,f"{TUN_LOCAL} <-> {TUN_REMOTE}"
      time.sleep(1)
    _,j,_=cmd(["journalctl","-u","sshplus-tunnel","-n","4","--no-pager","-o","cat"],10)
    return False,"تانل بالا نیامد: "+j[-250:]
  def f_exit():
    ip=tun_exit_ip()
    if not ip: return "warn","تانل برقرار است ولی تست اینترنت از مسیر تانل جواب نداد (سرور مقصد اینترنت دارد؟)"
    c=tconf(); c["EXIT_IP"]=ip; tconf_write(c)
    return True,"IP خروجی تانل: "+ip
  try:
    steps=[("بررسی ابزارهای لازم",f_tools),("ساخت کلید SSH مخصوص تانل",f_key),
           (f"اتصال به {host}:{port} با رمز و نصب کلید",f_login),("تست ورود با کلید",f_verify),
           ("آماده‌سازی سرور مقصد (PermitTunnel / فوروارد / NAT)",f_remote)]
    ok=True
    for m,f in steps:
      if not S(m,f): ok=False; break
    if ok:
      for m,f in [("راه‌اندازی تانل روی این سرور",f_local),("انتظار برای برقراری تانل",f_wait)]:
        if not S(m,f): ok=False; tunnel_rollback(); break
    if ok: S("تست خروجی اینترنت از مسیر تانل",f_exit)
  except Exception as e:
    ok=False; ts_begin("خطای داخلی"); ts_end(False,_scrub(e,pw))
  with TSL: TS["ok"]=bool(ok); TS["run"]=False
  return bool(ok)

def rev_ports():
  # panel-server ports that can be reached through the exit server's IP: Dropbear ports (direct + tunnel) + 2nd OpenSSH port
  pc=rjson(PORTS,{}); out=[]
  for x in list(pc.get("db",[]))+list(pc.get("tdb",[]))+[pc.get("ssh2",0)]:
    v=to_port(x)
    if v and v!=22 and v not in out: out.append(v)
  return out

def ports_autofix():
  # Dropbear ports (direct + tunnel) that another program already listens on are replaced by free ports
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[],"tdb":[]}); lis=listen_ports(); foreign=foreign_ports()
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053; bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  used=set(lis)|{22,panel,2053,bvp,bvp+1,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|sshd_ports()|set(pc.get("db",[]))|set(pc.get("tdb",[]))
  changes=[]
  for key in ("db","tdb"):
    out=[]
    for x in pc.get(key,[]):
      v=to_port(x)
      if v and v in foreign:
        q=next((q for q in range(v+1,min(v+500,65535)) if q not in used),0)
        if q:
          used.add(q); out.append(q)
          changes.append({"from":v,"to":q,"kind":key,"by":",".join(sorted(lis.get(v,[])))}); continue
      out.append(x)
    pc[key]=out
  if changes:
    wjson(PORTS,pc); SSHP["t"]=0
    ufw_open({c["to"] for c in changes})
    cmd(["systemctl","restart","sshplus-dropbear"]); cmd(["systemctl","restart","sshplus-dropbear-t"])
  return changes

def remote_listeners(host,port,user):
  # TCP ports the exit server already listens on (None if it cannot be asked)
  rc,o,_=_run(["ssh"]+_ssh_o(port)+[f"{user}@{host}","ss -ltnH"],t=40)
  if rc!=0: return None
  res=set()
  for l in o.splitlines():
    f=l.split(); m=re.search(r":(\d+)$",f[3]) if len(f)>=4 else None
    if m: res.add(int(m.group(1)))
  return res

def rev_map_calc(aports,blis):
  # this server's port -> port on the exit server. Same number whenever it is free there; otherwise a nearby free one
  used=set(blis or ())|{22}; m={}
  for p in aports:
    if p not in used: m[p]=p; used.add(p)
  for p in aports:
    if p in m: continue
    for q in [p+10000,p-10000]+list(range(p+1,p+400)):
      if 0<q<65536 and q not in used: m[p]=q; used.add(q); break
  return m

def tunnel_push(mapping,host=None,port=None,user=None):
  # (re)applies the exit-server side: NAT, the forwards {a_port: b_port} and the exit server's firewall
  c=tconf(); host=host or c.get("TUN_HOST",""); port=port or to_port(c.get("TUN_PORT",22)) or 22; user=user or c.get("TUN_USER","root")
  ent=",".join("%d:%d"%(b,a) for a,b in sorted(mapping.items()))
  pre="export SKIP_APT=1 REV_PORTS=%s\n"%ent
  rc,o,er=_run(["ssh"]+_ssh_o(port)+[f"{user}@{host}","bash -s"],inp=pre+REMOTE_SCRIPT,t=120)
  if rc!=0 or "SSHPLUS_REMOTE_OK" not in o: return False,{},[],"",(o.splitlines()[-1:] or [er or "failed"])[0][-200:]
  okm={}; sk=[]; fw="none"
  for l in o.splitlines():
    if l.startswith("REV_OK:"):
      for t in l.split(":",1)[1].split():
        b,_,a=t.partition(":")
        if a.isdigit() and b.isdigit(): okm[int(a)]=int(b)
    elif l.startswith("REV_SKIPPED:"):
      sk=[int(t.partition(":")[2]) for t in l.split(":",1)[1].split() if t.partition(":")[2].isdigit()]
    elif l.startswith("FW_B:"): fw=l.split(":",1)[1].strip() or "none"
  return True,okm,sk,fw,""

def tunnel_route_apply(mode):
  c=tconf()
  if not c.get("TUN_HOST"): return 400,{"ok":0,"msg":"Tunnel is not set up"}
  if mode=="reverse": mode="both"
  if mode not in ("forward","both"): return 400,{"ok":0,"msg":"Invalid routing mode"}
  ports=rev_ports() if mode=="both" else []
  mapping={}
  if ports:
    port=to_port(c.get("TUN_PORT",22)) or 22
    mapping=rev_map_calc(ports,remote_listeners(c.get("TUN_HOST",""),port,c.get("TUN_USER","root")))
  ok,okm,sk,fw,er=tunnel_push(mapping)
  if not ok: return 400,{"ok":0,"msg":"Exit server: "+er}
  c=tconf(); c["ROUTE"]=mode; c["REV_PORTS"]=",".join(map(str,sorted(okm)))
  c["REV_MAP"]=",".join("%d:%d"%(a,b) for a,b in sorted(okm.items())); c["REV_SKIPPED"]=",".join(map(str,sk)); tconf_write(c)
  return 200,{"ok":1,"map":[{"a":a,"b":b} for a,b in sorted(okm.items())],"skipped":sk,"fw_b":fw}

def ports_sync():
  # 1) conflicts on this server  2) conflicts / mapping on the exit server  3) firewalls of BOTH servers
  rep={"ok":1,"a_changes":ports_autofix(),"map":[],"skipped":[],"fw_b":"-"}
  pc=rjson(PORTS,{})
  rep["fw_a"]=ufw_open(set(pc.get("db",[]))|set(pc.get("tdb",[]))|sshd_ports())
  if tconf().get("TUN_HOST"):
    c,r=tunnel_route_apply("both")
    if r.get("ok"): rep["map"]=r["map"]; rep["skipped"]=r["skipped"]; rep["fw_b"]=r.get("fw_b","none")
    else: rep["err"]=r.get("msg","")
  return 200,rep

def tunnel_params(d):
  host=str(d.get("host","")).strip(); port=to_port(d.get("port") or 22); user=str(d.get("user") or "root").strip()
  pw=str(d.get("pw","")).replace("\r","").replace("\n","")
  if not HOST_RE.match(host): return None,(400,{"ok":0,"msg":"Invalid server address"})
  if not port: return None,(400,{"ok":0,"msg":"Invalid SSH port"})
  if not TUSER_RE.match(user): return None,(400,{"ok":0,"msg":"Invalid SSH user"})
  if not pw: return None,(400,{"ok":0,"msg":"Password required"})
  return (host,port,user,pw),None

def tunnel_setup_start(d):
  p,err=tunnel_params(d)
  if err: return err
  with TSL:
    if TS["run"]: return 409,{"ok":0,"msg":"Setup is already running"}
    TS["run"]=True; TS["steps"]=[]; TS["ok"]=None
  threading.Thread(target=tunnel_setup_run,args=p,daemon=True).start()
  return 200,{"ok":1}

def tunnel_restart():
  if not tconf().get("TUN_HOST"): return 400,{"ok":0,"msg":"Tunnel is not set up"}
  cmd(["systemctl","restart","sshplus-tunnel"],30)
  return 200,{"ok":1}

def tunnel_test():
  if not tconf().get("TUN_HOST"): return 400,{"ok":0,"msg":"Tunnel is not set up"}
  if cmd(["ping","-c","1","-W","2","-I",TUN_DEV,TUN_REMOTE],6)[0]!=0: return 200,{"ok":0,"msg":"Tunnel link is down"}
  ip=tun_exit_ip()
  if not ip: return 200,{"ok":0,"msg":"Link is up but there is no internet through the tunnel"}
  c=tconf(); c["EXIT_IP"]=ip; tconf_write(c)
  return 200,{"ok":1,"ip":ip}

def tunnel_remove():
  if TS["run"]: return 409,{"ok":0,"msg":"Setup is running"}
  if tconf().get("TUN_HOST"):
    try: tunnel_push({})                # take the forwarded ports back on the exit server
    except Exception: pass
  _,io=on_map(True); n=0
  for u,(_,sh) in passwd_map().items():
    if sh==SHELL_T:                     # keep these accounts alive as direct accounts
      cmd(["usermod","-s",SHELL,u]); n+=1
      for pid in io.get(u,[]): kill_pid(pid)
  tunnel_rollback()
  if os.path.exists(TNET): cmd([TNET,"sync"])
  with TSL: TS["steps"]=[]; TS["ok"]=None
  return 200,{"ok":1,"converted":n}

# ---------- monitor ----------
def mon():
  n=0
  while True:
    try:
      if n%5==0:
        svs=["sshplus-dropbear","sshplus-dropbear-t","badvpn","badvpn-t"]
        if tconf().get("TUN_HOST"): svs.append("sshplus-tunnel")
        for srv in svs:
          if cmd(["systemctl","is-active",srv])[0]!=0:
            cmd(["systemctl","reset-failed",srv]); cmd(["systemctl","restart",srv])
      n+=1
      if n==4: threading.Thread(target=ports_sync,daemon=True).start()     # once per panel start / update
      if n%10==1 and os.path.exists(TNET): cmd([TNET,"sync"])     # keep uid rules in line with the accounts
      sessions,io_pids=on_map(True)
      um=user_uid_map(); sh=shadow_map(); lim=read_limits_db(); today=int(time.time()//86400)
      with ML:
        meta=rjson(META,{}); ch=False; active=set()
        for u,pids in io_pids.items():
          m=meta.setdefault(u,newm(lim.get(u,1)))
          for pid in pids:
            active.add(pid)
            try:
              io={}
              for l in open(f"/proc/{pid}/io"):
                k,_,v=l.partition(":"); io[k]=int(v)
              cur=(io.get("rchar",0)+io.get("wchar",0))//2
            except Exception: continue
            prv=PIDS.get(pid,cur if STATE["first"] else 0); PIDS[pid]=cur
            if cur>prv: m["u"]=int(m.get("u",0))+(cur-prv); ch=True
        STATE["first"]=False
        for dead in [k for k in PIDS if k not in active]: PIDS.pop(dead,None)
        for u in um:
          m=meta.setdefault(u,newm(lim.get(u,1)))
          hs,ex=sh.get(u,("",""))
          q=float(m.get("q",0)); used=int(m.get("u",0))
          over=(q>0 and used>=int(q*1073741824)) or (ex.isdigit() and int(ex)<=today)
          if over:
            if not hs.startswith("!"): cmd(["usermod","-L",u])
            for pid in io_pids.get(u,[]): kill_pid(pid)
            continue
          ulim=max(1,int(m.get("lim",lim.get(u,1))))
          sp=sorted(sessions.get(u,[]))
          if len(sp)>ulim:
            for old in sp[:-ulim]: kill_pid(old)     # oldest sessions are cut first
        if ch: wjson(META,meta)
    except Exception: pass
    time.sleep(3)

# ---------- HTTP ----------
class Srv(ThreadingHTTPServer):
  allow_reuse_address=True; daemon_threads=True; request_queue_size=64

class H(BaseHTTPRequestHandler):
  def log_message(s,*a): pass
  def js(s,d,c=200):
    b=json.dumps(d).encode("utf-8")
    s.send_response(c); s.send_header("Content-Type","application/json; charset=utf-8")
    s.send_header("Content-Length",str(len(b))); s.end_headers(); s.wfile.write(b)
  def auth(s):
    a=s.headers.get("Authorization","")
    return a.startswith("Bearer ") and TOK.get(a[7:].strip(),0)>time.time()
  def do_GET(s):
    try:
      p=urlparse(s.path).path
      if p in ("/","/index.html"):
        b=open(HTML,"rb").read()
        s.send_response(200); s.send_header("Content-Type","text/html;charset=utf-8")
        s.send_header("Content-Length",str(len(b))); s.end_headers(); s.wfile.write(b); return
      if not s.auth(): s.js({"err":1},401); return
      if p=="/api/overview":
        st=stats(); bv=read_bv()
        pc=rjson(PORTS,{"ssh":22,"ssh2":2222,"db":[]}); pc["ssh_all"]=sorted(sshd_ports()); pc.setdefault("tdb",[])
        adm=str(rjson(CFG,{"username":"admin"}).get("username","admin")).strip()
        s.js({"st":st,"ports":pc,"bv":bv,"bbr":bbr_state(),"adm":adm,"tun":tunnel_status(False),"users":get_users(st["om"])}); return
      if p=="/api/tunnel": s.js(tunnel_status(True)); return
      s.js({"err":404},404)
    except Exception as e:
      try: s.js({"err":str(e)[:100]},500)
      except Exception: pass
  def do_POST(s):
    try:
      p=urlparse(s.path).path; ln=int(s.headers.get("Content-Length",0))
      try: d=json.loads(s.rfile.read(ln).decode("utf-8")) if ln>0 else {}
      except Exception: d={}
      if p=="/api/login":
        c=rjson(CFG,{"username":"admin","password":"admin"})
        ip=s.client_address[0]; now=time.time()
        FAIL[ip]=[t for t in FAIL.get(ip,[]) if now-t<300]
        if len(FAIL[ip])>=5: s.js({"err":2},429); return
        in_u=str(d.get("u","")).strip(); in_p=str(d.get("p","")).strip()
        cu=str(c.get("username","admin")).strip(); cp=str(c.get("password","admin")).strip()
        if in_u.lower()==cu.lower() and secrets.compare_digest(in_p.encode(),cp.encode()):
          t=secrets.token_hex(16); TOK[t]=time.time()+86400; s.js({"tok":t})
        else:
          FAIL[ip].append(time.time()); s.js({"err":1},401)
        return
      if not s.auth(): s.js({"err":1},401); return
      if p=="/api/user/save": c,r=user_save(d); s.js(r,c)
      elif p=="/api/user/del": c,r=user_del(d); s.js(r,c)
      elif p=="/api/ports": c,r=apply_ports(d); s.js(r,c)
      elif p=="/api/badvpn": c,r=save_bv(d); s.js(r,c)
      elif p=="/api/bbr":
        ok,msg=bbr_set(bool(d.get("on")))
        s.js({"ok":1 if ok else 0,"msg":msg,"bbr":bbr_state()},200 if ok else 400)
      elif p=="/api/tunnel/setup": c,r=tunnel_setup_start(d); s.js(r,c)
      elif p=="/api/tunnel/route": c,r=tunnel_route_apply(str(d.get("mode",""))); s.js(r,c)
      elif p=="/api/tunnel/ports": c,r=ports_sync(); s.js(r,c)
      elif p=="/api/tunnel/restart": c,r=tunnel_restart(); s.js(r,c)
      elif p=="/api/tunnel/test": c,r=tunnel_test(); s.js(r,c)
      elif p=="/api/tunnel/remove": c,r=tunnel_remove(); s.js(r,c)
      elif p=="/api/admin":
        c=rjson(CFG,{"port":2053,"username":"admin","password":"admin"})
        au=str(d.get("u","")).strip() or str(c.get("username","admin")).strip()
        ap=str(d.get("p","")).strip() or str(c.get("password","admin")).strip()
        if len(au)>=2 and len(ap)>=2:
          c["username"]=au; c["password"]=ap; wjson(CFG,c)
          t=secrets.token_hex(16); TOK[t]=time.time()+86400
          s.js({"ok":1,"u":au,"p":ap,"tok":t})
        else: s.js({"ok":0,"msg":"Min 2 chars"},400)
      else: s.js({"err":404},404)
    except Exception as e:
      try: s.js({"ok":0,"msg":str(e)[:100]},400)
      except Exception: pass

def cli_tunnel_setup(host,port,user):
  p,err=tunnel_params({"host":host,"port":port,"user":user,"pw":"x"})
  if err: print(err[1]["msg"]); return 1
  pw=getpass.getpass(f"Password of {user}@{host}: ")
  if not pw: print("Password required"); return 1
  CLI[0]=True; print(f"Setting up the tunnel to {host}:{p[1]} ...")
  ok=tunnel_setup_run(host,p[1],user,pw)
  print("Tunnel is UP" if ok else "FAILED (nothing was changed for your users)")
  return 0 if ok else 1

if __name__=="__main__":
  if len(sys.argv)>=5 and sys.argv[1]=="--tunnel-setup": sys.exit(cli_tunnel_setup(sys.argv[2],sys.argv[3],sys.argv[4]))
  open(DB,"a").close()
  threading.Thread(target=mon,daemon=True).start()
  c=rjson(CFG,{})
  Srv((str(c.get("bind","0.0.0.0")),int(c.get("port",2053))),H).serve_forever()
PYEOF
chmod 755 /opt/sshplus-panel/app.py
python3 -m py_compile /opt/sshplus-panel/app.py || { echo "FAILED: app.py syntax error"; exit 1; }
echo "=== STEP 3 OK ==="
}

# ------------------------------------------------------------------------------
step4() {
echo ">>> [4/4] Panel UI + start services"
cat > /opt/sshplus-panel/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CK.VPN</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 48 48'%3E%3Crect width='48' height='48' rx='12' fill='%2306b6d4'/%3E%3Ctext x='24' y='31' text-anchor='middle' font-family='Arial' font-weight='800' font-size='19' fill='white'%3ECK%3C/text%3E%3C/svg%3E">
<style>
:root{--bg:#0b1120;--card:#111827;--bd:#1f2937;--tx:#f3f4f6;--mu:#9ca3af;--pr:#06b6d4;--ok:#10b981;--er:#ef4444;--wn:#f59e0b}
*{box-sizing:border-box;margin:0;padding:0;font-family:system-ui,Tahoma,sans-serif}
body{background:var(--bg);color:var(--tx);padding:1rem;max-width:1280px;margin:auto}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:1.1rem;margin-bottom:1rem}
.g4{display:grid;grid-template-columns:repeat(auto-fit,minmax(195px,1fr));gap:.75rem;margin-bottom:1rem}
.g2{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:1rem;margin-bottom:1rem}
input,select{width:100%;background:#080c17;border:1px solid var(--bd);color:var(--tx);padding:.55rem;border-radius:8px;margin:.25rem 0 .7rem}
label{font-size:.8rem;color:var(--mu)}
.btn{background:var(--pr);color:#031116;border:none;padding:.55rem 1rem;border-radius:8px;font-weight:700;cursor:pointer}
.btn-s{padding:.35rem .65rem;font-size:.8rem}.btn-e{background:var(--er);color:#fff}.btn-w{background:var(--wn);color:#000}.btn-o{background:var(--ok);color:#03130c}
.tab-bar{display:flex;gap:.6rem;margin-bottom:1rem;border-bottom:1px solid var(--bd);padding-bottom:.75rem}
.tab-btn{background:var(--card);color:var(--mu);border:1px solid var(--bd);padding:.6rem 1.2rem;border-radius:10px;font-weight:700;cursor:pointer;flex:1;text-align:center}
.tab-btn.act{background:rgba(6,182,212,.15);color:var(--pr);border-color:var(--pr)}
.bdg{padding:.2rem .6rem;border-radius:99px;font-size:.75rem;font-weight:700;display:inline-block}
.ok{background:rgba(16,185,129,.15);color:var(--ok)}.er{background:rgba(239,68,68,.15);color:var(--er)}.wn{background:rgba(245,158,11,.15);color:var(--wn)}
table{width:100%;border-collapse:collapse;font-size:.86rem}th,td{padding:.6rem;text-align:start;border-bottom:1px solid var(--bd)}
.hid{display:none!important}.modal{position:fixed;inset:0;background:rgba(0,0,0,.82);display:flex;align-items:center;justify-content:center;padding:1rem;z-index:99}
.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:.5rem}
</style>
</head>
<body>
<div id="lBox" class="modal"><div class="card" style="width:100%;max-width:350px">
  <div style="display:flex;flex-direction:column;align-items:center;gap:.4rem;margin-bottom:.9rem"><svg width="56" height="56" viewBox="0 0 48 48" role="img" aria-label="CK.VPN"><defs><linearGradient id="lg2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#06b6d4"/><stop offset="1" stop-color="#6366f1"/></linearGradient></defs><rect width="48" height="48" rx="12" fill="url(#lg2)"/><path d="M11 31a13 13 0 0 1 26 0" fill="none" stroke="#fff" stroke-opacity=".4" stroke-width="3" stroke-linecap="round"/><circle cx="11" cy="31" r="2.6" fill="#fff"/><circle cx="37" cy="31" r="2.6" fill="#fff"/><text x="24" y="30" text-anchor="middle" font-family="system-ui,Arial,sans-serif" font-weight="800" font-size="18" fill="#fff">CK</text></svg><h3 style="color:var(--pr)">CK.VPN</h3><div style="font-size:.72rem;color:var(--mu)" dir="ltr">Panel Login · v__VERSION__</div></div>
  <label>Username</label><input id="lu" value="admin" autocapitalize="none" autocorrect="off">
  <label>Password</label><input id="lp" type="password" value="admin" autocapitalize="none" onkeydown="if(event.key==='Enter')login()">
  <button class="btn" style="width:100%" onclick="login()">ورود / Login</button>
</div></div>

<div id="eBox" class="modal hid"><div class="card" style="width:100%;max-width:420px">
  <h3 id="eTit" style="color:var(--pr);margin-bottom:.8rem">ویرایش کاربر</h3>
  <input type="hidden" id="eu">
  <label>رمز جدید (خالی = بدون تغییر)</label><input id="epw" autocapitalize="none">
  <div style="display:flex;gap:.5rem">
    <div style="flex:1"><label><bdi dir="ltr">In</bdi> — به کدام سرور وصل شود</label><select id="een" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
    <div style="flex:1"><label><bdi dir="ltr">Out</bdi> — با IP کدام سرور خارج شود</label><select id="eex" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
  </div>
  <div id="eHint" style="font-size:.78rem;color:var(--mu);margin:-.2rem 0 .3rem;line-height:1.8"></div>
  <div style="font-size:.72rem;color:var(--wn);margin:0 0 .6rem">با تغییر In/Out اتصال‌های فعال این کاربر قطع می‌شوند.</div>
  <label>پورت پیشنهادی (فقط برای نمایش/کپی)</label><select id="ept"></select>
  <div style="display:flex;gap:.5rem">
    <div style="flex:1"><label>حجم (GB | 0=نامحدود)</label><input id="eq" type="number" step="0.5" min="0"></div>
    <div style="flex:1"><label>کاربر همزمان</label><input id="el" type="number" min="1"></div>
  </div>
  <label>تمدید: اعتبار از امروز (روز) — خالی/۰ = بدون تغییر</label><input id="ed" type="number" min="0" placeholder="0">
  <label style="display:flex;align-items:center;gap:.4rem;margin-bottom:.8rem;color:var(--wn)"><input type="checkbox" id="erst" style="width:auto;margin:0"> صفر کردن ترافیک مصرفی</label>
  <div style="display:flex;gap:.5rem"><button class="btn" style="flex:1" onclick="saveUser(1)">ذخیره</button><button class="btn btn-e" onclick="$('eBox').classList.add('hid')">بستن</button></div>
</div></div>

<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.8rem;flex-wrap:wrap;gap:.5rem">
  <div style="display:flex;align-items:center;gap:.7rem"><svg width="42" height="42" viewBox="0 0 48 48" role="img" aria-label="CK.VPN"><defs><linearGradient id="lg1" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#06b6d4"/><stop offset="1" stop-color="#6366f1"/></linearGradient></defs><rect width="48" height="48" rx="12" fill="url(#lg1)"/><path d="M11 31a13 13 0 0 1 26 0" fill="none" stroke="#fff" stroke-opacity=".4" stroke-width="3" stroke-linecap="round"/><circle cx="11" cy="31" r="2.6" fill="#fff"/><circle cx="37" cy="31" r="2.6" fill="#fff"/><text x="24" y="30" text-anchor="middle" font-family="system-ui,Arial,sans-serif" font-weight="800" font-size="18" fill="#fff">CK</text></svg><div><h2 style="line-height:1.1;letter-spacing:.5px">CK.VPN <span id="ver" class="bdg ok" style="font-size:.62rem;vertical-align:middle;letter-spacing:0" dir="ltr" title="Panel version">v__VERSION__</span></h2><div style="font-size:.72rem;color:var(--mu)">SSH · Dropbear · BadVPN · Tunnel</div></div></div>
  <div>
    <button class="btn btn-s" onclick="document.documentElement.dir=document.documentElement.dir==='rtl'?'ltr':'rtl'">FA / EN</button>
    <button class="btn btn-s" onclick="load(1)">🔄</button>
    <button class="btn btn-s btn-e" onclick="localStorage.removeItem('tok');location.reload()">Logout</button>
  </div>
</div>

<div class="tab-bar">
  <button id="bTabU" class="tab-btn act" onclick="swTab('u')">👥 کاربران</button>
  <button id="bTabT" class="tab-btn" onclick="swTab('t')">🌐 تانل</button>
  <button id="bTabS" class="tab-btn" onclick="swTab('s')">⚙️ تنظیمات سرور</button>
</div>

<div id="secU">
  <div class="card" style="border-color:var(--pr);font-size:.88rem"><strong>🔌 پورت‌های فعال: </strong><span id="pBan">--</span></div>
  <div class="g4">
    <div class="card"><label>آنلاین / کل کاربران</label><h2 id="stU">0 / 0</h2></div>
    <div class="card"><label>Dropbear</label><div id="stDb" style="margin-top:.3rem">--</div></div>
    <div class="card"><label>BadVPN</label><div id="stBv" style="margin-top:.3rem">--</div></div>
    <div class="card"><label>تانل / Dropbear تانل</label><div id="stTn" style="margin-top:.3rem">--</div></div>
    <div class="card"><label>BBR / منابع</label><div id="stBbr" style="margin-top:.2rem">--</div><div id="stRes" style="font-size:.78rem;color:var(--mu);margin-top:.2rem">--</div></div>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.7rem">➕ ساخت کاربر جدید</h3>
    <div class="row">
      <div><label>نام کاربری (انگلیسی)</label><input id="nu" placeholder="user1" autocapitalize="none"></div>
      <div><label>رمز عبور</label><input id="npw" placeholder="123456" autocapitalize="none"></div>
      <div><label><bdi dir="ltr">In</bdi> — به کدام سرور وصل شود</label><select id="nen" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
      <div><label><bdi dir="ltr">Out</bdi> — با IP کدام سرور خارج شود</label><select id="nex" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
      <div><label>پورت پیشنهادی</label><select id="npt"></select></div>
      <div><label>حجم (GB | 0=نامحدود)</label><input id="nq" type="number" step="0.5" value="0" min="0"></div>
      <div><label>روز اعتبار</label><input id="nd" type="number" value="30" min="1"></div>
      <div><label>کاربر همزمان</label><input id="nl" type="number" value="1" min="1"></div>
    </div>
    <div id="nHint" style="font-size:.8rem;color:var(--mu);margin:.2rem 0 .7rem;line-height:1.8"></div>
    <button class="btn" onclick="saveUser(0)">ایجاد اکانت</button>
  </div>

  <div class="card" style="overflow-x:auto">
    <h3>📋 لیست کاربران</h3>
    <table>
      <thead><tr><th>User / Pass</th><th dir="ltr">In → Out</th><th>Port</th><th>Online / Limit</th><th>Traffic</th><th>Expires</th><th>Status</th><th>Actions</th></tr></thead>
      <tbody id="tb"></tbody>
    </table>
  </div>
</div>

<div id="secT" class="hid">
  <div class="g2">
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">🌐 وضعیت تانل</h3>
      <div id="tnStat" style="margin-bottom:.7rem">--</div>
      <div id="tnInfo" style="font-size:.85rem;line-height:1.9"></div>
      <div id="tnBtns" class="hid" style="display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.8rem">
        <button class="btn btn-s btn-o" onclick="tunTest()">🔍 تست خروجی</button>
        <button class="btn btn-s btn-w" onclick="tunRestart()">🔄 ری‌استارت تانل</button>
        <button class="btn btn-s btn-e" onclick="tunRemove()">🗑️ حذف تانل</button>
      </div>
    </div>
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">🚀 نصب و اتصال تانل (یک کلیک)</h3>
      <label>IP یا دامنه‌ی سرور جدید (خروجی)</label><input id="tnH" placeholder="1.2.3.4" autocapitalize="none" autocorrect="off">
      <div style="display:flex;gap:.5rem">
        <div style="flex:1"><label>پورت SSH</label><input id="tnP" type="number" value="22"></div>
        <div style="flex:1"><label>کاربر (باید root باشد)</label><input id="tnU" value="root" autocapitalize="none"></div>
      </div>
      <label>رمز SSH سرور جدید</label><input id="tnW" type="password" autocomplete="off" autocapitalize="none">
      <button id="tnGo" class="btn" style="width:100%" onclick="tunSetup()">⚡ نصب و برقراری تانل</button>
      <div style="font-size:.75rem;color:var(--mu);margin-top:.6rem;line-height:1.7">رمز فقط برای نصب کلید SSH استفاده می‌شود و ذخیره نمی‌شود. بعد از آن ارتباط با کلید است.<br>
      ⚠️ پنل روی HTTP ساده است؛ اگر نمی‌خواهی رمز سرور روی HTTP برود، در ترمینال این سرور بزن:<br><code dir="ltr">sshplus-tunnel-setup IP_SERVER [PORT] [USER]</code></div>
    </div>
  </div>
  <div class="card hid" id="tnBiBox">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">↔️ مسیر دوطرفه (همیشه فعال)</h3>
    <div id="tnBi" style="font-size:.85rem;line-height:1.9"></div>
    <div style="font-size:.78rem;color:var(--mu);margin-top:.5rem;line-height:1.8">موقع ساخت اکانت، ادمین دو انتخاب <bdi dir="ltr"><b>In</b></bdi> و <bdi dir="ltr"><b>Out</b></bdi> دارد: <bdi dir="ltr"><b>In</b></bdi> یعنی کاربر به IP کدام سرور وصل شود و <bdi dir="ltr"><b>Out</b></bdi> یعنی با IP کدام سرور به اینترنت برسد. هر چهار ترکیب (<span dir="ltr">1→1</span>، <span dir="ltr">1→2</span>، <span dir="ltr">2→1</span>، <span dir="ltr">2→2</span>) فعال است و UDPGW (بازی/تماس) روی همه‌ی آن‌ها کار می‌کند. نیازی به تنظیم مود جداگانه نیست.</div>
  </div>
  <div class="card hid" id="tnPortBox">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">🔌 هماهنگی پورت‌ها و فایروال دو سرور</h3>
    <div id="tnPorts" style="overflow-x:auto"></div>
    <button class="btn btn-s" style="margin-top:.7rem" onclick="tunPorts()">🔍 بررسی و رفع تداخل + به‌روزرسانی فایروال هر دو سرور</button>
    <div style="font-size:.75rem;color:var(--mu);margin-top:.5rem;line-height:1.8">اگر پورت Dropbear این سرور را برنامه‌ی دیگری گرفته باشد، خودکار با پورت آزاد عوض می‌شود. اگر پورتی روی سرور ۲ مشغول باشد، با شماره‌ی دیگری روی سرور ۲ منتشر می‌شود (پورت‌های این سرور و کانفیگ کلاینت‌های فعلی تغییر نمی‌کنند). فایروال (ufw یا firewalld) هر دو سرور برای پورت‌ها باز می‌شود. همین بررسی خودکار هم با هر راه‌اندازی پنل، نصب تانل و تغییر پورت انجام می‌شود.</div>
  </div>
  <div class="card" id="tnLogBox">
    <h3 style="margin-bottom:.6rem">📜 مراحل نصب</h3>
    <div id="tnLog" style="font-size:.85rem;line-height:1.9;color:var(--mu)">هنوز نصبی انجام نشده.</div>
  </div>
  <div class="card" style="font-size:.82rem;line-height:1.9;color:var(--mu)">
    <h3 style="margin-bottom:.5rem;color:var(--tx)">ℹ️ نحوه‌ی کار</h3>
    <bdi dir="ltr"><b>In</b></bdi> یعنی سروری که کاربر به IP آن وصل می‌شود و <bdi dir="ltr"><b>Out</b></bdi> یعنی سروری که IP آن در اینترنت دیده می‌شود. «سرور ۱» همین سرور است و «سرور ۲» سرور تانل.<br>
    ۱) وقتی <bdi dir="ltr"><b>Out</b></bdi> روی «سرور ۲» باشد، ترافیک از داخل تانل می‌گذرد. این اکانت روی پورت‌های <b>SSH (OpenSSH)</b> و <b>Dropbear تانل</b> کار می‌کند؛ پورت‌های Dropbear معمولی فقط برای اکانت‌هایی‌اند که <bdi dir="ltr"><b>Out</b></bdi> آن‌ها «سرور ۱» است. پورت‌ها در تب تنظیمات قابل تغییرند.<br>
    ۲) وقتی <bdi dir="ltr"><b>In</b></bdi> روی «سرور ۲» باشد، پورت‌های این سرور روی سرور ۲ باز می‌شوند و از داخل تانل به این سرور فوروارد می‌شوند. پورت ۲۲ و هر پورتی که سرور ۲ خودش رویش گوش می‌دهد هرگز دست نمی‌خورد؛ پس دسترسی ادمین به هر دو سرور و به پنل همیشه باز می‌ماند. فایروال سرور ۲ باید این پورت‌ها را باز کند و IP واقعی کاربر روی این سرور دیده نمی‌شود.<br>
    ۳) اگر تانل قطع شود، هر مسیری که از تانل می‌گذرد <b>بسته</b> می‌شود (به‌جای نشت از IP مستقیم). برقراری مجدد خودکار است.<br>
    ۴) UDPGW (بازی/تماس) روی هر چهار ترکیب کار می‌کند. وقتی <bdi dir="ltr"><b>Out</b></bdi> روی «سرور ۲» باشد از تانل می‌گذرد. کلاینت همان <span dir="ltr">127.0.0.1:7300</span> را استفاده می‌کند.<br>
    ۵) تانل روی SSH (TCP) است؛ برای سرعت بهتر BBR را روی هر دو سرور روشن نگه دار.
  </div>
</div>

<div id="secS" class="hid">
  <div class="g2">
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">🚀 BBR (کنترل ازدحام TCP)</h3>
      <div style="display:flex;gap:.5rem">
        <div style="flex:1"><label>الگوریتم فعلی</label><input id="bbrCc" readonly></div>
        <div style="flex:1"><label>Queue Discipline</label><input id="bbrQd" readonly></div>
      </div>
      <div id="bbrSt" style="margin-bottom:.7rem"></div>
      <button id="bbrBtn" class="btn" onclick="toggleBbr()">--</button>
      <div style="font-size:.75rem;color:var(--mu);margin-top:.6rem">روی اتصال‌های جدید اثر می‌گذارد؛ اتصال‌های فعلی تا اتصال مجدد با الگوریتم قبلی می‌مانند.</div>
    </div>
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">👤 نام کاربری و رمز ادمین پنل</h3>
      <label>نام کاربری ادمین</label><input id="au" autocapitalize="none" autocorrect="off">
      <label>رمز جدید ادمین</label><input id="ap" type="text" placeholder="New Password" autocapitalize="none" autocorrect="off">
      <button class="btn" onclick="saveAdm()">💾 ذخیره</button>
    </div>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.7rem">🔌 پورت‌های OpenSSH و Dropbear (حداکثر ۶ پورت)</h3>
    <div id="sshAll" style="font-size:.8rem;color:var(--mu);margin-bottom:.6rem"></div>
    <div class="row">
      <div><label>پورت SSH دوم</label><input id="s2" type="number"></div>
      <div><label>پورت SSH اصلی (پنل)</label><input id="s1" type="number"></div>
    </div>
    <div class="row">
      <div><label>Dropbear 1</label><input id="d1" type="number"></div>
      <div><label>Dropbear 2</label><input id="d2" type="number"></div>
      <div><label>Dropbear 3</label><input id="d3" type="number"></div>
      <div><label>Dropbear 4</label><input id="d4" type="number"></div>
      <div><label>Dropbear 5</label><input id="d5" type="number"></div>
      <div><label>Dropbear 6</label><input id="d6" type="number"></div>
    </div>
    <label style="display:block;margin:.4rem 0 .2rem">🌐 پورت‌های Dropbear مخصوص اکانت تانل (حداکثر ۴)</label>
    <div class="row">
      <div><label>Tunnel DB 1</label><input id="td1" type="number"></div>
      <div><label>Tunnel DB 2</label><input id="td2" type="number"></div>
      <div><label>Tunnel DB 3</label><input id="td3" type="number"></div>
      <div><label>Tunnel DB 4</label><input id="td4" type="number"></div>
    </div>
    <button class="btn btn-s" onclick="savePorts()">ذخیره پورت‌ها (اتصال‌های Dropbear لحظه‌ای قطع می‌شوند)</button>
    <h3 style="margin:1.2rem 0 .6rem">🎮 BadVPN UDPGW</h3>
    <div class="row">
      <div><label>پورت (TCP داخل تونل)</label><input id="bp" type="number"></div>
      <div><label>UDP MTU</label><input id="bm" type="number"></div>
      <div><label>Max Clients</label><input id="bc" type="number"></div>
      <div><label>Max Conn / Client</label><input id="bn" type="number"></div>
      <div><label>Bind</label><select id="bb"><option value="127.0.0.1">127.0.0.1 (امن)</option><option value="0.0.0.0">0.0.0.0 (عمومی)</option></select></div>
    </div>
    <button class="btn btn-s btn-w" onclick="saveBv()">ذخیره و ری‌استارت BadVPN</button>
  </div>
</div>

<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let tnCfg={};
let tok=localStorage.getItem("tok")||"", ul=[], pCfg={ssh:22,ssh2:0,db:[]}, bv={}, bbrOn=false, lastSig="";
function swTab(t){
  $("secU").classList.toggle("hid",t!=="u"); $("secS").classList.toggle("hid",t!=="s"); $("secT").classList.toggle("hid",t!=="t");
  $("bTabU").classList.toggle("act",t==="u"); $("bTabS").classList.toggle("act",t==="s"); $("bTabT").classList.toggle("act",t==="t");
  if(t==="t") loadTun();
}
function srvName(v){return v==="B"?"S2":"S1"}
function revMap(){const m={};(tnCfg.rev_map||[]).forEach(r=>{m[r.a]=r.b});return m}
function routeBadge(x){
  const inH=x.en==="B"?(tnCfg.host||"S2"):location.hostname, outH=x.tm==="tunnel"?(tnCfg.exit||tnCfg.host||"S2"):location.hostname;
  return `<span class="bdg ${(x.en==="B"||x.tm==="tunnel")?"wn":"ok"}" title="In: ${esc(inH)} | Out: ${esc(outH)}">${srvName(x.en)} → ${srvName(x.tm==="tunnel"?"B":"A")}</span>`;
}
function fillSrv(){
  ["nen","nex","een","eex"].forEach(id=>{
    const o=$(id).options; o[0].text="سرور ۱"; o[0].title=location.hostname;
    o[1].text=tnCfg.conf?"سرور ۲":"سرور ۲ (تانل نصب نیست)"; o[1].title=tnCfg.host||""; o[1].disabled=!tnCfg.conf;
    if(!tnCfg.conf&&$(id).value==="B") $(id).value="A";
  });
}
function fillPorts(cn,ce){
  const sk=tnCfg.rev_skipped||[];
  const mk=(en,ex)=>{
    const db=(ex==="B"?(pCfg.tdb||[]):(pCfg.db||[]));
    if(en==="B"){const mp=revMap(), s2=(pCfg.ssh2&&pCfg.ssh2!=22)?[pCfg.ssh2]:[]; return portOpts(s2.map(p=>mp[p]).filter(Boolean),db.map(p=>mp[p]).filter(Boolean))}
    return portOpts((pCfg.ssh_all&&pCfg.ssh_all.length)?pCfg.ssh_all:[22],db);
  };
  const n=cn!==undefined?cn:$("npt").value, e=ce!==undefined?ce:$("ept").value;
  $("npt").innerHTML=mk($("nen").value,$("nex").value); $("ept").innerHTML=mk($("een").value,$("eex").value);
  if([...$("npt").options].some(o=>o.value===n)) $("npt").value=n;
  if([...$("ept").options].some(o=>o.value===e)) $("ept").value=e;
  const ip=v=>v==="B"?(tnCfg.host||"سرور ۲"):location.hostname, xp=v=>v==="B"?(tnCfg.exit||tnCfg.host||"سرور ۲"):location.hostname;
  const hint=(en,ex)=>`کاربر به <b dir="ltr">${esc(ip(en))}</b> وصل می‌شود و با IP <b dir="ltr">${esc(xp(ex))}</b> به اینترنت می‌رسد.`;
  $("nHint").innerHTML=hint($("nen").value,$("nex").value); $("eHint").innerHTML=hint($("een").value,$("eex").value);
}
async function api(u,m="GET",b=null){
  const o={method:m,headers:{"Authorization":"Bearer "+tok}};
  if(b){o.headers["Content-Type"]="application/json";o.body=JSON.stringify(b)}
  const r=await fetch(u,o);
  if(r.status===401){localStorage.removeItem("tok");$("lBox").classList.remove("hid");throw new Error("401")}
  return r.json();
}
async function login(){
  const r=await fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({u:$("lu").value.trim(),p:$("lp").value.trim()})});
  if(r.status===429){alert("تلاش‌های ناموفق زیاد؛ ۵ دقیقه صبر کنید");return}
  const j=await r.json();
  if(j.tok){tok=j.tok;localStorage.setItem("tok",tok);$("lBox").classList.add("hid");load(1)}else alert("نام کاربری یا رمز عبور اشتباه است");
}
function portOpts(sp,db){
  let o='<option value="All">همه پورت‌ها</option>';
  sp.forEach(p=>o+=`<option value="SSH:${p}">SSH: ${p}</option>`);
  db.forEach(p=>o+=`<option value="Dropbear:${p}">Dropbear: ${p}</option>`);
  return o;
}
async function load(force){
  let d; try{d=await api("/api/overview")}catch(e){return}
  ul=d.users||[]; pCfg=d.ports||pCfg; bv=d.bv||{}; const bb=d.bbr||{};
  bbrOn=!!bb.on;
  const sp=(pCfg.ssh_all&&pCfg.ssh_all.length)?pCfg.ssh_all:[22];
  const db=pCfg.db||[];
  $("stU").innerText=d.st.on_tot+" / "+ul.length;
  const tn=d.tun||{}; tnCfg=tn; fillSrv();
  $("stTn").innerHTML=(tn.conf?(tn.up?`<span class="bdg ok">TUNNEL UP</span> <span style="font-size:.75rem;color:var(--mu)">${esc(tn.exit||"")}</span>`:`<span class="bdg er">TUNNEL DOWN</span>`):`<span class="bdg wn">OFF</span>`)
    +" "+(d.st.dbt?`<span class="bdg ok">DB-T (${(pCfg.tdb||[]).join(",")})</span>`:`<span class="bdg er">DB-T STOPPED</span>`);
  $("stDb").innerHTML=d.st.db?`<span class="bdg ok">ACTIVE (${db.join(",")})</span>`:`<span class="bdg er">STOPPED</span>`;
  $("stBv").innerHTML=(d.st.bvt?"":'<span class="bdg er">UDPGW-T ✖</span> ')+(d.st.bv?`<span class="bdg ok">UDPGW ${esc(bv.BIND_ADDR||"")}:${esc(bv.UDP_PORT||7300)}</span>`:`<span class="bdg er">STOPPED</span>`);
  $("stBbr").innerHTML=bbrOn?`<span class="bdg ok">BBR ON</span>`:`<span class="bdg wn">${esc(bb.cc||"?")}</span>`;
  $("stRes").innerText=`CPU:${d.st.cpu}% | RAM:${d.st.mem}% | ↓${d.st.rx}M ↑${d.st.tx}M`;
  $("pBan").innerText=`OpenSSH: ${sp.join(", ")} | Dropbear: ${db.join(", ")} | Tunnel-Dropbear: ${(pCfg.tdb||[]).join(", ")} | UDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`;
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
    <td><b>${x.on}</b> / ${x.lim}</td>
    <td><b>${esc(x.ugb)}</b> / ${x.q>0?x.q+" GB":"∞"}</td>
    <td>${esc(x.exp)}</td>
    <td><span class="bdg ${x.qfull||x.expd?'er':'ok'}">${x.qfull?'Quota Full':x.expd?'Expired':'Active'}</span></td>
    <td style="display:flex;gap:.3rem;flex-wrap:wrap">
      <button class="btn btn-s" onclick="editU('${esc(x.u)}')">✏️</button>
      <button class="btn btn-s btn-w" onclick="copyU('${esc(x.u)}')">📋</button>
      <button class="btn btn-s btn-e" onclick="delU('${esc(x.u)}')">🗑️</button>
    </td></tr>`).join("");
}
function editU(u){
  const x=ul.find(i=>i.u===u); if(!x) return;
  $("eTit").innerText="ویرایش: "+x.u; $("eu").value=x.u; $("epw").value=x.pw||"";
  fillSrv(); $("een").value=x.en==="B"?"B":"A"; $("eex").value=x.tm==="tunnel"?"B":"A"; fillPorts(undefined,x.pt);
  $("eq").value=x.q||0; $("el").value=x.lim||1; $("ed").value=""; $("erst").checked=false; $("eBox").classList.remove("hid");
}
async function saveUser(edit){
  const b=edit?{edit:1,u:$("eu").value,pw:$("epw").value,pt:$("ept").value,en:$("een").value,tm:$("eex").value==="B"?"tunnel":"direct",q:$("eq").value,l:$("el").value,d:$("ed").value,rst:$("erst").checked}
              :{edit:0,u:$("nu").value,pw:$("npw").value,pt:$("npt").value,en:$("nen").value,tm:$("nex").value==="B"?"tunnel":"direct",q:$("nq").value,l:$("nl").value,d:$("nd").value};
  const r=await api("/api/user/save","POST",b);
  if(r.ok){$("eBox").classList.add("hid");$("nu").value="";$("npw").value="";load(0)}else alert(r.msg||"Error");
}
async function delU(u){if(confirm("Delete "+u+"?")){await api("/api/user/del","POST",{u});load(0)}}
async function savePorts(){
  const r=await api("/api/ports","POST",{ssh:$("s1").value,ssh2:$("s2").value,db:[1,2,3,4,5,6].map(i=>$("d"+i).value),tdb:[1,2,3,4].map(i=>$("td"+i).value)});
  if(!r.ok){alert(r.msg||"Error");return}
  alert("پورت‌ها ذخیره شد"+(r.dropped&&r.dropped.length?"\nنادیده گرفته شد (تکراری/رزرو): "+r.dropped.join(", "):""));
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
  const t=`Host/IP: ${host}\nIn: ${inB?"Server 2":"Server 1"} | Out: ${out?"Server 2":"Server 1"} (exit IP: ${exitIp})\nSSH Ports: ${ssh.join(", ")||"-"}\nDropbear Ports: ${dbl.join(", ")||"-"}\nUser: ${x.u}\nPass: ${x.pw}\nLimit: ${x.lim}\nQuota: ${x.q>0?x.q+" GB":"Unlimited"}\nUDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`;
  if(navigator.clipboard&&navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(()=>alert("Copied!"),()=>prompt("Copy:",t)); else prompt("Copy:",t);
}
async function loadTun(){
  let d; try{d=await api("/api/tunnel")}catch(e){return}
  const sp=d.setup||{steps:[]}; const run=!!sp.run;
  $("tnStat").innerHTML=!d.conf?'<span class="bdg wn">تانل نصب نشده</span>':(d.up?'<span class="bdg ok">🟢 متصل</span>':'<span class="bdg er">🔴 قطع / در حال اتصال</span>');
  $("tnInfo").innerHTML=d.conf?`سرور خروجی: <b dir="ltr">${esc(d.user)}@${esc(d.host)}:${esc(d.port)}</b><br>IP خروجی: <b dir="ltr">${esc(d.exit||"—")}</b><br>پورت‌های Dropbear تانل: <b dir="ltr">${esc((d.tdb||[]).join(", ")||"—")}</b><br>اکانت‌های تانل: <b>${(d.users||[]).length}</b>`:"هنوز تانلی تنظیم نشده. فرم کناری را پر کن.";
  $("tnBtns").classList.toggle("hid",!d.conf);
  $("tnBiBox").classList.toggle("hid",!d.conf);
  $("tnPortBox").classList.toggle("hid",!d.conf);
  if(d.conf){
    const kind=p=>(pCfg.tdb||[]).includes(p)?"Dropbear تانل":((pCfg.db||[]).includes(p)?"Dropbear":"SSH دوم");
    const rows=(d.rev_map||[]).map(r=>`<tr><td dir="ltr">${r.a}</td><td>${kind(r.a)}</td><td dir="ltr">${r.b}</td><td>${r.a===r.b?'<span class="bdg ok">هم‌شماره</span>':'<span class="bdg wn">جابه‌جا شد (مشغول بود)</span>'}</td></tr>`)
      .concat((d.rev_skipped||[]).map(p=>`<tr><td dir="ltr">${p}</td><td>${kind(p)}</td><td>—</td><td><span class="bdg er">منتشر نشد</span></td></tr>`)).join("");
    $("tnPorts").innerHTML=`<table><thead><tr><th>پورت سرور ۱</th><th>نوع</th><th>پورت روی سرور ۲</th><th>وضعیت</th></tr></thead><tbody>${rows||'<tr><td colspan="4" style="color:var(--mu)">هنوز پورتی منتشر نشده</td></tr>'}</tbody></table>`;
  }
  if(d.conf){
    const me=location.hostname;
    $("tnBi").innerHTML=`<div>سرور ۱ (این سرور): <b dir="ltr">${esc(me)}</b> &nbsp;|&nbsp; سرور ۲: <b dir="ltr">${esc(d.host)}</b> <span style="color:var(--mu)">(IP خروجی: <span dir="ltr">${esc(d.exit||d.host)}</span>)</span></div>`
      +`<div>پورت‌هایی که روی سرور ۲ به این سرور فوروارد شده‌اند: <b dir="ltr">${esc((d.rev_map||[]).map(r=>r.b).join(", ")||"—")}</b></div>`
      +((d.rev_skipped||[]).length?`<div style="color:var(--wn)">⚠️ این پورت‌ها روی سرور ۲ از قبل مشغول‌اند و فوروارد نشدند: <b dir="ltr">${esc(d.rev_skipped.join(", "))}</b></div>`:"");
  }
  $("tnGo").disabled=run; $("tnGo").innerText=run?"⏳ در حال نصب...":(d.conf?"♻️ نصب مجدد / تغییر سرور":"⚡ نصب و برقراری تانل");
  if(sp.steps.length){
    const ic={run:"⏳",ok:"✅",err:"❌",warn:"⚠️"}, cl={err:"var(--er)",warn:"var(--wn)"};
    $("tnLog").innerHTML=sp.steps.map(x=>`<div>${ic[x.s]||""} ${esc(x.m)}${x.d?`<div style="font-size:.78rem;padding-inline-start:1.5rem;color:${cl[x.s]||"var(--mu)"}">${esc(x.d)}</div>`:""}</div>`).join("")
      +(!run&&sp.ok===true?'<div style="color:var(--ok);margin-top:.5rem"><b>✔ تانل برقرار شد. در «ساخت کاربر» نوع اکانت را «تانل» انتخاب کن.</b></div>':"")
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
  (r.a_changes||[]).forEach(c=>m.push(`سرور ۱: پورت ${c.from} (مشغول توسط ${c.by||"برنامه‌ی دیگر"}) ← ${c.to}`));
  (r.map||[]).filter(x=>x.a!==x.b).forEach(x=>m.push(`سرور ۲: پورت ${x.a} مشغول بود ← منتشر شد روی ${x.b}`));
  if(!m.length) m.push("تداخلی پیدا نشد.");
  m.push(`فایروال سرور ۱: ${r.fw_a||"-"} | سرور ۲: ${r.fw_b||"-"}`);
  if(r.err) m.push("خطا: "+r.err);
  alert(m.join("\n")); load(1); loadTun();
}
async function tunTest(){const r=await api("/api/tunnel/test","POST",{}); alert(r.ok?("تانل سالم است. IP خروجی: "+r.ip):(r.msg||"Error")); loadTun()}
async function tunRestart(){const r=await api("/api/tunnel/restart","POST",{}); alert(r.ok?"ری‌استارت شد؛ چند ثانیه بعد وضعیت را ببین":(r.msg||"Error")); loadTun()}
async function tunRemove(){
  if(!confirm("تانل حذف شود؟ اکانت‌های تانل به «مستقیم» تبدیل می‌شوند."))return;
  const r=await api("/api/tunnel/remove","POST",{});
  alert(r.ok?("تانل حذف شد. اکانت‌های تبدیل‌شده به مستقیم: "+(r.converted||0)):(r.msg||"Error")); load(1); loadTun();
}
if(tok){$("lBox").classList.add("hid");load(1)}
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid"))load(0)},4000);
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid")&&!$("secT").classList.contains("hid"))loadTun()},2000);
</script>
</body>
</html>
HTMLEOF
sed -i "s/__VERSION__/$VERSION/g" /opt/sshplus-panel/index.html

# firewall: only if ufw is active
FWP="$(sshd -T 2>/dev/null | awk '/^port /{print $2}') 2053 $(python3 -c 'import json;d=json.load(open("/etc/SSHPlus/ports.json"));print(" ".join(map(str,d["db"]+d.get("tdb",[]))))')"
if ufw status 2>/dev/null | grep -q '^Status: active'; then
  for p in $FWP; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  for p in $FWP; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1; done
  firewall-cmd --reload >/dev/null 2>&1
fi

systemctl reset-failed sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel-net sshplus-tunnel badvpn badvpn-t 2>/dev/null || true
systemctl enable sshplus-panel sshplus-dropbear sshplus-dropbear-t sshplus-tunnel-net badvpn badvpn-t >/dev/null 2>&1
systemctl restart sshplus-tunnel-net
systemctl restart sshplus-dropbear sshplus-dropbear-t badvpn badvpn-t sshplus-panel
# a tunnel configured by a previous run keeps working after an update
if [ -f /etc/SSHPlus/tunnel.conf ]; then
  systemctl enable sshplus-tunnel >/dev/null 2>&1
  systemctl restart sshplus-tunnel
fi
sleep 2

IP=$(curl -sfL --max-time 4 https://api.ipify.org || hostname -I | awk '{print $1}')
echo "=========================================="
echo "Panel:     $(systemctl is-active sshplus-panel)"
echo "Dropbear:  $(systemctl is-active sshplus-dropbear)   (tunnel instance: $(systemctl is-active sshplus-dropbear-t))"
if [ -f /etc/SSHPlus/tunnel.conf ]; then echo "Tunnel:    $(systemctl is-active sshplus-tunnel)"; else echo "Tunnel:    not set up (Panel -> Tunnel tab, or: sshplus-tunnel-setup EXIT_IP)"; fi
echo "BadVPN:    $(systemctl is-active badvpn)   (tunnel instance: $(systemctl is-active badvpn-t))"
echo "SSH:       $(systemctl is-active ssh)"
echo "BBR:       $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
echo "--- listening:"
ss -tlnp | grep -E 'dropbear|badvpn|python3|sshd' | awk '{print $4, $6}'
echo "Version:   $VERSION"
echo "Panel URL: http://${IP}:2053  (admin / admin)"
echo "=========================================="
}

# ------------------------------------------------------------------------------
mkdir -p /var/log/sshplus
# SSHPLUS_LIB=1 only loads the functions (used for testing)
if [ -z "$SSHPLUS_LIB" ]; then
  step1
  step2
  step3
  step4
fi
