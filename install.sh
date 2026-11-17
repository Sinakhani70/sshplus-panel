#!/usr/bin/env bash
# ==============================================================================
#  SSH Plus Panel  -  OpenSSH + Dropbear (6 ports) + BadVPN UDPGW + BBR
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
LOG=/var/log/sshplus/install.log

[ "$(id -u)" = 0 ] || { echo "باید با root اجرا کنی / run as root"; exit 1; }

# ------------------------------------------------------------------------------
step1() {
echo ">>> [1/4] Base system, BBR, BadVPN"
mkdir -p /opt/sshplus-panel /etc/SSHPlus /etc/dropbear /var/log/sshplus
echo "== install $(date)" >> $LOG

apt-get update -y >>$LOG 2>&1
apt-get install -y python3 curl git cmake build-essential dropbear-bin openssh-server iptables iproute2 psmisc procps kmod >>$LOG 2>&1
for c in python3 dropbear dropbearkey cmake git; do
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
for s in sshplus-dropbear badvpn sshplus-panel; do systemctl stop $s >/dev/null 2>&1 || true; done

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
grep -qxF "/usr/local/bin/sshplus-shell" /etc/shells || echo "/usr/local/bin/sshplus-shell" >> /etc/shells

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
python3 - <<'PY'
import json,os,subprocess
p="/etc/SSHPlus/ports.json"
d=json.load(open(p)) if os.path.exists(p) else {}
s1=int(d.get("ssh",22) or 22); s2=int(d.get("ssh2",2222) or 0)
res={22,s1,s2,2053,7300}
try:
    o=subprocess.run(["sshd","-T"],capture_output=True,text=True,timeout=10).stdout
    for l in o.splitlines():
        if l.startswith("port "): res.add(int(l.split()[1]))
except Exception: pass
db=[]
for x in list(d.get("db",[]))+[442,444,8085,8443,10443,9443,8880,2083]:
    try: v=int(x)
    except Exception: continue
    if 0<v<65536 and v not in res and v not in db: db.append(v)
json.dump({"ssh":s1,"ssh2":s2,"db":db[:6]},open(p,"w"))
print("Dropbear ports:",db[:6])
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

# Dropbear (up to 6 ports from ports.json)
cat > /usr/local/bin/start-dropbear.sh <<'EOF'
#!/bin/bash
mkdir -p /etc/dropbear
for t in rsa ecdsa ed25519; do
  f="/etc/dropbear/dropbear_${t}_host_key"
  [ -s "$f" ] || dropbearkey -t "$t" -f "$f" >/dev/null 2>&1
done
P=$(python3 - <<'PY'
import json
try:
    d=json.load(open("/etc/SSHPlus/ports.json")); out=[]
    for x in d.get("db",[]):
        try: v=int(x)
        except Exception: continue
        if 0<v<65536 and v not in (22,2053) and v not in out: out.append(v)
    print(" ".join("-p %d"%p for p in out[:6]) or "-p 442 -p 444")
except Exception:
    print("-p 442 -p 444")
PY
)
exec /usr/sbin/dropbear -F -E -w -K 30 \
  -r /etc/dropbear/dropbear_rsa_host_key \
  -r /etc/dropbear/dropbear_ecdsa_host_key \
  -r /etc/dropbear/dropbear_ed25519_host_key $P
EOF
chmod 755 /usr/local/bin/start-dropbear.sh

# BadVPN
cat > /usr/local/bin/start-badvpn.sh <<'EOF'
#!/bin/bash
UDP_PORT=7300; BIND_ADDR=127.0.0.1; UDP_MTU=1200; MAX_CLIENTS=1000; MAX_CONN=64; SEND_BUFFER=65536; MSS_CLAMP=1
[ -f /etc/SSHPlus/badvpn.conf ] && . /etc/SSHPlus/badvpn.conf
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
Description=SSH Plus Dropbear
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/usr/local/bin/start-dropbear.sh
Restart=always
RestartSec=2
LimitNOFILE=65535
Nice=-5
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
import os, re, json, time, secrets, threading, subprocess
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

CFG="/etc/SSHPlus/panel.json"; DB="/root/users.db"; META="/etc/SSHPlus/meta.json"
PORTS="/etc/SSHPlus/ports.json"; BV="/etc/SSHPlus/badvpn.conf"
BBRF="/etc/sysctl.d/99-sshplus-bbr.conf"; SHELL="/usr/local/bin/sshplus-shell"
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

def ufw_open(ports):
  rc,o,_=cmd(["ufw","status"])
  if rc==0 and o.startswith("Status: active"):
    for p in ports: cmd(["ufw","allow",f"{p}/tcp"])

def user_uid_map():
  m={}
  try:
    for l in open("/etc/passwd"):
      p=l.strip().split(":")
      if len(p)>=7 and p[2].isdigit() and int(p[2])>=1000 and p[6]==SHELL: m[p[0]]=int(p[2])
  except Exception: pass
  return m

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
      elif comm=="sshplus-shell":
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
    _,j,_=cmd(["journalctl","-u","sshplus-dropbear","-n","3000","--no-pager","-o","cat"],20)
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
          "db":cmd(["systemctl","is-active","sshplus-dropbear"])[0]==0,
          "on_tot":sum(len(v) for v in om.values()),"om":{k:len(v) for k,v in om.items()}}

def get_users(om):
  um=user_uid_map(); lim=read_limits_db(); meta=rjson(META,{}); sh=shadow_map()
  today=int(time.time()//86400); res=[]
  for u in sorted(um):
    hs,ex=sh.get(u,("",""))
    if ex.isdigit():
      es=(datetime(1970,1,1)+timedelta(days=int(ex))).strftime("%Y-%m-%d"); dl=max(0,int(ex)-today); expd=int(ex)<=today
    else: es="Never"; dl=0; expd=False
    m=meta.get(u,{}); q=float(m.get("q",0)); ub=int(m.get("u",0))
    res.append({"u":u,"pw":m.get("pw",""),"lim":int(m.get("lim",lim.get(u,1))),"on":om.get(u,0),"exp":es,"dl":dl,
                "expd":expd,"q":q,"ugb":fmt_traffic(ub),"qfull":(q>0 and ub>=int(q*1073741824)),
                "pt":str(m.get("pt","All"))})
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
  um=user_uid_map()
  if edit and u not in um: return 404,{"ok":0,"msg":"User not found"}
  if not edit and not pw: return 400,{"ok":0,"msg":"Password required"}
  if not edit and days<=0: days=30
  ea=["-e",(datetime.utcnow()+timedelta(days=days)).strftime("%Y-%m-%d")] if days>0 else []
  if edit: rc,_,er=cmd(["usermod","-s",SHELL]+ea+[u])
  else: rc,_,er=cmd(["useradd","-M","-s",SHELL]+ea+[u])
  if rc!=0: return 400,{"ok":0,"msg":er or "Failed"}
  if pw:
    r=subprocess.run(["chpasswd"],input=f"{u}:{pw}\n",text=True,capture_output=True,env=ENV)
    if r.returncode!=0:
      if not edit: cmd(["userdel","-f",u])
      return 400,{"ok":0,"msg":(r.stderr or "chpasswd failed")[:120]}
  with ML:
    ls=read_limits_db(); ls[u]=lim; write_limits_db(ls)
    meta=rjson(META,{}); m=meta.setdefault(u,newm(lim))
    m["q"]=q; m["pt"]=pt; m["lim"]=lim
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
  reserved=ssh_set|extra|{panel,bvp,2053}
  db=[]; dropped=[]
  for x in d.get("db",[]):
    if str(x).strip()=="": continue
    v=to_port(x)
    if v and v not in reserved and v not in db: db.append(v)
    else: dropped.append(str(x))
  db=db[:6]
  if not db: return 400,{"ok":0,"msg":"At least one valid Dropbear port is required"}
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
  wjson(PORTS,{"ssh":s1,"ssh2":s2,"db":db}); SSHP["t"]=0
  ufw_open(ssh_set|set(db)|{panel})
  if cmd(["systemctl","reload","ssh"])[0]!=0: cmd(["systemctl","restart","ssh"])
  cmd(["systemctl","restart","sshplus-dropbear"])
  return 200,{"ok":1,"db":db,"dropped":dropped}

def save_bv(d):
  p=to_port(d.get("p")) or 7300
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[]})
  used={22,2053,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|set(pc.get("db",[]))|sshd_ports()
  if p in used: return 400,{"ok":0,"msg":"Port already used by SSH/Dropbear/panel"}
  m=min(max(int(float(d.get("m") or 1200)),576),1500)
  c=min(max(int(float(d.get("c") or 1000)),1),10000)
  n=min(max(int(float(d.get("n") or 64)),1),1000)
  b=str(d.get("b","127.0.0.1")); b=b if b in ("127.0.0.1","0.0.0.0") else "127.0.0.1"
  open(BV,"w").write(f"UDP_PORT={p}\nBIND_ADDR={b}\nUDP_MTU={m}\nMAX_CLIENTS={c}\nMAX_CONN={n}\nSEND_BUFFER=65536\nMSS_CLAMP=1\n")
  if b=="0.0.0.0": ufw_open({p})
  cmd(["systemctl","restart","badvpn"])
  return 200,{"ok":1}

# ---------- monitor ----------
def mon():
  n=0
  while True:
    try:
      if n%5==0:
        for srv in ("sshplus-dropbear","badvpn"):
          if cmd(["systemctl","is-active",srv])[0]!=0:
            cmd(["systemctl","reset-failed",srv]); cmd(["systemctl","restart",srv])
      n+=1
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
        pc=rjson(PORTS,{"ssh":22,"ssh2":2222,"db":[]}); pc["ssh_all"]=sorted(sshd_ports())
        adm=str(rjson(CFG,{"username":"admin"}).get("username","admin")).strip()
        s.js({"st":st,"ports":pc,"bv":bv,"bbr":bbr_state(),"adm":adm,"users":get_users(st["om"])}); return
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

if __name__=="__main__":
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
<title>SSH Plus + Dropbear + BadVPN</title>
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
  <h3 style="color:var(--pr);margin-bottom:.8rem;text-align:center">SSH Plus Panel</h3>
  <label>Username</label><input id="lu" value="admin" autocapitalize="none" autocorrect="off">
  <label>Password</label><input id="lp" type="password" value="admin" autocapitalize="none" onkeydown="if(event.key==='Enter')login()">
  <button class="btn" style="width:100%" onclick="login()">ورود / Login</button>
</div></div>

<div id="eBox" class="modal hid"><div class="card" style="width:100%;max-width:420px">
  <h3 id="eTit" style="color:var(--pr);margin-bottom:.8rem">ویرایش کاربر</h3>
  <input type="hidden" id="eu">
  <label>رمز جدید (خالی = بدون تغییر)</label><input id="epw" autocapitalize="none">
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
  <h2>⚡ SSH Plus + Dropbear + BadVPN</h2>
  <div>
    <button class="btn btn-s" onclick="document.documentElement.dir=document.documentElement.dir==='rtl'?'ltr':'rtl'">FA / EN</button>
    <button class="btn btn-s" onclick="load(1)">🔄</button>
    <button class="btn btn-s btn-e" onclick="localStorage.removeItem('tok');location.reload()">Logout</button>
  </div>
</div>

<div class="tab-bar">
  <button id="bTabU" class="tab-btn act" onclick="swTab('u')">👥 کاربران</button>
  <button id="bTabS" class="tab-btn" onclick="swTab('s')">⚙️ تنظیمات سرور</button>
</div>

<div id="secU">
  <div class="card" style="border-color:var(--pr);font-size:.88rem"><strong>🔌 پورت‌های فعال: </strong><span id="pBan">--</span></div>
  <div class="g4">
    <div class="card"><label>آنلاین / کل کاربران</label><h2 id="stU">0 / 0</h2></div>
    <div class="card"><label>Dropbear</label><div id="stDb" style="margin-top:.3rem">--</div></div>
    <div class="card"><label>BadVPN</label><div id="stBv" style="margin-top:.3rem">--</div></div>
    <div class="card"><label>BBR / منابع</label><div id="stBbr" style="margin-top:.2rem">--</div><div id="stRes" style="font-size:.78rem;color:var(--mu);margin-top:.2rem">--</div></div>
  </div>

  <div class="card">
    <h3 style="margin-bottom:.7rem">➕ ساخت کاربر جدید</h3>
    <div class="row">
      <div><label>نام کاربری (انگلیسی)</label><input id="nu" placeholder="user1" autocapitalize="none"></div>
      <div><label>رمز عبور</label><input id="npw" placeholder="123456" autocapitalize="none"></div>
      <div><label>پورت پیشنهادی</label><select id="npt"></select></div>
      <div><label>حجم (GB | 0=نامحدود)</label><input id="nq" type="number" step="0.5" value="0" min="0"></div>
      <div><label>روز اعتبار</label><input id="nd" type="number" value="30" min="1"></div>
      <div><label>کاربر همزمان</label><input id="nl" type="number" value="1" min="1"></div>
    </div>
    <button class="btn" onclick="saveUser(0)">ایجاد اکانت</button>
  </div>

  <div class="card" style="overflow-x:auto">
    <h3>📋 لیست کاربران</h3>
    <table>
      <thead><tr><th>User / Pass</th><th>Port</th><th>Online / Limit</th><th>Traffic</th><th>Expires</th><th>Status</th><th>Actions</th></tr></thead>
      <tbody id="tb"></tbody>
    </table>
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
let tok=localStorage.getItem("tok")||"", ul=[], pCfg={ssh:22,ssh2:0,db:[]}, bv={}, bbrOn=false, lastSig="";
function swTab(t){
  $("secU").classList.toggle("hid",t!=="u"); $("secS").classList.toggle("hid",t!=="s");
  $("bTabU").classList.toggle("act",t==="u"); $("bTabS").classList.toggle("act",t==="s");
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
  $("stDb").innerHTML=d.st.db?`<span class="bdg ok">ACTIVE (${db.join(",")})</span>`:`<span class="bdg er">STOPPED</span>`;
  $("stBv").innerHTML=d.st.bv?`<span class="bdg ok">UDPGW ${esc(bv.BIND_ADDR||"")}:${esc(bv.UDP_PORT||7300)}</span>`:`<span class="bdg er">STOPPED</span>`;
  $("stBbr").innerHTML=bbrOn?`<span class="bdg ok">BBR ON</span>`:`<span class="bdg wn">${esc(bb.cc||"?")}</span>`;
  $("stRes").innerText=`CPU:${d.st.cpu}% | RAM:${d.st.mem}% | ↓${d.st.rx}M ↑${d.st.tx}M`;
  $("pBan").innerText=`OpenSSH: ${sp.join(", ")} | Dropbear: ${db.join(", ")} | UDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`;
  $("bbrCc").value=bb.cc||""; $("bbrQd").value=bb.qdisc||"";
  $("bbrSt").innerHTML=bbrOn?`<span class="bdg ok">فعال</span>`:(bb.avail?`<span class="bdg wn">غیرفعال</span>`:`<span class="bdg er">کرنل پشتیبانی نمی‌کند</span>`);
  $("bbrBtn").innerText=bbrOn?"⛔ خاموش کردن BBR":"🚀 روشن کردن BBR";
  $("bbrBtn").className="btn "+(bbrOn?"btn-e":"btn-o");
  const sig=sp.join(",")+"|"+db.join(",")+"|"+JSON.stringify(bv)+"|"+pCfg.ssh+"|"+pCfg.ssh2;
  if(force||sig!==lastSig){
    lastSig=sig;
    const cn=$("npt").value, ce=$("ept").value;
    $("s1").value=pCfg.ssh||22; $("s2").value=pCfg.ssh2||0;
    for(let i=1;i<=6;i++) $("d"+i).value=db[i-1]||"";
    $("bp").value=bv.UDP_PORT||7300; $("bm").value=bv.UDP_MTU||1200; $("bc").value=bv.MAX_CLIENTS||1000;
    $("bn").value=bv.MAX_CONN||64; $("bb").value=bv.BIND_ADDR||"127.0.0.1";
    $("sshAll").innerText="پورت‌های فعال sshd: "+sp.join(", ")+" (پورت‌هایی که بیرون از پنل تعریف شده‌اند، مثل پورت اصلی شما، دست نمی‌خورند)";
    if(!$("au").value && document.activeElement!==$("au")) $("au").value=d.adm||"admin";
    const o=portOpts(sp,db); $("npt").innerHTML=o; $("ept").innerHTML=o;
    if(cn) $("npt").value=cn; if(ce) $("ept").value=ce;
  }
  $("tb").innerHTML=ul.map(x=>`<tr>
    <td><b>${esc(x.u)}</b><div style="font-size:.75rem;color:var(--mu)">🔑 ${esc(x.pw||"***")}</div></td>
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
  if([...$("ept").options].some(o=>o.value===x.pt)) $("ept").value=x.pt; else $("ept").value="All";
  $("eq").value=x.q||0; $("el").value=x.lim||1; $("ed").value=""; $("erst").checked=false; $("eBox").classList.remove("hid");
}
async function saveUser(edit){
  const b=edit?{edit:1,u:$("eu").value,pw:$("epw").value,pt:$("ept").value,q:$("eq").value,l:$("el").value,d:$("ed").value,rst:$("erst").checked}
              :{edit:0,u:$("nu").value,pw:$("npw").value,pt:$("npt").value,q:$("nq").value,l:$("nl").value,d:$("nd").value};
  const r=await api("/api/user/save","POST",b);
  if(r.ok){$("eBox").classList.add("hid");$("nu").value="";$("npw").value="";load(0)}else alert(r.msg||"Error");
}
async function delU(u){if(confirm("Delete "+u+"?")){await api("/api/user/del","POST",{u});load(0)}}
async function savePorts(){
  const r=await api("/api/ports","POST",{ssh:$("s1").value,ssh2:$("s2").value,db:[1,2,3,4,5,6].map(i=>$("d"+i).value)});
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
  const t=`Host/IP: ${location.hostname}\nSSH Ports: ${(pCfg.ssh_all||[22]).join(", ")}\nDropbear Ports: ${(pCfg.db||[]).join(", ")}\nUser: ${x.u}\nPass: ${x.pw}\nLimit: ${x.lim}\nQuota: ${x.q>0?x.q+" GB":"Unlimited"}\nUDPGW: 127.0.0.1:${bv.UDP_PORT||7300}`;
  if(navigator.clipboard&&navigator.clipboard.writeText) navigator.clipboard.writeText(t).then(()=>alert("Copied!")); else prompt("Copy:",t);
}
if(tok){$("lBox").classList.add("hid");load(1)}
setInterval(()=>{if(tok&&$("lBox").classList.contains("hid"))load(0)},4000);
</script>
</body>
</html>
HTMLEOF

# firewall: only if ufw is active
if ufw status 2>/dev/null | grep -q '^Status: active'; then
  for p in $(sshd -T 2>/dev/null | awk '/^port /{print $2}') 2053 \
           $(python3 -c 'import json;print(" ".join(map(str,json.load(open("/etc/SSHPlus/ports.json"))["db"])))'); do
    ufw allow "${p}/tcp" >/dev/null 2>&1
  done
fi

systemctl reset-failed sshplus-panel sshplus-dropbear badvpn 2>/dev/null || true
systemctl enable --now sshplus-panel sshplus-dropbear badvpn >/dev/null 2>&1
systemctl restart sshplus-dropbear badvpn sshplus-panel
sleep 2

IP=$(curl -sfL --max-time 4 https://api.ipify.org || hostname -I | awk '{print $1}')
echo "=========================================="
echo "Panel:     $(systemctl is-active sshplus-panel)"
echo "Dropbear:  $(systemctl is-active sshplus-dropbear)"
echo "BadVPN:    $(systemctl is-active badvpn)"
echo "SSH:       $(systemctl is-active ssh)"
echo "BBR:       $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
echo "--- listening:"
ss -tlnp | grep -E 'dropbear|badvpn|python3|sshd' | awk '{print $4, $6}'
echo "Panel URL: http://${IP}:2053  (admin / admin)"
echo "=========================================="
}

# ------------------------------------------------------------------------------
mkdir -p /var/log/sshplus
step1
step2
step3
step4
