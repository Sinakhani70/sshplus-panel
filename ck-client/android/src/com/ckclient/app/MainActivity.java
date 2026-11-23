package com.ckclient.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;
import android.os.Handler;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;
import android.widget.AdapterView;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final int REQ_VPN = 1;

    private Store store;
    private final Handler ui = new Handler();
    private List<Profile> profiles = new ArrayList<Profile>();

    private View dot;
    private TextView stText, stSub, stErr, statUp, statDown, statPing, connectBtn, udpgwInfo, logView, noProfile;
    private Spinner spinner;
    private String pendingStart;

    private final Runnable tick = new Runnable() {
        public void run() {
            render();
            ui.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        store = new Store(this);
        getWindow().setStatusBarColor(Ui.BG);
        getWindow().setNavigationBarColor(Ui.BG);
        buildUi();
        reloadProfiles();
        handleIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleIntent(intent);
    }

    @Override
    protected void onResume() {
        super.onResume();
        reloadProfiles();
        ui.post(tick);
    }

    @Override
    protected void onPause() {
        super.onPause();
        ui.removeCallbacks(tick);
    }

    // ------------------------------------------------------------------ UI

    private void buildUi() {
        int pad = Ui.dp(this, 16);
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(Ui.BG);
        sv.setFillViewport(true);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        sv.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // header
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        ImageView logo = new ImageView(this);
        logo.setImageResource(R.drawable.logo);
        head.addView(logo, new LinearLayout.LayoutParams(Ui.dp(this, 48), Ui.dp(this, 48)));
        LinearLayout titles = new LinearLayout(this);
        titles.setOrientation(LinearLayout.VERTICAL);
        titles.setPadding(Ui.dp(this, 12), 0, Ui.dp(this, 12), 0);
        titles.addView(Ui.text(this, getString(R.string.app_name), 22, Ui.TEXT, true));
        titles.addView(Ui.text(this, getString(R.string.subtitle), 12, Ui.MUTED, false));
        head.addView(titles);
        root.addView(head, matchWrap(0, 0, 0, 14));

        // status card
        LinearLayout card = card();
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        dot = new View(this);
        dot.setBackground(Ui.oval(Ui.MUTED));
        row.addView(dot, new LinearLayout.LayoutParams(Ui.dp(this, 12), Ui.dp(this, 12)));
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(Ui.dp(this, 10), 0, Ui.dp(this, 10), 0);
        stText = Ui.text(this, "", 17, Ui.TEXT, true);
        stSub = Ui.text(this, "", 12, Ui.MUTED, false);
        col.addView(stText);
        col.addView(stSub);
        row.addView(col);
        card.addView(row);
        stErr = Ui.text(this, "", 12, Ui.ERROR, false);
        stErr.setPadding(0, Ui.dp(this, 6), 0, 0);
        card.addView(stErr);

        LinearLayout stats = new LinearLayout(this);
        stats.setOrientation(LinearLayout.HORIZONTAL);
        stats.setPadding(0, Ui.dp(this, 14), 0, 0);
        statUp = statBox(stats, getString(R.string.upload));
        statDown = statBox(stats, getString(R.string.download));
        statPing = statBox(stats, getString(R.string.ping));
        card.addView(stats);
        root.addView(card, matchWrap(0, 0, 0, 12));

        // connect
        connectBtn = Ui.button(this, "", Ui.PRIMARY, Ui.ON_PRIMARY, 17);
        connectBtn.setPadding(0, Ui.dp(this, 16), 0, Ui.dp(this, 16));
        connectBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { toggle(); }
        });
        root.addView(connectBtn, matchWrap(0, 0, 0, 16));

        // profile picker
        root.addView(Ui.text(this, getString(R.string.profile), 11, Ui.MUTED, false), matchWrap(0, 0, 0, 6));
        spinner = new Spinner(this);
        spinner.setBackground(Ui.rounded(this, Ui.INPUT, Ui.BORDER, 12));
        spinner.setPadding(Ui.dp(this, 8), Ui.dp(this, 6), Ui.dp(this, 8), Ui.dp(this, 6));
        spinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                if (position >= 0 && position < profiles.size()) {
                    store.setActive(profiles.get(position).name);
                    render();
                }
            }
            public void onNothingSelected(AdapterView<?> parent) { }
        });
        root.addView(spinner, matchWrap(0, 0, 0, 8));
        noProfile = Ui.text(this, getString(R.string.no_profile), 13, Ui.MUTED, false);
        root.addView(noProfile, matchWrap(0, 0, 0, 8));

        LinearLayout btns = new LinearLayout(this);
        btns.setOrientation(LinearLayout.HORIZONTAL);
        btns.addView(smallButton(getString(R.string.btn_import), Ui.PRIMARY, Ui.ON_PRIMARY, new View.OnClickListener() {
            public void onClick(View v) { importFromClipboard(); }
        }), weight());
        btns.addView(smallButton(getString(R.string.btn_new), Ui.CARD, Ui.TEXT, new View.OnClickListener() {
            public void onClick(View v) { editProfile(null); }
        }), weight());
        btns.addView(smallButton(getString(R.string.btn_edit), Ui.CARD, Ui.TEXT, new View.OnClickListener() {
            public void onClick(View v) { Profile p = selected(); if (p != null) editProfile(p); }
        }), weight());
        btns.addView(smallButton(getString(R.string.btn_delete), Ui.CARD, Ui.ERROR, new View.OnClickListener() {
            public void onClick(View v) { deleteSelected(); }
        }), weight());
        root.addView(btns, matchWrap(0, 0, 0, 12));

        LinearLayout udp = card();
        udpgwInfo = Ui.text(this, "", 13, Ui.TEXT, false);
        udp.addView(udpgwInfo);
        root.addView(udp, matchWrap(0, 0, 0, 12));

        // log
        LinearLayout logHead = new LinearLayout(this);
        logHead.setOrientation(LinearLayout.HORIZONTAL);
        logHead.setGravity(Gravity.CENTER_VERTICAL);
        TextView lt = Ui.text(this, getString(R.string.log), 11, Ui.MUTED, false);
        logHead.addView(lt, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView copy = Ui.text(this, getString(R.string.copy_log), 12, Ui.PRIMARY, true);
        copy.setPadding(Ui.dp(this, 8), Ui.dp(this, 4), Ui.dp(this, 8), Ui.dp(this, 4));
        copy.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                cm.setPrimaryClip(ClipData.newPlainText("CK Client log", CkVpnService.logText()));
                Toast.makeText(MainActivity.this, R.string.log_copied, Toast.LENGTH_SHORT).show();
            }
        });
        logHead.addView(copy);
        root.addView(logHead, matchWrap(0, 0, 0, 6));
        logView = Ui.text(this, "", 11, Ui.MUTED, false);
        logView.setTypeface(android.graphics.Typeface.MONOSPACE);
        logView.setBackground(Ui.rounded(this, Ui.INPUT, Ui.BORDER, 12));
        logView.setPadding(Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10));
        logView.setTextIsSelectable(true);
        logView.setMinHeight(Ui.dp(this, 120));
        root.addView(logView, matchWrap(0, 0, 0, 10));

        root.addView(Ui.text(this, getString(R.string.about_note), 11, Ui.MUTED, false), matchWrap(0, 0, 0, 0));

        setContentView(sv);
    }

    private LinearLayout card() {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setBackground(Ui.rounded(this, Ui.CARD, Ui.BORDER, 18));
        int p = Ui.dp(this, 16);
        c.setPadding(p, p, p, p);
        return c;
    }

    private TextView statBox(LinearLayout parent, String title) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.addView(Ui.text(this, title, 10, Ui.MUTED, false));
        TextView v = Ui.text(this, "-", 15, Ui.TEXT, true);
        c.addView(v);
        parent.addView(c, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return v;
    }

    private TextView smallButton(String t, int bg, int fg, View.OnClickListener l) {
        TextView b = Ui.button(this, t, bg, fg, 13);
        b.setPadding(Ui.dp(this, 4), Ui.dp(this, 10), Ui.dp(this, 4), Ui.dp(this, 10));
        b.setOnClickListener(l);
        return b;
    }

    private LinearLayout.LayoutParams weight() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.setMargins(Ui.dp(this, 3), 0, Ui.dp(this, 3), 0);
        return lp;
    }

    private LinearLayout.LayoutParams matchWrap(int l, int t, int r, int bDp) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(Ui.dp(this, l), Ui.dp(this, t), Ui.dp(this, r), Ui.dp(this, bDp));
        return lp;
    }

    // ------------------------------------------------------------------ state

    private void render() {
        int st = CkVpnService.state;
        boolean active = st == CkVpnService.ST_CONNECTING || st == CkVpnService.ST_CONNECTED;
        int color = Ui.MUTED;
        String text = getString(R.string.st_disconnected);
        if (st == CkVpnService.ST_CONNECTED) {
            color = CkVpnService.link ? Ui.OK : Ui.WARN;
            text = getString(CkVpnService.link ? R.string.st_connected : R.string.st_reconnecting);
        } else if (st == CkVpnService.ST_CONNECTING) {
            color = Ui.WARN;
            text = getString(R.string.st_connecting);
        } else if (st == CkVpnService.ST_ERROR) {
            color = Ui.ERROR;
            text = getString(R.string.st_error);
        }
        dot.setBackground(Ui.oval(color));
        stText.setText(text);
        String sub = "";
        if (active) {
            sub = CkVpnService.activeName;
            if (st == CkVpnService.ST_CONNECTED && CkVpnService.since > 0) {
                long s = (System.currentTimeMillis() - CkVpnService.since) / 1000;
                sub += String.format(Locale.US, " · %02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60);
            }
        }
        stSub.setText(sub);
        stErr.setText(st == CkVpnService.ST_ERROR ? CkVpnService.error : "");

        boolean conn = st == CkVpnService.ST_CONNECTED;
        statUp.setText(conn ? bytes(CkVpnService.up) : "-");
        statDown.setText(conn ? bytes(CkVpnService.down) : "-");
        int ms = CkVpnService.pingMs;
        if (!conn) {
            statPing.setText("-");
            statPing.setTextColor(Ui.TEXT);
        } else if (ms < 0 || !CkVpnService.link) {
            statPing.setText("...");
            statPing.setTextColor(Ui.MUTED);
        } else {
            statPing.setText(ms + " ms");
            statPing.setTextColor(ms < 120 ? Ui.OK : (ms < 300 ? Ui.WARN : Ui.ERROR));
        }

        connectBtn.setText(active ? R.string.disconnect : R.string.connect);
        connectBtn.setBackground(Ui.rounded(this, active ? Ui.ERROR : Ui.PRIMARY, 0, 14));
        connectBtn.setTextColor(active ? Color_WHITE : Ui.ON_PRIMARY);
        spinner.setEnabled(!active);

        Profile p = selected();
        if (p != null) {
            udpgwInfo.setText(getString(R.string.udpgw) + "  " + p.udpgwAddr + "   " + getString(p.udpgwEnabled ? R.string.on : R.string.off));
        } else {
            udpgwInfo.setText(getString(R.string.udpgw) + "  127.0.0.1:7300");
        }
        String log = CkVpnService.logText();
        if (!log.equals(logView.getText().toString())) logView.setText(log);
    }

    private static final int Color_WHITE = 0xFFFFFFFF;

    private static String bytes(long n) {
        String[] u = {"B", "KB", "MB", "GB", "TB"};
        double v = n;
        int i = 0;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return i == 0 ? n + " B" : String.format(Locale.US, "%.1f %s", v, u[i]);
    }

    // ------------------------------------------------------------------ profiles

    private Profile selected() {
        int i = spinner == null ? -1 : spinner.getSelectedItemPosition();
        return (i >= 0 && i < profiles.size()) ? profiles.get(i) : null;
    }

    private void reloadProfiles() {
        profiles = store.list();
        List<String> names = new ArrayList<String>();
        int sel = 0;
        String active = store.active();
        for (int i = 0; i < profiles.size(); i++) {
            names.add(profiles.get(i).name);
            if (profiles.get(i).name.equals(active)) sel = i;
        }
        ArrayAdapter<String> ad = new ArrayAdapter<String>(this, android.R.layout.simple_spinner_item, names) {
            @Override
            public View getView(int position, View convertView, ViewGroup parent) {
                TextView v = (TextView) super.getView(position, convertView, parent);
                v.setTextColor(Ui.TEXT);
                v.setTextSize(15);
                return v;
            }

            @Override
            public View getDropDownView(int position, View convertView, ViewGroup parent) {
                TextView v = (TextView) super.getDropDownView(position, convertView, parent);
                v.setTextColor(Ui.TEXT);
                v.setBackgroundColor(Ui.CARD);
                v.setPadding(Ui.dp(MainActivity.this, 14), Ui.dp(MainActivity.this, 12), Ui.dp(MainActivity.this, 14), Ui.dp(MainActivity.this, 12));
                return v;
            }
        };
        ad.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        spinner.setAdapter(ad);
        if (!names.isEmpty()) spinner.setSelection(sel);
        spinner.setVisibility(names.isEmpty() ? View.GONE : View.VISIBLE);
        noProfile.setVisibility(names.isEmpty() ? View.VISIBLE : View.GONE);
    }

    private void deleteSelected() {
        final Profile p = selected();
        if (p == null) return;
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setMessage(getString(R.string.delete_q, p.name))
                .setPositiveButton(R.string.yes, new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) { store.delete(p.name); reloadProfiles(); render(); }
                })
                .setNegativeButton(R.string.no, null)
                .show();
    }

    private void editProfile(final Profile original) {
        final Profile p = original == null ? new Profile() : original;
        final boolean isNew = original == null;
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = Ui.dp(this, 18);
        form.setPadding(pad, Ui.dp(this, 8), pad, 0);

        final EditText name = field(form, getString(R.string.f_name), p.name, false);
        name.setEnabled(isNew);
        final EditText host = field(form, getString(R.string.f_host), p.host, false);
        final EditText port = field(form, getString(R.string.f_port), String.valueOf(p.port), false);
        port.setInputType(InputType.TYPE_CLASS_NUMBER);
        final EditText user = field(form, getString(R.string.f_user), p.user, false);
        boolean hasPw = !isNew && p.password.length() > 0;
        final EditText pass = field(form, getString(hasPw ? R.string.f_pass_saved : R.string.f_pass), "", true);
        final CheckBox tls = check(form, getString(R.string.f_tls), p.isTls());
        final EditText sni = field(form, getString(R.string.f_sni), p.sni, false);
        final CheckBox udp = check(form, getString(R.string.f_udpgw), p.udpgwEnabled);
        final EditText udpAddr = field(form, getString(R.string.f_udpgw_addr), p.udpgwAddr, false);
        final EditText dns = field(form, getString(R.string.f_dns), p.dns, false);
        final EditText ping = field(form, getString(R.string.f_ping), p.pingTarget, false);
        if (!isNew && p.hostKey.length() > 0) {
            TextView forget = Ui.text(this, getString(R.string.f_forget), 13, Ui.ERROR, true);
            forget.setPadding(0, Ui.dp(this, 12), 0, Ui.dp(this, 4));
            forget.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) { store.setHostKey(p.name, ""); p.hostKey = ""; v.setVisibility(View.GONE); }
            });
            form.addView(forget);
        }
        ScrollView sc = new ScrollView(this);
        sc.addView(form);

        final AlertDialog dlg = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(R.string.edit_title)
                .setView(sc)
                .setPositiveButton(R.string.save, null)
                .setNegativeButton(R.string.cancel, null)
                .create();
        dlg.setOnShowListener(new DialogInterface.OnShowListener() {
            public void onShow(DialogInterface d) {
                dlg.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(new View.OnClickListener() {
                    public void onClick(View v) {
                        String n = name.getText().toString().trim();
                        String h = host.getText().toString().trim();
                        String u = user.getText().toString().trim();
                        if (n.length() == 0 || h.length() == 0 || u.length() == 0) { toast(R.string.err_required); return; }
                        int prt;
                        try { prt = Integer.parseInt(port.getText().toString().trim()); } catch (Exception e) { prt = 0; }
                        if (prt < 1 || prt > 65535) { toast(R.string.err_port); return; }
                        if (isNew && store.get(n) != null) { toast(R.string.err_exists); return; }
                        String pw = pass.getText().toString();
                        if (pw.length() == 0 && p.password.length() == 0) { toast(R.string.err_secret); return; }
                        String pt = ping.getText().toString().trim();
                        Profile np = isNew ? new Profile() : p;
                        np.name = n; np.host = h; np.port = prt; np.user = u;
                        if (pw.length() > 0) np.password = pw;
                        np.transport = tls.isChecked() ? "tls" : "direct";
                        np.sni = sni.getText().toString().trim();
                        np.udpgwEnabled = udp.isChecked();
                        String ua = udpAddr.getText().toString().trim();
                        np.udpgwAddr = ua.length() == 0 ? "127.0.0.1:7300" : ua;
                        String dd = dns.getText().toString().trim();
                        np.dns = dd.length() == 0 ? "1.1.1.1,8.8.8.8" : dd.replace(" ", "");
                        np.pingTarget = pt.length() == 0 ? "1.1.1.1:443" : pt;
                        store.put(np);
                        store.setActive(np.name);
                        reloadProfiles();
                        render();
                        dlg.dismiss();
                    }
                });
            }
        });
        dlg.show();
    }

    private EditText field(LinearLayout parent, String hint, String value, boolean password) {
        TextView lbl = Ui.text(this, hint, 12, Ui.MUTED, false);
        lbl.setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 2));
        parent.addView(lbl);
        EditText e = new EditText(this);
        e.setText(value);
        e.setTextColor(Ui.TEXT);
        e.setSingleLine(true);
        e.setInputType(password ? (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD) : (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS));
        parent.addView(e);
        return e;
    }

    private CheckBox check(LinearLayout parent, String text, boolean on) {
        CheckBox c = new CheckBox(this);
        c.setText(text);
        c.setTextColor(Ui.TEXT);
        c.setChecked(on);
        c.setPadding(0, Ui.dp(this, 8), 0, Ui.dp(this, 4));
        parent.addView(c);
        return c;
    }

    private void toast(int res) { Toast.makeText(this, res, Toast.LENGTH_SHORT).show(); }

    // ------------------------------------------------------------------ connect

    private void toggle() {
        int st = CkVpnService.state;
        if (st == CkVpnService.ST_CONNECTING || st == CkVpnService.ST_CONNECTED) {
            CkVpnService.stop(this);
            return;
        }
        Profile p = selected();
        if (p == null) { toast(R.string.err_no_profile); return; }
        store.setActive(p.name);
        pendingStart = p.name;
        Intent prep = VpnService.prepare(this);
        if (prep != null) {
            startActivityForResult(prep, REQ_VPN);
        } else {
            startVpn();
        }
    }

    private void startVpn() {
        if (pendingStart != null) CkVpnService.start(this, pendingStart);
        pendingStart = null;
        ui.postDelayed(new Runnable() { public void run() { render(); } }, 300);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) startVpn(); else { pendingStart = null; toast(R.string.err_perm); }
        }
    }

    // ------------------------------------------------------------------ import

    private void handleIntent(Intent i) {
        if (i == null) return;
        String text = null;
        if (Intent.ACTION_VIEW.equals(i.getAction()) && i.getData() != null) {
            text = i.getDataString();
        } else if (Intent.ACTION_SEND.equals(i.getAction())) {
            text = i.getStringExtra(Intent.EXTRA_TEXT);
        }
        if (text != null && text.trim().length() > 0) {
            i.setAction(Intent.ACTION_MAIN); // handle once
            i.setData(null);
            runImport(text);
        }
    }

    private void importFromClipboard() {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        String text = "";
        if (cm != null && cm.hasPrimaryClip() && cm.getPrimaryClip().getItemCount() > 0) {
            CharSequence cs = cm.getPrimaryClip().getItemAt(0).coerceToText(this);
            if (cs != null) text = cs.toString();
        }
        if (text.trim().length() == 0) {
            // Android 10+ lets only the focused app read the clipboard; offer a paste box as a fallback
            final EditText box = new EditText(this);
            box.setHint(R.string.import_hint);
            box.setTextColor(Ui.TEXT);
            box.setHintTextColor(Ui.MUTED);
            new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                    .setTitle(R.string.import_paste)
                    .setMessage(R.string.clip_empty)
                    .setView(box)
                    .setPositiveButton(R.string.btn_import, new DialogInterface.OnClickListener() {
                        public void onClick(DialogInterface d, int w) { runImport(box.getText().toString()); }
                    })
                    .setNegativeButton(R.string.cancel, null)
                    .show();
            return;
        }
        runImport(text);
    }

    private void runImport(final String text) {
        new Thread(new Runnable() {
            public void run() {
                List<Profile> found = null;
                String err = null;
                try {
                    found = Importer.importText(MainActivity.this, text);
                } catch (Exception e) {
                    err = e.getMessage();
                }
                final List<Profile> res = found;
                final String msg = err;
                runOnUiThread(new Runnable() {
                    public void run() {
                        if (res == null || res.isEmpty()) {
                            Toast.makeText(MainActivity.this, msg == null ? getString(R.string.clip_empty) : msg, Toast.LENGTH_LONG).show();
                        } else {
                            confirmImport(res);
                        }
                    }
                });
            }
        }, "import").start();
    }

    private void confirmImport(final List<Profile> found) {
        StringBuilder sb = new StringBuilder();
        for (Profile p : found) sb.append("• ").append(p.name).append("  (").append(p.host).append(':').append(p.port).append(p.isTls() ? ", TLS" : "").append(")\n");
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle(R.string.import_title)
                .setMessage(getString(R.string.import_n, found.size(), sb.toString().trim()))
                .setPositiveButton(R.string.yes, new DialogInterface.OnClickListener() {
                    public void onClick(DialogInterface d, int w) {
                        String first = addImported(found);
                        store.setActive(first);
                        reloadProfiles();
                        render();
                        Toast.makeText(MainActivity.this, getString(R.string.import_done, found.size()), Toast.LENGTH_SHORT).show();
                    }
                })
                .setNegativeButton(R.string.no, null)
                .show();
    }

    /** The same account on the same server just updates the password; a clashing name gets a numeric suffix. */
    private String addImported(List<Profile> found) {
        String first = "";
        for (Profile p : found) {
            Profile old = store.get(p.name);
            if (old != null && old.host.equals(p.host) && old.port == p.port && old.user.equals(p.user)) {
                old.password = p.password;
                old.transport = p.transport;
                old.sni = p.sni;
                store.put(old);
                if (first.length() == 0) first = old.name;
                continue;
            }
            String base = p.name;
            int n = 2;
            while (store.get(p.name) != null) { p.name = base + " (" + n + ")"; n++; }
            store.put(p);
            if (first.length() == 0) first = p.name;
        }
        return first;
    }
}
