package com.ckclient.app;

import android.content.Context;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;

/** Runs the Go engine (libckengine.so) as a child process and relays its JSON-line events. */
final class EngineProcess {
    interface Listener {
        void onEvent(JSONObject event);
        void onExit(int code);
    }

    private final Process proc;

    private EngineProcess(Process p) { proc = p; }

    static EngineProcess start(Context c, String profileJson, int port, final Listener l) throws IOException {
        // The engine reads the profile (it contains the password) and deletes the file right away.
        File f = new File(c.getFilesDir(), "session.json");
        FileOutputStream fo = new FileOutputStream(f);
        fo.write(profileJson.getBytes("UTF-8"));
        fo.close();
        f.setReadable(false, false);
        f.setReadable(true, true);

        ProcessBuilder pb = new ProcessBuilder(Importer.engine(c).getAbsolutePath(), "run", f.getAbsolutePath(), "127.0.0.1:" + port);
        pb.redirectErrorStream(true); // Go panics go to stderr: show them in the log
        final Process p = pb.start();
        final EngineProcess ep = new EngineProcess(p);
        Thread t = new Thread(new Runnable() {
            public void run() {
                try {
                    BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
                    String line;
                    while ((line = r.readLine()) != null) {
                        JSONObject o;
                        try {
                            o = new JSONObject(line);
                        } catch (Exception notJson) {
                            o = new JSONObject();
                            o.put("type", "log");
                            o.put("line", line);
                        }
                        l.onEvent(o);
                    }
                } catch (Exception ignored) {
                }
                int code = -1;
                try { code = p.waitFor(); } catch (InterruptedException ignored) { }
                l.onExit(code);
            }
        }, "engine-events");
        t.setDaemon(true);
        t.start();
        return ep;
    }

    void stop() { proc.destroy(); }
}
