package com.ckclient.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;

import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * The VPN. This service owns the TUN interface and moves IP packets between it
 * and the Go engine (a child process) over a loopback socket; the engine does
 * SSH + UDPGW + the TCP/IP stack. The app's own traffic (including the engine's
 * SSH connection) is excluded from the VPN so nothing loops.
 */
public class CkVpnService extends VpnService {
    static final String ACTION_START = "com.ckclient.app.START";
    static final String ACTION_STOP = "com.ckclient.app.STOP";
    static final String EXTRA_PROFILE = "profile";

    static final int ST_IDLE = 0, ST_CONNECTING = 1, ST_CONNECTED = 2, ST_ERROR = 3;

    // ---- state shared with the UI (read every second) ----
    static volatile int state = ST_IDLE;
    static volatile String error = "";
    static volatile String activeName = "";
    static volatile long up, down, since;
    static volatile int pingMs = -1;
    static volatile boolean link;
    private static final StringBuilder LOG = new StringBuilder();

    static void log(String line) {
        synchronized (LOG) {
            LOG.append(new java.text.SimpleDateFormat("HH:mm:ss ", java.util.Locale.US).format(new java.util.Date())).append(line).append('\n');
            if (LOG.length() > 24000) LOG.delete(0, LOG.length() - 20000);
        }
    }

    static String logText() { synchronized (LOG) { return LOG.toString(); } }

    static void start(Context c, String profileName) {
        Intent i = new Intent(c, CkVpnService.class).setAction(ACTION_START).putExtra(EXTRA_PROFILE, profileName);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
    }

    static void stop(Context c) {
        c.startService(new Intent(c, CkVpnService.class).setAction(ACTION_STOP));
    }

    // ---- instance ----
    private final Object lock = new Object();
    private ParcelFileDescriptor tun;
    private Socket sock;
    private ServerSocket server;
    private EngineProcess engine;
    private boolean running;
    private String profileName = "";

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            teardown(ST_IDLE, "");
            return START_NOT_STICKY;
        }
        if (ACTION_START.equals(action)) {
            synchronized (lock) {
                if (running) return START_NOT_STICKY;
                running = true;
            }
            profileName = intent.getStringExtra(EXTRA_PROFILE);
            if (profileName == null) profileName = "";
            showNotification();
            new Thread(new Runnable() {
                public void run() { connect(); }
            }, "vpn-connect").start();
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onRevoke() { teardown(ST_IDLE, ""); }

    @Override
    public void onDestroy() {
        teardown(state == ST_ERROR ? ST_ERROR : ST_IDLE, error);
        super.onDestroy();
    }

    private void fail(String msg) {
        log("ERROR: " + msg);
        teardown(ST_ERROR, msg);
    }

    private void connect() {
        state = ST_CONNECTING;
        error = "";
        up = down = 0;
        pingMs = -1;
        link = false;
        activeName = profileName;
        log("connecting profile " + profileName);
        try {
            Profile p = new Store(this).get(profileName);
            if (p == null) { fail(getString(R.string.err_no_profile)); return; }

            // Resolve the server name now: once the VPN is up the engine has no DNS of its own.
            JSONObject pj = p.toJson(true);
            if (!p.host.matches("[0-9.:]+")) {
                String ip = null;
                try {
                    InetAddress[] all = InetAddress.getAllByName(p.host);
                    for (InetAddress a : all) if (a instanceof Inet4Address) { ip = a.getHostAddress(); break; }
                    if (ip == null && all.length > 0) ip = all[0].getHostAddress();
                } catch (Exception e) { ip = null; }
                if (ip == null) { fail(getString(R.string.err_resolve)); return; }
                pj.put("dialAddr", ip);
                log("server " + p.host + " -> " + ip);
            }

            server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"));
            final CountDownLatch ready = new CountDownLatch(1);
            final String[] engineError = new String[1];
            final Store store = new Store(this);
            final String name = profileName;
            engine = EngineProcess.start(this, pj.toString(), server.getLocalPort(), new EngineProcess.Listener() {
                public void onEvent(JSONObject e) {
                    String type = e.optString("type");
                    if ("ready".equals(type)) {
                        ready.countDown();
                    } else if ("error".equals(type)) {
                        engineError[0] = e.optString("msg");
                        ready.countDown();
                    } else if ("log".equals(type)) {
                        log(e.optString("line"));
                    } else if ("hostkey".equals(type)) {
                        store.setHostKey(name, e.optString("fp"));
                    } else if ("link".equals(type)) {
                        link = e.optBoolean("up");
                    } else if ("status".equals(type)) {
                        up = e.optLong("up");
                        down = e.optLong("down");
                        pingMs = e.optInt("pingMs", -1);
                        link = e.optBoolean("link");
                    }
                }

                public void onExit(int code) {
                    if (state == ST_CONNECTED) fail(getString(R.string.err_lost));
                    else if (state == ST_CONNECTING && engineError[0] == null) engineError[0] = getString(R.string.err_engine) + " (" + code + ")";
                    ready.countDown(); // after the error is recorded
                }
            });

            if (!ready.await(40, TimeUnit.SECONDS)) { fail(getString(R.string.err_timeout)); return; }
            if (!running) return; // the user pressed Disconnect meanwhile
            if (engineError[0] != null) { fail(engineError[0]); return; }

            // SSH is up: create the TUN interface. Some phones refuse the IPv6 address (or a /24):
            // try the full set first, then IPv4 only, then a /32.
            int[][] attempts = {{1, 24}, {0, 24}, {0, 32}};
            tun = null;
            for (int[] at : attempts) {
                try {
                    tun = configure(p, at[0] == 1, at[1]).establish();
                    if (tun != null) break;
                    fail(getString(R.string.err_perm));
                    return;
                } catch (Exception e) {
                    log("VPN interface (" + (at[0] == 1 ? "IPv4+IPv6" : "IPv4 only") + ", /" + at[1] + ") failed: " + e.getMessage());
                }
            }
            if (tun == null) { fail(getString(R.string.err_tun)); return; }
            if (!running) return;

            server.setSoTimeout(15000);
            sock = server.accept();
            if (!running) { sock.close(); return; }
            sock.setTcpNoDelay(true);
            since = System.currentTimeMillis();
            state = ST_CONNECTED;
            log("tunnel up");
            pump();
        } catch (Exception e) {
            if (running) fail(String.valueOf(e.getMessage()));
        }
    }

    private Builder configure(Profile p, boolean ipv6, int prefix4) {
        Builder b = new Builder();
        b.setSession("CK Client");
        b.setMtu(1200);
        b.addAddress("10.77.0.2", prefix4);
        b.addRoute("0.0.0.0", 0);
        if (ipv6) { // IPv6 into the tunnel too, so it cannot leak around it
            b.addAddress("fd77:77::2", 128);
            b.addRoute("::", 0);
        }
        boolean anyDns = false;
        for (String d : p.dns.split(",")) {
            d = d.trim();
            if (d.length() > 0 && d.matches("[0-9a-fA-F.:]+")) {
                try { b.addDnsServer(d); anyDns = true; } catch (Exception ignored) { }
            }
        }
        if (!anyDns) { b.addDnsServer("1.1.1.1"); b.addDnsServer("8.8.8.8"); }
        try { b.addDisallowedApplication(getPackageName()); } catch (Exception ignored) { }
        b.setBlocking(true);
        b.setConfigureIntent(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), pendingFlags()));
        return b;
    }

    private static int pendingFlags() {
        return Build.VERSION.SDK_INT >= 23 ? (PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE) : PendingIntent.FLAG_UPDATE_CURRENT;
    }

    /** Two threads: TUN -> engine and engine -> TUN. Returns when either side ends. */
    private void pump() {
        final FileInputStream tunIn = new FileInputStream(tun.getFileDescriptor());
        final FileOutputStream tunOut = new FileOutputStream(tun.getFileDescriptor());
        final Socket s = sock;
        Thread toEngine = new Thread(new Runnable() {
            public void run() {
                try {
                    OutputStream so = s.getOutputStream();
                    byte[] buf = new byte[32767];
                    int n;
                    while ((n = tunIn.read(buf)) >= 0) {
                        if (n == 0) continue;
                        byte[] frame = new byte[2 + n];
                        frame[0] = (byte) (n >> 8);
                        frame[1] = (byte) n;
                        System.arraycopy(buf, 0, frame, 2, n);
                        so.write(frame);
                    }
                } catch (IOException ignored) {
                }
                if (running && state == ST_CONNECTED) fail(getString(R.string.err_lost));
            }
        }, "tun-to-engine");
        toEngine.setDaemon(true);
        toEngine.start();

        try {
            DataInputStream di = new DataInputStream(s.getInputStream());
            while (true) {
                int len = di.readUnsignedShort();
                byte[] pkt = new byte[len];
                di.readFully(pkt);
                tunOut.write(pkt);
            }
        } catch (IOException ignored) {
        }
        if (running && state == ST_CONNECTED) fail(getString(R.string.err_lost));
    }

    private void teardown(int newState, String msg) {
        synchronized (lock) {
            if (!running && newState == ST_IDLE && tun == null) { state = newState; return; }
            running = false;
        }
        try { if (engine != null) engine.stop(); } catch (Exception ignored) { }
        try { if (sock != null) sock.close(); } catch (Exception ignored) { }
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        try { if (tun != null) tun.close(); } catch (Exception ignored) { }
        engine = null; sock = null; server = null; tun = null;
        state = newState;
        error = msg == null ? "" : msg;
        link = false;
        pingMs = -1;
        if (newState == ST_IDLE) log("disconnected");
        try { stopForeground(true); } catch (Exception ignored) { }
        stopSelf();
    }

    private void showNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder nb;
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel("vpn", getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW));
            nb = new Notification.Builder(this, "vpn");
        } else {
            nb = new Notification.Builder(this);
        }
        nb.setContentTitle(getString(R.string.notif_title))
          .setContentText(getString(R.string.notif_text))
          .setSmallIcon(R.drawable.ic_stat)
          .setOngoing(true)
          .setContentIntent(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), pendingFlags()));
        startForeground(1, nb.build());
    }
}
