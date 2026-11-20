#!/usr/bin/env bash
# ==============================================================================
#  SSH Plus Panel v1.7.0  -  OpenSSH + Dropbear (6 ports) + BadVPN UDPGW + BBR
#                            + Tunnel (SSH tun to an exit server, one-click)
#                            + SSH over TLS (stunnel, domain + Let's Encrypt from the panel)
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
VERSION="1.7.0"
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
apt-get install -y python3 git cmake build-essential dropbear-bin openssh-server openssh-client sshpass openssl python3-cryptography python3-qrcode iptables iproute2 psmisc procps kmod >>$LOG 2>&1
# SSH over TLS front. Optional here: the panel installs it on demand when TLS is switched on. Its own generic service is not used.
apt-get install -y stunnel4 >>$LOG 2>&1 || echo "WARN: stunnel4 نصب نشد؛ هنگام روشن‌کردن TLS از پنل نصب می‌شود"
systemctl disable --now stunnel4 >/dev/null 2>&1 || true
# WireGuard tunnel type (fast, UDP): the tools are small; the panel installs them on demand if this fails
apt-get install -y wireguard-tools >>$LOG 2>&1 || echo "WARN: wireguard-tools نصب نشد؛ هنگام انتخاب WireGuard از پنل نصب می‌شود"
for c in python3 dropbear dropbearkey cmake git sshpass ssh-keygen ip iptables openssl; do
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
for s in sshplus-stunnel sshplus-dropbear-s sshplus-dropbear-ts sshplus-dropbear sshplus-dropbear-t badvpn badvpn-t sshplus-panel; do systemctl stop $s >/dev/null 2>&1 || true; done

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
# account = type (direct/tunnel) x connection (both/normal/tls): -t tunnel, -n normal only, -s TLS only, -tn / -ts the tunnel variants
ALLSH="sshplus-shell sshplus-shell-t sshplus-shell-n sshplus-shell-tn sshplus-shell-s sshplus-shell-ts"
for s in $ALLSH; do
  [ "$s" = sshplus-shell ] || install -m 755 /usr/local/bin/sshplus-shell /usr/local/bin/$s
  grep -qxF "/usr/local/bin/$s" /etc/shells || echo "/usr/local/bin/$s" >> /etc/shells
done
# per-instance /etc/shells (bind-mounted into each Dropbear service): an instance only accepts the account shells it serves
shells_file() { local kind=$1; shift; { grep -vxF -f <(printf '/usr/local/bin/%s\n' $ALLSH) /etc/shells; printf '/usr/local/bin/%s\n' "$@"; } > /etc/SSHPlus/shells.$kind; }
shells_file direct sshplus-shell   sshplus-shell-n      # plain ports, direct accounts
shells_file tunnel sshplus-shell-t sshplus-shell-tn     # plain ports, tunnel accounts
shells_file tlsd   sshplus-shell   sshplus-shell-s      # TLS back end, direct accounts
shells_file tlst   sshplus-shell-t sshplus-shell-ts     # TLS back end, tunnel accounts

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
# usage: start-dropbear.sh direct|tunnel|tlsd|tlst
#   direct / tunnel : public ports from ports.json ("db" / "tdb")
#   tlsd   / tlst   : TLS back ends, bound to 127.0.0.1 only (stunnel is the public TLS front, tls.json "bd" / "bt").
#                     TLS_BACKENDS (6) Dropbear processes on consecutive ports: Dropbear refuses more than 5 unauthenticated
#                     connections per source IP and every TLS client reaches it from 127.0.0.1, so stunnel spreads them round-robin.
MODE="${1:-direct}"
mkdir -p /etc/dropbear
for t in rsa ecdsa ed25519; do
  f="/etc/dropbear/dropbear_${t}_host_key"
  [ -s "$f" ] || dropbearkey -t "$t" -f "$f" >/dev/null 2>&1
done
P=$(python3 - "$MODE" <<'PY'
import json,sys
mode=sys.argv[1]
if mode in ("tlsd","tlst"):
    key,dflt="bd" if mode=="tlsd" else "bt",40100 if mode=="tlsd" else 40120
    try: v=int(json.load(open("/etc/SSHPlus/tls.json")).get(key,dflt))
    except Exception: v=dflt
    print(v if 0<v<65500 else dflt)
    sys.exit(0)
key="tdb" if mode=="tunnel" else "db"
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
DB=(/usr/sbin/dropbear -F -E -w -K 30
  -r /etc/dropbear/dropbear_rsa_host_key
  -r /etc/dropbear/dropbear_ecdsa_host_key
  -r /etc/dropbear/dropbear_ed25519_host_key)
case "$MODE" in
  tlsd|tlst)
    TLS_BACKENDS=6
    for i in $(seq 0 $((TLS_BACKENDS-1))); do "${DB[@]}" -p 127.0.0.1:$((P+i)) & done
    trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
    wait -n                                   # one of them died: stop the rest, systemd restarts the unit
    kill $(jobs -p) 2>/dev/null; exit 1 ;;
  *) exec "${DB[@]}" $P ;;
esac
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
CG_DBS="system.slice/sshplus-dropbear-t.service system.slice/sshplus-dropbear-ts.service"      # tunnel Dropbear: normal + TLS back end
CGS="$CG_DBS system.slice/badvpn-t.service"
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
  for cg in $CG_DBS; do
    cgdir "$cg" || continue
    iptables -t nat -A SSHPLUS_UDPGW_C -p tcp -d 127.0.0.1 --dport "$UDP_PORT" -m cgroup --path "$cg" \
      -j DNAT --to-destination "127.0.0.1:$TUDP" || return 1
  done
}
up() {
  ip addr replace "$TUN_LOCAL/30" dev "$TUN_DEV"
  ip link set "$TUN_DEV" mtu "${TUN_MTU:-1400}" up
  sysctl -qw "net.ipv4.conf.$TUN_DEV.rp_filter=0" 2>/dev/null
  ip route replace default dev "$TUN_DEV" table $TBL metric 1
}
down() { ip route del default dev "$TUN_DEV" table $TBL metric 1 2>/dev/null; return 0; }
sync() {
local out uids u
out=$(python3 - "$TBL" "$PRIO_UID" <<'PY'
import subprocess,sys
tbl,prio=sys.argv[1],sys.argv[2]
SH={"/usr/local/bin/sshplus-shell-"+x for x in ("t","tn","ts")}        # tunnel accounts: both / normal only / TLS only
want=set()
for l in open("/etc/passwd"):
    p=l.rstrip("\n").split(":")
    if len(p)>=7 and p[6] in SH and p[2].isdigit(): want.add(int(p[2]))
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
EOF
chmod 755 /usr/local/bin/start-tunnel.sh

cat > /usr/local/bin/start-wg.sh <<'EOF'
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
EOF
chmod 755 /usr/local/bin/start-wg.sh

cat > /usr/local/bin/sshplus-tunnel-setup <<'EOF'
#!/bin/bash
# terminal version of the panel's Tunnel tab (the password is typed here instead of going through the panel's plain HTTP)
# usage: sshplus-tunnel-setup EXIT_SERVER_IP [SSH_PORT] [USER] [wg|ssh]     (wg = WireGuard, faster; ssh = the SSH tun tunnel)
[ -n "$1" ] || { echo "usage: sshplus-tunnel-setup EXIT_SERVER_IP [SSH_PORT=22] [USER=root] [wg|ssh=ssh]"; exit 1; }
exec python3 /opt/sshplus-panel/app.py --tunnel-setup "$1" "${2:-22}" "${3:-root}" "${4:-ssh}"
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

cat > /usr/local/bin/sshplus-tls-fw <<'EOF'
#!/bin/bash
# usage: sshplus-tls-fw apply|clean
# Per-client-IP limit on concurrent connections to the public TLS ports (own chain SSHPLUS_TLSLIM, nothing else is touched).
# stunnel sees the real client address, so this stops one host from filling the TLS front with half-open connections.
# Called by sshplus-stunnel.service (start / stop); the limit is tls.json "perip" (0 = no limit).
CH=SSHPLUS_TLSLIM
clean() {
  local T
  for T in iptables ip6tables; do
    command -v $T >/dev/null 2>&1 || continue
    while $T -D INPUT -j $CH 2>/dev/null; do :; done
    $T -F $CH 2>/dev/null; $T -X $CH 2>/dev/null
  done
  return 0
}
apply() {
  local out ports lim T M p
  out=$(python3 - <<'PY'
import json
try:
    d=json.load(open("/etc/SSHPlus/tls.json"))
    ps=[int(x) for x in d.get("ports",[])+d.get("tports",[]) if 0<int(x)<65536] if d.get("on") else []
    lim=int(d.get("perip",100))
    print(" ".join(map(str,ps)),lim)
except Exception:
    print("","0")
PY
)
  ports=${out% *}; lim=${out##* }
  clean
  [ -n "$ports" ] && [ "${lim:-0}" -gt 0 ] || return 0
  for T in iptables ip6tables; do
    command -v $T >/dev/null 2>&1 || continue
    [ $T = ip6tables ] && { [ -s /proc/net/if_inet6 ] || continue; M=128; } || M=32
    $T -N $CH 2>/dev/null || continue
    for p in $ports; do
      $T -A $CH -p tcp --dport "$p" -m connlimit --connlimit-above "$lim" --connlimit-mask $M -j REJECT --reject-with tcp-reset 2>/dev/null || true
    done
    $T -I INPUT -j $CH 2>/dev/null || true
  done
  return 0
}
case "$1" in
  apply) apply ;;
  clean) clean ;;
  *) echo "usage: $0 apply|clean"; exit 1 ;;
esac
EOF
chmod 755 /usr/local/bin/sshplus-tls-fw

cat > /etc/systemd/system/sshplus-dropbear-s.service <<'EOF'
[Unit]
Description=SSH Plus Dropbear (TLS back end, direct accounts, 127.0.0.1 only)
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
BindReadOnlyPaths=/etc/SSHPlus/shells.tlsd:/etc/shells
ExecStart=/usr/local/bin/start-dropbear.sh tlsd
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-dropbear-ts.service <<'EOF'
[Unit]
Description=SSH Plus Dropbear (TLS back end, tunnel accounts, 127.0.0.1 only)
After=network.target sshplus-tunnel-net.service
Wants=sshplus-tunnel-net.service
StartLimitIntervalSec=0
[Service]
Type=simple
BindReadOnlyPaths=/etc/SSHPlus/shells.tlst:/etc/shells
ExecStartPre=/usr/local/bin/sshplus-tunnel-net base
ExecStart=/usr/local/bin/start-dropbear.sh tlst
ExecStartPost=/usr/local/bin/sshplus-tunnel-net mark
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sshplus-stunnel.service <<'EOF'
[Unit]
Description=SSH Plus TLS front (stunnel -> Dropbear)
After=network.target sshplus-dropbear-s.service sshplus-dropbear-ts.service
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/bin/stunnel /etc/SSHPlus/stunnel.conf
ExecStartPost=/usr/local/bin/sshplus-tls-fw apply
ExecStopPost=/usr/local/bin/sshplus-tls-fw clean
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=2
LimitNOFILE=65535
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
Before=ssh.service sshd.service sshplus-dropbear-t.service sshplus-dropbear-ts.service badvpn-t.service
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
# no configuration = no restart loop
ConditionPathExists=/etc/SSHPlus/tunnel.conf
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
import os, re, io, sys, json, time, ssl, socket, base64, hashlib, shutil, getpass, secrets, threading, subprocess
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, quote

CFG="/etc/SSHPlus/panel.json"; DB="/root/users.db"; META="/etc/SSHPlus/meta.json"
PORTS="/etc/SSHPlus/ports.json"; BV="/etc/SSHPlus/badvpn.conf"
BBRF="/etc/sysctl.d/99-sshplus-bbr.conf"; SHELL="/usr/local/bin/sshplus-shell"; SHELL_T=SHELL+"-t"
HTML="/opt/sshplus-panel/index.html"; SSHCONF="/etc/ssh/sshd_config.d/00-sshplus.conf"
TOK={}; PIDS={}; FAIL={}; DBU={}; DBT={}; DBA={}; IPS={}
STATE={"first":True}; CACHE={"t":0.0,"v":None}; SSHP={"t":0.0,"v":set()}
LOCK=threading.Lock(); ML=threading.RLock()
ENV={"LC_ALL":"C","PATH":"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
NAME_RE=re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,31}$")
# An account = type (direct / tunnel) x connection (both / normal only / TLS only). The login shell encodes it and every Dropbear
# instance lists only the shells it serves in its own /etc/shells (see the systemd units), so e.g. a TLS-only account is refused on the plain ports.
SHELLS={("direct","both"):SHELL,("tunnel","both"):SHELL_T,("direct","normal"):SHELL+"-n",("tunnel","normal"):SHELL+"-tn",
        ("direct","tls"):SHELL+"-s",("tunnel","tls"):SHELL+"-ts"}
SHELL_OF={v:k for k,v in SHELLS.items()}
TLS_BACKENDS=6                                   # Dropbear processes per TLS instance (keep in line with scripts/start-dropbear.sh)
def shell_for(tm,cx): return SHELLS[("tunnel" if tm=="tunnel" else "direct",cx if cx in ("normal","tls") else "both")]
def is_tun(sh): return SHELL_OF.get(sh,("direct",""))[0]=="tunnel"
SSHDENY="/etc/ssh/sshd_config.d/02-sshplus-deny.conf"

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
  # panel accounts: name -> (uid, shell). The shell tells the account type (direct/tunnel) and connection (both/normal/tls), see SHELLS
  m={}
  try:
    for l in open("/etc/passwd"):
      p=l.strip().split(":")
      if len(p)>=7 and p[2].isdigit() and int(p[2])>=1000 and p[6] in SHELL_OF: m[p[0]]=(int(p[2]),p[6])
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
  rows=[]; masters=set(); launchers=set()
  for l in o.splitlines():
    p=l.split(None,4)
    if len(p)<4 or not p[0].isdigit() or not p[1].isdigit(): continue
    pid,ppid,usr,comm=int(p[0]),int(p[1]),p[2],p[3]
    args=p[4] if len(p)>4 else ""
    rows.append((pid,ppid,usr,comm,args))
    if ppid==1 and comm in ("sshd","dropbear"): masters.add(pid)
    if comm.startswith("start-dropbear"): launchers.add(pid)                 # TLS back ends: several Dropbear masters under one launcher script

  masters|={pid for pid,ppid,_,comm,_ in rows if comm=="dropbear" and ppid in launchers}
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
  for k in [k for k in DBA if k not in wset]: DBA.pop(k,None)
  unknown=[p for p in workers if p not in DBU and now-DBT.get(p,0)>15]
  if unknown:
    for p in unknown: DBT[p]=now
    _,j,_=cmd(["journalctl","-u","sshplus-dropbear","-u","sshplus-dropbear-t","-u","sshplus-dropbear-s","-u","sshplus-dropbear-ts","-n","3000","--no-pager","-o","cat"],20)
    for jl in j.splitlines():
      mt=re.search(r"\[(\d+)\].*Password auth succeeded for '([^']+)' from (\S+):(\d+)\s*$",jl)
      if mt: DBU[int(mt.group(1))]=mt.group(2); DBA[int(mt.group(1))]=(mt.group(3),int(mt.group(4)))
  ips={}; cip=None
  for dpid in workers:
    u=DBU.get(dpid)
    if u in um:
      io_pids[u].add(dpid)
      if dpid not in sessions[u]: sessions[u].append(dpid)
      a=DBA.get(dpid)
      if a:
        ip=a[0]
        if ip=="127.0.0.1":                                         # TLS: the real client address is in stunnel's log
          if cip is None: cip=tls_client_ips()
          ip=cip.get(a[1],"")
        if ip: ips.setdefault(u,set()).add(ip)
  IPS.clear(); IPS.update({k:sorted(v) for k,v in ips.items()})
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
    res.append({"u":u,"pw":dec(m.get("pw","")),"lim":int(m.get("lim",lim.get(u,1))),"on":om.get(u,0),"exp":es,"dl":dl,
                "expd":expd,"q":q,"ugb":fmt_traffic(ub),"qfull":(q>0 and ub>=int(q*1073741824)),
                "pt":str(m.get("pt","All")),"tm":"tunnel" if is_tun(pm[u][1]) else "direct","cx":SHELL_OF.get(pm[u][1],("direct","both"))[1],"en":"B" if m.get("en")=="B" else "A","st":m.get("tok",""),"ips":IPS.get(u,[])})
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
  cur=pm.get(u,(0,SHELL))[1]; ctm,ccx=SHELL_OF.get(cur,("direct","both")); tmq=str(d.get("tm","")); cxq=str(d.get("cx",""))
  tm=tmq if tmq in ("tunnel","direct") else ctm; cx=cxq if cxq in ("both","normal","tls") else ccx
  shl=shell_for(tm,cx)                          # account type + connection type = login shell
  if tm=="tunnel" and ctm!="tunnel" and not tconf().get("TUN_HOST"):
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
    if pw: m["pw"]=enc(pw)
    if not m.get("tok"): m["tok"]=secrets.token_hex(12)
    if d.get("rst"): m["u"]=0
    wjson(META,meta)
  refresh_lock(u); sshd_deny_sync()
  return 200,({"ok":1,"warn":"tls_off"} if cx!="normal" and not tls_cfg()["on"] else {"ok":1})

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
  sshd_deny_sync()
  return 200,{"ok":1}

def sshd_deny_sync():
  # TLS-only accounts must not log in on the OpenSSH ports either (OpenSSH does not look at the per-instance /etc/shells)
  names=sorted(u for u,(_,sh) in passwd_map().items() if SHELL_OF.get(sh,("","both"))[1]=="tls")
  want=("# generated by the CK.VPN panel: TLS-only accounts\nDenyUsers "+" ".join(names)+"\n") if names else ""
  try:
    with open(SSHDENY) as f: cur=f.read()
  except Exception: cur=""
  if cur==want: return
  try:
    if want:
      with open(SSHDENY,"w") as f: f.write(want)
    elif os.path.exists(SSHDENY): os.remove(SSHDENY)
    if cmd(["sshd","-t"])[0]!=0:                                   # never leave a broken sshd config behind
      if cur:
        with open(SSHDENY,"w") as f: f.write(cur)
      elif os.path.exists(SSHDENY): os.remove(SSHDENY)
      return
    if cmd(["systemctl","reload","ssh"])[0]!=0: cmd(["systemctl","restart","ssh"])
  except Exception: pass

# ---------- ports & BadVPN ----------
def apply_ports(d):
  old=rjson(PORTS,{"ssh":22,"ssh2":2222,"db":[]})
  s1=to_port(d.get("ssh")) or 22; s2=to_port(d.get("ssh2"))
  ssh_set={22,s1}|({s2} if s2 else set())
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053
  bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  managed={22,to_port(old.get("ssh")),to_port(old.get("ssh2"))}
  extra=sshd_ports()-managed-ssh_set          # e.g. 9011, defined outside the panel
  reserved=ssh_set|extra|{panel,bvp,bvp+1,2053}|foreign_ports()|tls_taken()
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
  used={22,2053,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|set(pc.get("db",[]))|set(pc.get("tdb",[]))|sshd_ports()|tls_taken()
  if p in used or p+1 in used or p+1>65535: return 400,{"ok":0,"msg":"Port (or port+1, used by the tunnel UDPGW) is already used by SSH/Dropbear/panel"}
  m=min(max(int(float(d.get("m") or 1200)),576),1500)
  c=min(max(int(float(d.get("c") or 1000)),1),10000)
  n=min(max(int(float(d.get("n") or 64)),1),1000)
  b=str(d.get("b","127.0.0.1")); b=b if b in ("127.0.0.1","0.0.0.0") else "127.0.0.1"  # nosec B104 - the admin may choose to expose UDPGW
  open(BV,"w").write(f"UDP_PORT={p}\nBIND_ADDR={b}\nUDP_MTU={m}\nMAX_CLIENTS={c}\nMAX_CONN={n}\nSEND_BUFFER=65536\nMSS_CLAMP=1\n")
  if b=="0.0.0.0": ufw_open({p})  # nosec B104
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
if [ ! -c /dev/net/tun ]; then modprobe tun 2>/dev/null || true; mkdir -p /dev/net; [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null || true; chmod 600 /dev/net/tun 2>/dev/null || true; fi
[ -c /dev/net/tun ] || { echo "the exit server has no /dev/net/tun (OpenVZ/LXC VPS: enable TUN/TAP in its provider panel)"; exit 13; }
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
  # only connections addressed to THIS server (not traffic of tunnel users going out to the internet on the same port, e.g. :443)
  iptables -t nat -A SSHPLUS_REV ! -i tun99 -m addrtype --dst-type LOCAL -p tcp --dport "$bp" -j DNAT --to-destination "10.99.0.1:$ap"
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

REMOTE_WG=r'''set -e
export DEBIAN_FRONTEND=noninteractive
command -v wg >/dev/null 2>&1 || {
  command -v apt-get >/dev/null 2>&1 || { echo "wireguard-tools is missing (apt-get not found)"; exit 21; }
  apt-get update -y -qq >/dev/null 2>&1 || true
  apt-get install -y -qq wireguard-tools >/dev/null 2>&1 || { echo "cannot install wireguard-tools"; exit 21; }
}
ip link del sshplus-wgtest 2>/dev/null || true
if ip link add sshplus-wgtest type wireguard 2>/dev/null; then ip link del sshplus-wgtest; WGM=kernel
else
  command -v wireguard-go >/dev/null 2>&1 || apt-get install -y -qq wireguard-go >/dev/null 2>&1 || true
  if command -v wireguard-go >/dev/null 2>&1 && [ -c /dev/net/tun ]; then WGM=go
  else echo "this server has no WireGuard support (no kernel module, no wireguard-go / TUN device)"; exit 22; fi
fi
umask 077
mkdir -p /etc/sshplus-wg
[ -s /etc/sshplus-wg/exit.key ] || wg genkey > /etc/sshplus-wg/exit.key
PUB=$(wg pubkey < /etc/sshplus-wg/exit.key)
ip link del tun99 2>/dev/null || true; sleep 0.5
P=${WG_PORT:-51820}; B=$P
while ss -lunH "sport = :$P" 2>/dev/null | grep -q . && [ "$P" -lt $((B+20)) ]; do P=$((P+1)); done
printf 'PEER_PUB=%s\nWG_PORT=%s\nWG_MTU=%s\n' "$PEER_PUB" "$P" "${WG_MTU:-1380}" > /etc/sshplus-wg/exit.conf
cat > /usr/local/bin/sshplus-exit-wg.sh <<'XEOF'
#!/bin/bash
. /etc/sshplus-wg/exit.conf
ip link del tun99 2>/dev/null
if ! ip link add tun99 type wireguard 2>/dev/null; then wireguard-go tun99 >/dev/null 2>&1; sleep 1; fi
wg set tun99 private-key /etc/sshplus-wg/exit.key listen-port "$WG_PORT" peer "$PEER_PUB" allowed-ips 10.99.0.1/32 || exit 1
ip addr replace 10.99.0.2/30 dev tun99
ip link set tun99 mtu "$WG_MTU" up
sysctl -qw net.ipv4.ip_forward=1
XEOF
chmod 755 /usr/local/bin/sshplus-exit-wg.sh
cat > /etc/systemd/system/sshplus-exit-wg.service <<'XEOF'
[Unit]
Description=SSH Plus exit-server WireGuard link
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sshplus-exit-wg.sh
ExecStop=/bin/sh -c 'ip link del tun99'
[Install]
WantedBy=multi-user.target
XEOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable sshplus-exit-wg.service >/dev/null 2>&1 || true
/usr/local/bin/sshplus-exit-wg.sh
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$P/udp" >/dev/null 2>&1
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd --permanent --add-port="$P/udp" >/dev/null 2>&1; firewall-cmd --add-port="$P/udp" >/dev/null 2>&1; fi
echo "WG_EXIT_PUB:$PUB"; echo "WG_PORT:$P"; echo "WG_MODE:$WGM"
echo SSHPLUS_WG_OK
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
  return sorted(u for u,(_,sh) in passwd_map().items() if is_tun(sh))

def tunnel_status(full=False):
  c=tconf(); conf=bool(c.get("TUN_HOST"))
  svc=conf and cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0
  up=bool(svc) and cmd(["ip","link","show",TUN_DEV])[0]==0
  r={"conf":conf,"mode":c.get("TUN_MODE","ssh"),"host":c.get("TUN_HOST",""),"port":to_port(c.get("TUN_PORT",22)) or 22,"user":c.get("TUN_USER",""),
     "exit":c.get("EXIT_IP",""),"since":int(c.get("SINCE","0") or 0),"svc":bool(svc),"up":up,
     "route":"both","rev_ports":[int(x) for x in c.get("REV_PORTS","").split(",") if x.isdigit()],
     "rev_skipped":[int(x) for x in c.get("REV_SKIPPED","").split(",") if x.isdigit()],
     "rev_map":[{"a":int(a),"b":int(b)} for a,b in (x.split(":",1) for x in c.get("REV_MAP","").split(",") if ":" in x) if a.isdigit() and b.isdigit()]}
  if full:
    if up:
      r["up"]=tun_probe()[0]
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
    if TS["steps"]: TS["steps"][-1]["s"]=st; TS["steps"][-1]["d"]=str(d)[:900]
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

_TP={"t":0.0,"v":(False,0.0)}
def tun_probe(force=False):
  # (is data passing through the tunnel, round-trip ms). ICMP first; many exit servers drop ping (firewall), so a TCP connect to its
  # SSH port through the tunnel counts just as well. Cached for a few seconds: the Tunnel tab polls and a connect per poll would be noise.
  if not force and time.time()-_TP["t"]<10: return _TP["v"]
  rc,o,_=cmd(["ping","-c","1","-W","2","-I",TUN_DEV,TUN_REMOTE],6)
  if rc==0:
    m=re.search(r"time=([\d.]+)",o); v=(True,float(m.group(1)) if m else 0.0)
  else:
    port=to_port(tconf().get("TUN_PORT",22)) or 22; t0=time.time(); v=(False,0.0)
    try:
      sk=socket.socket(); sk.settimeout(3); sk.bind((TUN_LOCAL,0)); sk.connect((TUN_REMOTE,port)); sk.close(); v=(True,round((time.time()-t0)*1000,1))
    except Exception: pass
  _TP["t"]=time.time(); _TP["v"]=v; return v

WGPRIV="/etc/SSHPlus/wg_private"; WGPUB="/etc/SSHPlus/wg_public"
def wg_local_support():
  # "kernel" (module in the kernel), "go" (userspace wireguard-go on /dev/net/tun) or "" (not possible here)
  if cmd(["ip","link","add","sshplus-wgtest","type","wireguard"])[0]==0:
    cmd(["ip","link","del","sshplus-wgtest"]); return "kernel"
  return "go" if shutil.which("wireguard-go",path=ENV["PATH"]) and os.path.exists("/dev/net/tun") else ""

def wg_keys():
  # this server's WireGuard key pair (created once); returns (public_key, error)
  if not (os.path.exists(WGPRIV) and os.path.exists(WGPUB)):
    rc,priv,er=_run(["wg","genkey"])
    if rc!=0 or not priv: return "",er or "wg genkey failed"
    rc,pub,er=_run(["wg","pubkey"],inp=priv+"\n")
    if rc!=0 or not pub: return "",er or "wg pubkey failed"
    for f,v in ((WGPRIV,priv),(WGPUB,pub)):
      fd=os.open(f,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,(v+"\n").encode()); os.close(fd)
  return open(WGPUB).read().strip(),""

def wg_handshake():
  rc,o,_=cmd(["wg","show",TUN_DEV,"latest-handshakes"])
  return rc==0 and any(x.isdigit() and int(x)>0 for x in o.split())

def tun_local_check():
  # can this server open /dev/net/tun? returns "" or the reason
  try:
    if not os.path.exists("/dev/net/tun"):
      cmd(["modprobe","tun"]); os.makedirs("/dev/net",exist_ok=True)
      if not os.path.exists("/dev/net/tun"):
        import stat; os.mknod("/dev/net/tun",0o600|stat.S_IFCHR,os.makedev(10,200))
    os.close(os.open("/dev/net/tun",os.O_RDWR)); return ""
  except Exception as e: return str(e)

TUN_NOISE=re.compile(r"^(Started|Stopped|Starting|Stopping)\b|\.service: |Main process exited|Failed with result|Scheduled restart|Consumed .*CPU|Deactivated successfully|systemd\[")
def tun_diag(j):
  # the unit's own messages (ssh errors, SSHPLUS-TUNNEL lines) without systemd's start/stop chatter, plus a hint for the usual causes
  lines=[l.strip() for l in j.splitlines() if l.strip() and not TUN_NOISE.search(l)]
  txt="\n".join(lines[-6:])
  hints=[(r"cannot open /dev/net/tun|Tunnel device open failed|/dev/net/tun|TUN/TAP","سرور TUN ندارد (روی OpenVZ/LXC در پنل VPS گزینه‌ی TUN/TAP را روشن کن) / the server has no TUN device"),
         (r"Could not request tunnel forwarding|tun: Operation not permitted|channel \d+: open failed","سرور مقصد تانل را نمی‌پذیرد (PermitTunnel یا TUN در سرور مقصد) / the exit server refused the tunnel (PermitTunnel or TUN there)"),
         (r"Host key verification failed|REMOTE HOST IDENTIFICATION","کلید هاست سرور مقصد عوض شده؛ تانل را حذف و دوباره نصب کن / the exit server's host key changed"),
         (r"Permission denied \(publickey","کلید تانل روی سرور مقصد پذیرفته نشد؛ دوباره نصب کن / the exit server did not accept the tunnel key"),
         (r"Connection (timed out|refused)|No route to host|Network is unreachable","به سرور مقصد نمی‌رسد (فایروال/پورت SSH؟) / cannot reach the exit server (firewall / SSH port?)")]
  h=next((m for p,m in hints if re.search(p,txt,re.I)),"")
  return txt,h

def tunnel_rollback():
  cmd(["systemctl","disable","--now","sshplus-tunnel"])
  for f in (TCONF,TKH):
    try: os.remove(f)
    except OSError: pass
  cmd([TNET,"down"])

def tunnel_setup_run(host,port,user,pw,mode="ssh"):
  with TSL: TS["run"]=True; TS["steps"]=[]; TS["ok"]=None
  wg=(mode=="wg")
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
    if miss: return False,"missing: "+", ".join(miss)
    if wg:
      if not shutil.which("wg",path=ENV["PATH"]): _run(["apt-get","install","-y","wireguard-tools"],t=300)
      if not shutil.which("wg",path=ENV["PATH"]): return False,"wireguard-tools could not be installed (apt-get install wireguard-tools)"
      if not wg_local_support():
        _run(["apt-get","install","-y","wireguard-go"],t=300)
        if not wg_local_support(): return False,"this server cannot create a WireGuard interface (no kernel module and no wireguard-go / TUN). Use the SSH tunnel type instead."
    return True,""
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
    if not wg: _run(["ssh"]+_ssh_o(port)+[tgt,"systemctl disable --now sshplus-exit-wg.service >/dev/null 2>&1; ip link show tun99 2>/dev/null | grep -q . && [ -f /etc/sshplus-wg/exit.conf ] && ip link del tun99; true"],t=40)
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
  def f_wg():
    pub,er=wg_keys()
    if er: return False,"WireGuard key: "+er
    env="export WG_PORT=51820 PEER_PUB=%s WG_MTU=1380\n"%pub
    rc,o,er=_run(["ssh"]+_ssh_o(port)+[tgt,"bash -s"],inp=env+REMOTE_WG,t=300)
    if rc!=0 or "SSHPLUS_WG_OK" not in o: return False,(o.splitlines()[-1:] or [er or "failed"])[0][-250:]
    for l in o.splitlines():
      if l.startswith("WG_EXIT_PUB:"): ctx["wgpub"]=l.split(":",1)[1].strip()
      elif l.startswith("WG_PORT:"): ctx["wgport"]=l.split(":",1)[1].strip()
      elif l.startswith("WG_MODE:"): ctx["wgmode"]=l.split(":",1)[1].strip()
    if not ctx.get("wgpub") or not ctx.get("wgport","").isdigit(): return False,"the exit server did not report its WireGuard key / port"
    return True,"WireGuard (%s) UDP %s"%(ctx.get("wgmode","?"),ctx["wgport"])
  def f_local():
    tn=tun_local_check()
    if tn: return False,"این سرور نمی‌تواند /dev/net/tun را باز کند: %s (روی OpenVZ/LXC در پنل VPS گزینه‌ی TUN/TAP را روشن کن)"%tn
    tconf_write({"TUN_HOST":host,"TUN_PORT":port,"TUN_USER":user,"TUN_DEV":TUN_DEV,"TUN_ID":TUN_ID,
                 "TUN_LOCAL":TUN_LOCAL,"TUN_REMOTE":TUN_REMOTE,"SINCE":int(time.time()),"ROUTE":old_route,
                 "TUN_MODE":"wg" if wg else "ssh","TUN_MTU":1380 if wg else 1400,
                 **({"WG_PORT":ctx["wgport"],"WG_EXIT_PUB":ctx["wgpub"]} if wg else {}),
                 "REV_PORTS":",".join(map(str,sorted(ctx.get("okm",{})))),
                 "REV_MAP":",".join("%d:%d"%(a,b) for a,b in sorted(ctx.get("okm",{}).items())),
                 "REV_SKIPPED":",".join(ctx.get("sk",[]))})
    cmd([TNET,"sync"]); cmd(["systemctl","daemon-reload"])
    cmd(["systemctl","enable","sshplus-tunnel"]); cmd(["systemctl","restart","sshplus-tunnel"],30)
    return True,""
  def f_wait():
    if wg:
      for _ in range(45):
        if cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0 and wg_handshake(): break
        time.sleep(1)
      else:
        _,j,_=cmd(["journalctl","-u","sshplus-tunnel","-n","40","--no-pager","-o","cat"],10); txt,_h=tun_diag(j)
        sh=cmd(["wg","show",TUN_DEV])[1].replace("\n"," | ")[:260]
        return False,"WireGuard: no handshake with the exit server. UDP port %s is probably blocked (provider firewall / security group / ufw): open UDP %s on the exit server, or choose the SSH tunnel type. / %s\n%s"%(ctx.get("wgport"),ctx.get("wgport"),sh,txt[-200:])
    for _ in range(40):
      if cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0 and \
         tun_probe(True)[0]:
        return True,f"{TUN_LOCAL} <-> {TUN_REMOTE}"
      time.sleep(1)
    _,j,_=cmd(["journalctl","-u","sshplus-tunnel","-n","60","--no-pager","-o","cat"],10)
    txt,h=tun_diag(j); tn=tun_local_check(); virt=cmd(["systemd-detect-virt"])[1]
    extra=("TUN: "+tn+" | " if tn else "")+("virt: "+virt if virt else "")
    # the link may be up while nothing passes through it: collect what both ends look like (the key login works at this point)
    act=cmd(["systemctl","is-active","sshplus-tunnel"])[0]==0
    if act:
      pg=cmd(["ping","-c","1","-W","2","-I",TUN_DEV,TUN_REMOTE],6); pl=[x for x in (pg[1]+"\n"+pg[2]).splitlines() if x.strip()][-1:]+["tcp:"+("ok" if tun_probe(True)[0] else "fail")]
      loc=cmd(["ip","-br","addr","show",TUN_DEV])[1] or "no "+TUN_DEV
      rem=_run(["ssh"]+_ssh_o(port)+[tgt,"ip -br addr show %s 2>&1; ufw status 2>/dev/null | head -1; iptables -S INPUT 2>/dev/null | head -3"%TUN_DEV],t=30)[1]
      extra+="\nلینک SSH برقرار است ولی داخل تانل ping جواب نمی‌دهد / the SSH link is up but nothing passes: local: %s | ping: %s | exit server: %s"%(loc," ".join(pl),rem.replace("\n"," / ")[:240])
    return False,("تانل بالا نیامد: "+(h+"\n" if h else "")+(extra+"\n" if extra else "")+txt[-300:])
  def f_exit():
    ip=tun_exit_ip()
    if not ip:
      # the link works but nothing reaches the internet through it: say where it stops (DNS? routing here? forwarding / NAT on the exit server?)
      cu=cmd(["curl","-sS","-m","8","--interface",TUN_LOCAL,"-o","/dev/null","-w","%{http_code}","http://1.1.1.1/"],12)
      byip="HTTP "+cu[1] if cu[0]==0 else (cu[2] or "no answer")[-90:]
      rg=cmd(["ip","-4","route","get","1.1.1.1","from",TUN_LOCAL])[1].replace("\n"," ")[:110]
      rem=_run(["ssh"]+_ssh_o(port)+[tgt,"echo ip_forward=$(sysctl -n net.ipv4.ip_forward); iptables -t nat -S POSTROUTING 2>&1 | head -3; iptables -S FORWARD 2>&1 | head -3; ip -4 route show default | head -1"],t=30)[1].replace("\n"," / ")[:330]
      return "warn","تانل برقرار است ولی تست اینترنت از مسیر تانل جواب نداد (سرور مقصد اینترنت دارد؟) / the link is up but the internet is not reachable through it. direct-IP test: %s | route here: %s | exit server: %s"%(byip,rg,rem)
    c=tconf(); c["EXIT_IP"]=ip; tconf_write(c)
    return True,"IP خروجی تانل: "+ip
  try:
    steps=[("بررسی ابزارهای لازم",f_tools),("ساخت کلید SSH مخصوص تانل",f_key),
           (f"اتصال به {host}:{port} با رمز و نصب کلید",f_login),("تست ورود با کلید",f_verify),
           ("آماده‌سازی سرور مقصد (PermitTunnel / فوروارد / NAT)",f_remote)]+([("آماده‌سازی WireGuard روی سرور مقصد",f_wg)] if wg else [])
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
  tl=tls_cfg(); extra=(tl["ports"]+tl["tports"]) if tl["on"] else []              # SSH over TLS: the public TLS ports too
  for x in list(pc.get("db",[]))+list(pc.get("tdb",[]))+[pc.get("ssh2",0)]+extra:
    v=to_port(x)
    if v and v!=22 and v not in out: out.append(v)
  return out

def ports_autofix():
  # Dropbear ports (direct + tunnel) that another program already listens on are replaced by free ports
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[],"tdb":[]}); lis=listen_ports(); foreign=foreign_ports()
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053; bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  used=set(lis)|{22,panel,2053,bvp,bvp+1,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|sshd_ports()|set(pc.get("db",[]))|set(pc.get("tdb",[]))|tls_taken()
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

def tunnel_exit_update():
  # rewrites the exit server's scripts/rules from this panel's current version (no re-install, the tunnel and its settings stay) - the
  # exit side is only written at setup, so a panel update that changes it needs this
  c=tconf()
  if not c.get("TUN_HOST"): return 400,{"ok":0,"msg":"Tunnel is not set up"}
  if TS["run"]: return 409,{"ok":0,"msg":"Setup is running"}
  return tunnel_route_apply("forward" if c.get("ROUTE")=="forward" else "both")

def ports_sync():
  # 1) conflicts on this server  2) conflicts / mapping on the exit server  3) firewalls of BOTH servers
  rep={"ok":1,"a_changes":ports_autofix(),"map":[],"skipped":[],"fw_b":"-"}
  pc=rjson(PORTS,{})
  tl=tls_cfg(); rep["fw_a"]=ufw_open(set(pc.get("db",[]))|set(pc.get("tdb",[]))|sshd_ports()|((set(tl["ports"])|set(tl["tports"])) if tl["on"] else set()))
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
  p=p+(("wg" if str(d.get("mode","")).lower()=="wg" else "ssh"),)
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
  if not tun_probe(True)[0]: return 200,{"ok":0,"msg":"Tunnel link is down"}
  ip=tun_exit_ip()
  if not ip: return 200,{"ok":0,"msg":"Link is up but there is no internet through the tunnel"}
  c=tconf(); c["EXIT_IP"]=ip; tconf_write(c)
  return 200,{"ok":1,"ip":ip}

def tunnel_remove():
  if TS["run"]: return 409,{"ok":0,"msg":"Setup is running"}
  if tconf().get("TUN_HOST"):
    try: tunnel_push({})                # take the forwarded ports back on the exit server
    except Exception: pass
    if tconf().get("TUN_MODE")=="wg":
      c0=tconf(); _run(["ssh"]+_ssh_o(to_port(c0.get("TUN_PORT",22)) or 22)+[c0.get("TUN_USER","root")+"@"+c0.get("TUN_HOST",""),"systemctl disable --now sshplus-exit-wg.service >/dev/null 2>&1; ip link del tun99 2>/dev/null; rm -rf /etc/sshplus-wg /usr/local/bin/sshplus-exit-wg.sh /etc/systemd/system/sshplus-exit-wg.service; systemctl daemon-reload >/dev/null 2>&1; true"],t=40)
  _,io=on_map(True); n=0
  for u,(_,sh) in passwd_map().items():
    if is_tun(sh):                      # keep these accounts alive as direct accounts (same connection type)
      cmd(["usermod","-s",shell_for("direct",SHELL_OF[sh][1]),u]); n+=1
      for pid in io.get(u,[]): kill_pid(pid)
  tunnel_rollback()
  if os.path.exists(TNET): cmd([TNET,"sync"])
  sshd_deny_sync()
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
        if tls_cfg()["on"]: svs+=list(TLS_SVC)
        for srv in svs:
          if cmd(["systemctl","is-active",srv])[0]!=0:
            cmd(["systemctl","reset-failed",srv]); cmd(["systemctl","restart",srv])
      n+=1
      if n==4:                                                             # once per panel start / update
        threading.Thread(target=ports_sync,daemon=True).start(); sshd_deny_sync()
      if n%20==0:                                                          # every minute: history + Telegram alerts
        stunnel_log_trim()
        try: alerts_tick(hist_tick())
        except Exception: pass
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
            if cur>prv: m["u"]=int(m.get("u",0))+(cur-prv); DAYU[u]=DAYU.get(u,0)+(cur-prv); ch=True
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

# ---------- v1.5: secrets at rest, TLS, backup, Telegram, templates/bulk, subscription links, history ----------
try:
  from cryptography.fernet import Fernet, InvalidToken
  HAVE_FERNET=True
except Exception: HAVE_FERNET=False
try:
  import qrcode, qrcode.image.svg
  HAVE_QR=True
except Exception: HAVE_QR=False

SECRETK="/etc/SSHPlus/secret.key"; CERT="/etc/SSHPlus/panel.crt"; CKEY="/etc/SSHPlus/panel.key"
TGC="/etc/SSHPlus/telegram.json"; TGS="/etc/SSHPlus/tg_state.json"; TPL="/etc/SSHPlus/templates.json"; HIST="/etc/SSHPlus/history.json"
VERSION="__VERSION__"
SRV=[None]; _FER=[None]; DAYU={}; TG={"off":0,"tun":None,"cpu":0,"mem":0,"tdown":0,"via":"direct"}
PWCH="abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"

# ---- 3) user passwords are encrypted at rest (key in a separate root-only file)
def fer():
  if not HAVE_FERNET: return None
  if _FER[0] is None:
    try: k=open(SECRETK,"rb").read().strip()
    except Exception:
      k=Fernet.generate_key(); fd=os.open(SECRETK,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,k); os.close(fd)
    _FER[0]=Fernet(k)
  return _FER[0]

def enc(s):
  f=fer(); s=str(s or "")
  return ("enc:"+f.encrypt(s.encode()).decode()) if (f and s) else s

def dec(s):
  s=str(s or "")
  if not s.startswith("enc:"): return s
  f=fer()
  try: return f.decrypt(s[4:].encode()).decode() if f else ""
  except Exception: return ""

def migrate_secrets():
  if not fer(): return
  with ML:
    meta=rjson(META,{}); ch=False
    for u,m in meta.items():
      v=m.get("pw","")
      if v and not str(v).startswith("enc:"): m["pw"]=enc(v); ch=True
      if not m.get("tok"): m["tok"]=secrets.token_hex(12); ch=True
    if ch: wjson(META,meta)
  t=rjson(TGC,{}); ch=False
  for k in ("token","bpass"):
    if t.get(k) and not str(t[k]).startswith("enc:"): t[k]=enc(t[k]); ch=True
  if ch: wjson(TGC,t)

# ---- 1) HTTPS (self-signed by default, own certificate can be uploaded) + forced password change
def ensure_cert():
  if os.path.exists(CERT) and os.path.exists(CKEY): return True
  cmd(["openssl","req","-x509","-newkey","rsa:2048","-nodes","-days","3650","-subj","/CN=CK.VPN","-keyout",CKEY,"-out",CERT],90)
  try: os.chmod(CKEY,0o600)
  except Exception: pass
  return os.path.exists(CERT) and os.path.exists(CKEY)

def tls_ctx(cert=CERT,key=CKEY):
  c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.minimum_version=ssl.TLSVersion.TLSv1_2; c.load_cert_chain(cert,key); return c

def cert_info():
  rc,o,_=cmd(["openssl","x509","-in",CERT,"-noout","-subject","-enddate","-issuer"])
  return o if rc==0 else ""

def cert_save(d):
  cp=str(d.get("cert","")).strip()+"\n"; kp=str(d.get("key","")).strip()+"\n"
  if len(cp)>40000 or len(kp)>40000 or "BEGIN" not in cp or "PRIVATE KEY" not in kp: return 400,{"ok":0,"msg":"Invalid PEM (need certificate chain + private key)"}
  t1=CERT+".new"; t2=CKEY+".new"
  try:
    for f,v in ((t1,cp),(t2,kp)):
      fd=os.open(f,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,v.encode()); os.close(fd)
    ctx=tls_ctx(t1,t2)                         # raises if the key does not match the certificate
  except Exception as e:
    for f in (t1,t2):
      try: os.remove(f)
      except OSError: pass
    return 400,{"ok":0,"msg":"Certificate/key rejected: "+str(e)[:100]}
  os.replace(t1,CERT); os.replace(t2,CKEY)
  if SRV[0] is not None: SRV[0].ctx=ctx
  tls_reload()                                   # the SSH-TLS front uses the same certificate
  return 200,{"ok":1}

def must_change():
  return str(rjson(CFG,{"password":"admin"}).get("password","admin")).strip()=="admin"

# ---- 8) SSH over TLS: stunnel (public) -> Dropbear on 127.0.0.1 (one instance per account type).
#         The certificate + domain are shared with the panel's own HTTPS, so there is a single place to manage them.
TLSC="/etc/SSHPlus/tls.json"; STUN_CONF="/etc/SSHPlus/stunnel.conf"; ETC_SHELLS="/etc/shells"; SHELLS_DIR="/etc/SSHPlus"; TLSFW="/usr/local/bin/sshplus-tls-fw"; STUNLOG="/var/log/sshplus/stunnel.log"
TLS_SVC=("sshplus-dropbear-s","sshplus-dropbear-ts","sshplus-stunnel")
HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/ckvpn.sh"
TJ={"run":False,"steps":[],"ok":None,"domain":""}; TJL=threading.Lock(); TAL=threading.Lock()
DOM_RE=re.compile(r"^(?=.{4,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\Z")
DUCK_RE=re.compile(r"^[a-z0-9][a-z0-9-]{0,62}\Z"); DUCKTOK_RE=re.compile(r"^[0-9A-Fa-f-]{8,64}\Z")
MAIL_RE=re.compile(r"^[^@\s\"']{1,64}@[^@\s\"']{1,200}\.[^@\s\"']{2,24}\Z")
WILD={"sslip":"sslip.io","nip":"nip.io"}          # wildcard-DNS services: <ip-with-dashes>.<suffix> resolves to that IP (no account needed)
DUCK_URL=os.environ.get("SSHPLUS_DUCK_URL","https://www.duckdns.org/update")

def tls_cfg():
  d=rjson(TLSC,{})
  def pl(k,df):
    out=[]
    for x in d.get(k,df):
      v=to_port(x)
      if v and v not in out: out.append(v)
    return out[:3]
  md=d.get("mode") if d.get("mode") in ("self","own","free") else "self"
  try: pi=max(0,min(10000,int(d.get("perip",100))))              # max concurrent connections per client IP on the TLS ports (0 = no limit)
  except Exception: pi=100
  return {"on":bool(d.get("on")),"ports":pl("ports",[443]),"tports":pl("tports",[8843]),"bd":to_port(d.get("bd")) or 40100,"bt":to_port(d.get("bt")) or 40120,
          "mode":md,"domain":str(d.get("domain","")),"prov":str(d.get("prov","")),"suffix":str(d.get("suffix","")),"duckname":str(d.get("duckname","")),
          "duck":bool(d.get("duck")),"email":str(d.get("email","")),"staging":bool(d.get("staging")),
          "perip":pi}

def tls_back_ports(c):
  return set(range(c["bd"],c["bd"]+TLS_BACKENDS))|set(range(c["bt"],c["bt"]+TLS_BACKENDS))

def tls_taken(c=None):
  # ports this feature owns (public TLS ports + the local Dropbear back ends): other settings must not use them
  c=c or tls_cfg(); return set(c["ports"])|set(c["tports"])|tls_back_ports(c)

def tls_reserved(c=None):
  c=c or tls_cfg(); pc=rjson(PORTS,{})
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053; bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  return {22,80,panel,2053,bvp,bvp+1,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|tls_back_ports(c)|{to_port(x) for x in pc.get("db",[])}|{to_port(x) for x in pc.get("tdb",[])}|sshd_ports()

def cert_meta():
  rc,o,_=cmd(["openssl","x509","-in",CERT,"-noout","-subject","-issuer","-enddate"])
  if rc!=0: return {}
  m={}
  for l in o.splitlines():
    k,_,v=l.partition("="); m[k.strip()]=v.strip()
  cn=re.search(r"CN\s*=\s*([^,/]+)",m.get("subject","")); left=None
  try: left=(datetime.strptime(re.sub(r"\s+"," ",m.get("notAfter","")),"%b %d %H:%M:%S %Y GMT")-datetime.utcnow()).days
  except Exception: pass
  return {"cn":cn.group(1).strip() if cn else "","issuer":m.get("issuer",""),"self":m.get("issuer","x")==m.get("subject","y"),"days":left,"end":m.get("notAfter","")}

def have(name): return shutil.which(name,path=ENV["PATH"]) is not None

def tls_brief():
  c=tls_cfg()
  return {"on":c["on"],"up":c["on"] and cmd(["systemctl","is-active","sshplus-stunnel"])[0]==0,"ports":c["ports"],"tports":c["tports"],"dom":c["domain"]}

def tj_snap():
  with TJL: return {"run":TJ["run"],"ok":TJ["ok"],"domain":TJ["domain"],"steps":[dict(x) for x in TJ["steps"]]}

def tj_begin(m):
  with TJL: TJ["steps"].append({"m":m,"s":"run","d":""})

def tj_end(ok,d=""):
  st={True:"ok",False:"err","warn":"warn"}[ok]
  with TJL:
    if TJ["steps"]: TJ["steps"][-1]["s"]=st; TJ["steps"][-1]["d"]=str(d)[:500]

_CIP={"t":0.0,"v":{}}
def tls_client_ips():
  # local source port stunnel used towards Dropbear -> the real client address (from stunnel's own log)
  if time.time()-_CIP["t"]<4: return _CIP["v"]
  conns={}; res={}
  try:
    with open(STUNLOG,"rb") as f:
      f.seek(0,2); n=f.tell(); f.seek(max(0,n-400000)); data=f.read().decode("utf-8","replace")
    for l in data.splitlines():
      m=re.search(r"LOG5\[(\d+)\]: Service \[[^\]]+\] accepted connection from (\S+)$",l)
      if m: conns[m.group(1)]=m.group(2).rsplit(":",1)[0]; continue
      m=re.search(r"LOG5\[(\d+)\]: Service \[[^\]]+\] connected remote server from 127\.0\.0\.1:(\d+)$",l)
      if m and m.group(1) in conns: res[int(m.group(2))]=conns[m.group(1)]
  except Exception: pass
  _CIP["t"]=time.time(); _CIP["v"]=res; return res

def stunnel_log_trim():
  try:
    if os.path.getsize(STUNLOG)>8*1048576: os.truncate(STUNLOG,0)
  except OSError: pass

def tls_manual_text(x):
  # everything an app that has no import link needs, plus an OpenSSH one-liner
  t=x.get("tls")
  if not t: return ""
  h=t["host"]; sni=t.get("sni") or ""
  return ("SSH over TLS\nHost: %s\nTLS port(s): %s\nSNI: %s\nUsername: %s\nPassword: %s\nAllow untrusted certificate: %s\n"
          "OpenSSH: ssh -o ProxyCommand=\"openssl s_client -quiet -connect %s:%d%s\" %s@%s")%(
          h,", ".join(map(str,t["ports"])),sni or "-",x["u"],x["pw"],"yes (self-signed)" if t.get("insecure") else "no",
          h,t["ports"][0]," -servername "+sni if sni else "",x["u"],h)

def tls_state():
  c=tls_cfg(); svc={s:(cmd(["systemctl","is-active",s])[0]==0) for s in TLS_SVC}; lis=listen_ports()
  return {"cfg":c,"svc":svc,"up":c["on"] and all(svc.values()),"cert":cert_meta(),"https":bool(SRV[0] and SRV[0].ctx is not None),
          "ports_up":{str(p):(p in lis) for p in sorted(c["ports"]+c["tports"])},"installed":{"stunnel":have("stunnel"),"certbot":have("certbot")},
          "job":tj_snap(),"fer":HAVE_FERNET}

def tls_shell_files():
  # per-instance /etc/shells: a Dropbear instance only accepts the account shells it is meant to serve
  try: base=[l.rstrip("\n") for l in open(ETC_SHELLS)]
  except Exception: base=["/bin/sh","/bin/bash"]
  mine=set(SHELLS.values()); clean=[l for l in base if l and l not in mine]
  allow={"direct":("direct","normal"),"tunnel":("tunnel","normal"),"tlsd":("direct","tls"),"tlst":("tunnel","tls")}
  for k,(tm,cx) in allow.items():
    fp=os.path.join(SHELLS_DIR,"shells."+k)
    with open(fp,"w") as f: f.write("\n".join(clean+[SHELLS[(tm,"both")],SHELLS[(tm,cx)]])+"\n")
    os.chmod(fp,0o644)

def stunnel_write(c):
  L=["; generated by the CK.VPN panel - changes are overwritten","foreground = yes","pid =","debug = 5","output = "+STUNLOG,"sslVersionMin = TLSv1.2",
     "socket = l:TCP_NODELAY=1","socket = r:TCP_NODELAY=1"]
  for kind,ports,bp in (("d",c["ports"],c["bd"]),("t",c["tports"],c["bt"])):
    for p in ports:
      L+=["","[tls-%s-%d]"%(kind,p),"accept = 0.0.0.0:%d"%p]+["connect = 127.0.0.1:%d"%(bp+i) for i in range(TLS_BACKENDS)]+["failover = rr","TIMEOUTbusy = 30","cert = "+CERT,"key = "+CKEY]
  t=STUN_CONF+".t"
  with open(t,"w") as f: f.write("\n".join(L)+"\n")
  os.chmod(t,0o600); os.replace(t,STUN_CONF)

def tls_backends(c):
  # first ports of the two blocks of local Dropbear back ends: keep the current ones unless something else listens there
  lis=listen_ports(); res=tls_reserved(c)-tls_back_ports(c)
  def block_free(b,avoid): return all(p not in res and p not in avoid and (p not in lis or lis[p]<={"dropbear"}) for p in range(b,b+TLS_BACKENDS))
  bd=c["bd"]
  if not block_free(bd,set()): bd=next((b for b in range(40100,40900,TLS_BACKENDS+2) if block_free(b,set())),bd)
  own=set(range(bd,bd+TLS_BACKENDS)); bt=c["bt"]
  if not block_free(bt,own): bt=next((b for b in range(bd+TLS_BACKENDS+2,40990,TLS_BACKENDS+2) if block_free(b,own)),bt)
  return bd,bt

def tls_reload():
  c=tls_cfg()
  if not c["on"] or not os.path.exists(STUN_CONF): return
  stunnel_write(c)
  if cmd(["systemctl","reload","sshplus-stunnel"])[0]!=0: cmd(["systemctl","restart","sshplus-stunnel"])

def tls_apply(d):
  with TAL: return _tls_apply(d)

def _tls_apply(d):
  c=tls_cfg(); on=bool(d["on"]) if "on" in d else c["on"]; d0=rjson(TLSC,{}); dropped=[]
  front=("ports" in d or "tports" in d or on!=c["on"])                     # does the TLS front itself change? (a limit / staging change must not drop sessions)
  if "domain" in d:
    dom=str(d.get("domain","")).strip().lower()
    if dom and not DOM_RE.match(dom): return 400,{"ok":0,"msg":"Invalid domain name"}
    d0["domain"]=dom; d0["mode"]="own" if dom and not cert_meta().get("self",True) else "self"   # "own" only once a real certificate is installed
  if "perip" in d:
    try: pi=int(str(d["perip"]).strip() or 0)
    except Exception: return 400,{"ok":0,"msg":"Invalid per-IP limit (a number, 0 = no limit)"}
    if not 0<=pi<=10000: return 400,{"ok":0,"msg":"Invalid per-IP limit (0..10000, 0 = no limit)"}
    d0["perip"]=pi
  if "staging" in d: d0["staging"]=bool(d["staging"])
  if "ports" in d or "tports" in d:
    res=tls_reserved(c); foreign={p for p,n in listen_ports().items() if not n<={"dropbear","sshd","stunnel"}}; new={}; used=set()
    for key in ("ports","tports"):
      out=[]
      for x in (d[key] if key in d else c[key]):
        if str(x).strip()=="": continue
        v=to_port(x)
        if v and v not in res and v not in foreign and v not in used and v not in out: out.append(v); used.add(v)
        else: dropped.append(str(x))
      new[key]=out[:3]
    if not new["ports"]: return 400,{"ok":0,"msg":"At least one valid TLS port for normal accounts is required (443 is the usual choice)"}
    if not new["tports"]: return 400,{"ok":0,"msg":"At least one valid TLS port for tunnel accounts is required"}
    c.update(new)
  if on:
    if not have("stunnel"):
      _run(["apt-get","install","-y","stunnel4"],env=dict(ENV,DEBIAN_FRONTEND="noninteractive"),t=240)
      cmd(["systemctl","disable","--now","stunnel4"],30)                       # the package's own generic service is not used
      if not have("stunnel"): return 500,{"ok":0,"msg":"stunnel4 could not be installed (apt-get install stunnel4)"}
    if not ensure_cert(): return 500,{"ok":0,"msg":"No certificate available (openssl missing?)"}
    c["bd"],c["bt"]=tls_backends(c)
  d0.update({"on":on,"ports":c["ports"],"tports":c["tports"],"bd":c["bd"],"bt":c["bt"]}); wjson(TLSC,d0)
  if on:
    tls_shell_files(); stunnel_write(c); ufw_open(set(c["ports"])|set(c["tports"]))
    if os.path.exists(TLSFW): cmd([TLSFW,"apply"])                      # per-IP connection limit (also applied again by the stunnel unit)
    if front or not all(cmd(["systemctl","is-active",x])[0]==0 for x in TLS_SVC):
      for s in TLS_SVC[:2]: cmd(["systemctl","enable",s]); cmd(["systemctl","restart",s],20)
      cmd(["systemctl","enable",TLS_SVC[2]]); cmd(["systemctl","restart",TLS_SVC[2]],20)
      end=time.time()+12; want=set(c["ports"])|set(c["tports"])|tls_back_ports(c)       # the public ports AND every Dropbear back end
      while time.time()<end and not want<=set(listen_ports()): time.sleep(0.5)
      miss=sorted(want-set(listen_ports()))
      if miss:
        _,j,_=cmd(["journalctl","-u","sshplus-stunnel","-n","4","--no-pager","-o","cat"],10)
        return 500,{"ok":0,"msg":"TLS front did not start on port(s) %s: %s"%(",".join(map(str,miss)),(j or "see: journalctl -u sshplus-stunnel")[-160:])}
  else:
    for s in reversed(TLS_SVC): cmd(["systemctl","stop",s],20); cmd(["systemctl","disable",s],20)
  if tconf().get("TUN_HOST"): threading.Thread(target=ports_sync,daemon=True).start()     # publish / withdraw the TLS ports on the exit server
  return 200,{"ok":1,"dropped":dropped,"on":on}

def tls_selfsign():
  # back to a self-signed certificate (no domain)
  for f in (CERT,CKEY):
    try: os.remove(f)
    except OSError: pass
  if not ensure_cert(): return 500,{"ok":0,"msg":"openssl failed"}
  if SRV[0] is not None:
    try: SRV[0].ctx=tls_ctx()
    except Exception: pass
  d0=rjson(TLSC,{}); d0.update({"mode":"self","domain":""}); wjson(TLSC,d0); tls_reload()
  return 200,{"ok":1}

# ---- free domain + Let's Encrypt certificate in one click
def pub_ip():
  urls=[os.environ["SSHPLUS_IPCHECK_URL"]] if os.environ.get("SSHPLUS_IPCHECK_URL") else ["https://api.ipify.org","https://ipv4.icanhazip.com"]
  for u in urls:
    rc,o,_=cmd(["curl","-4","-sfL","--max-time","6",u],10)
    if rc==0 and re.match(r"^\d{1,3}(\.\d{1,3}){3}$",o.strip()): return o.strip(),True
  rc,o,_=cmd(["ip","-4","route","get","1.1.1.1"]); m=re.search(r"src (\d+\.\d+\.\d+\.\d+)",o)
  if m:
    import ipaddress
    return m.group(1),not ipaddress.ip_address(m.group(1)).is_private
  return "",False

def dns_ips(host):
  try: return sorted({r[4][0] for r in socket.getaddrinfo(host,None,socket.AF_INET)})
  except Exception: return []

def wait_dns(host,ip,secs):
  end=time.time()+secs
  while True:
    got=dns_ips(host)
    if ip in got or time.time()>=end: return got
    time.sleep(3)

def duck_update(name,token,ip):
  rc,o,er=_run(["curl","-sS","--max-time","20","-K","-"],inp='url = "%s?domains=%s&token=%s&ip=%s"\n'%(DUCK_URL,name,token,ip),t=30)
  return (rc==0 and o.strip().startswith("OK")),(o or er)[:80]

def free_name(prov,ip,p):
  # the domain a free provider gives for this server
  if prov in WILD: return ip.replace(".","-")+"."+WILD[prov]
  if prov=="custom": return ip.replace(".","-")+"."+p["suffix"]
  if prov=="duckdns": return p["duckname"]+".duckdns.org"
  return ""

def le_dir(): return os.environ.get("SSHPLUS_LE_DIR","/etc/letsencrypt")

def write_hook():
  os.makedirs(os.path.dirname(HOOK_PATH),exist_ok=True)
  with open(HOOK_PATH,"w") as f: f.write('#!/bin/sh\n# CK.VPN: after a renewal copy the new certificate to the panel + the TLS front\nexec /usr/bin/python3 /opt/sshplus-panel/app.py --cert-renewed "${RENEWED_LINEAGE:-}"\n')
  os.chmod(HOOK_PATH,0o755)  # nosec B103 - root-owned hook that certbot has to execute

def tls_issue_start(d):
  mode=str(d.get("mode",""))
  if mode not in ("own","free"): return 400,{"ok":0,"msg":"Choose own domain or free domain"}
  email=str(d.get("email","")).strip()
  if email and not MAIL_RE.match(email): return 400,{"ok":0,"msg":"Invalid e-mail address"}
  p={"mode":mode,"email":email,"domain":"","prov":"","suffix":"","duckname":"","duck":""}
  if mode=="own":
    p["domain"]=str(d.get("domain","")).strip().lower()
    if not DOM_RE.match(p["domain"]): return 400,{"ok":0,"msg":"Invalid domain name"}
  else:
    p["prov"]=str(d.get("prov","")); old=rjson(TLSC,{})
    if p["prov"] not in ("sslip","nip","duckdns","custom"): return 400,{"ok":0,"msg":"Unknown free-domain provider"}
    if p["prov"]=="custom":
      p["suffix"]=str(d.get("suffix","")).strip().lower().strip(".")
      if not DOM_RE.match("x."+p["suffix"]): return 400,{"ok":0,"msg":"Invalid wildcard-DNS suffix (e.g. sslip.io)"}
    if p["prov"]=="duckdns":
      p["duckname"]=str(d.get("duckname","")).strip().lower().replace(".duckdns.org","")
      tk=str(d.get("duck","")).strip() or (dec(old.get("duck","")) if old.get("duck") else "")
      if not DUCK_RE.match(p["duckname"]): return 400,{"ok":0,"msg":"Invalid DuckDNS sub-domain (letters, digits, dashes)"}
      if not DUCKTOK_RE.match(tk): return 400,{"ok":0,"msg":"DuckDNS token is required (copy it from your duckdns.org account page)"}
      p["duck"]=tk
  with TJL:
    if TJ["run"]: return 409,{"ok":0,"msg":"A certificate request is already running"}
    TJ["run"]=True; TJ["steps"]=[]; TJ["ok"]=None; TJ["domain"]=""
  threading.Thread(target=tls_issue_run,args=(p,),daemon=True).start()
  return 200,{"ok":1}

def tls_issue_run(p):
  ok=False
  try: ok=_tls_issue(p)
  except Exception as e:
    tj_begin("Internal error"); tj_end(False,str(e)[:200])
  with TJL: TJ["ok"]=bool(ok); TJ["run"]=False

def _tls_issue(p):
  tj_begin("Detecting the public IP of this server"); ip,pub=pub_ip()
  if not ip: tj_end(False,"Could not detect the IP (no internet?)"); return False
  if not pub and p["mode"]=="free": tj_end(False,ip+": a free domain needs a public IP address (the server seems to be behind NAT)"); return False
  tj_end(True if pub else "warn",ip+("" if pub else "  (private address: the server seems to be behind NAT)"))
  if p["mode"]=="own": dom=p["domain"]
  else:
    if p["prov"]=="duckdns":
      tj_begin("Pointing %s.duckdns.org to %s (DuckDNS)"%(p["duckname"],ip)); ok,msg=duck_update(p["duckname"],p["duck"],ip)
      if not ok: tj_end(False,"DuckDNS refused the update (%s). Check the token and that the sub-domain exists in your DuckDNS account."%(msg or "no answer")); return False
      tj_end(True)
    dom=free_name(p["prov"],ip,p)
  with TJL: TJ["domain"]=dom
  tj_begin("Checking that %s points to this server"%dom); got=wait_dns(dom,ip,45 if p["mode"]=="free" else 10)
  if pub and ip not in got:
    res=", ".join(got) or "nothing"
    if p["mode"]=="free": tj_end(False,"%s resolves to %s, not to %s yet. The provider's DNS may be slow or down: try again in a minute, or choose another provider."%(dom,res,ip))
    else: tj_end(False,"%s resolves to %s but this server is %s. Add an A record pointing to %s (if you use Cloudflare, set it to \"DNS only\") and try again."%(dom,res,ip,ip))
    return False
  tj_end(True if pub else "warn",", ".join(got) or "not checked")
  if not have("certbot"):
    tj_begin("Installing certbot (apt)")
    env=dict(ENV,DEBIAN_FRONTEND="noninteractive")
    rc,_,er=_run(["apt-get","install","-y","certbot"],env=env,t=300)
    if rc!=0 or not have("certbot"):
      _run(["apt-get","update","-y"],env=env,t=180); rc,_,er=_run(["apt-get","install","-y","certbot"],env=env,t=300)
    if not have("certbot"): tj_end(False,"certbot could not be installed: "+er[-200:]); return False
    tj_end(True)
  tj_begin("Preparing port 80 (Let's Encrypt validates over HTTP)"); busy=listen_ports().get(80)
  if busy: tj_end(False,"Port 80 is used by %s. Stop it temporarily, or upload a certificate manually."%", ".join(sorted(busy))); return False
  ufw_open({80}); tj_end(True)
  stg=bool(rjson(TLSC,{}).get("staging")); lin=dom+("-staging" if stg else "")           # staging = Let's Encrypt test CA: for trying the flow, the certificate is NOT trusted
  tj_begin("Requesting the certificate from Let's Encrypt%s (about 30 seconds)"%(" STAGING" if stg else "")); write_hook()
  args=["certbot","certonly","--standalone","--non-interactive","--agree-tos","--preferred-challenges","http","--keep-until-expiring",
        "--cert-name",lin,"-d",dom,"--deploy-hook",HOOK_PATH]+(["--test-cert"] if stg else [])+(["--email",p["email"]] if p["email"] else ["--register-unsafely-without-email"])
  rc,o,er=_run(args,t=240); out=(o+"\n"+er).strip()
  if rc!=0:
    hint=" Let's Encrypt is limiting this domain (shared free domains such as sslip.io / nip.io are used by many people): try another provider or your own domain." if re.search(r"rateLimited|too many certificates|rate limit",out,re.I) else ""
    tj_end(False,"certbot failed:"+hint+" "+out[-300:]); return False
  tj_end(True)
  tj_begin("Installing the certificate (panel HTTPS + SSH-TLS)")
  try:
    live=os.path.join(le_dir(),"live",lin); c1=open(os.path.join(live,"fullchain.pem")).read(); k1=open(os.path.join(live,"privkey.pem")).read()
  except Exception as e: tj_end(False,"certificate files not found: "+str(e)[:120]); return False
  code,r=cert_save({"cert":c1,"key":k1})
  if code!=200: tj_end(False,r.get("msg","rejected")); return False
  d0=rjson(TLSC,{}); d0.update({"mode":p["mode"],"domain":dom,"prov":p["prov"],"suffix":p["suffix"],"duckname":p["duckname"],"email":p["email"]})
  if p["duck"]: d0["duck"]=enc(p["duck"])
  wjson(TLSC,d0); tj_end(True,dom+" - the certificate renews automatically (certbot timer)")
  return True

def tls_renew_start():
  c=tls_cfg(); dom=c["domain"]
  lin=dom+("-staging" if c["staging"] else "")
  if c["mode"] not in ("own","free") or not dom or not os.path.isdir(os.path.join(le_dir(),"live",lin)):
    return 400,{"ok":0,"msg":"There is no Let's Encrypt certificate from this panel to renew: use \"Get domain and certificate\" first"}
  with TJL:
    if TJ["run"]: return 409,{"ok":0,"msg":"A certificate request is already running"}
    TJ["run"]=True; TJ["steps"]=[]; TJ["ok"]=None; TJ["domain"]=dom
  threading.Thread(target=tls_renew_run,args=(lin,),daemon=True).start()
  return 200,{"ok":1}

def tls_renew_run(dom):
  ok=False
  try: ok=_tls_renew(dom)
  except Exception as e:
    tj_begin("Internal error"); tj_end(False,str(e)[:200])
  with TJL: TJ["ok"]=bool(ok); TJ["run"]=False

def _tls_renew(dom):
  tj_begin("Preparing port 80 (Let's Encrypt validates over HTTP)"); busy=listen_ports().get(80)
  if busy: tj_end(False,"Port 80 is used by %s. Stop it temporarily and try again."%", ".join(sorted(busy))); return False
  ufw_open({80}); tj_end(True)
  tj_begin("Renewing the certificate with Let's Encrypt (about 30 seconds)"); write_hook()
  rc,o,er=_run(["certbot","renew","--cert-name",dom,"--force-renewal","--non-interactive","--deploy-hook",HOOK_PATH],t=240); out=(o+"\n"+er).strip()
  if rc!=0:
    hint=" Let's Encrypt is limiting this domain: try again later." if re.search(r"rateLimited|too many certificates|rate limit",out,re.I) else ""
    tj_end(False,"certbot failed:"+hint+" "+out[-300:]); return False
  tj_end(True)
  tj_begin("Installing the renewed certificate (panel HTTPS + SSH-TLS)")
  try:
    live=os.path.join(le_dir(),"live",dom); c1=open(os.path.join(live,"fullchain.pem")).read(); k1=open(os.path.join(live,"privkey.pem")).read()
  except Exception as e: tj_end(False,"certificate files not found: "+str(e)[:120]); return False
  code,r=cert_save({"cert":c1,"key":k1})
  if code!=200: tj_end(False,r.get("msg","rejected")); return False
  m=cert_meta(); tj_end(True,"%s - valid until %s"%(dom,m.get("end","?"))); return True

def cli_cert_renewed(lineage):
  # called by the certbot deploy hook after a renewal
  dom=str(rjson(TLSC,{}).get("domain","")); lineage=str(lineage).rstrip("/")
  if not dom or os.path.basename(lineage) not in (dom,dom+"-staging"): return 0
  try: c1=open(lineage+"/fullchain.pem").read(); k1=open(lineage+"/privkey.pem").read()
  except Exception as e: print(e); return 1
  code,r=cert_save({"cert":c1,"key":k1})
  if code!=200: print(r.get("msg","")); return 1
  cmd(["systemctl","--no-block","restart","sshplus-panel"])                  # the panel loads the certificate at start
  return 0

# ---- 2) encrypted backup / restore
BK_MAGIC=b"CKBK1"
BK_FILES=[CFG,PORTS,BV,META,TCONF,TKEY,TKEY+".pub",TKH,SECRETK,DB,TGC,TPL,HIST,CERT,CKEY,TLSC,WGPRIV,WGPUB]

def bk_key(pw,salt): return base64.urlsafe_b64encode(hashlib.pbkdf2_hmac("sha256",pw.encode(),salt,200000,32))

def make_backup(pw):
  if not HAVE_FERNET: raise Exception("python3-cryptography is not installed")
  files={}
  for f in BK_FILES:
    try: files[f]=base64.b64encode(open(f,"rb").read()).decode()
    except Exception: pass
  sh=shadow_map(); users=[]
  for u,(uid,shl) in passwd_map().items():
    h,ex=sh.get(u,("",""))
    users.append({"u":u,"sh":shl,"h":h,"ex":ex})
  raw=json.dumps({"ver":VERSION,"ts":int(time.time()),"files":files,"users":users}).encode()
  salt=os.urandom(16)
  return BK_MAGIC+salt+Fernet(bk_key(pw,salt)).encrypt(raw)

def restore_backup(raw,pw):
  if not HAVE_FERNET: return 500,{"ok":0,"msg":"python3-cryptography is not installed"}
  if not raw.startswith(BK_MAGIC) or len(raw)<40: return 400,{"ok":0,"msg":"Not a CK.VPN backup file"}
  try: d=json.loads(Fernet(bk_key(pw,raw[5:21])).decrypt(raw[21:]))
  except InvalidToken: return 400,{"ok":0,"msg":"Wrong passphrase or damaged file"}
  except Exception: return 400,{"ok":0,"msg":"Backup could not be read"}
  allowed=set(BK_FILES)
  for path,b in d.get("files",{}).items():
    if path not in allowed: continue
    t=path+".r"; fd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.write(fd,base64.b64decode(b)); os.close(fd); os.replace(t,path)
  _FER[0]=None
  n=0
  for x in d.get("users",[]):
    u=str(x.get("u","")); shl=x.get("sh") if x.get("sh") in SHELL_OF else SHELL
    if not NAME_RE.match(u) or u in ("root","admin","ubuntu","nobody"): continue
    if cmd(["id","-u",u])[0]!=0:
      ea=[]
      if str(x.get("ex","")).isdigit(): ea=["-e",(datetime(1970,1,1)+timedelta(days=int(x["ex"]))).strftime("%Y-%m-%d")]
      if cmd(["useradd","-M","-s",shl]+ea+[u])[0]!=0: continue
    else: cmd(["usermod","-s",shl,u])
    if x.get("h"): cmd(["usermod","-p",str(x["h"]),u])
    n+=1
  if os.path.exists(TNET): cmd([TNET,"sync"])
  sshd_deny_sync()
  for sv in ("sshplus-dropbear","sshplus-dropbear-t","badvpn","badvpn-t"): cmd(["systemctl","restart",sv])
  if tls_cfg()["on"]: threading.Thread(target=tls_apply,args=({"on":True},),daemon=True).start()
  if tconf().get("TUN_HOST"):
    cmd(["systemctl","restart","sshplus-tunnel"],30); threading.Thread(target=ports_sync,daemon=True).start()
  threading.Timer(3,lambda: cmd(["systemctl","--no-block","restart","sshplus-panel"])).start()      # reload settings / password / certificate
  return 200,{"ok":1,"users":n}

# ---- 4) Telegram: alerts, daily backup, small bot. Goes direct first, then through the tunnel (Telegram is often blocked)
def tg_cfg():
  c=rjson(TGC,{}); c["token"]=dec(c.get("token","")); c["bpass"]=dec(c.get("bpass","")); return c

def tg_base(): return os.environ.get("SSHPLUS_TG_BASE","https://api.telegram.org")

def tg_call(method,params,file=None,timeout=20):
  c=tg_cfg()
  if not c.get("token"): return None
  q=lambda v: str(v).replace("\\","\\\\").replace('"','\\"').replace("\n","\\n").replace("\r","")
  base=['url = "%s/bot%s/%s"'%(tg_base(),c["token"],method),"silent","show-error","connect-timeout = 6","max-time = %d"%timeout]
  for k,v in params.items(): base.append('form-string = "%s=%s"'%(k,q(v)))
  if file: base.append('form = "document=@%s"'%file)
  tries=[("direct",[])]
  if tconf().get("TUN_HOST") and cmd(["ip","link","show",TUN_DEV])[0]==0: tries.append(("tun",['interface = "%s"'%TUN_LOCAL]))
  if TG["via"]=="tun": tries.reverse()
  for name,extra in tries:
    try:
      r=subprocess.run(["curl","-K","-"],input="\n".join(base+extra)+"\n",capture_output=True,text=True,timeout=timeout+8,env=ENV)
      if r.returncode==0 and r.stdout.strip():
        j=json.loads(r.stdout)
        TG["via"]=name; return j
    except Exception: pass
  return None

def tg_send(text):
  c=tg_cfg()
  if not (c.get("token") and c.get("chat")): return False
  r=tg_call("sendMessage",{"chat_id":c["chat"],"text":str(text)[:3900]})
  return bool(r and r.get("ok"))

def tg_send_backup(tag="backup"):
  c=tg_cfg()
  if not (c.get("token") and c.get("chat") and c.get("bpass")): return False,"backup passphrase is not set"
  try: raw=make_backup(c["bpass"])
  except Exception as e: return False,str(e)
  import tempfile
  td=tempfile.mkdtemp(prefix="ckvpn-")                          # private (0700) directory: no predictable /tmp name for a local user to pre-create or symlink
  fn=os.path.join(td,"ckvpn-%s-%s.ckbk"%(tag,datetime.now().strftime("%Y%m%d-%H%M")))
  fd=os.open(fn,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.write(fd,raw); os.close(fd)
  try: r=tg_call("sendDocument",{"chat_id":c["chat"],"caption":"CK.VPN backup (encrypted) v"+VERSION},file=fn,timeout=60)
  finally: shutil.rmtree(td,ignore_errors=True)
  return bool(r and r.get("ok")),("" if (r and r.get("ok")) else "Telegram unreachable")

def tg_save(d):
  c=rjson(TGC,{})
  if str(d.get("token","")).strip(): c["token"]=enc(str(d["token"]).strip())
  if str(d.get("bpass","")).strip(): c["bpass"]=enc(str(d["bpass"]).strip())
  if "chat" in d: c["chat"]=str(d.get("chat","")).strip()[:40]
  a=d.get("alerts") or {}
  c["alerts"]={k:bool(a.get(k)) for k in ("tunnel","quota","expiry","res","daily")}
  try: c["hour"]=min(23,max(0,int(d.get("hour",3))))
  except Exception: c["hour"]=3
  wjson(TGC,c); return 200,{"ok":1}

def tg_state():
  c=rjson(TGC,{}); return {"set":bool(c.get("token")),"chat":c.get("chat",""),"bpass":bool(c.get("bpass")),
    "alerts":c.get("alerts",{"tunnel":True,"quota":True,"expiry":True,"res":True,"daily":False}),"hour":c.get("hour",3)}

def tg_detect():
  r=tg_call("getUpdates",{"timeout":0},timeout=20)
  if not r: return 200,{"ok":0,"msg":"Telegram unreachable (direct and through the tunnel)"}
  seen={}
  for u in r.get("result",[]):
    m=u.get("message") or {}; ch=m.get("chat") or {}
    if ch.get("id") is not None: seen[str(ch["id"])]=ch.get("title") or ch.get("username") or ch.get("first_name") or ""
  return 200,{"ok":1,"chats":[{"id":k,"name":v} for k,v in seen.items()]}

def fmt_bytes(n):
  n=float(n)
  for u in ("B","KB","MB","GB","TB"):
    if n<1024 or u=="TB": return ("%.0f %s"%(n,u)) if u=="B" else ("%.1f %s"%(n,u))
    n/=1024

def status_text():
  st=stats(); t=tunnel_status(False); users=get_users(st["om"])
  l=["CK.VPN v%s"%VERSION,"CPU %s%% | RAM %s%%"%(st["cpu"],st["mem"]),
     "Online: %d / %d users"%(st["on_tot"],len(users)),
     "Dropbear: %s | tunnel Dropbear: %s | UDPGW: %s/%s"%("OK" if st["db"] else "DOWN","OK" if st["dbt"] else "DOWN","OK" if st["bv"] else "DOWN","OK" if st["bvt"] else "DOWN")]
  l.append("Tunnel: "+(("UP (exit %s)"%(t["exit"] or t["host"])) if t["up"] else "DOWN") if t["conf"] else "Tunnel: not set up")
  return "\n".join(l)

def users_text(limit=40):
  us=sorted(get_users({}),key=lambda x:-x["q"] if x["q"]>0 else 0)
  out=[]
  for x in us[:limit]:
    out.append("%s  %s%s  %s  %s"%(x["u"],x["ugb"],("/%gGB"%x["q"]) if x["q"]>0 else "","exp "+x["exp"],"EXPIRED" if x["expd"] else ("FULL" if x["qfull"] else "")))
  return "\n".join(out) or "no users"

def tg_cmd(t):
  w=(t.split() or [""])[0].split("@")[0].lower()
  if w in ("/start","/help"): tg_send("CK.VPN bot\n/status  status\n/users  users and usage\n/online  who is online\n/backup  encrypted backup file")
  elif w=="/status": tg_send(status_text())
  elif w=="/users": tg_send(users_text())
  elif w=="/online":
    om=stats()["om"]; tg_send("\n".join("%s: %d"%(k,v) for k,v in sorted(om.items())) or "nobody online")
  elif w=="/backup":
    ok,er=tg_send_backup("manual")
    if not ok: tg_send("backup failed: "+er)

def tg_poll():
  off=0
  while True:
    try:
      c=tg_cfg()
      if not (c.get("token") and c.get("chat")): time.sleep(10); continue
      r=tg_call("getUpdates",{"offset":off,"timeout":10},timeout=25)
      if not r or not r.get("ok"): time.sleep(20); continue
      for u in r.get("result",[]):
        off=u["update_id"]+1
        m=u.get("message") or {}
        if str((m.get("chat") or {}).get("id"))==str(c["chat"]): tg_cmd((m.get("text") or "").strip())
      time.sleep(3)
    except Exception: time.sleep(15)

def tg_once(key,text):
  s=rjson(TGS,{})
  if s.get(key): return
  if tg_send(text): s[key]=int(time.time()); wjson(TGS,s)

def tg_clear(prefix):
  s=rjson(TGS,{}); k=[x for x in s if x.startswith(prefix)]
  for x in k: s.pop(x)
  if k: wjson(TGS,s)

def alerts_tick(res):
  c=tg_cfg()
  if not (c.get("token") and c.get("chat")): return
  a=c.get("alerts",{"tunnel":True,"quota":True,"expiry":True,"res":True,"daily":False})
  if a.get("tunnel") and res["up"]>=0:
    if res["up"]==0:
      TG["tdown"]+=1
      if TG["tdown"]==2 and TG["tun"]!=0: TG["tun"]=0; tg_send("🔴 Tunnel is DOWN (tunnel accounts have no internet until it is back)")
    else:
      TG["tdown"]=0
      if TG["tun"]==0: tg_send("🟢 Tunnel is UP again")
      TG["tun"]=1
  if a.get("res"):
    hi=res["cpu"]>=90 or res["mem"]>=90
    TG["cpu"]=TG["cpu"]+1 if hi else 0
    if TG["cpu"]==3: tg_send("⚠️ High load for 3 minutes: CPU %s%% RAM %s%%"%(res["cpu"],res["mem"]))
  if a.get("quota") or a.get("expiry"):
    meta=rjson(META,{}); today=int(time.time()//86400); sh=shadow_map()
    for u in user_uid_map():
      m=meta.get(u,{}); q=float(m.get("q",0)); used=int(m.get("u",0))
      if a.get("quota") and q>0:
        pct=used/(q*1073741824.0)
        if pct>=1: tg_once("q100:"+u,"⛔ %s: quota is FULL (%s of %g GB)"%(u,fmt_bytes(used),q))
        elif pct>=0.9: tg_once("q90:"+u,"⚠️ %s: 90%% of the quota is used (%s of %g GB)"%(u,fmt_bytes(used),q))
        else: tg_clear("q100:"+u); tg_clear("q90:"+u)
      ex=sh.get(u,("",""))[1]
      if a.get("expiry") and ex.isdigit():
        dl=int(ex)-today
        if dl<=0: tg_once("e0:"+u+":"+ex,"⛔ %s: account EXPIRED"%u)
        elif dl<=3: tg_once("e3:"+u+":"+ex,"⏳ %s: %d day(s) left"%(u,dl))
  if a.get("daily") and datetime.now().hour==int(c.get("hour",3)):
    s=rjson(TGS,{}); day=datetime.now().strftime("%Y-%m-%d")
    if s.get("backup_day")!=day:
      s["backup_day"]=day; wjson(TGS,s); threading.Thread(target=tg_send_backup,args=("daily",),daemon=True).start()

# ---- 5) templates and bulk creation
def tpl_list(): return rjson(TPL,[])

def tpl_save(d):
  name=str(d.get("name","")).strip()[:40]
  if not name: return 400,{"ok":0,"msg":"Template name required"}
  t={"name":name,"d":max(1,int(float(d.get("d") or 30))),"q":max(0.0,float(d.get("q") or 0)),"l":max(1,int(float(d.get("l") or 1))),
     "en":"B" if d.get("en")=="B" else "A","tm":"tunnel" if d.get("tm")=="tunnel" else "direct","cx":d.get("cx") if d.get("cx") in ("normal","tls") else "both"}
  ls=[x for x in tpl_list() if x.get("name")!=name]+[t]; wjson(TPL,ls[:60]); return 200,{"ok":1}

def tpl_del(d):
  wjson(TPL,[x for x in tpl_list() if x.get("name")!=str(d.get("name",""))]); return 200,{"ok":1}

def rand_pw(n=8): return "".join(secrets.choice(PWCH) for _ in range(n))

def user_bulk(d):
  prefix=str(d.get("prefix","")).strip()
  try: count=int(d.get("count",0)); start=int(d.get("start",1) or 1)
  except Exception: return 400,{"ok":0,"msg":"Invalid count"}
  if not re.match(r"^[A-Za-z_][A-Za-z0-9_-]{0,20}$",prefix): return 400,{"ok":0,"msg":"Invalid prefix (letters/digits, max 21 chars)"}
  if not 1<=count<=200: return 400,{"ok":0,"msg":"Count must be 1..200"}
  same=str(d.get("pw","")).strip(); width=len(str(start+count-1)); made=[]; errs=[]
  for i in range(count):
    name="%s%0*d"%(prefix,width,start+i); pw=same or rand_pw(8)
    c,r=user_save({"u":name,"pw":pw,"d":d.get("d",30),"q":d.get("q",0),"l":d.get("l",1),"pt":"All","tm":d.get("tm","direct"),"cx":d.get("cx","both"),"en":d.get("en","A")})
    if c==200: made.append({"u":name,"pw":pw})
    else: errs.append({"u":name,"msg":r.get("msg","")})
  return 200,{"ok":1,"created":made,"errors":errs}

# ---- 6) subscription links and QR codes
def sub_find(tok):
  if not re.match(r"^[0-9a-f]{24}$",str(tok)): return None
  for u,m in rjson(META,{}).items():
    if m.get("tok")==tok and u in user_uid_map(): return u
  return None

def sub_data(u,hosthdr):
  x=next((y for y in get_users({}) if y["u"]==u),None)
  if not x: return None
  tc=tunnel_status(False); pc=rjson(PORTS,{}); out=x["tm"]=="tunnel"; inB=x.get("en")=="B" and tc["conf"]
  host=tc["host"] if inB else re.sub(r":\d+$","",hosthdr or "")
  dbl=list(pc.get("tdb" if out else "db",[]))
  if inB:
    mp={r["a"]:r["b"] for r in tc["rev_map"]}; s2=pc.get("ssh2") or 0
    ssh=[mp[s2]] if s2 in mp else []; dbl=[mp[p] for p in dbl if p in mp]
  else: ssh=sorted(sshd_ports())
  x.update({"host":host,"ssh":ssh,"db":dbl,"in":"B" if inB else "A","out":"B" if out else "A","exit":(tc["exit"] or tc["host"]) if out else host})
  tl=tls_cfg(); x["tls"]=None
  if tl["on"] and x.get("cx","both")!="normal":                    # SSH over TLS: the host is the domain if there is one (the exit server's address when entering via server 2)
    tp=list(tl["tports" if out else "ports"])
    if inB: mp2={r["a"]:r["b"] for r in tc["rev_map"]}; tp=[mp2[p] for p in tp if p in mp2]
    if tp:
      x["tls"]={"host":host if inB else (tl["domain"] or host),"ports":tp,"sni":tl["domain"],"insecure":tl["mode"]=="self"}
      if x["cx"]=="tls": x["db"]=[]; x["ssh"]=[]                  # TLS-only account: do not offer the plain ports
  return x

def ssh_uri(x):
  if x.get("tls") and not (x["db"] or x["ssh"]): return ssh_uris(x)[0]
  p=(x["db"] or x["ssh"] or [22])[0]
  return "ssh://%s:%s@%s:%d#%s"%(quote(x["u"],safe=""),quote(x["pw"],safe=""),x["host"],p,quote("CK.VPN-"+x["u"],safe=""))

def ssh_uris(x,b64auth=False):
  # one ssh:// link per usable port: ssh://user:pass@host:port#remark  (b64auth: base64("user:pass") as the userinfo)
  out=[]; seen=set()
  for p in list(x["db"])+list(x["ssh"]):
    if p in seen: continue
    seen.add(p)
    ui=quote(base64.b64encode(("%s:%s"%(x["u"],x["pw"])).encode()).decode(),safe="") if b64auth else "%s:%s"%(quote(x["u"],safe=""),quote(x["pw"],safe=""))
    out.append("ssh://%s@%s:%d#%s"%(ui,x["host"],p,quote("CK.VPN-%s-%d"%(x["u"],p),safe="")))
  t=x.get("tls")
  if t:                                            # SSH over TLS (there is no standard URI: security=tls + sni is the usual convention)
    q="?security=tls"+("&sni="+quote(t["sni"],safe="") if t.get("sni") else "")+("&allowInsecure=1" if t.get("insecure") else "")
    for p in t["ports"]:
      ui=quote(base64.b64encode(("%s:%s"%(x["u"],x["pw"])).encode()).decode(),safe="") if b64auth else "%s:%s"%(quote(x["u"],safe=""),quote(x["pw"],safe=""))
      out.append("ssh://%s@%s:%d%s#%s"%(ui,t["host"],p,q,quote("CK.VPN-%s-TLS-%d"%(x["u"],p),safe="")))
  return out or [ssh_uri(x)]

def sub_list(u,hosthdr,fmt,auth):
  x=sub_data(u,hosthdr)
  if not x: return None,None,{}
  text="\n".join(ssh_uris(x,auth=="b64"))+"\n"
  body=base64.b64encode(text.encode()).decode() if fmt!="plain" else text
  m=rjson(META,{}).get(u,{}); q=float(m.get("q",0)); ex=shadow_map().get(u,("",""))[1]
  hdr={"Cache-Control":"no-store","Content-Disposition":'inline; filename="ckvpn-%s.txt"'%u,"Profile-Title":"CK.VPN-%s"%u,"Profile-Update-Interval":"12",
       "Subscription-Userinfo":"upload=0; download=%d; total=%d; expire=%d"%(int(m.get("u",0)),int(q*1073741824),(int(ex)*86400 if ex.isdigit() else 0))}
  return x,body,hdr

def qr_svg(text):
  if not HAVE_QR: return ""
  img=qrcode.make(text,image_factory=qrcode.image.svg.SvgPathImage,box_size=10,border=2)
  b=io.BytesIO(); img.save(b); return b.getvalue().decode()

SUBT={"fa":{"dir":"rtl","title":"وضعیت اکانت","status":"وضعیت","ok":"فعال","bad":"منقضی/پر","exp":"انقضا","days":"روز","usage":"مصرف","unl":"نامحدود",
  "conc":"اتصال همزمان","info":"اطلاعات اتصال","host":"آدرس","user":"نام کاربری","pw":"رمز","ssh":"پورت‌های SSH","db":"پورت‌های Dropbear","exit":"IP خروجی",
  "qr":"لینک و QR","cpl":"کپی لینک ssh","cpa":"کپی همه‌ی اطلاعات","copied":"کپی شد","other":"English","tls":"پورت‌های TLS","insec":"گواهی self-signed است: در برنامه گزینه‌ی «اجازه به گواهی نامعتبر / Allow insecure» را روشن کنید."},
 "en":{"dir":"ltr","title":"Account status","status":"Status","ok":"Active","bad":"Expired/Full","exp":"Expires","days":"days","usage":"Usage","unl":"Unlimited",
  "conc":"Concurrent connections","info":"Connection info","host":"Host","user":"Username","pw":"Password","ssh":"SSH ports","db":"Dropbear ports","exit":"Exit IP",
  "qr":"Link & QR","cpl":"Copy ssh link","cpa":"Copy all info","copied":"Copied","other":"فارسی","tls":"TLS ports","insec":"The certificate is self-signed: turn on \"Allow insecure\" in the app."}}
SUBHTML='''<!DOCTYPE html><html lang="@@LANG@@" dir="@@DIR@@"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CK.VPN - @@USER@@</title><meta name="robots" content="noindex">
<style>:root{--bg:#0b1120;--card:#111827;--bd:#1f2937;--tx:#f3f4f6;--mu:#9ca3af;--pr:#06b6d4;--ok:#10b981;--er:#ef4444;--wn:#f59e0b}
*{box-sizing:border-box;margin:0;padding:0;font-family:system-ui,Tahoma,sans-serif}body{background:var(--bg);color:var(--tx);padding:1rem;max-width:560px;margin:auto}
.card{background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:1.1rem;margin-bottom:1rem}h1{font-size:1.3rem}h3{margin-bottom:.6rem;color:var(--pr)}
.row{display:flex;justify-content:space-between;gap:.6rem;padding:.4rem 0;border-bottom:1px solid var(--bd);font-size:.9rem}.row:last-child{border:0}.row span:first-child{color:var(--mu)}
.bar{height:10px;border-radius:99px;background:#080c17;overflow:hidden;margin:.5rem 0}.bar>i{display:block;height:100%;background:var(--pr)}
.btn{background:var(--pr);color:#031116;border:0;padding:.5rem .9rem;border-radius:8px;font-weight:700;cursor:pointer;margin:.15rem}
.bdg{padding:.15rem .6rem;border-radius:99px;font-size:.75rem;font-weight:700}.ok{background:rgba(16,185,129,.15);color:var(--ok)}.er{background:rgba(239,68,68,.15);color:var(--er)}
code{direction:ltr;display:inline-block;word-break:break-all;color:var(--pr)}.qr{background:#fff;border-radius:12px;padding:10px;max-width:240px;margin:.6rem auto}.qr svg{width:100%;height:auto;display:block}</style></head><body>
<div class="card" style="display:flex;align-items:center;gap:.8rem"><div style="font-size:2rem;font-weight:800;color:var(--pr)">CK</div><div><h1>CK.VPN</h1><div style="color:var(--mu);font-size:.8rem">@@USER@@</div></div><a href="?lang=@@OTHERLANG@@" onclick="try{localStorage.setItem('lang','@@OTHERLANG@@')}catch(e){}" style="margin-inline-start:auto;color:var(--pr);font-size:.8rem;text-decoration:none">@@T_other@@</a></div>
<div class="card"><h3>@@T_title@@</h3>
<div class="row"><span>@@T_status@@</span><span class="bdg @@STCLS@@">@@STTXT@@</span></div>
<div class="row"><span>@@T_exp@@</span><span dir="ltr">@@EXP@@ (@@DL@@ @@T_days@@)</span></div>
<div class="row"><span>@@T_usage@@</span><span dir="ltr">@@USED@@ / @@QUOTA@@</span></div><div class="bar"><i style="width:@@PCT@@%"></i></div>
<div class="row"><span>@@T_conc@@</span><span>@@LIM@@</span></div></div>
<div class="card"><h3>@@T_info@@</h3>
<div class="row"><span>@@T_host@@</span><code>@@HOST@@</code></div><div class="row"><span>@@T_user@@</span><code>@@USER@@</code></div><div class="row"><span>@@T_pw@@</span><code>@@PASS@@</code></div>
<div class="row"><span>@@T_ssh@@</span><code>@@SSH@@</code></div><div class="row"><span>@@T_db@@</span><code>@@DB@@</code></div>
<div class="row"><span>UDPGW</span><code>127.0.0.1:7300</code></div>
<div class="row"><span>@@T_exit@@</span><code>@@EXIT@@</code></div>@@TLSROWS@@</div>
<div class="card" style="text-align:center"><h3>@@T_qr@@</h3><div class="qr">@@QR@@</div><div style="margin:.5rem 0"><code>@@URI@@</code></div>
<button class="btn" onclick="cp(@@URIJS@@)">@@T_cpl@@</button><button class="btn" onclick="cp(@@ALLJS@@)">@@T_cpa@@</button></div>
<script>function cp(t){var ok=function(){alert("@@T_copied@@")},fb=function(){try{var a=document.createElement("textarea");a.value=t;a.style.cssText="position:fixed;opacity:0";document.body.appendChild(a);a.focus();a.select();a.setSelectionRange(0,t.length);var r=document.execCommand("copy");a.remove();if(r){ok();return}}catch(e){}prompt("Copy:",t)};if(window.isSecureContext&&navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(t).then(ok,fb);else fb()}
try{if(!/[?&]lang=/.test(location.search)&&localStorage.getItem("lang")==="en")location.replace(location.pathname+"?lang=en")}catch(e){}</script></body></html>'''

def sub_page(u,hosthdr,lang="fa"):
  lang="en" if lang=="en" else "fa"; T=SUBT[lang]
  x=sub_data(u,hosthdr)
  if not x: return None
  esc_=lambda v: (str(v).replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;"))
  uri=ssh_uri(x); q=x["q"]; used_txt=x["ugb"]
  try: pct=min(100,int(100*float(x["ugb"].split()[0])*(1024 if x["ugb"].endswith("GB") else 1)/(q*1024))) if q>0 else 0
  except Exception: pct=0
  bad=x["expd"] or x["qfull"]
  allt="Host: %s\nUser: %s\nPass: %s\nSSH ports: %s\nDropbear ports: %s\nUDPGW: 127.0.0.1:7300"%(x["host"],x["u"],x["pw"],", ".join(map(str,x["ssh"])) or "-",", ".join(map(str,x["db"])) or "-")
  tr=""; t=x.get("tls")
  if t:
    allt+="\n\n"+tls_manual_text(x)
    tr='<div class="row"><span>%s</span><code>%s</code></div>'%(T["tls"],esc_(", ".join(map(str,t["ports"]))))
    if t.get("sni"): tr+='<div class="row"><span>SNI</span><code>%s</code></div>'%esc_(t["sni"])
    if t.get("insecure"): tr+='<div class="row" style="color:var(--wn);font-size:.8rem">%s</div>'%esc_(T["insec"])
  rep={"TLSROWS":tr,"USER":esc_(x["u"]),"STCLS":"er" if bad else "ok","STTXT":T["bad"] if bad else T["ok"],"EXP":esc_(x["exp"]),"DL":x["dl"],"USED":esc_(used_txt),
       "QUOTA":("%g GB"%q) if q>0 else T["unl"],"PCT":pct,"LIM":x["lim"],"HOST":esc_(x["host"]),"PASS":esc_(x["pw"]),
       "SSH":esc_(", ".join(map(str,x["ssh"])) or "-"),"DB":esc_(", ".join(map(str,x["db"])) or "-"),"EXIT":esc_(x["exit"]),
       "QR":qr_svg(uri) or "<div style='color:#555;font-size:.8rem'>QR unavailable (python3-qrcode)</div>","URI":esc_(uri),
       "URIJS":json.dumps(uri).replace("<","\\u003c").replace("\"","&quot;"),"ALLJS":json.dumps(allt).replace("<","\\u003c").replace("\"","&quot;")}
  h=SUBHTML.replace("@@LANG@@",lang).replace("@@DIR@@",T["dir"]).replace("@@OTHERLANG@@","fa" if lang=="en" else "en")
  for k,v in T.items(): h=h.replace("@@T_%s@@"%k,v)
  for k,v in rep.items(): h=h.replace("@@%s@@"%k,str(v))
  return h

# ---- 7) history: tunnel health, load, daily traffic per user
def res_now():
  try:
    l1=float(open("/proc/loadavg").read().split()[0]); cpu=min(100.0,round((l1/(os.cpu_count() or 1))*100,1))
  except Exception: cpu=0.0
  try:
    mi={l.split()[0].rstrip(":"):int(l.split()[1]) for l in open("/proc/meminfo") if len(l.split())>=2}
    mem=round(((mi.get("MemTotal",1)-mi.get("MemAvailable",0))/mi.get("MemTotal",1))*100,1)
  except Exception: mem=0.0
  up=-1; rtt=0
  if tconf().get("TUN_HOST"):
    ok,ms=tun_probe(); up=1 if ok else 0; rtt=ms
  return {"t":int(time.time()),"up":up,"rtt":rtt,"cpu":cpu,"mem":mem}

def hist_tick():
  r=res_now(); h=rjson(HIST,{"s":[],"d":{}})
  h["s"]=(h.get("s",[])+[[r["t"],r["up"],r["rtt"],r["cpu"],r["mem"]]])[-1440:]
  day=datetime.now().strftime("%Y-%m-%d"); dd=h.setdefault("d",{}); cur=dd.setdefault(day,{})
  with ML:
    snap=dict(DAYU); DAYU.clear()
  for u,b in snap.items(): cur[u]=int(cur.get(u,0))+int(b)
  for k in sorted(dd)[:-35]: dd.pop(k,None)
  wjson(HIST,h)
  return r

def hist_get():
  h=rjson(HIST,{"s":[],"d":{}}); days=sorted(h.get("d",{}))[-14:]
  return {"s":h.get("s",[]),"d":{k:h["d"][k] for k in days}}

# ---------- HTTP ----------
class Srv(ThreadingHTTPServer):
  allow_reuse_address=True; daemon_threads=True; request_queue_size=64; ctx=None
  def finish_request(s,request,client_address):
    try:
      if s.ctx is not None:
        request.settimeout(10)
        if request.recv(1,socket.MSG_PEEK)==b"\x16": request=s.ctx.wrap_socket(request,server_side=True)
        elif rjson(CFG,{}).get("plain_sub") and re.match(rb"GET /s/[0-9a-f]{24}[ ?]",request.recv(2048,socket.MSG_PEEK)): pass     # opt-in: subscription URL over plain HTTP
        else:                                   # plain HTTP on the TLS port: answer with a redirect to https
          buf=request.recv(4096); host=""
          for l in buf.split(b"\r\n"):
            if l.lower().startswith(b"host:"): host=l[5:].strip().decode("latin1")[:100]
          host=re.sub(r"[^A-Za-z0-9.:\[\]-]","",host) or "localhost"
          request.sendall(("HTTP/1.1 301 Moved Permanently\r\nLocation: https://%s/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"%host).encode())
          return
        request.settimeout(None)
      s.RequestHandlerClass(request,client_address,s)
    except Exception: pass
    finally:
      try: request.close()
      except Exception: pass

class H(BaseHTTPRequestHandler):
  def log_message(s,*a): pass
  def js(s,d,c=200):
    b=json.dumps(d).encode("utf-8")
    s.send_response(c); s.send_header("Content-Type","application/json; charset=utf-8")
    s.send_header("Content-Length",str(len(b))); s.end_headers(); s.wfile.write(b)
  def raw(s,b,ctype,c=200,extra=None):
    s.send_response(c); s.send_header("Content-Type",ctype); s.send_header("Content-Length",str(len(b)))
    for k,v in (extra or {}).items(): s.send_header(k,v)
    s.end_headers(); s.wfile.write(b)
  def auth(s):
    a=s.headers.get("Authorization","")
    return a.startswith("Bearer ") and TOK.get(a[7:].strip(),0)>time.time()
  def do_GET(s):
    try:
      p=urlparse(s.path).path
      if p in ("/","/index.html"):
        b=open(HTML,"rb").read()
        s.send_response(200); s.send_header("Content-Type","text/html;charset=utf-8"); s.send_header("Cache-Control","no-cache")   # revalidate: a panel update shows up without a hard refresh
        s.send_header("Content-Length",str(len(b))); s.end_headers(); s.wfile.write(b); return
      if p.startswith("/s/"):                                   # public subscription page (secret token in the URL)
        k="s:"+s.client_address[0]; now=time.time(); FAIL[k]=[t for t in FAIL.get(k,[]) if now-t<300]
        if len(FAIL[k])>=20: s.js({"err":2},429); return
        qs=parse_qs(urlparse(s.path).query); u=sub_find(p[3:]); host=s.headers.get("Host","")
        fmt=qs.get("fmt",[""])[0] or ("html" if "text/html" in s.headers.get("Accept","") else "b64")     # apps do not ask for text/html
        if not u: FAIL[k].append(now); s.raw(b"not found","text/plain",404); return
        if fmt=="html":
          s.raw(sub_page(u,host,qs.get("lang",["fa"])[0]).encode(),"text/html; charset=utf-8",200,{"Cache-Control":"no-store","Referrer-Policy":"no-referrer","X-Robots-Tag":"noindex"}); return
        x,body,hdr=sub_list(u,host,fmt,qs.get("auth",["plain"])[0])
        if body is None: s.raw(b"not found","text/plain",404); return
        s.raw(body.encode(),"text/plain; charset=utf-8",200,hdr); return
      if not s.auth(): s.js({"err":1},401); return
      if must_change(): s.js({"err":"must_change"},403); return
      if p=="/api/qr":
        u=parse_qs(urlparse(s.path).query).get("u",[""])[0]; x=sub_data(u,s.headers.get("Host",""))
        if not x: s.js({"err":404},404); return
        s.raw(qr_svg(ssh_uri(x)).encode(),"image/svg+xml"); return
      if p=="/api/sublinks":
        u=parse_qs(urlparse(s.path).query).get("u",[""])[0]; x=sub_data(u,s.headers.get("Host",""))
        if not x: s.js({"err":404},404); return
        s.js({"ssh":ssh_uris(x),"sshb":ssh_uris(x,True),"plain_sub":bool(rjson(CFG,{}).get("plain_sub")),"tlsinfo":tls_manual_text(x)}); return
      if p=="/api/history": s.js(hist_get()); return
      if p=="/api/telegram": s.js(tg_state()); return
      if p=="/api/templates": s.js(tpl_list()); return
      if p=="/api/cert": s.js({"info":cert_info(),"https":bool(SRV[0] and SRV[0].ctx is not None),"plain_sub":bool(rjson(CFG,{}).get("plain_sub"))}); return
      if p=="/api/tls": s.js(tls_state()); return
      if p=="/api/overview":
        st=stats(); bv=read_bv()
        pc=rjson(PORTS,{"ssh":22,"ssh2":2222,"db":[]}); pc["ssh_all"]=sorted(sshd_ports()); pc.setdefault("tdb",[])
        adm=str(rjson(CFG,{"username":"admin"}).get("username","admin")).strip()
        s.js({"st":st,"ports":pc,"bv":bv,"bbr":bbr_state(),"adm":adm,"tun":tunnel_status(False),"ver":VERSION,"fer":HAVE_FERNET,"qr":HAVE_QR,"tls":tls_brief(),"users":get_users(st["om"])}); return
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
          t=secrets.token_hex(16); TOK[t]=time.time()+86400; s.js({"tok":t,"chg":1 if must_change() else 0})
        else:
          FAIL[ip].append(time.time()); s.js({"err":1},401)
        return
      if not s.auth(): s.js({"err":1},401); return
      if must_change() and p!="/api/admin": s.js({"err":"must_change"},403); return
      if p=="/api/user/save": c,r=user_save(d); s.js(r,c)
      elif p=="/api/user/bulk": c,r=user_bulk(d); s.js(r,c)
      elif p=="/api/template/save": c,r=tpl_save(d); s.js(r,c)
      elif p=="/api/template/del": c,r=tpl_del(d); s.js(r,c)
      elif p=="/api/cert": c,r=cert_save(d); s.js(r,c)
      elif p=="/api/tls/save": c,r=tls_apply(d); s.js(r,c)
      elif p=="/api/tls/issue": c,r=tls_issue_start(d); s.js(r,c)
      elif p=="/api/tls/self": c,r=tls_selfsign(); s.js(r,c)
      elif p=="/api/tls/renew": c,r=tls_renew_start(); s.js(r,c)
      elif p=="/api/plainsub":
        c2=rjson(CFG,{"port":2053,"username":"admin","password":"admin"}); c2["plain_sub"]=bool(d.get("on")); wjson(CFG,c2); s.js({"ok":1,"plain_sub":c2["plain_sub"]})
      elif p=="/api/telegram": c,r=tg_save(d); s.js(r,c)
      elif p=="/api/telegram/test": s.js({"ok":1 if tg_send("✅ CK.VPN v%s: Telegram connection works"%VERSION) else 0})
      elif p=="/api/telegram/detect": c,r=tg_detect(); s.js(r,c)
      elif p=="/api/telegram/backup": ok,er=tg_send_backup("manual"); s.js({"ok":1 if ok else 0,"msg":er})
      elif p=="/api/backup":
        pw=str(d.get("pass",""));
        if len(pw)<6: s.js({"ok":0,"msg":"Passphrase must be at least 6 characters"},400); return
        try: b=make_backup(pw)
        except Exception as e: s.js({"ok":0,"msg":str(e)[:100]},500); return
        s.raw(b,"application/octet-stream",200,{"Content-Disposition":'attachment; filename="ckvpn-%s.ckbk"'%datetime.now().strftime("%Y%m%d-%H%M")})
      elif p=="/api/restore":
        try: raw=base64.b64decode(str(d.get("data","")))
        except Exception: s.js({"ok":0,"msg":"Invalid file"},400); return
        c,r=restore_backup(raw,str(d.get("pass",""))); s.js(r,c)
      elif p=="/api/user/del": c,r=user_del(d); s.js(r,c)
      elif p=="/api/ports": c,r=apply_ports(d); s.js(r,c)
      elif p=="/api/badvpn": c,r=save_bv(d); s.js(r,c)
      elif p=="/api/bbr":
        ok,msg=bbr_set(bool(d.get("on")))
        s.js({"ok":1 if ok else 0,"msg":msg,"bbr":bbr_state()},200 if ok else 400)
      elif p=="/api/tunnel/setup": c,r=tunnel_setup_start(d); s.js(r,c)
      elif p=="/api/tunnel/route": c,r=tunnel_route_apply(str(d.get("mode",""))); s.js(r,c)
      elif p=="/api/tunnel/ports": c,r=ports_sync(); s.js(r,c)
      elif p=="/api/tunnel/exit-update": c,r=tunnel_exit_update(); s.js(r,c)
      elif p=="/api/tunnel/restart": c,r=tunnel_restart(); s.js(r,c)
      elif p=="/api/tunnel/test": c,r=tunnel_test(); s.js(r,c)
      elif p=="/api/tunnel/remove": c,r=tunnel_remove(); s.js(r,c)
      elif p=="/api/admin":
        c=rjson(CFG,{"port":2053,"username":"admin","password":"admin"})
        au=str(d.get("u","")).strip() or str(c.get("username","admin")).strip()
        ap=str(d.get("p","")).strip() or str(c.get("password","admin")).strip()
        if must_change() and (len(ap)<8 or ap=="admin"): s.js({"ok":0,"msg":"New password must be at least 8 characters and not 'admin'"},400); return
        if len(au)>=2 and len(ap)>=2:
          c["username"]=au; c["password"]=ap; wjson(CFG,c)
          t=secrets.token_hex(16); TOK[t]=time.time()+86400
          s.js({"ok":1,"u":au,"p":ap,"tok":t})
        else: s.js({"ok":0,"msg":"Min 2 chars"},400)
      else: s.js({"err":404},404)
    except Exception as e:
      try: s.js({"ok":0,"msg":str(e)[:100]},400)
      except Exception: pass

def cli_tunnel_setup(host,port,user,mode="ssh"):
  p,err=tunnel_params({"host":host,"port":port,"user":user,"pw":"x"})
  if err: print(err[1]["msg"]); return 1
  pw=getpass.getpass(f"Password of {user}@{host}: ")
  if not pw: print("Password required"); return 1
  CLI[0]=True; print(f"Setting up the tunnel to {host}:{p[1]} ...")
  ok=tunnel_setup_run(host,p[1],user,pw,"wg" if mode=="wg" else "ssh")
  print("Tunnel is UP" if ok else "FAILED (nothing was changed for your users)")
  return 0 if ok else 1

if __name__=="__main__":
  if len(sys.argv)>=5 and sys.argv[1]=="--tunnel-setup": sys.exit(cli_tunnel_setup(sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5] if len(sys.argv)>5 else "ssh"))
  if len(sys.argv)>=3 and sys.argv[1]=="--cert-renewed": sys.exit(cli_cert_renewed(sys.argv[2]))
  open(DB,"a").close()
  try: migrate_secrets()
  except Exception: pass
  threading.Thread(target=mon,daemon=True).start()
  threading.Thread(target=tg_poll,daemon=True).start()
  c=rjson(CFG,{})
  srv=Srv((str(c.get("bind","0.0.0.0")),int(c.get("port",2053))),H); SRV[0]=srv  # nosec B104 - the panel is meant to be reachable
  try:
    if ensure_cert(): srv.ctx=tls_ctx()
  except Exception: srv.ctx=None                 # no openssl / bad certificate: fall back to plain HTTP
  srv.serve_forever()
PYEOF
sed -i "s/__VERSION__/$VERSION/g" /opt/sshplus-panel/app.py
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
.g2{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(310px,100%),1fr));gap:1rem;margin-bottom:1rem}
textarea{width:100%;background:#080c17;border:1px solid var(--bd);color:var(--tx);padding:.55rem;border-radius:8px;margin:.25rem 0 .7rem;font-family:monospace;font-size:.75rem}
input,select{width:100%;background:#080c17;border:1px solid var(--bd);color:var(--tx);padding:.55rem;border-radius:8px;margin:.25rem 0 .7rem}
label{font-size:.8rem;color:var(--mu)}
.btn{background:var(--pr);color:#031116;border:none;padding:.55rem 1rem;border-radius:8px;font-weight:700;cursor:pointer}
.btn-s{padding:.35rem .65rem;font-size:.8rem}.btn-e{background:var(--er);color:#fff}.btn-w{background:var(--wn);color:#000}.btn-o{background:var(--ok);color:#03130c}
.tab-bar{display:flex;flex-wrap:wrap;gap:.5rem;margin-bottom:1rem;border-bottom:1px solid var(--bd);padding-bottom:.75rem}
.tab-btn{background:var(--card);color:var(--mu);border:1px solid var(--bd);padding:.6rem 1rem;border-radius:10px;font-weight:700;cursor:pointer;flex:1 1 auto;text-align:center}
@media(max-width:640px){.tab-btn{padding:.5rem .6rem;font-size:.85rem}}
.tab-btn.act{background:rgba(6,182,212,.15);color:var(--pr);border-color:var(--pr)}
.bdg{padding:.2rem .6rem;border-radius:99px;font-size:.75rem;font-weight:700;display:inline-block;max-width:100%;overflow-wrap:anywhere}
.ok{background:rgba(16,185,129,.15);color:var(--ok)}.er{background:rgba(239,68,68,.15);color:var(--er)}.wn{background:rgba(245,158,11,.15);color:var(--wn)}
table{width:100%;border-collapse:collapse;font-size:.86rem}th,td{padding:.6rem;text-align:start;border-bottom:1px solid var(--bd)}
.hid{display:none!important}.modal{position:fixed;inset:0;background:rgba(0,0,0,.82);display:flex;align-items:center;justify-content:center;padding:1rem;z-index:99}
.row{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:.5rem}
</style>
</head>
<body>
<div id="lBox" class="modal"><div class="card" style="width:100%;max-width:350px">
  <div style="text-align:end;margin:-.2rem 0 .2rem"><button class="btn btn-s langBtn" onclick="toggleLang()" title="Language / زبان">EN</button></div>
  <div style="display:flex;flex-direction:column;align-items:center;gap:.4rem;margin-bottom:.9rem"><svg width="56" height="56" viewBox="0 0 48 48" role="img" aria-label="CK.VPN"><defs><linearGradient id="lg2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#06b6d4"/><stop offset="1" stop-color="#6366f1"/></linearGradient></defs><rect width="48" height="48" rx="12" fill="url(#lg2)"/><path d="M11 31a13 13 0 0 1 26 0" fill="none" stroke="#fff" stroke-opacity=".4" stroke-width="3" stroke-linecap="round"/><circle cx="11" cy="31" r="2.6" fill="#fff"/><circle cx="37" cy="31" r="2.6" fill="#fff"/><text x="24" y="30" text-anchor="middle" font-family="system-ui,Arial,sans-serif" font-weight="800" font-size="18" fill="#fff">CK</text></svg><h3 style="color:var(--pr)">CK.VPN</h3><div style="font-size:.72rem;color:var(--mu)" dir="ltr">Panel Login · v__VERSION__</div></div>
  <label>Username</label><input id="lu" value="admin" autocapitalize="none" autocorrect="off">
  <label>Password</label><input id="lp" type="password" value="admin" autocapitalize="none" onkeydown="if(event.key==='Enter')login()">
  <button class="btn" style="width:100%" onclick="login()">ورود / Login</button>
</div></div>

<div id="fpBox" class="modal hid" style="z-index:120"><div class="card" style="width:100%;max-width:380px">
  <h3 style="color:var(--wn);margin-bottom:.6rem">🔐 تغییر رمز پیش‌فرض</h3>
  <div style="font-size:.82rem;color:var(--mu);margin-bottom:.7rem;line-height:1.8">رمز پیش‌فرض (admin) امن نیست. برای ادامه یک رمز جدید انتخاب کن (حداقل ۸ کاراکتر).</div>
  <label>رمز جدید</label><input id="fp1" type="password" autocomplete="new-password" autocapitalize="none">
  <label>تکرار رمز</label><input id="fp2" type="password" autocomplete="new-password" autocapitalize="none" onkeydown="if(event.key==='Enter')saveFp()">
  <button class="btn" style="width:100%" onclick="saveFp()">ذخیره و ادامه</button>
</div></div>

<div id="subBox" class="modal hid"><div class="card" style="width:100%;max-width:360px;text-align:center">
  <h3 id="subTit" style="margin-bottom:.4rem"></h3>
  <div id="subQr" style="background:#fff;border-radius:12px;padding:10px;max-width:240px;margin:.5rem auto"></div>
  <textarea id="subLink" rows="2" dir="ltr" readonly style="font-size:.7rem;margin:.3rem 0" onclick="this.select()"></textarea>
  <div style="display:flex;gap:.35rem;justify-content:center;flex-wrap:wrap">
    <button class="btn btn-s" onclick="copyText(subUrl)">📋 لینک اشتراک (برای برنامه‌ها)</button>
    <button class="btn btn-s" onclick="copyText(subUrl+'?fmt=plain')">📋 متن ساده</button>
    <button class="btn btn-s btn-o" onclick="copyText(subSsh[0]||'')">📋 لینک SSH</button>
    <button class="btn btn-s btn-o" onclick="copyText(subSshB[0]||'')">📋 لینک SSH (base64)</button>
    <button class="btn btn-s btn-o hid" id="subTlsBtn" onclick="copyText(subTls)">📋 مشخصات TLS (ورود دستی)</button>
    <button class="btn btn-s btn-w" onclick="window.open(subUrl+'?fmt=html')">🔗 باز کردن صفحه</button>
    <button class="btn btn-s btn-e" onclick="$('subBox').classList.add('hid')">بستن</button>
  </div>
  <div style="font-size:.7rem;color:var(--mu);margin-top:.5rem;line-height:1.7">اگر برنامه‌ی تانل لینک را نپذیرفت، یکی از حالت‌های دیگر را امتحان کن. برنامه‌هایی که گواهی self-signed را رد می‌کنند به گواهی معتبر نیاز دارند، یا لینک اشتراک را روی HTTP ساده فعال کن (تنظیمات ← HTTPS).</div>
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
  <label>نوع اتصال</label><select id="ecx" onchange="fillPorts()"><option value="both">معمولی + TLS</option><option value="normal">فقط معمولی</option><option value="tls">فقط TLS</option></select>
  <div id="eCx" style="font-size:.76rem;color:var(--wn);margin:-.4rem 0 .5rem;line-height:1.8"></div>
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
    <button class="btn btn-s langBtn" onclick="toggleLang()" title="Language / زبان">EN</button>
    <button class="btn btn-s" onclick="load(1)">🔄</button>
    <button class="btn btn-s btn-e" onclick="localStorage.removeItem('tok');location.reload()">Logout</button>
  </div>
</div>

<div class="tab-bar">
  <button id="bTabU" class="tab-btn act" onclick="swTab('u')">👥 کاربران</button>
  <button id="bTabT" class="tab-btn" onclick="swTab('t')">🌐 تانل</button>
  <button id="bTabL" class="tab-btn" onclick="swTab('l')">🔒 TLS و دامنه</button>
  <button id="bTabH" class="tab-btn" onclick="swTab('h')">📈 آمار</button>
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
    <div style="display:flex;gap:.4rem;flex-wrap:wrap;align-items:center;margin-bottom:.6rem">
      <label style="margin:0">قالب:</label>
      <select id="tplSel" style="width:auto;margin:0;min-width:150px" onchange="applyTpl()"><option value="">— بدون قالب —</option></select>
      <button class="btn btn-s btn-o" onclick="saveTpl()">💾 ذخیره فرم به‌عنوان قالب</button>
      <button class="btn btn-s btn-e" onclick="delTpl()">🗑️</button>
    </div>
    <div class="row">
      <div><label>نام کاربری (انگلیسی)</label><input id="nu" placeholder="user1" autocapitalize="none"></div>
      <div><label>رمز عبور</label><input id="npw" placeholder="123456" autocapitalize="none"></div>
      <div><label><bdi dir="ltr">In</bdi> — به کدام سرور وصل شود</label><select id="nen" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
      <div><label><bdi dir="ltr">Out</bdi> — با IP کدام سرور خارج شود</label><select id="nex" onchange="fillPorts()"><option value="A">سرور ۱ (این سرور)</option><option value="B">سرور ۲ (سرور تانل)</option></select></div>
      <div><label>نوع اتصال</label><select id="ncx" onchange="fillPorts()"><option value="both">معمولی + TLS</option><option value="normal">فقط معمولی</option><option value="tls">فقط TLS</option></select></div>
      <div><label>پورت پیشنهادی</label><select id="npt"></select></div>
      <div><label>حجم (GB | 0=نامحدود)</label><input id="nq" type="number" step="0.5" value="0" min="0"></div>
      <div><label>روز اعتبار</label><input id="nd" type="number" value="30" min="1"></div>
      <div><label>کاربر همزمان</label><input id="nl" type="number" value="1" min="1"></div>
    </div>
    <div id="nHint" style="font-size:.8rem;color:var(--mu);margin:.2rem 0 .3rem;line-height:1.8"></div>
    <div id="nCx" style="font-size:.78rem;color:var(--wn);margin:0 0 .7rem;line-height:1.8"></div>
    <button class="btn" onclick="saveUser(0)">ایجاد اکانت</button>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.7rem">📦 ساخت دسته‌ای اکانت</h3>
    <div class="row">
      <div><label>پیشوند نام</label><input id="bu_pf" placeholder="cust" autocapitalize="none"></div>
      <div><label>تعداد (۱ تا ۲۰۰)</label><input id="bu_n" type="number" value="10" min="1" max="200"></div>
      <div><label>شروع شماره</label><input id="bu_s" type="number" value="1" min="0"></div>
      <div><label>روز اعتبار</label><input id="bu_d" type="number" value="30" min="1"></div>
      <div><label>حجم (GB | 0=نامحدود)</label><input id="bu_q" type="number" value="0" min="0" step="0.5"></div>
      <div><label>کاربر همزمان</label><input id="bu_l" type="number" value="1" min="1"></div>
      <div><label><bdi dir="ltr">In</bdi> — به کدام سرور وصل شود</label><select id="bu_en"><option value="A">سرور ۱</option><option value="B">سرور ۲</option></select></div>
      <div><label><bdi dir="ltr">Out</bdi> — با IP کدام سرور خارج شود</label><select id="bu_ex"><option value="A">سرور ۱</option><option value="B">سرور ۲</option></select></div>
      <div><label>نوع اتصال</label><select id="bu_cx"><option value="both">معمولی + TLS</option><option value="normal">فقط معمولی</option><option value="tls">فقط TLS</option></select></div>
      <div><label>رمز (خالی = تصادفی برای هر اکانت)</label><input id="bu_pw" autocapitalize="none"></div>
    </div>
    <button class="btn" onclick="doBulk()">ایجاد اکانت‌ها</button>
    <div id="bkRes" style="margin-top:.7rem"></div>
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
        <button class="btn btn-s btn-o" onclick="tunExitUpdate()">⬆️ به‌روزرسانی سرور مقصد</button>
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
      <label>نوع تانل</label><select id="tnMode" onchange="tnModeUi()"><option value="wg">WireGuard — سریع (UDP، پیشنهادی)</option><option value="ssh">SSH — سازگار (TCP، کندتر)</option></select>
      <div id="tnModeNote" style="font-size:.76rem;color:var(--mu);line-height:1.8;margin:-.3rem 0 .7rem"></div>
      <button id="tnGo" class="btn" style="width:100%" onclick="tunSetup()">⚡ نصب و برقراری تانل</button>
      <div data-th="tnNote" style="font-size:.75rem;color:var(--mu);margin-top:.6rem;line-height:1.7">رمز فقط برای نصب کلید SSH استفاده می‌شود و ذخیره نمی‌شود؛ بعد از آن ارتباط با کلید است.<br>
      ⚠️ اگر نمی‌خواهی رمز سرور را در صفحه‌ی وب تایپ کنی، در ترمینال همین سرور بزن:<br><code dir="ltr">sshplus-tunnel-setup IP_SERVER [PORT] [USER]</code></div>
    </div>
  </div>
  <div class="card hid" id="tnBiBox">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">↔️ مسیر دوطرفه (همیشه فعال)</h3>
    <div id="tnBi" style="font-size:.85rem;line-height:1.9"></div>
    <div style="font-size:.78rem;color:var(--mu);margin-top:.5rem;line-height:1.8" data-th="biNote">موقع ساخت اکانت، ادمین دو انتخاب <bdi dir="ltr"><b>In</b></bdi> و <bdi dir="ltr"><b>Out</b></bdi> دارد: <bdi dir="ltr"><b>In</b></bdi> یعنی کاربر به IP کدام سرور وصل شود و <bdi dir="ltr"><b>Out</b></bdi> یعنی با IP کدام سرور به اینترنت برسد. هر چهار ترکیب (<span dir="ltr">1→1</span>، <span dir="ltr">1→2</span>، <span dir="ltr">2→1</span>، <span dir="ltr">2→2</span>) فعال است و UDPGW (بازی/تماس) روی همه‌ی آن‌ها کار می‌کند. نیازی به تنظیم مود جداگانه نیست.</div>
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
    <div data-th="how">    <bdi dir="ltr"><b>In</b></bdi> یعنی سروری که کاربر به IP آن وصل می‌شود و <bdi dir="ltr"><b>Out</b></bdi> یعنی سروری که IP آن در اینترنت دیده می‌شود. «سرور ۱» همین سرور است و «سرور ۲» سرور تانل.<br>
    ۱) وقتی <bdi dir="ltr"><b>Out</b></bdi> روی «سرور ۲» باشد، ترافیک از داخل تانل می‌گذرد. این اکانت روی پورت‌های <b>SSH (OpenSSH)</b> و <b>Dropbear تانل</b> کار می‌کند؛ پورت‌های Dropbear معمولی فقط برای اکانت‌هایی‌اند که <bdi dir="ltr"><b>Out</b></bdi> آن‌ها «سرور ۱» است. پورت‌ها در تب تنظیمات قابل تغییرند.<br>
    ۲) وقتی <bdi dir="ltr"><b>In</b></bdi> روی «سرور ۲» باشد، پورت‌های این سرور روی سرور ۲ باز می‌شوند و از داخل تانل به این سرور فوروارد می‌شوند. پورت ۲۲ و هر پورتی که سرور ۲ خودش رویش گوش می‌دهد هرگز دست نمی‌خورد؛ پس دسترسی ادمین به هر دو سرور و به پنل همیشه باز می‌ماند. فایروال سرور ۲ باید این پورت‌ها را باز کند و IP واقعی کاربر روی این سرور دیده نمی‌شود.<br>
    ۳) اگر تانل قطع شود، هر مسیری که از تانل می‌گذرد <b>بسته</b> می‌شود (به‌جای نشت از IP مستقیم). برقراری مجدد خودکار است.<br>
    ۴) UDPGW (بازی/تماس) روی هر چهار ترکیب کار می‌کند. وقتی <bdi dir="ltr"><b>Out</b></bdi> روی «سرور ۲» باشد از تانل می‌گذرد. کلاینت همان <span dir="ltr">127.0.0.1:7300</span> را استفاده می‌کند.<br>
    ۵) تانل روی SSH (TCP) است؛ برای سرعت بهتر BBR را روی هر دو سرور روشن نگه دار.</div>
  </div>
</div>

<div id="secL" class="hid">
  <div class="g2">
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">🔒 SSH روی TLS</h3>
      <div id="tlsStat" style="margin-bottom:.6rem">--</div>
      <label style="display:flex;gap:.5rem;align-items:center;color:var(--tx);margin-bottom:.7rem"><input type="checkbox" id="tlsOn" style="width:auto;margin:0" onchange="tlsToggle()"><b>فعال‌سازی SSH روی TLS</b></label>
      <div class="row">
        <div><label>پورت(های) TLS اکانت‌های معمولی (با کاما جدا کن)</label><input id="tlsP1" dir="ltr" placeholder="443"></div>
        <div><label>پورت(های) TLS اکانت‌های تانل</label><input id="tlsP2" dir="ltr" placeholder="8843"></div>
      </div>
      <div class="row"><div><label>حداکثر اتصال هم‌زمان از هر IP روی پورت‌های TLS (۰ = بدون محدودیت)</label><input id="tlsPerIp" type="number" min="0" max="10000" dir="ltr" placeholder="100"></div></div>
      <button class="btn btn-s" onclick="tlsPorts()">💾 ذخیره‌ی پورت‌ها</button>
      <div style="font-size:.76rem;color:var(--mu);line-height:1.9;margin-top:.8rem" data-th="tlsNote">SSH داخل یک اتصال TLS قرار می‌گیرد؛ برای برنامه‌ها یا شبکه‌هایی که اتصال TLS/SNI می‌خواهند.<br>• اکانت «فقط معمولی» روی پورت TLS وارد نمی‌شود و اکانت «فقط TLS» روی پورت‌های Dropbear معمولی وارد نمی‌شود.<br>• روی پورت‌های OpenSSH (مثل 22) هم اکانت «فقط TLS» وارد نمی‌شود؛ اکانت‌های «معمولی» و «هر دو» وارد می‌شوند.<br>• اکانت‌های تانل پورت TLS جداگانه دارند (از مسیر تانل خارج می‌شوند).<br>• فرمت لینک <span dir="ltr">ssh://</span> برای TLS استاندارد نیست؛ اگر برنامه‌ات نپذیرفت آدرس، پورت و SNI را دستی وارد کن.</div>
    </div>
    <div class="card">
      <h3 style="margin-bottom:.7rem;color:var(--pr)">📜 گواهی فعلی</h3>
      <div id="tlsCert" style="font-size:.85rem;line-height:1.9;margin-bottom:.6rem"></div>
      <div style="display:flex;gap:.4rem;flex-wrap:wrap">
        <button class="btn btn-s btn-o" id="tlsRenewBtn" onclick="tlsRenew()">🔄 تمدید گواهی</button>
        <button class="btn btn-s btn-w" onclick="tlsSelf()">↩️ بازگشت به گواهی self-signed</button>
      </div>
      <div style="font-size:.76rem;color:var(--mu);line-height:1.9;margin-top:.8rem" data-th="tlsShared">همین گواهی و دامنه برای HTTPS خودِ پنل هم استفاده می‌شود؛ جای دیگری چیزی لازم نیست تنظیم شود.</div>
    </div>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.7rem;color:var(--pr)">🌍 دامنه و گواهی (یک‌کلیک)</h3>
    <div class="row">
      <div><label>منبع دامنه</label><select id="tlsSrc" onchange="tlsSrcUi()"><option value="free">دامنه‌ی رایگان (خودکار)</option><option value="own">دامنه‌ی خودم را دارم</option></select></div>
      <div><label>ایمیل (اختیاری؛ برای هشدار انقضا از Let's Encrypt)</label><input id="tlsMail" dir="ltr" autocapitalize="none" placeholder="you@example.com"></div>
    </div>
    <div id="tlsFree">
      <div class="row">
        <div><label>سرویس دامنه‌ی رایگان</label><select id="tlsProv" onchange="tlsSrcUi()"><option value="sslip">sslip.io — بدون ثبت‌نام</option><option value="nip">nip.io — بدون ثبت‌نام</option><option value="duckdns">DuckDNS — زیردامنه‌ی ثابت (حساب رایگان لازم است)</option><option value="custom">سرویس wildcard-DNS دیگر (خودت وارد کن)</option></select></div>
        <div id="tlsDuckN"><label>نام زیردامنه در DuckDNS</label><input id="tlsDuckName" dir="ltr" autocapitalize="none" placeholder="myvpn"></div>
        <div id="tlsDuckT"><label>توکن DuckDNS <span id="tlsDuckSet" style="color:var(--ok)"></span></label><input id="tlsDuckTok" type="password" dir="ltr" autocomplete="off" autocapitalize="none"></div>
        <div id="tlsSufB"><label>پسوند سرویس (مثلاً sslip.io)</label><input id="tlsSuf" dir="ltr" autocapitalize="none" placeholder="sslip.io"></div>
      </div>
    </div>
    <div id="tlsOwnB" class="hid"><label>دامنه‌ی شما</label><input id="tlsDom" dir="ltr" autocapitalize="none" placeholder="vpn.example.com"></div>
    <div id="tlsProvNote" style="font-size:.78rem;color:var(--mu);line-height:1.9;margin:.1rem 0 .8rem"></div>
    <label style="display:flex;gap:.4rem;align-items:flex-start;color:var(--tx);margin:.2rem 0 .7rem"><input type="checkbox" id="tlsStaging" style="width:auto;margin:.2rem 0 0" onchange="tlsStagingSave()"><span>حالت آزمایشی Let's Encrypt (staging): برای امتحان کردن مراحل بدون مصرف سقف؛ گواهی آن معتبر نیست</span></label>
    <button class="btn" id="tlsGo" onclick="tlsGo()">⚡ دریافت دامنه و گواهی</button>
    <div id="tlsLog" style="margin-top:.8rem;font-size:.85rem;line-height:1.9"></div>
  </div>

  <details class="card">
    <summary style="cursor:pointer;color:var(--pr);font-weight:700">⬆️ آپلود گواهی دلخواه (PEM)</summary>
    <label style="display:block;margin-top:.7rem">دامنه‌ی این گواهی (برای لینک‌ها و SNI)</label><input id="tlsUpDom" dir="ltr" autocapitalize="none" placeholder="vpn.example.com">
    <label>گواهی (fullchain، فرمت PEM)</label><textarea id="certPem" rows="3" dir="ltr" placeholder="-----BEGIN CERTIFICATE-----"></textarea>
    <label>کلید خصوصی (PEM)</label><textarea id="certKey" rows="3" dir="ltr" placeholder="-----BEGIN PRIVATE KEY-----"></textarea>
    <button class="btn btn-s" onclick="saveCert()">آپلود گواهی</button>
  </details>
</div>

<div id="secH" class="hid">
  <div class="card"><h3 style="margin-bottom:.4rem;color:var(--pr)">🌐 وضعیت تانل (۲۴ ساعت گذشته)</h3>
    <div id="hTunSum" style="font-size:.82rem;color:var(--mu);margin-bottom:.4rem"></div><canvas id="cTun" style="width:100%;display:block"></canvas>
    <div style="font-size:.72rem;color:var(--mu);margin-top:.3rem">خط آبی: تأخیر (ms) · نوار قرمز: تانل قطع بوده</div></div>
  <div class="card"><h3 style="margin-bottom:.4rem;color:var(--pr)">🖥️ بار سرور (۲۴ ساعت)</h3><canvas id="cLoad" style="width:100%;display:block"></canvas>
    <div style="font-size:.72rem;color:var(--mu);margin-top:.3rem">آبی: CPU · نارنجی: RAM</div></div>
  <div class="card"><h3 style="margin-bottom:.4rem;color:var(--pr)">📊 مصرف روزانه‌ی کل (۱۴ روز)</h3><canvas id="cDay" style="width:100%;display:block"></canvas></div>
  <div class="card" style="overflow-x:auto"><h3 style="margin-bottom:.4rem;color:var(--pr)">🏆 پرمصرف‌ترین کاربران (۷ روز)</h3><div id="hTop"></div></div>
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

  <div class="g2">
  <div class="card">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">🔒 HTTPS و گواهی</h3>
    <div id="certInfo" style="font-size:.78rem;color:var(--mu);white-space:pre-wrap;direction:ltr;text-align:left;margin-bottom:.6rem"></div>
    <div style="font-size:.78rem;color:var(--mu);line-height:1.8;margin-bottom:.6rem">پنل روی همین پورت HTTPS است (آدرس http قدیمی خودکار به https می‌رود). گواهی و دامنه در تب «TLS و دامنه» مدیریت می‌شود (یک گواهی برای HTTPS پنل و SSH روی TLS)؛ گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد.</div>
    <label style="display:flex;gap:.4rem;align-items:flex-start;color:var(--tx);margin-bottom:.2rem"><input type="checkbox" id="plainSub" style="width:auto;margin:.2rem 0 0" onchange="savePlainSub()"><span>اجازه‌ی لینک اشتراک روی HTTP ساده (برای برنامه‌هایی که گواهی self-signed را نمی‌پذیرند)</span></label>
    <div style="font-size:.74rem;color:var(--wn);line-height:1.7;margin:0 0 .8rem">⚠️ رمز اکانت داخل لینک است و روی HTTP ساده در مسیر قابل شنود است. فقط در صورت نیاز روشن کن؛ بقیه‌ی پنل همیشه HTTPS می‌ماند.</div>
    <button class="btn btn-s" onclick="swTab('l')">🔒 رفتن به تب TLS و دامنه</button>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">💾 بکاپ و بازیابی</h3>
    <div id="bkWarn" style="font-size:.8rem;color:var(--wn);margin-bottom:.4rem"></div>
    <div style="font-size:.78rem;color:var(--mu);line-height:1.8;margin-bottom:.6rem">کاربران، حجم‌ها، تنظیمات، پورت‌ها، کلید تانل و تلگرام در یک فایل رمزنگاری‌شده. پسفریز را گم نکن؛ بدون آن فایل قابل بازیابی نیست.</div>
    <label>پسفریز (حداقل ۶ کاراکتر)</label><input id="bkPass" type="password" autocomplete="off" autocapitalize="none">
    <button class="btn btn-s btn-o" onclick="doBackup()">⬇️ دانلود بکاپ</button>
    <label style="display:block;margin-top:.9rem">بازیابی از فایل بکاپ (.ckbk)</label><input id="bkFile" type="file" accept=".ckbk">
    <button class="btn btn-s btn-w" onclick="doRestore()">⬆️ بازیابی (پنل ری‌استارت می‌شود)</button>
  </div>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.6rem;color:var(--pr)">🤖 ربات و هشدار تلگرام</h3>
    <div style="font-size:.78rem;color:var(--mu);line-height:1.8;margin-bottom:.6rem" data-th="tgNote">ابتدا در تلگرام با @BotFather یک ربات بساز و توکن را اینجا بگذار؛ بعد به ربات پیام <span dir="ltr">/start</span> بده و «پیدا کردن Chat ID» را بزن. اگر تلگرام از روی این سرور باز نمی‌شود، پنل خودکار از مسیر تانل می‌فرستد.</div>
    <div class="row">
      <div><label>توکن ربات <span id="tgSet" style="color:var(--ok)"></span></label><input id="tgToken" type="password" placeholder="123456:ABC..." autocomplete="off" autocapitalize="none"></div>
      <div><label>Chat ID</label><input id="tgChat" autocapitalize="none" placeholder="123456789"></div>
      <div><label>پسفریز بکاپ خودکار <span id="tgBp" style="color:var(--ok)"></span></label><input id="tgBpass" type="password" autocomplete="off" autocapitalize="none"></div>
      <div><label>ساعت بکاپ روزانه (۰ تا ۲۳)</label><input id="tgHour" type="number" min="0" max="23" value="3"></div>
    </div>
    <div style="display:flex;gap:1rem;flex-wrap:wrap;font-size:.85rem;margin-bottom:.8rem">
      <label style="display:flex;gap:.3rem;align-items:center;color:var(--tx)"><input type="checkbox" id="tgA_tunnel" style="width:auto;margin:0"> قطع/وصل تانل</label>
      <label style="display:flex;gap:.3rem;align-items:center;color:var(--tx)"><input type="checkbox" id="tgA_quota" style="width:auto;margin:0"> ۹۰٪ و پر شدن حجم</label>
      <label style="display:flex;gap:.3rem;align-items:center;color:var(--tx)"><input type="checkbox" id="tgA_expiry" style="width:auto;margin:0"> نزدیک/پایان انقضا</label>
      <label style="display:flex;gap:.3rem;align-items:center;color:var(--tx)"><input type="checkbox" id="tgA_res" style="width:auto;margin:0"> فشار CPU/RAM</label>
      <label style="display:flex;gap:.3rem;align-items:center;color:var(--tx)"><input type="checkbox" id="tgA_daily" style="width:auto;margin:0"> بکاپ روزانه به تلگرام</label>
    </div>
    <div style="display:flex;gap:.4rem;flex-wrap:wrap">
      <button class="btn btn-s" onclick="saveTg()">💾 ذخیره</button>
      <button class="btn btn-s btn-o" onclick="tgTest()">📨 پیام آزمایشی</button>
      <button class="btn btn-s btn-w" onclick="tgDetect()">🔎 پیدا کردن Chat ID</button>
      <button class="btn btn-s btn-w" onclick="tgBackup()">💾 ارسال بکاپ همین حالا</button>
    </div>
    <div style="font-size:.75rem;color:var(--mu);margin-top:.6rem;line-height:1.8" data-th="tgCmd">دستورهای ربات (فقط از Chat ID تنظیم‌شده): <span dir="ltr">/status /users /online /backup</span></div>
  </div>
</div>

<script>
const $=id=>document.getElementById(id);
// ---- language: fa (default) / en. Static labels: EN dictionary; paragraphs: data-th blocks; JS sentences: L(fa,en)
let LANG="fa"; try{LANG=localStorage.getItem("lang")==="en"?"en":"fa"}catch(e){}
const L=(fa,en)=>LANG==="en"?en:fa;
const EN={"👥 کاربران": "👥 Users", "🌐 تانل": "🌐 Tunnel", "📈 آمار": "📈 Statistics", "⚙️ تنظیمات سرور": "⚙️ Server settings", "ورود / Login": "Login", "بستن": "Close", "ذخیره": "Save", "💾 ذخیره": "💾 Save", "ذخیره و ادامه": "Save and continue", "(ذخیره شده)": "(saved)", "وضعیت": "Status", "نوع": "Type", "فعال": "Active", "غیرفعال": "Disabled", "آنلاین / کل کاربران": "Online / Total users", "تانل / Dropbear تانل": "Tunnel / Tunnel Dropbear", "BBR / منابع": "BBR / Resources", "🔌 پورت‌های فعال:": "🔌 Active ports:", "رمز عبور": "Password", "🔐 تغییر رمز پیش‌فرض": "🔐 Change the default password", "رمز پیش‌فرض (admin) امن نیست. برای ادامه یک رمز جدید انتخاب کن (حداقل ۸ کاراکتر).": "The default password (admin) is not secure. Choose a new one to continue (at least 8 characters).", "رمز جدید": "New password", "تکرار رمز": "Repeat password", "➕ ساخت کاربر جدید": "➕ Create new user", "قالب:": "Template:", "— بدون قالب —": "— No template —", "💾 ذخیره فرم به‌عنوان قالب": "💾 Save form as template", "نام کاربری (انگلیسی)": "Username (English letters)", "پورت پیشنهادی": "Suggested port", "پورت پیشنهادی (فقط برای نمایش/کپی)": "Suggested port (display/copy only)", "حجم (GB | 0=نامحدود)": "Quota (GB | 0 = unlimited)", "روز اعتبار": "Validity (days)", "کاربر همزمان": "Concurrent users", "— به کدام سرور وصل شود": "— which server the user connects to", "— با IP کدام سرور خارج شود": "— whose IP the user leaves with", "سرور ۱": "Server 1", "سرور ۲": "Server 2", "سرور ۱ (این سرور)": "Server 1 (this server)", "سرور ۲ (سرور تانل)": "Server 2 (tunnel server)", "سرور ۲ (تانل نصب نیست)": "Server 2 (tunnel not installed)", "ایجاد اکانت": "Create account", "همه پورت‌ها": "All ports", "📦 ساخت دسته‌ای اکانت": "📦 Bulk account creation", "پیشوند نام": "Name prefix", "تعداد (۱ تا ۲۰۰)": "Count (1 to 200)", "شروع شماره": "Start number", "رمز (خالی = تصادفی برای هر اکانت)": "Password (empty = random per account)", "ایجاد اکانت‌ها": "Create accounts", "📋 لیست کاربران": "📋 Users", "📋 کپی": "📋 Copy", "⬇️ دانلود CSV": "⬇️ Download CSV", "ویرایش کاربر": "Edit user", "رمز جدید (خالی = بدون تغییر)": "New password (empty = unchanged)", "تمدید: اعتبار از امروز (روز) — خالی/۰ = بدون تغییر": "Renew: validity from today (days) — empty/0 = unchanged", "صفر کردن ترافیک مصرفی": "Reset used traffic", "با تغییر In/Out اتصال‌های فعال این کاربر قطع می‌شوند.": "Changing In/Out cuts this user's active connections.", "لینک اشتراک و QR": "Subscription link & QR", "📋 کپی لینک اشتراک": "📋 Copy subscription link", "🔗 باز کردن": "🔗 Open", "🌐 وضعیت تانل": "🌐 Tunnel status", "🚀 نصب و اتصال تانل (یک کلیک)": "🚀 Install & connect the tunnel (one click)", "IP یا دامنه‌ی سرور جدید (خروجی)": "IP or domain of the new (exit) server", "پورت SSH": "SSH port", "کاربر (باید root باشد)": "User (must be root)", "رمز SSH سرور جدید": "SSH password of the new server", "⚡ نصب و برقراری تانل": "⚡ Install & connect the tunnel", "♻️ نصب مجدد / تغییر سرور": "♻️ Reinstall / change server", "⏳ در حال نصب...": "⏳ Installing...", "🔍 تست خروجی": "🔍 Test exit", "🔄 ری‌استارت تانل": "🔄 Restart tunnel", "🗑️ حذف تانل": "🗑️ Remove tunnel", "تانل نصب نشده": "Tunnel not installed", "🟢 متصل": "🟢 Connected", "🔴 قطع / در حال اتصال": "🔴 Down / connecting", "هنوز تانلی تنظیم نشده. فرم کناری را پر کن.": "No tunnel is configured yet. Fill in the form beside this.", "↔️ مسیر دوطرفه (همیشه فعال)": "↔️ Two-way routing (always on)", "🔌 هماهنگی پورت‌ها و فایروال دو سرور": "🔌 Port coordination & firewalls (both servers)", "پورت سرور ۱": "Port on server 1", "پورت روی سرور ۲": "Port on server 2", "Dropbear تانل": "Tunnel Dropbear", "SSH دوم": "2nd SSH", "هم‌شماره": "Same number", "جابه‌جا شد (مشغول بود)": "Moved (port was busy)", "منتشر نشد": "Not published", "هنوز پورتی منتشر نشده": "No port published yet", "اگر پورت Dropbear این سرور را برنامه‌ی دیگری گرفته باشد، خودکار با پورت آزاد عوض می‌شود. اگر پورتی روی سرور ۲ مشغول باشد، با شماره‌ی دیگری روی سرور ۲ منتشر می‌شود (پورت‌های این سرور و کانفیگ کلاینت‌های فعلی تغییر نمی‌کنند). فایروال (ufw یا firewalld) هر دو سرور برای پورت‌ها باز می‌شود. همین بررسی خودکار هم با هر راه‌اندازی پنل، نصب تانل و تغییر پورت انجام می‌شود.": "If another program has taken this server's Dropbear port, it is replaced by a free one automatically. If a port is busy on server 2, it is published there under another number (this server's ports and existing client configs do not change). The firewall (ufw or firewalld) of both servers is opened for the ports. The same check also runs automatically on every panel start, tunnel install and port change.", "🔍 بررسی و رفع تداخل + به‌روزرسانی فایروال هر دو سرور": "🔍 Check & fix conflicts + update the firewalls of both servers", "📜 مراحل نصب": "📜 Installation steps", "هنوز نصبی انجام نشده.": "No installation has been run yet.", "🌐 وضعیت تانل (۲۴ ساعت گذشته)": "🌐 Tunnel status (last 24 hours)", "خط آبی: تأخیر (ms) · نوار قرمز: تانل قطع بوده": "Blue line: latency (ms) · red bar: the tunnel was down", "🖥️ بار سرور (۲۴ ساعت)": "🖥️ Server load (24 h)", "آبی: CPU · نارنجی: RAM": "Blue: CPU · orange: RAM", "📊 مصرف روزانه‌ی کل (۱۴ روز)": "📊 Total daily traffic (14 days)", "🏆 پرمصرف‌ترین کاربران (۷ روز)": "🏆 Top users (7 days)", "تانلی تنظیم نشده یا هنوز نمونه‌ای ثبت نشده (هر دقیقه ثبت می‌شود).": "No tunnel configured or no sample recorded yet (one sample per minute).", "هنوز داده‌ای ثبت نشده": "No data recorded yet", "داده‌ای ثبت نشده": "No data recorded", "🚀 BBR (کنترل ازدحام TCP)": "🚀 BBR (TCP congestion control)", "الگوریتم فعلی": "Current algorithm", "کرنل پشتیبانی نمی‌کند": "Kernel does not support it", "⛔ خاموش کردن BBR": "⛔ Turn BBR off", "🚀 روشن کردن BBR": "🚀 Turn BBR on", "روی اتصال‌های جدید اثر می‌گذارد؛ اتصال‌های فعلی تا اتصال مجدد با الگوریتم قبلی می‌مانند.": "Applies to new connections; existing connections keep the previous algorithm until they reconnect.", "👤 نام کاربری و رمز ادمین پنل": "👤 Panel admin username & password", "نام کاربری ادمین": "Admin username", "رمز جدید ادمین": "New admin password", "🔌 پورت‌های OpenSSH و Dropbear (حداکثر ۶ پورت)": "🔌 OpenSSH & Dropbear ports (max 6)", "پورت SSH دوم": "Second SSH port", "پورت SSH اصلی (پنل)": "Main SSH port (panel)", "🌐 پورت‌های Dropbear مخصوص اکانت تانل (حداکثر ۴)": "🌐 Dropbear ports for tunnel accounts (max 4)", "ذخیره پورت‌ها (اتصال‌های Dropbear لحظه‌ای قطع می‌شوند)": "Save ports (Dropbear connections are briefly dropped)", "پورت (TCP داخل تونل)": "Port (TCP inside the tunnel)", "0.0.0.0 (عمومی)": "0.0.0.0 (public)", "127.0.0.1 (امن)": "127.0.0.1 (safe)", "ذخیره و ری‌استارت BadVPN": "Save and restart BadVPN", "🔒 HTTPS و گواهی": "🔒 HTTPS & certificate", "پنل روی همین پورت HTTPS است (آدرس http قدیمی خودکار به https می‌رود). گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد. اگر دامنه داری، گواهی معتبر (مثلاً از Let's Encrypt) را اینجا بگذار.": "The panel is served over HTTPS on this port (an old http address is redirected to https automatically). The default certificate is self-signed, so the browser warns. If you have a domain, put a valid certificate (for example from Let's Encrypt) here.", "گواهی (fullchain، فرمت PEM)": "Certificate (fullchain, PEM format)", "کلید خصوصی (PEM)": "Private key (PEM)", "آپلود گواهی": "Upload certificate", "💾 بکاپ و بازیابی": "💾 Backup & restore", "کاربران، حجم‌ها، تنظیمات، پورت‌ها، کلید تانل و تلگرام در یک فایل رمزنگاری‌شده. پسفریز را گم نکن؛ بدون آن فایل قابل بازیابی نیست.": "Users, quotas, settings, ports, the tunnel key and Telegram in one encrypted file. Do not lose the passphrase; without it the file cannot be restored.", "پسفریز (حداقل ۶ کاراکتر)": "Passphrase (at least 6 characters)", "⬇️ دانلود بکاپ": "⬇️ Download backup", "بازیابی از فایل بکاپ (.ckbk)": "Restore from backup file (.ckbk)", "⬆️ بازیابی (پنل ری‌استارت می‌شود)": "⬆️ Restore (the panel restarts)", "🤖 ربات و هشدار تلگرام": "🤖 Telegram bot & alerts", "توکن ربات": "Bot token", "پسفریز بکاپ خودکار": "Automatic backup passphrase", "ساعت بکاپ روزانه (۰ تا ۲۳)": "Daily backup hour (0 to 23)", "قطع/وصل تانل": "Tunnel down/up", "۹۰٪ و پر شدن حجم": "90% and quota full", "نزدیک/پایان انقضا": "Expiry near/reached", "فشار CPU/RAM": "High CPU/RAM load", "بکاپ روزانه به تلگرام": "Daily backup to Telegram", "📨 پیام آزمایشی": "📨 Test message", "🔎 پیدا کردن Chat ID": "🔎 Find Chat ID", "💾 ارسال بکاپ همین حالا": "💾 Send a backup now", "ℹ️ نحوه‌ی کار": "ℹ️ How it works", "رمز باید حداقل ۸ کاراکتر و غیر از admin باشد": "The password must be at least 8 characters and not 'admin'", "تکرار رمز یکسان نیست": "The passwords do not match", "تلاش‌های ناموفق زیاد؛ ۵ دقیقه صبر کنید": "Too many failed attempts; wait 5 minutes", "نام کاربری یا رمز عبور اشتباه است": "Wrong username or password", "پورت‌ها ذخیره شد": "Ports saved", "BadVPN به‌روز شد": "BadVPN updated", "نام کاربری یا رمز جدید را وارد کنید": "Enter a new username or password", "مشخصات ورود تغییر کرد": "Login details changed", "IP و رمز سرور جدید را وارد کن": "Enter the IP and password of the new server", "گواهی جدید فعال شد (اتصال‌های بعدی از آن استفاده می‌کنند)": "New certificate activated (new connections will use it)", "پسفریز حداقل ۶ کاراکتر": "The passphrase must be at least 6 characters", "فایل بکاپ را انتخاب کن": "Choose the backup file", "پسفریز را وارد کن": "Enter the passphrase", "بازیابی تنظیمات و کاربران فعلی را بازنویسی می‌کند. ادامه؟": "Restore will overwrite the current settings and users. Continue?", "ذخیره شد": "Saved", "پیام ارسال شد": "Message sent", "ارسال نشد: توکن/Chat ID یا دسترسی به تلگرام (مستقیم و از مسیر تانل) را بررسی کن": "Not sent: check the token/Chat ID or the connection to Telegram (direct and through the tunnel)", "پیامی پیدا نشد. اول به ربات پیام /start بده و دوباره امتحان کن": "No message found. First send /start to the bot, then try again", "بکاپ به تلگرام ارسال شد": "Backup sent to Telegram", "نام قالب:": "Template name:", "پیشوند نام را وارد کن": "Enter a name prefix", "⏳ در حال ساخت...": "⏳ Creating...", "لینک هنوز ساخته نشده؛ چند ثانیه بعد دوباره امتحان کن": "The link has not been created yet; try again in a few seconds", "QR در دسترس نیست": "QR unavailable", "ری‌استارت شد؛ چند ثانیه بعد وضعیت را ببین": "Restarted; check the status in a few seconds", "تانل حذف شود؟ اکانت‌های تانل به «مستقیم» تبدیل می‌شوند.": "Remove the tunnel? Tunnel accounts will become “Direct”.", "✔ تانل برقرار شد. در «ساخت کاربر» برای Out گزینه‌ی «سرور ۲» را انتخاب کن.": "✔ The tunnel is up. In “Create new user” choose “Server 2” for Out.", "✖ نصب ناموفق بود؛ تغییری روی کاربران فعلی اعمال نشد.": "✖ Installation failed; no change was made to existing users.", "تانل سالم است": "Tunnel is healthy", "بررسی ابزارهای لازم": "Checking the required tools", "ساخت کلید SSH مخصوص تانل": "Creating the tunnel's SSH key", "تست ورود با کلید": "Testing the key login", "آماده‌سازی سرور مقصد (PermitTunnel / فوروارد / NAT)": "Preparing the exit server (PermitTunnel / forwarding / NAT)", "راه‌اندازی تانل روی این سرور": "Starting the tunnel on this server", "انتظار برای برقراری تانل": "Waiting for the tunnel to come up", "تست خروجی اینترنت از مسیر تانل": "Testing internet access through the tunnel", "خطای داخلی": "Internal error", "رمز عبور یا نام کاربری اشتباه است (wrong password/user)": "Wrong password or username", "کاربر باید root باشد (برای ساخت کارت شبکه تانل)": "The user must be root (needed to create the tunnel network device)", "کلید SSH روی سرور مقصد نصب شد (رمز ذخیره نمی‌شود)": "SSH key installed on the exit server (the password is not stored)", "PermitTunnel + ip_forward + NAT روی سرور مقصد فعال شد": "PermitTunnel + ip_forward + NAT enabled on the exit server", "تانل برقرار است ولی تست اینترنت از مسیر تانل جواب نداد (سرور مقصد اینترنت دارد؟)": "The tunnel is up but the internet test through it got no answer (does the exit server have internet?)", "📋 لینک اشتراک (برای برنامه‌ها)": "📋 Subscription link (for apps)", "📋 متن ساده": "📋 Plain-text list", "📋 لینک SSH": "📋 SSH link", "📋 لینک SSH (base64)": "📋 SSH link (base64 login)", "🔗 باز کردن صفحه": "🔗 Open the page", "اگر برنامه‌ی تانل لینک را نپذیرفت، یکی از حالت‌های دیگر را امتحان کن. برنامه‌هایی که گواهی self-signed را رد می‌کنند به گواهی معتبر نیاز دارند، یا لینک اشتراک را روی HTTP ساده فعال کن (تنظیمات ← HTTPS).": "If a tunnel app does not accept the link, try one of the other formats. Apps that reject a self-signed certificate need a valid certificate, or enable the subscription link over plain HTTP (Settings → HTTPS).", "اجازه‌ی لینک اشتراک روی HTTP ساده (برای برنامه‌هایی که گواهی self-signed را نمی‌پذیرند)": "Allow the subscription link over plain HTTP (for apps that do not accept a self-signed certificate)", "⚠️ رمز اکانت داخل لینک است و روی HTTP ساده در مسیر قابل شنود است. فقط در صورت نیاز روشن کن؛ بقیه‌ی پنل همیشه HTTPS می‌ماند.": "⚠️ The account password is inside the link and can be sniffed on the way over plain HTTP. Turn it on only if you need it; the rest of the panel always stays HTTPS.", "🔒 TLS و دامنه": "🔒 TLS & Domain", "نوع اتصال": "Connection type", "فقط TLS": "TLS only", "🔒 SSH روی TLS": "🔒 SSH over TLS", "فعال‌سازی SSH روی TLS": "Enable SSH over TLS", "پورت(های) TLS اکانت‌های معمولی (با کاما جدا کن)": "TLS port(s) for normal accounts (comma-separated)", "پورت(های) TLS اکانت‌های تانل": "TLS port(s) for tunnel accounts", "💾 ذخیره‌ی پورت‌ها": "💾 Save ports", "📜 گواهی فعلی": "📜 Current certificate", "↩️ بازگشت به گواهی self-signed": "↩️ Back to a self-signed certificate", "🌍 دامنه و گواهی (یک‌کلیک)": "🌍 Domain and certificate (one click)", "منبع دامنه": "Domain source", "دامنه‌ی رایگان (خودکار)": "Free domain (automatic)", "دامنه‌ی خودم را دارم": "I have my own domain", "ایمیل (اختیاری؛ برای هشدار انقضا از Let's Encrypt)": "E-mail (optional; Let's Encrypt expiry warnings)", "سرویس دامنه‌ی رایگان": "Free-domain service", "sslip.io — بدون ثبت‌نام": "sslip.io — no sign-up", "nip.io — بدون ثبت‌نام": "nip.io — no sign-up", "DuckDNS — زیردامنه‌ی ثابت (حساب رایگان لازم است)": "DuckDNS — fixed sub-domain (free account needed)", "سرویس wildcard-DNS دیگر (خودت وارد کن)": "Another wildcard-DNS service (enter it yourself)", "نام زیردامنه در DuckDNS": "DuckDNS sub-domain name", "توکن DuckDNS": "DuckDNS token", "پسوند سرویس (مثلاً sslip.io)": "Service suffix (e.g. sslip.io)", "دامنه‌ی شما": "Your domain", "⚡ دریافت دامنه و گواهی": "⚡ Get domain and certificate", "⏳ در حال دریافت...": "⏳ Working...", "⬆️ آپلود گواهی دلخواه (PEM)": "⬆️ Upload your own certificate (PEM)", "دامنه‌ی این گواهی (برای لینک‌ها و SNI)": "Domain of this certificate (used in links and SNI)", "🔒 رفتن به تب TLS و دامنه": "🔒 Go to the TLS & Domain tab", "پنل روی همین پورت HTTPS است (آدرس http قدیمی خودکار به https می‌رود). گواهی و دامنه در تب «TLS و دامنه» مدیریت می‌شود (یک گواهی برای HTTPS پنل و SSH روی TLS)؛ گواهی پیش‌فرض self-signed است و مرورگر هشدار می‌دهد.": "The panel uses HTTPS on this same port (an old http address redirects to https automatically). The certificate and domain are managed in the “TLS & Domain” tab (one certificate for the panel's HTTPS and for SSH over TLS); the default certificate is self-signed and the browser shows a warning.", "خاموش": "Off", "🟢 فعال": "🟢 Active", "🔴 سرویس بالا نیست": "🔴 Service is not running", "دامنه را وارد کن": "Enter the domain", "به گواهی self-signed برگردیم؟ دامنه‌ی فعلی پاک می‌شود.": "Go back to a self-signed certificate? The current domain will be cleared.", "معمولی + TLS": "Normal + TLS", "فقط معمولی": "Normal only", "🔄 تمدید گواهی": "🔄 Renew certificate", "گواهی همین حالا از Let's Encrypt دوباره صادر شود؟ (تمدید خودکار هم هر روز بررسی می‌شود؛ این دکمه برای تمدید فوری است.)": "Re-issue the certificate from Let's Encrypt right now? (Automatic renewal is also checked every day; this button is for an immediate renewal.)", "حداکثر اتصال هم‌زمان از هر IP روی پورت‌های TLS (۰ = بدون محدودیت)": "Max simultaneous connections per IP on the TLS ports (0 = no limit)", "حالت آزمایشی Let's Encrypt (staging): برای امتحان کردن مراحل بدون مصرف سقف؛ گواهی آن معتبر نیست": "Let's Encrypt test mode (staging): to try the steps without using the rate limit; its certificate is not trusted", "📋 مشخصات TLS (ورود دستی)": "📋 TLS details (manual entry)", "نوع تانل": "Tunnel type", "WireGuard — سریع (UDP، پیشنهادی)": "WireGuard — fast (UDP, recommended)", "SSH — سازگار (TCP، کندتر)": "SSH — compatible (TCP, slower)", "⬆️ به‌روزرسانی سرور مقصد": "⬆️ Update exit server"}, ENP=[["ویرایش: {0}", "Edit: {0}"], ["پورت‌های فعال sshd: {0} (پورت‌هایی که بیرون از پنل تعریف شده‌اند، مثل پورت اصلی شما، دست نمی‌خورند)", "Active sshd ports: {0} (ports defined outside the panel, such as your own main port, are never touched)"], ["دسترس‌پذیری ۲۴ ساعت: {0}٪ · میانگین تأخیر: {1} ms · {2} نمونه قطع", "24 h availability: {0}% · average latency: {1} ms · {2} samples down"], ["بازیابی انجام شد ({0} کاربر). پنل چند ثانیه دیگر ری‌استارت می‌شود؛ دوباره وارد شو.", "Restore finished ({0} users). The panel restarts in a few seconds; log in again."], ["ارسال نشد: {0}", "Not sent: {0}"], ["قالب «{0}» حذف شود؟", "Delete template “{0}”?"], ["{0} اکانت با پیشوند {1} ساخته شود؟", "Create {0} accounts with prefix {1}?"], ["تانل سالم است. IP خروجی: {0}", "The tunnel is healthy. Exit IP: {0}"], ["تانل حذف شد. اکانت‌های تبدیل‌شده به مستقیم: {0}", "Tunnel removed. Accounts converted to Direct: {0}"], ["اتصال به {0}:{1} با رمز و نصب کلید", "Connecting to {0}:{1} with the password and installing the key"], ["اتصال SSH برقرار نشد: {0}", "SSH connection failed: {0}"], ["ورود با کلید ناموفق: {0}", "Key login failed: {0}"], ["تداخل پورت روی این سرور رفع شد: {0}", "Port conflicts on this server were fixed: {0}"], ["تانل بالا نیامد: {0}", "The tunnel did not come up: {0}"], ["IP خروجی تانل: {0}", "Tunnel exit IP: {0}"]], HT={"tnNote": "The password is only used to install an SSH key and is not stored; after that the link uses the key.<br>⚠️ If you prefer not to type the server's password into the web page, run this in a terminal on this server:<br><code dir=\"ltr\">sshplus-tunnel-setup IP_SERVER [PORT] [USER]</code>", "biNote": "When creating an account the admin has two choices, <bdi dir=\"ltr\"><b>In</b></bdi> and <bdi dir=\"ltr\"><b>Out</b></bdi>: <bdi dir=\"ltr\"><b>In</b></bdi> is which server's IP the user connects to and <bdi dir=\"ltr\"><b>Out</b></bdi> is which server's IP the user reaches the internet with. All four combinations (<span dir=\"ltr\">1→1</span>, <span dir=\"ltr\">1→2</span>, <span dir=\"ltr\">2→1</span>, <span dir=\"ltr\">2→2</span>) are active and UDPGW (games/calls) works on all of them. No separate mode needs to be configured.", "how": "<bdi dir=\"ltr\"><b>In</b></bdi> is the server whose IP the user connects to and <bdi dir=\"ltr\"><b>Out</b></bdi> is the server whose IP is seen on the internet. “Server 1” is this server and “Server 2” is the tunnel server.<br>\n    1) When <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 2”, the traffic goes through the tunnel. This account works on the <b>SSH (OpenSSH)</b> ports and the <b>tunnel Dropbear</b> ports; the normal Dropbear ports are only for accounts whose <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 1”. Ports can be changed in the Settings tab.<br>\n    2) When <bdi dir=\"ltr\"><b>In</b></bdi> is “Server 2”, this server's ports are opened on server 2 and forwarded through the tunnel to this server. Port 22 and any port server 2 itself listens on are never touched, so admin access to both servers and to the panel always stays open. The firewall of server 2 must allow these ports and the real IP of the user is not visible on this server.<br>\n    3) If the tunnel goes down, every path that goes through it is <b>blocked</b> (instead of leaking out through the direct IP). It reconnects automatically.<br>\n    4) UDPGW (games/calls) works on all four combinations. When <bdi dir=\"ltr\"><b>Out</b></bdi> is “Server 2” it goes through the tunnel. The client keeps using <span dir=\"ltr\">127.0.0.1:7300</span>.<br>\n    5) The tunnel runs over SSH (TCP); for better speed keep BBR on for both servers.", "tgNote": "First create a bot in Telegram with @BotFather and paste the token here; then send <span dir=\"ltr\">/start</span> to the bot and press “Find Chat ID”. If Telegram cannot be reached from this server, the panel automatically sends through the tunnel.", "tgCmd": "Bot commands (only from the configured Chat ID): <span dir=\"ltr\">/status /users /online /backup</span>", "tlsNote": "SSH is wrapped inside a TLS connection, for apps or networks that want TLS/SNI.<br>• A “Normal only” account cannot log in on a TLS port, and a “TLS only” account cannot log in on the plain Dropbear ports.<br>• A “TLS only” account is also refused on the OpenSSH ports (such as 22); “Normal only” and “Both” accounts can log in there.<br>• Tunnel accounts have their own TLS port (they exit through the tunnel).<br>• The <span dir=\"ltr\">ssh://</span> link format for TLS is not standardised; if your app does not accept it, enter the address, port and SNI by hand.", "tlsShared": "This same certificate and domain are also used for the panel's own HTTPS; nothing else needs to be set up elsewhere."};
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
  $("tnInfo").innerHTML=d.conf?L(`سرور خروجی: <b dir="ltr">${esc(d.user)}@${esc(d.host)}:${esc(d.port)}</b><br>نوع تانل: <b dir="ltr">${d.mode==="wg"?"WireGuard":"SSH"}</b><br>IP خروجی: <b dir="ltr">${esc(d.exit||"—")}</b><br>پورت‌های Dropbear تانل: <b dir="ltr">${esc((d.tdb||[]).join(", ")||"—")}</b><br>اکانت‌های تانل: <b>${(d.users||[]).length}</b>`,`Exit server: <b dir="ltr">${esc(d.user)}@${esc(d.host)}:${esc(d.port)}</b><br>Tunnel type: <b dir="ltr">${d.mode==="wg"?"WireGuard":"SSH"}</b><br>Exit IP: <b dir="ltr">${esc(d.exit||"—")}</b><br>Tunnel Dropbear ports: <b dir="ltr">${esc((d.tdb||[]).join(", ")||"—")}</b><br>Tunnel accounts: <b>${(d.users||[]).length}</b>`):"هنوز تانلی تنظیم نشده. فرم کناری را پر کن.";
  $("tnBtns").classList.toggle("hid",!d.conf);
  if(d.conf&&!$("tnMode").dataset.set){$("tnMode").value=d.mode==="wg"?"wg":"ssh"; $("tnMode").dataset.set="1"}
  tnModeUi();
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
function tnModeUi(){
  $("tnModeNote").innerHTML=esc($("tnMode").value==="wg"
    ?L("WireGuard با UDP کار می‌کند و تانل SSH ترافیک TCP را داخل یک اتصال TCP می‌برد (در تأخیر یا افت بسته بسیار کند می‌شود). پورت UDP 51820 روی سرور مقصد باید باز باشد؛ اگر نصب شکست خورد «SSH» را انتخاب کن.","WireGuard uses UDP, while the SSH tunnel carries TCP inside a TCP connection (very slow with latency or packet loss). UDP port 51820 must be open on the exit server; if setup fails choose “SSH”.")
    :L("تانل SSH روی هر سروری کار می‌کند ولی چون TCP داخل TCP است در مسیرهای دور یا پرافت کند می‌شود.","The SSH tunnel works on any server but, being TCP inside TCP, becomes slow on long or lossy routes."));
}
async function tunSetup(){
  if(!$("tnH").value.trim()||!$("tnW").value){alert("IP و رمز سرور جدید را وارد کن");return}
  const r=await api("/api/tunnel/setup","POST",{host:$("tnH").value.trim(),port:$("tnP").value,user:$("tnU").value.trim(),pw:$("tnW").value,mode:$("tnMode").value});
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
async function tunExitUpdate(){
  if(!confirm(L("اسکریپت و قاعده‌های سرور مقصد با نسخه‌ی فعلی پنل دوباره نوشته شود؟ تانل حذف نمی‌شود و ممکن است چند ثانیه اتصال‌های ورودی از سرور ۲ قطع شود.","Rewrite the exit server's script and rules with this panel version? The tunnel is not removed; entries via server 2 may drop for a few seconds."))) return;
  const r=await api("/api/tunnel/exit-update","POST",{});
  alert(r.ok?L("سرور مقصد به‌روزرسانی شد.","Exit server updated.")+((r.skipped||[]).length?"\n"+L("پورت‌های ردشده (روی سرور مقصد مشغول): ","Skipped ports (busy on the exit server): ")+r.skipped.join(", "):""):(r.msg||"Error"));
  loadTun();
}
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
</script>
</body>
</html>
HTMLEOF
sed -i "s/__VERSION__/$VERSION/g" /opt/sshplus-panel/index.html

# firewall: only if ufw is active
FWP="$(sshd -T 2>/dev/null | awk '/^port /{print $2}') 2053 $(python3 -c 'import json;d=json.load(open("/etc/SSHPlus/ports.json"));print(" ".join(map(str,d["db"]+d.get("tdb",[]))))') $(python3 -c 'import json;d=json.load(open("/etc/SSHPlus/tls.json"));print(" ".join(map(str,d.get("ports",[])+d.get("tports",[]))) if d.get("on") else "")' 2>/dev/null)"
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
# SSH over TLS stays on after an update if it was switched on from the panel
if python3 -c 'import json,sys;sys.exit(0 if json.load(open("/etc/SSHPlus/tls.json")).get("on") else 1)' 2>/dev/null; then
  systemctl enable sshplus-dropbear-s sshplus-dropbear-ts sshplus-stunnel >/dev/null 2>&1
  systemctl restart sshplus-dropbear-s sshplus-dropbear-ts sshplus-stunnel
fi
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
if systemctl is-active --quiet sshplus-stunnel; then echo "SSH-TLS:   active (Panel -> TLS tab)"; else echo "SSH-TLS:   off (Panel -> TLS tab to switch on)"; fi
if [ -f /etc/SSHPlus/tunnel.conf ]; then echo "Tunnel:    $(systemctl is-active sshplus-tunnel)"; else echo "Tunnel:    not set up (Panel -> Tunnel tab, or: sshplus-tunnel-setup EXIT_IP)"; fi
echo "BadVPN:    $(systemctl is-active badvpn)   (tunnel instance: $(systemctl is-active badvpn-t))"
echo "SSH:       $(systemctl is-active ssh)"
echo "BBR:       $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
echo "--- listening:"
ss -tlnp | grep -E 'dropbear|badvpn|python3|sshd|stunnel' | awk '{print $4, $6}'
echo "Version:   $VERSION"
echo "Panel URL: https://${IP}:2053  (first login: admin / admin, you must change it)"
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
