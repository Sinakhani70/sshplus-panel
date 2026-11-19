#!/bin/bash
# usage: start-dropbear.sh direct|tunnel|tlsd|tlst
#   direct / tunnel : public ports from ports.json ("db" / "tdb")
#   tlsd   / tlst   : TLS back ends, bound to 127.0.0.1 only (stunnel is the public TLS front, tls.json "bd" / "bt")
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
    key,dflt="bd" if mode=="tlsd" else "bt",40022 if mode=="tlsd" else 40023
    try: v=int(json.load(open("/etc/SSHPlus/tls.json")).get(key,dflt))
    except Exception: v=dflt
    print("-p 127.0.0.1:%d"%(v if 0<v<65536 else dflt))
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
exec /usr/sbin/dropbear -F -E -w -K 30 \
  -r /etc/dropbear/dropbear_rsa_host_key \
  -r /etc/dropbear/dropbear_ecdsa_host_key \
  -r /etc/dropbear/dropbear_ed25519_host_key $P
