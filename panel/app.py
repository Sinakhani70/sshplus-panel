#!/usr/bin/env python3
import os, re, io, sys, json, time, ssl, socket, base64, hashlib, shutil, getpass, secrets, threading, subprocess
from datetime import datetime, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, quote

CFG="/etc/SSHPlus/panel.json"; DB="/root/users.db"; META="/etc/SSHPlus/meta.json"
PORTS="/etc/SSHPlus/ports.json"; BV="/etc/SSHPlus/badvpn.conf"
BBRF="/etc/sysctl.d/99-sshplus-bbr.conf"; SHELL="/usr/local/bin/sshplus-shell"; SHELL_T=SHELL+"-t"
HTML="/opt/sshplus-panel/index.html"; SSHCONF="/etc/ssh/sshd_config.d/00-sshplus.conf"
TOK={}; PIDS={}; FAIL={}; DBU={}; DBT={}; DBA={}; IPS={}; SIP={}; IPC={}; GRP={}; DROP={}
STATE={"first":True}; CACHE={"t":0.0,"v":None}; SSHP={"t":0.0,"v":set()}
LOCK=threading.Lock(); ML=threading.RLock()
ENV={"LC_ALL":"C","PATH":"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
NAME_RE=re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,31}\Z")
# An account = type (direct / tunnel) x connection (both / normal only / TLS only). The login shell encodes it and every Dropbear
# instance lists only the shells it serves in its own /etc/shells (see the systemd units), so e.g. a TLS-only account is refused on the plain ports.
SHELLS={("direct","both"):SHELL,("tunnel","both"):SHELL_T,("direct","normal"):SHELL+"-n",("tunnel","normal"):SHELL+"-tn",
        ("direct","tls"):SHELL+"-s",("tunnel","tls"):SHELL+"-ts",
        ("direct","game"):SHELL+"-g"}                                      # game accounts: own Dropbear instance + port, direct only
SHELL_OF={v:k for k,v in SHELLS.items()}
TLS_BACKENDS=6                                   # Dropbear processes per TLS instance (keep in line with scripts/start-dropbear.sh)
def shell_for(tm,cx):
  if cx=="game": return SHELLS[("direct","game")]
  return SHELLS[("tunnel" if tm=="tunnel" else "direct",cx if cx in ("normal","tls") else "both")]
def game_ports():
  return [p for p in (to_port(x) for x in rjson(PORTS,{}).get("gdb",[])) if p][:2]
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
def ss_peers():
  # pid -> (client ip, client port) of every established TCP connection, straight from the kernel (no log parsing, no delay)
  rc,o,_=cmd(["ss","-tnpH","state","established"],10); m={}
  for l in (o.splitlines() if rc==0 else []):
    f=l.split()
    if len(f)<4 or ":" not in f[3]: continue
    ip,_,port=f[3].rpartition(":")
    ip=ip.strip("[]").replace("::ffff:","")
    for pid in re.findall(r"pid=(\d+)",l): m.setdefault(int(pid),(ip,int(port) if port.isdigit() else 0))
  return m

def pid_start(pid):
  # process start time (clock ticks since boot): orders sessions by age independently of pid numbers
  try:
    d=open("/proc/%d/stat"%pid).read()
    return int(d[d.rindex(")")+2:].split()[19])
  except Exception: return 1<<62

def limit_groups(pids,sip):
  # one "device" = one client IP (several connections from the same IP count once); a session whose address is unknown counts alone
  g={}
  for p in pids: g.setdefault(("ip",sip[p]) if sip.get(p) else ("s",p),[]).append(p)
  return g

def limit_victims(pids,ulim,sip,start):
  # which sessions of ONE account must go: keep the `ulim` oldest devices untouched, cut every session of the newer ones.
  # Returns (pids to kill, client IPs that were turned away)
  g=limit_groups(pids,sip)
  order=sorted(g.items(),key=lambda kv:(min(start.get(p,1<<62) for p in kv[1]),min(kv[1])))
  drop=order[max(1,int(ulim)):]
  return [p for _,ps in drop for p in ps],[k[1] for k,_ in drop if k[0]=="ip"]

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
  unknown=[p for p in workers if p not in DBU and now-DBT.get(p,0)>3]
  if unknown:
    for p in unknown: DBT[p]=now
    _,j,_=cmd(["journalctl","-u","sshplus-dropbear","-u","sshplus-dropbear-t","-u","sshplus-dropbear-s","-u","sshplus-dropbear-ts","-u","sshplus-dropbear-g","-n","3000","--no-pager","-o","cat"],20)
    for jl in j.splitlines():
      mt=re.search(r"\[(\d+)\].*Password auth succeeded for '([^']+)' from (\S+):(\d+)\s*$",jl)
      if mt: DBU[int(mt.group(1))]=mt.group(2); DBA[int(mt.group(1))]=(mt.group(3),int(mt.group(4)))
  for dpid in workers:
    u=DBU.get(dpid)
    if u in um:
      io_pids[u].add(dpid)
      if dpid not in sessions[u]: sessions[u].append(dpid)
  # client address of every session (kernel socket table first, the auth log as a fallback)
  ssm=ss_peers(); cip=None; sip={}; ipc={}
  for u,ps in sessions.items():
    for p in ps:
      a=ssm.get(p) or DBA.get(p); ip=""
      if a:
        ip,port=str(a[0]).replace("::ffff:",""),a[1]
        if ip in ("127.0.0.1","::1"):                                 # TLS: the real client address is in stunnel's log
          if cip is None: cip=tls_client_ips()
          ip=cip.get(port,"")
        if ip.startswith("10.99.0."): ip=""                            # entry via server 2: this is the tunnel peer, not a client
      sip[p]=ip
      if ip: ipc.setdefault(u,{})[ip]=ipc.setdefault(u,{}).get(ip,0)+1
  SIP.clear(); SIP.update(sip); IPC.clear(); IPC.update(ipc)
  IPS.clear(); IPS.update({k:sorted(v) for k,v in ipc.items()})
  GRP.clear(); GRP.update({u:len(limit_groups(ps,sip)) for u,ps in sessions.items() if ps})
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


# ---------- Game Profile: low-latency network settings (sysctl + root qdisc), reversible; optional OpenSSH tuning ----------
GAMEF="/etc/SSHPlus/game.json"; GAME_SYSF="/etc/sysctl.d/99-sshplus-game.conf"; GAME_SSHD="/etc/ssh/sshd_config.d/03-sshplus-game.conf"
GAME_SYSCTL=(("net.core.default_qdisc","fq"),("net.ipv4.tcp_congestion_control","bbr"),("net.ipv4.tcp_notsent_lowat","16384"),("net.ipv4.tcp_slow_start_after_idle","0"))
GAME_CIPHERS="chacha20-poly1305@openssh.com,aes128-gcm@openssh.com"
DEV_RE=re.compile(r"^[A-Za-z0-9_.-]{1,15}\Z"); QD_RE=re.compile(r"^[a-z][a-z0-9_]{1,15}\Z")

def wan_dev():
  rc,o,_=cmd(["ip","-o","route","get","1.1.1.1"])
  m=re.search(r"\bdev (\S+)",o) if rc==0 else None
  return m.group(1) if m and DEV_RE.match(m.group(1)) else ""

def root_qdisc(dev):
  if not dev: return ""
  rc,o,_=cmd(["tc","qdisc","show","dev",dev])
  m=re.search(r"^qdisc (\S+) \S+ root\b",o,re.M) if rc==0 else None
  return m.group(1) if m else ""

def game_sshd_text(ciphers):
  pc=rjson(PORTS,{"ssh":22,"ssh2":0})
  ports=sorted({22,to_port(pc.get("ssh")) or 22}|({to_port(pc.get("ssh2"))} if to_port(pc.get("ssh2")) else set()))
  t="# generated by the CK.VPN panel (Game Profile). Compression/UseDNS/Ciphers can only be global in sshd; IPQoS is limited to the panel's SSH ports.\nCompression no\nUseDNS no\n"
  if ciphers: t+="Ciphers "+GAME_CIPHERS+"\n"
  for p in ports: t+="Match LocalPort %d\n  IPQoS lowdelay\n"%p
  return t

def game_state():
  g=rjson(GAMEF,{}); dev=wan_dev(); bb=bbr_state()
  keys=[{"k":k,"want":v,"cur":sysctl_get(k)} for k,v in GAME_SYSCTL]
  try: st=open(GAME_SSHD).read()
  except OSError: st=""
  return {"on":bool(g.get("on")),"keys":keys,"dev":dev,"qdisc":root_qdisc(dev),"bbr_avail":bb["avail"],"notes":g.get("notes",[]),
          "sshd":{"on":bool(st),"ciphers":bool(re.search(r"(?m)^Ciphers ",st))}}

def game_apply(on):
  g=rjson(GAMEF,{}); notes=[]
  if on:
    prev=g.get("prev") or {}
    if not g.get("on"):                                                    # remember what was there: disabling restores exactly this
      prev={k:sysctl_get(k) for k,_ in GAME_SYSCTL}; dev=wan_dev(); prev["_qdisc"]={"dev":dev,"kind":root_qdisc(dev)}
    bbr_state()                                                            # loads tcp_bbr when it exists
    applied=[]
    for k,v in GAME_SYSCTL:
      if not sysctl_get(k): notes.append("%s: not available on this kernel"%k); continue
      if k.endswith("congestion_control") and not bbr_state()["avail"]: notes.append("BBR is not available on this kernel"); continue
      cmd(["sysctl","-w","%s=%s"%(k,v)])
      if sysctl_get(k)==v: applied.append((k,v))
      else: notes.append("%s: could not be set"%k)
    open(GAME_SYSF,"w").write("# generated by the CK.VPN panel: Game Profile\n"+"".join("%s = %s\n"%kv for kv in applied))
    MOD="/etc/modules-load.d/sshplus-bbr.conf"
    if ("net.ipv4.tcp_congestion_control","bbr") in applied and not os.path.exists(MOD):      # load tcp_bbr at boot too (removed again when the profile is turned off)
      os.makedirs("/etc/modules-load.d",exist_ok=True); open(MOD,"w").write("tcp_bbr\n"); prev["_mod"]=1
    dev=wan_dev()
    if dev and root_qdisc(dev)!="fq":                                      # default_qdisc only affects qdiscs created later: replace the root qdisc of the WAN interface too
      cmd(["tc","qdisc","replace","dev",dev,"root","fq"])
      if root_qdisc(dev)!="fq": notes.append("fq could not be set on %s (it stays %s)"%(dev,root_qdisc(dev) or "unknown"))
    wjson(GAMEF,{"on":True,"prev":prev,"notes":notes,"ts":int(time.time())})
  else:
    prev=g.get("prev") or {}
    for k,_ in GAME_SYSCTL:
      v=str(prev.get(k,"")).strip()
      if v and re.match(r"^[A-Za-z0-9_ .-]{1,40}\Z",v): cmd(["sysctl","-w","%s=%s"%(k,v)])
    try: os.remove(GAME_SYSF)
    except OSError: pass
    if prev.get("_mod") and not os.path.exists(BBRF):
      try: os.remove("/etc/modules-load.d/sshplus-bbr.conf")
      except OSError: pass
    q=prev.get("_qdisc") or {}; dev=str(q.get("dev","")); kind=str(q.get("kind",""))
    if DEV_RE.match(dev) and root_qdisc(dev)=="fq":
      if QD_RE.match(kind) and kind not in ("noqueue",): cmd(["tc","qdisc","replace","dev",dev,"root",kind])
      if root_qdisc(dev)=="fq": cmd(["tc","qdisc","del","dev",dev,"root"])    # kind unknown or not restorable: back to the kernel default
    wjson(GAMEF,{"on":False,"prev":{},"notes":[]})
  return 200,dict(game_state(),ok=1,notes=notes)

def game_sshd_apply(d):
  # explicit, separate action: it needs an sshd reload (the same sshd serves every SSH port, a main one included)
  on=bool(d.get("on")); cip=bool(d.get("ciphers")); old=None
  try: old=open(GAME_SSHD).read()
  except OSError: pass
  new=game_sshd_text(cip) if on else None
  if new==old: return 200,dict(game_state(),ok=1,reloaded=False)
  try:
    if new is None: os.remove(GAME_SSHD)
    else: open(GAME_SSHD,"w").write(new)
    if cmd(["sshd","-t"])[0]!=0: raise ValueError("sshd -t failed")
  except Exception as e:
    try:
      if old is None: os.remove(GAME_SSHD)
      else: open(GAME_SSHD,"w").write(old)
    except OSError: pass
    return 400,{"ok":0,"msg":"OpenSSH settings rejected (rolled back): "+str(e)[:100]}
  if cmd(["systemctl","reload","ssh"])[0]!=0: cmd(["systemctl","restart","ssh"])
  SSHP["t"]=0
  return 200,dict(game_state(),ok=1,reloaded=True)


# ---------- Network monitor: ping / jitter / loss from this server to chosen targets, plus per-session TCP stats ----------
NETMON_CF="/etc/SSHPlus/netmon.json"; NETMON_HIST="/etc/SSHPlus/netmon_hist.json"; NM_KEEP=720            # 12 h at one sample per minute and target
NM={"s":{},"n":0}; NML=threading.Lock()
NM_DEFAULT=["1.1.1.1","8.8.8.8"]

def nm_target(x):
  # an IP literal or a plain host name; never anything that could look like an option
  x=str(x).strip().lower()
  try: return str(ipaddress.ip_address(x))
  except ValueError: pass
  return x if HOST_RE.match(x) and "." in x and len(x)<=100 else ""

def netmon_cfg():
  d=rjson(NETMON_CF,{}); tg=[]
  for x in d.get("targets",NM_DEFAULT):
    t=nm_target(x)
    if t and t not in tg: tg.append(t)
  return {"on":bool(d.get("on")),"targets":tg[:3] or list(NM_DEFAULT)}

def netmon_save(d):
  raw=d.get("targets",[])
  if isinstance(raw,str): raw=re.split(r"[\s,;]+",raw)
  if not isinstance(raw,list): return 400,{"ok":0,"msg":"Invalid targets"}
  tg=[]
  for x in raw:
    if str(x).strip()=="": continue
    t=nm_target(x)
    if not t: return 400,{"ok":0,"msg":"Invalid target: "+str(x)[:60]}
    if t not in tg: tg.append(t)
  if len(tg)>3: return 400,{"ok":0,"msg":"At most 3 targets"}
  wjson(NETMON_CF,{"on":bool(d.get("on")),"targets":tg or list(NM_DEFAULT)})
  return 200,{"ok":1,**netmon_state()}

def nm_sample(o):
  # sample = [timestamp, mean rtt ms, jitter ms, loss %, max rtt ms]; jitter = mean absolute difference of consecutive replies
  ts=[float(v) for v in re.findall(r"time[=<]([0-9.]+) ?ms",o)]
  m=re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received",o)
  sent,rcv=(int(m.group(1)),int(m.group(2))) if m else (0,0)
  loss=round(100.0*(sent-rcv)/sent,1) if sent else 100.0
  if not ts: return [int(time.time()),-1,0,loss,-1]
  jit=sum(abs(b-a) for a,b in zip(ts,ts[1:]))/(len(ts)-1) if len(ts)>1 else 0.0
  return [int(time.time()),round(sum(ts)/len(ts),1),round(jit,1),loss,round(max(ts),1)]

def nm_round():
  cfg=netmon_cfg()
  for t in cfg["targets"]:
    _,o,_=cmd(["ping","-n"]+(["-6"] if ":" in t else [])+["-c","10","-i","0.2","-W","1",t],25)
    smp=nm_sample(o)
    with NML:
      sr=NM["s"].setdefault(t,[]); sr.append(smp); del sr[:-NM_KEEP]
  with NML:
    NM["n"]+=1
    if NM["n"]%5==0: wjson(NETMON_HIST,{k:v for k,v in NM["s"].items() if k in cfg["targets"]})

def netmon_loop():
  with NML: NM["s"]=rjson(NETMON_HIST,{})
  while True:
    t0=time.time()
    try:
      if netmon_cfg()["on"]: nm_round()
    except Exception: pass
    time.sleep(max(5,60-(time.time()-t0)))

def netmon_state():
  cfg=netmon_cfg()
  with NML: ser={t:list(NM["s"].get(t,[])) for t in cfg["targets"]}
  return {"on":cfg["on"],"targets":cfg["targets"],"series":ser,"last":{t:(v[-1] if v else None) for t,v in ser.items()}}

def net_sessions():
  # per-connection TCP stats of the clients on the SSH/Dropbear/TLS ports, taken from this server's own TCP stack (ss -ti):
  # the RTT here includes the client's mobile network, so it separates "the server" from "the path to the client"
  pc=rjson(PORTS,{}); tl=tls_cfg()
  ports=set(sshd_ports())|{to_port(x) for x in pc.get("db",[])}|{to_port(x) for x in pc.get("tdb",[])}|set(game_ports())|((set(tl["ports"])|set(tl["tports"])) if tl["on"] else set())
  ports.discard(None)
  rc,o,_=cmd(["ss","-tinH","state","established"],10)
  byip={}
  for u,ips in IPS.items():
    for ip in ips: byip.setdefault(ip,[]).append(u)
  rows=[]; head=None
  for l in (o.splitlines() if rc==0 else []):
    if l[:1] not in (" ","\t"):
      f=l.split(); head=None
      if len(f)>=4 and ":" in f[-1] and ":" in f[-2]:
        lp=f[-2].rsplit(":",1)[1]; pe=f[-1].rsplit(":",1)[0].strip("[]")
        if lp.isdigit() and int(lp) in ports and pe not in ("127.0.0.1","::1"): head=(int(lp),pe)
      continue
    if head is None: continue
    r=re.search(r"\brtt:([0-9.]+)/([0-9.]+)",l); rt=re.search(r"\bretrans:(\d+)/(\d+)",l)
    if r: rows.append({"port":head[0],"peer":head[1],"user":",".join(byip.get(head[1],[])[:2]),"rtt":float(r.group(1)),"var":float(r.group(2)),"retrans":int(rt.group(2)) if rt else 0})
    head=None
  rows.sort(key=lambda x:-x["rtt"])
  rt=sorted(x["rtt"] for x in rows)
  return {"n":len(rows),"median":rt[len(rt)//2] if rt else None,"with_retrans":sum(1 for x in rows if x["retrans"]>0),"rows":rows[:60]}

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
          "dbg":cmd(["systemctl","is-active","sshplus-dropbear-g"])[0]==0 if game_ports() else None,
          "ssh":cmd(["systemctl","is-active","ssh"])[0]==0 or cmd(["systemctl","is-active","sshd"])[0]==0,
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
                "pt":str(m.get("pt","All")),"tm":"tunnel" if is_tun(pm[u][1]) else "direct","cx":SHELL_OF.get(pm[u][1],("direct","both"))[1],"en":"B" if m.get("en")=="B" else "A","st":m.get("tok",""),"ips":IPS.get(u,[]),"ipc":IPC.get(u,{}),"dev":GRP.get(u,0),
                "drop":sorted(ip for ip,t in DROP.get(u,{}).items() if time.time()-t<300)})
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
  tm=tmq if tmq in ("tunnel","direct") else ctm; cx=cxq if cxq in ("both","normal","tls","game") else ccx
  if cx=="game" and tm=="tunnel": return 400,{"ok":0,"msg":"Game accounts are direct-only (they cannot leave through the exit server)"}
  if cx=="game" and not game_ports() and not (edit and ccx=="game"): return 400,{"ok":0,"msg":"No game Dropbear port is set (Settings > ports)"}
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
  cmd(["pkill","-9","-u",u]); cmd(["userdel","-f",u]); DROP.pop(u,None)
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
  gdb=[]                                       # Dropbear ports of the game instance (0..2); an empty list switches the instance off
  for x in (d["gdb"] if "gdb" in d else old.get("gdb",[])):
    if str(x).strip()=="": continue
    v=to_port(x)
    if v and v not in reserved and v not in db and v not in tdb and v not in gdb: gdb.append(v)
    else: dropped.append(str(x))
  gdb=gdb[:2]
  bak=open(SSHCONF).read() if os.path.exists(SSHCONF) else None
  # Port lines in this file that the panel does not manage (e.g. a main SSH port such as 9011 someone put here) are kept as they are
  keep={q for q in (to_port(m) for m in re.findall(r"(?m)^Port[ \t]+(\d+)[ \t]*$",bak or "")) if q}-managed-ssh_set
  lines=[f"Port {x}" for x in sorted(ssh_set|keep)]+[
    "PasswordAuthentication yes","PermitRootLogin yes","UsePAM yes","AllowTcpForwarding yes",
    "AllowStreamLocalForwarding yes","AllowAgentForwarding no","GatewayPorts no","PermitTunnel yes",
    "TCPKeepAlive yes","ClientAliveInterval 30","ClientAliveCountMax 10","MaxSessions 100","MaxStartups 100:30:200"]
  newtxt="\n".join(lines)+"\n"
  open(SSHCONF,"w").write(newtxt)
  rc,_,er=cmd(["sshd","-t"])
  if rc!=0:
    if bak is not None: open(SSHCONF,"w").write(bak)
    return 400,{"ok":0,"msg":"sshd config invalid: "+er[:120]}
  wjson(PORTS,{"ssh":s1,"ssh2":s2,"db":db,"tdb":tdb,"gdb":gdb}); SSHP["t"]=0
  ufw_open(ssh_set|set(db)|set(tdb)|set(gdb)|{panel})
  if bak!=newtxt:                                   # sshd (and with it every SSH port, 9011 included) is only reloaded when its configuration really changed
    if cmd(["systemctl","reload","ssh"])[0]!=0: cmd(["systemctl","restart","ssh"])
  cmd(["systemctl","restart","sshplus-dropbear"]); cmd(["systemctl","restart","sshplus-dropbear-t"]); game_unit_sync()
  if tconf().get("TUN_HOST"): threading.Thread(target=ports_sync,daemon=True).start()
  return 200,{"ok":1,"db":db,"tdb":tdb,"gdb":gdb,"dropped":dropped}

def game_unit_sync():
  # the game Dropbear instance runs only while it has a port
  if game_ports():
    try: tls_shell_files()
    except Exception: pass
    cmd(["systemctl","enable","sshplus-dropbear-g"]); cmd(["systemctl","restart","sshplus-dropbear-g"])
  else: cmd(["systemctl","disable","--now","sshplus-dropbear-g"])

def save_bv(d):
  p=to_port(d.get("p")) or 7300
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[]})
  used={22,2053,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|set(pc.get("db",[]))|set(pc.get("tdb",[]))|set(game_ports())|sshd_ports()|tls_taken()
  if p in used or p+1 in used or p+1>65535: return 400,{"ok":0,"msg":"Port (or port+1, used by the tunnel UDPGW) is already used by SSH/Dropbear/panel"}
  m=min(max(int(float(d.get("m") or 1200)),576),1500)
  c=min(max(int(float(d.get("c") or 1000)),1),10000)
  n=min(max(int(float(d.get("n") or 64)),1),1000)
  b=str(d.get("b","127.0.0.1")); b=b if b in ("127.0.0.1","0.0.0.0") else "127.0.0.1"  # nosec B104 - the admin may choose to expose UDPGW
  sb=d.get("s"); sb=65536 if sb in (None,"") else min(max(int(float(sb)),0),16777216)     # --client-socket-sndbuf <bytes / 0> (0 = system default)
  open(BV,"w").write(f"UDP_PORT={p}\nBIND_ADDR={b}\nUDP_MTU={m}\nMAX_CLIENTS={c}\nMAX_CONN={n}\nSEND_BUFFER={sb}\nMSS_CLAMP=1\n")
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
HOST_RE=re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}\Z"); TUSER_RE=re.compile(r"^[a-z_][a-z0-9_-]{0,31}\Z")
IP_RE=re.compile(r"^[0-9a-fA-F:.]{3,45}\Z")

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
CHK='^permittunnel (yes|point-to-point)'
HAD_TUN=0; sshd -T 2>/dev/null | grep -qiE "$CHK" && HAD_TUN=1          # already effective: sshd must not be reloaded again (it also serves this server's own SSH ports)
echo "PermitTunnel yes" > /etc/ssh/sshd_config.d/01-sshplus-tunnel.conf
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
[ "$HAD_TUN" = 1 ] || (systemctl reload ssh || systemctl reload sshd) >/dev/null 2>&1 || true
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
    fixed=ports_autofix(); ufw_open(set(rjson(PORTS,{}).get("db",[]))|set(rjson(PORTS,{}).get("tdb",[]))|set(game_ports()))   # this server first
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
  for x in list(pc.get("db",[]))+list(pc.get("tdb",[]))+game_ports()+[pc.get("ssh2",0)]+extra:
    v=to_port(x)
    if v and v!=22 and v not in out: out.append(v)
  return out

def ports_autofix():
  # Dropbear ports (direct + tunnel) that another program already listens on are replaced by free ports
  pc=rjson(PORTS,{"ssh":22,"ssh2":0,"db":[],"tdb":[]}); lis=listen_ports(); foreign=foreign_ports()
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053; bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  used=set(lis)|{22,panel,2053,bvp,bvp+1,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|sshd_ports()|set(pc.get("db",[]))|set(pc.get("tdb",[]))|set(game_ports())|tls_taken()
  changes=[]
  for key in ("db","tdb","gdb"):
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
    cmd(["systemctl","restart","sshplus-dropbear"]); cmd(["systemctl","restart","sshplus-dropbear-t"]); game_unit_sync()
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
  tl=tls_cfg(); rep["fw_a"]=ufw_open(set(pc.get("db",[]))|set(pc.get("tdb",[]))|set(game_ports())|sshd_ports()|((set(tl["ports"])|set(tl["tports"])) if tl["on"] else set()))
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
        svs=["sshplus-dropbear","sshplus-dropbear-t","badvpn","badvpn-t"]+(["sshplus-dropbear-g"] if game_ports() else [])
        if tconf().get("TUN_HOST"): svs.append("sshplus-tunnel")
        if tls_cfg()["on"]: svs+=list(TLS_SVC)
        for srv in svs:
          if cmd(["systemctl","is-active",srv])[0]!=0:
            cmd(["systemctl","reset-failed",srv]); cmd(["systemctl","restart",srv])
      n+=1
      if n==4:                                                             # once per panel start / update
        threading.Thread(target=ports_sync,daemon=True).start(); sshd_deny_sync()
      if n%20==0:                                                          # every minute: history + Telegram alerts
        prune_auth(); stunnel_log_trim()
        try: alerts_tick(hist_tick())
        except Exception: pass
      cert_reload_check()                                                  # a certificate renewed by certbot's hook is loaded without restarting the panel
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
          sp=sessions.get(u,[])
          if len(sp)>1 and len(limit_groups(sp,SIP))>ulim:
            # over the limit: the devices (client IPs) that were there first keep working, the newer ones are cut
            vic,dips=limit_victims(sp,ulim,SIP,{p:pid_start(p) for p in sp})
            for p in vic: kill_pid(p)
            for ip in (dips or ["?"]): DROP.setdefault(u,{})[ip]=time.time()
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
MAIL_RE=re.compile(r"^(?!-)[^@\s\"']{1,64}@[^@\s\"']{1,200}\.[^@\s\"']{2,24}\Z")
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
          "lineage":str(d.get("lineage","")),"perip":pi}

def tls_lineage(c):
  # certbot lineage (cert-name) of the certificate that is installed: recorded when it was issued, otherwise derived from the flag
  rec=str(c.get("lineage","")); dom=str(c.get("domain",""))
  return rec if rec and (rec==dom or rec==dom+"-staging") else (dom+("-staging" if c.get("staging") else "") if dom else "")

def tls_back_ports(c):
  return set(range(c["bd"],c["bd"]+TLS_BACKENDS))|set(range(c["bt"],c["bt"]+TLS_BACKENDS))

def tls_taken(c=None):
  # ports this feature owns (public TLS ports + the local Dropbear back ends): other settings must not use them
  c=c or tls_cfg(); return set(c["ports"])|set(c["tports"])|tls_back_ports(c)

def tls_reserved(c=None):
  c=c or tls_cfg(); pc=rjson(PORTS,{})
  panel=to_port(rjson(CFG,{}).get("port",2053)) or 2053; bvp=to_port(read_bv().get("UDP_PORT",7300)) or 7300
  return {22,80,panel,2053,bvp,bvp+1,to_port(pc.get("ssh")),to_port(pc.get("ssh2"))}|tls_back_ports(c)|{to_port(x) for x in pc.get("db",[])}|{to_port(x) for x in pc.get("tdb",[])}|set(game_ports())|sshd_ports()

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
  fp=os.path.join(SHELLS_DIR,"shells.game")                      # game instance: game accounts only
  with open(fp,"w") as f: f.write("\n".join(clean+[SHELLS[("direct","game")]])+"\n")
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
  d0=rjson(TLSC,{}); d0.update({"mode":"self","domain":"","lineage":""}); wjson(TLSC,d0); tls_reload()
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

def dns_ips6(host):
  try: return sorted({r[4][0].lower() for r in socket.getaddrinfo(host,None,socket.AF_INET6)})
  except Exception: return []

def local_ips6():
  rc,o,_=cmd(["ip","-6","-o","addr","show","scope","global"])
  return {m.lower() for m in re.findall(r"inet6 ([0-9a-fA-F:]+)/",o)} if rc==0 else set()

def aaaa_mismatch(v6,local):
  # Let's Encrypt prefers IPv6: an AAAA record that is not this server makes the HTTP challenge fail
  return bool(v6) and not (set(v6)&set(local))

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
  v6=dns_ips6(dom)
  if v6:
    tj_begin("Checking the IPv6 (AAAA) record of %s"%dom)
    if aaaa_mismatch(v6,local_ips6()):
      tj_end(False,"%s has an AAAA (IPv6) record %s that does not belong to this server. Let's Encrypt tries IPv6 first and would fail: remove the AAAA record (or point it to this server) and try again."%(dom,", ".join(v6))); return False
    tj_end(True,", ".join(v6))
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
  d0=rjson(TLSC,{}); d0.update({"mode":p["mode"],"domain":dom,"lineage":lin,"prov":p["prov"],"suffix":p["suffix"],"duckname":p["duckname"],"email":p["email"]})
  if p["duck"]: d0["duck"]=enc(p["duck"])
  wjson(TLSC,d0); tj_end(True,dom+" - the certificate renews automatically (certbot timer)")
  return True

def tls_renew_start():
  c=tls_cfg(); dom=c["domain"]
  lin=tls_lineage(c)
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
  c=tls_cfg(); lineage=str(lineage).rstrip("/")
  if not c["domain"] or os.path.basename(lineage)!=tls_lineage(c): return 0           # only the lineage that is installed: a leftover staging (or old) lineage must not replace the real certificate
  try: c1=open(lineage+"/fullchain.pem").read(); k1=open(lineage+"/privkey.pem").read()
  except Exception as e: print(e); return 1
  code,r=cert_save({"cert":c1,"key":k1})
  if code!=200: print(r.get("msg","")); return 1
  try: open(CERT_RELOAD,"w").close()                                          # the running panel reloads the certificate itself: no restart (it would end a running job and sign everybody out)
  except OSError: pass
  return 0

CERT_RELOAD="/etc/SSHPlus/cert.reload"
def cert_reload_check():
  if not os.path.exists(CERT_RELOAD): return
  try: os.remove(CERT_RELOAD)
  except OSError: pass
  if SRV[0] is not None:
    try: SRV[0].ctx=tls_ctx()
    except Exception: pass

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
     "en":"B" if d.get("en")=="B" else "A","tm":"tunnel" if d.get("tm")=="tunnel" else "direct","cx":d.get("cx") if d.get("cx") in ("normal","tls","game") else "both"}
  ls=[x for x in tpl_list() if x.get("name")!=name]+[t]; wjson(TPL,ls[:60]); return 200,{"ok":1}

def tpl_del(d):
  wjson(TPL,[x for x in tpl_list() if x.get("name")!=str(d.get("name",""))]); return 200,{"ok":1}

def rand_pw(n=8): return "".join(secrets.choice(PWCH) for _ in range(n))

def user_bulk(d):
  prefix=str(d.get("prefix","")).strip()
  try: count=int(d.get("count",0)); start=int(d.get("start",1) or 1)
  except Exception: return 400,{"ok":0,"msg":"Invalid count"}
  if not re.match(r"^[A-Za-z_][A-Za-z0-9_-]{0,20}\Z",prefix): return 400,{"ok":0,"msg":"Invalid prefix (letters/digits, max 21 chars)"}
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
  if not re.match(r"^[0-9a-f]{24}\Z",str(tok)): return None
  for u,m in rjson(META,{}).items():
    if m.get("tok")==tok and u in user_uid_map(): return u
  return None

def sub_data(u,hosthdr):
  x=next((y for y in get_users({}) if y["u"]==u),None)
  if not x: return None
  tc=tunnel_status(False); pc=rjson(PORTS,{}); out=x["tm"]=="tunnel"; inB=x.get("en")=="B" and tc["conf"]
  host=tc["host"] if inB else re.sub(r":\d+$","",hosthdr or "")
  dbl=list(pc.get("tdb" if out else "db",[])) if x.get("cx")!="game" else game_ports()
  if inB:
    mp={r["a"]:r["b"] for r in tc["rev_map"]}; s2=pc.get("ssh2") or 0
    ssh=[mp[s2]] if s2 in mp else []; dbl=[mp[p] for p in dbl if p in mp]
  else: ssh=sorted(sshd_ports())
  if x.get("cx")=="game": ssh=[]                                     # a game account is meant for the game port only
  x.update({"host":host,"ssh":ssh,"db":dbl,"in":"B" if inB else "A","out":"B" if out else "A","exit":(tc["exit"] or tc["host"]) if out else host})
  tl=tls_cfg(); x["tls"]=None
  if tl["on"] and x.get("cx","both") not in ("normal","game"):                    # SSH over TLS: the host is the domain if there is one (the exit server's address when entering via server 2)
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
import ipaddress
def req_len(raw,path):
  # Content-Length of a request body: (bytes, 0) or (0, http status). Negative / non-numeric / oversize bodies are refused before reading
  try: n=int(str(raw if raw is not None else "0").strip())
  except ValueError: return 0,400
  if n<0: return 0,400
  if n>(32<<20 if path=="/api/restore" else 1<<20): return 0,413
  return n,0

def ip_allowed(ip,allow):
  # panel IP allowlist: empty list = everybody
  if not allow: return True
  try:
    a=ipaddress.ip_address(str(ip).split("%")[0])
    if a.version==6 and a.ipv4_mapped: a=a.ipv4_mapped
  except ValueError: return False
  for n in allow:
    try:
      if a in ipaddress.ip_network(str(n),strict=False): return True
    except ValueError: continue
  return False

def allow_parse(items):
  out=[]
  for x in items[:200]:
    x=str(x).strip()
    if not x: continue
    try: n=str(ipaddress.ip_network(x,strict=False))
    except ValueError: raise ValueError(x[:60])
    if n not in out: out.append(n)
  if len(out)>50: raise ValueError("max 50 entries")
  return out

def allow_save(d,me):
  raw=d.get("list",[])
  if isinstance(raw,str): raw=re.split(r"[\s,;]+",raw)
  if not isinstance(raw,list): return 400,{"ok":0,"msg":"Invalid list"}
  try: lst=allow_parse(raw)
  except ValueError as e: return 400,{"ok":0,"msg":"Invalid address: "+str(e)}
  if lst and not ip_allowed(me,lst): return 400,{"ok":0,"msg":"Your own address ("+me+") must be in the list, otherwise you would lock yourself out"}
  c=rjson(CFG,{"port":2053,"username":"admin","password":"admin"}); c["allow"]=lst; wjson(CFG,c)
  return 200,{"ok":1,"list":lst}

def prune_auth():
  now=time.time()
  for u in list(DROP):
    DROP[u]={ip:t for ip,t in DROP[u].items() if now-t<600}
    if not DROP[u]: DROP.pop(u,None)
  for t in [k for k,v in list(TOK.items()) if v<=now]: TOK.pop(t,None)
  for k in list(FAIL):
    FAIL[k]=[t for t in FAIL.get(k,[]) if now-t<300]
    if not FAIL[k]: FAIL.pop(k,None)

def cli_allow_off():
  c=rjson(CFG,{}); c["allow"]=[]; wjson(CFG,c); print("IP allowlist cleared: the panel accepts every address again."); return 0

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
        request.settimeout(30)                   # idle timeout per read: a stalled client can no longer hold a thread forever
      s.RequestHandlerClass(request,client_address,s)
    except Exception: pass
    finally:
      try: request.close()
      except Exception: pass

class H(BaseHTTPRequestHandler):
  timeout=30
  def log_message(s,*a): pass
  def blocked(s,p):
    if p.startswith("/s/"): return False                      # public subscription links stay reachable for users' apps
    return not ip_allowed(s.client_address[0],rjson(CFG,{}).get("allow") or [])
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
      if s.blocked(p): s.js({"err":3},403); return
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
      if p=="/api/allow": s.js({"list":rjson(CFG,{}).get("allow") or [],"me":s.client_address[0]}); return
      if p=="/api/game": s.js(game_state()); return
      if p=="/api/netmon": s.js(netmon_state()); return
      if p=="/api/netmon/sessions": s.js(net_sessions()); return
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
      p=urlparse(s.path).path
      if s.blocked(p): s.js({"err":3},403); return
      ln,le=req_len(s.headers.get("Content-Length"),p)
      if le: s.js({"err":le},le); return
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
      elif p=="/api/netmon/save": c,r=netmon_save(d); s.js(r,c)
      elif p=="/api/game": c,r=game_apply(bool(d.get("on"))); s.js(r,c)
      elif p=="/api/game/sshd": c,r=game_sshd_apply(d); s.js(r,c)
      elif p=="/api/bbr" and rjson(GAMEF,{}).get("on"): s.js({"ok":0,"msg":"Game Profile controls BBR and the queue discipline; turn it off first"},400)
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
      elif p=="/api/allow": c,r=allow_save(d,s.client_address[0]); s.js(r,c)
      elif p=="/api/admin":
        c=rjson(CFG,{"port":2053,"username":"admin","password":"admin"})
        au=str(d.get("u","")).strip() or str(c.get("username","admin")).strip()
        ap=str(d.get("p","")).strip() or str(c.get("password","admin")).strip()
        if must_change() and (len(ap)<8 or ap=="admin"): s.js({"ok":0,"msg":"New password must be at least 8 characters and not 'admin'"},400); return
        if len(au)>=2 and len(ap)>=2:
          c["username"]=au; c["password"]=ap; wjson(CFG,c)
          TOK.clear()                                                     # a changed password signs out every other session
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
  if len(sys.argv)>=2 and sys.argv[1]=="--allow-off": sys.exit(cli_allow_off())
  open(DB,"a").close()
  try: migrate_secrets()
  except Exception: pass
  threading.Thread(target=mon,daemon=True).start()
  threading.Thread(target=netmon_loop,daemon=True).start()
  threading.Thread(target=tg_poll,daemon=True).start()
  c=rjson(CFG,{})
  srv=Srv((str(c.get("bind","0.0.0.0")),int(c.get("port",2053))),H); SRV[0]=srv  # nosec B104 - the panel is meant to be reachable
  try:
    if ensure_cert(): srv.ctx=tls_ctx()
  except Exception: srv.ctx=None                 # no openssl / bad certificate: fall back to plain HTTP
  srv.serve_forever()
