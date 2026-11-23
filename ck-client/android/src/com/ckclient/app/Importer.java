package com.ckclient.app;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Turns text copied from the CK.VPN panel into profiles. Parsing is done by the
 * engine binary ("ckengine parse") so the Windows, iOS and Android apps accept
 * exactly the same formats. A subscription URL (https://HOST:2053/s/TOKEN) is
 * downloaded here first. Call from a background thread.
 */
final class Importer {
    private Importer() { }

    static File engine(Context c) { return new File(c.getApplicationInfo().nativeLibraryDir, "libckengine.so"); }

    static List<Profile> importText(Context c, String text) throws Exception {
        text = text == null ? "" : text.trim();
        if (text.length() == 0) throw new Exception("empty");
        if (text.startsWith("ckclient://")) { // ckclient://import?link=<url-encoded>
            android.net.Uri u = android.net.Uri.parse(text);
            String link = u.getQueryParameter("link");
            if (link != null) text = link.trim();
        }
        if (text.indexOf('\n') < 0 && (text.startsWith("http://") || text.startsWith("https://"))) {
            text = fetch(text);
        }
        Process p = new ProcessBuilder(engine(c).getAbsolutePath(), "parse").redirectErrorStream(false).start();
        OutputStream os = p.getOutputStream();
        os.write(text.getBytes("UTF-8"));
        os.close();
        String out = readAll(p.getInputStream());
        String err = readAll(p.getErrorStream());
        int code = p.waitFor();
        if (code != 0) throw new Exception(err.trim().length() > 0 ? err.trim() : "no profile found");
        JSONArray a = new JSONArray(out);
        List<Profile> res = new ArrayList<Profile>();
        for (int i = 0; i < a.length(); i++) res.add(Profile.fromJson((JSONObject) a.get(i)));
        return res;
    }

    private static String readAll(InputStream in) throws Exception {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
        return bo.toString("UTF-8");
    }

    /** Subscription link: verified TLS first; the panel's certificate is often self-signed, so then without verification. */
    private static String fetch(String link) throws Exception {
        String sep = link.indexOf('?') >= 0 ? "&" : "?";
        String url = link + sep + "fmt=plain";
        try {
            return get(url, false);
        } catch (javax.net.ssl.SSLException e) {
            if (!url.startsWith("https://")) throw e;
            return get(url, true);
        }
    }

    private static String get(String url, boolean insecure) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(15000);
        c.setReadTimeout(15000);
        if (insecure && c instanceof HttpsURLConnection) {
            TrustManager[] all = new TrustManager[]{new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] chain, String authType) { }
                public void checkServerTrusted(X509Certificate[] chain, String authType) { }
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }};
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, all, new SecureRandom());
            HttpsURLConnection h = (HttpsURLConnection) c;
            h.setSSLSocketFactory(ctx.getSocketFactory());
            h.setHostnameVerifier(new javax.net.ssl.HostnameVerifier() {
                public boolean verify(String hostname, javax.net.ssl.SSLSession session) { return true; }
            });
        }
        int code = c.getResponseCode();
        if (code != 200) throw new Exception("The panel answered HTTP " + code + " (wrong or expired link?)");
        return readAll(c.getInputStream());
    }
}
