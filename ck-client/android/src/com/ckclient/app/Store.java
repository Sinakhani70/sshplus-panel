package com.ckclient.app;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Profiles in SharedPreferences. Passwords are encrypted with an Android Keystore key (API 23+). */
final class Store {
    private static final String PREFS = "ckclient";
    private static final String KEY_PROFILES = "profiles";
    private static final String KEY_ACTIVE = "active";
    private static final String ALIAS = "ckclient-secrets";

    private final SharedPreferences sp;

    Store(Context c) { sp = c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE); }

    synchronized List<Profile> list() {
        List<Profile> out = new ArrayList<Profile>();
        try {
            JSONArray a = new JSONArray(sp.getString(KEY_PROFILES, "[]"));
            for (int i = 0; i < a.length(); i++) {
                JSONObject o = a.getJSONObject(i);
                Profile p = Profile.fromJson(o);
                p.password = decrypt(o.optString("pw", ""));
                out.add(p);
            }
        } catch (Exception ignored) { }
        return out;
    }

    synchronized Profile get(String name) {
        for (Profile p : list()) if (p.name.equals(name)) return p;
        return null;
    }

    /** Create or replace. An empty password keeps the stored one. */
    synchronized void put(Profile p) {
        List<Profile> all = list();
        boolean found = false;
        for (int i = 0; i < all.size(); i++) {
            Profile old = all.get(i);
            if (old.name.equals(p.name)) {
                if (p.password.length() == 0) p.password = old.password;
                if (old.host.equals(p.host) && old.port == p.port) p.hostKey = old.hostKey; // keep the pin unless the server changed
                all.set(i, p);
                found = true;
            }
        }
        if (!found) all.add(p);
        save(all);
    }

    synchronized void delete(String name) {
        List<Profile> all = list();
        for (int i = all.size() - 1; i >= 0; i--) if (all.get(i).name.equals(name)) all.remove(i);
        save(all);
    }

    synchronized void setHostKey(String name, String fp) {
        List<Profile> all = list();
        for (Profile p : all) if (p.name.equals(name)) p.hostKey = fp;
        save(all);
    }

    String active() { return sp.getString(KEY_ACTIVE, ""); }
    void setActive(String name) { sp.edit().putString(KEY_ACTIVE, name).apply(); }

    private void save(List<Profile> all) {
        try {
            JSONArray a = new JSONArray();
            for (Profile p : all) {
                JSONObject o = p.toJson(false);
                o.put("pw", encrypt(p.password));
                a.put(o);
            }
            sp.edit().putString(KEY_PROFILES, a.toString()).apply();
        } catch (Exception ignored) { }
    }

    // ---- encryption (AndroidKeyStore AES-GCM); below API 23 the value is only obfuscated ----

    private static SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (!ks.containsAlias(ALIAS)) {
            KeyGenerator g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            g.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build());
            return g.generateKey();
        }
        return (SecretKey) ks.getKey(ALIAS, null);
    }

    private static String encrypt(String plain) {
        if (plain == null || plain.length() == 0) return "";
        try {
            if (Build.VERSION.SDK_INT < 23) return "p:" + Base64.encodeToString(plain.getBytes("UTF-8"), Base64.NO_WRAP);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key());
            byte[] iv = c.getIV();
            byte[] enc = c.doFinal(plain.getBytes("UTF-8"));
            return "e:" + Base64.encodeToString(iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(enc, Base64.NO_WRAP);
        } catch (Exception e) {
            return "";
        }
    }

    private static String decrypt(String s) {
        if (s == null || s.length() == 0) return "";
        try {
            if (s.startsWith("p:")) return new String(Base64.decode(s.substring(2), Base64.NO_WRAP), "UTF-8");
            if (s.startsWith("e:") && Build.VERSION.SDK_INT >= 23) {
                String[] parts = s.split(":");
                byte[] iv = Base64.decode(parts[1], Base64.NO_WRAP);
                byte[] enc = Base64.decode(parts[2], Base64.NO_WRAP);
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, iv));
                return new String(c.doFinal(enc), "UTF-8");
            }
        } catch (Exception ignored) { }
        return "";
    }
}
