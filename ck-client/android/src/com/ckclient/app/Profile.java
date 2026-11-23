package com.ckclient.app;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** One saved server connection (same fields as the Windows/iOS apps). The password is kept separately, encrypted. */
final class Profile {
    String name = "";
    String host = "";
    int port = 22;
    String user = "";
    String password = "";       // only in memory / when sent to the engine; stored encrypted by Store
    String transport = "direct"; // "direct" | "tls"
    String sni = "";
    boolean udpgwEnabled = true;
    String udpgwAddr = "127.0.0.1:7300";
    String dns = "1.1.1.1,8.8.8.8";
    String pingTarget = "1.1.1.1:443";
    String hostKey = "";

    boolean isTls() { return "tls".equals(transport); }

    JSONObject toJson(boolean withPassword) throws JSONException {
        JSONObject o = new JSONObject();
        o.put("name", name);
        o.put("host", host);
        o.put("port", port);
        o.put("user", user);
        if (withPassword) o.put("password", password);
        o.put("transport", transport);
        o.put("sni", sni);
        o.put("udpgwEnabled", udpgwEnabled);
        o.put("udpgwAddr", udpgwAddr);
        JSONArray d = new JSONArray();
        for (String s : dns.split(",")) {
            s = s.trim();
            if (s.length() > 0) d.put(s);
        }
        o.put("dns", d);
        o.put("pingTarget", pingTarget);
        o.put("hostKey", hostKey);
        return o;
    }

    /** Reads either the engine's import JSON (dns is an array) or our own stored form. */
    static Profile fromJson(JSONObject o) {
        Profile p = new Profile();
        p.name = o.optString("name", "");
        p.host = o.optString("host", "");
        p.port = o.optInt("port", 22);
        p.user = o.optString("user", "");
        p.password = o.optString("password", "");
        p.transport = o.optString("transport", "direct");
        p.sni = o.optString("sni", "");
        p.udpgwEnabled = o.optBoolean("udpgwEnabled", true);
        String a = o.optString("udpgwAddr", "");
        if (a.length() > 0) p.udpgwAddr = a;
        JSONArray d = o.optJSONArray("dns");
        if (d != null && d.length() > 0) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < d.length(); i++) {
                if (i > 0) sb.append(',');
                sb.append(d.optString(i));
            }
            p.dns = sb.toString();
        }
        String pt = o.optString("pingTarget", "");
        if (pt.length() > 0) p.pingTarget = pt;
        p.hostKey = o.optString("hostKey", "");
        return p;
    }
}
