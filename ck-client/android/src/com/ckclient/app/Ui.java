package com.ckclient.app;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.widget.TextView;

/** Colours of the CK.VPN panel and small view helpers (the UI is built in code, no layout files). */
final class Ui {
    private Ui() { }

    static final int BG = Color.parseColor("#0B1120");
    static final int CARD = Color.parseColor("#111827");
    static final int BORDER = Color.parseColor("#1F2937");
    static final int INPUT = Color.parseColor("#080C17");
    static final int TEXT = Color.parseColor("#F3F4F6");
    static final int MUTED = Color.parseColor("#9CA3AF");
    static final int PRIMARY = Color.parseColor("#06B6D4");
    static final int ON_PRIMARY = Color.parseColor("#031116");
    static final int OK = Color.parseColor("#10B981");
    static final int ERROR = Color.parseColor("#EF4444");
    static final int WARN = Color.parseColor("#F59E0B");

    static int dp(Context c, float v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics());
    }

    static GradientDrawable rounded(Context c, int fill, int stroke, float radiusDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setCornerRadius(dp(c, radiusDp));
        if (stroke != 0) g.setStroke(dp(c, 1), stroke);
        return g;
    }

    static GradientDrawable oval(int fill) {
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(fill);
        return g;
    }

    static TextView text(Context c, CharSequence t, float sp, int color, boolean bold) {
        TextView v = new TextView(c);
        v.setText(t);
        v.setTextSize(sp);
        v.setTextColor(color);
        if (bold) v.setTypeface(android.graphics.Typeface.DEFAULT_BOLD);
        return v;
    }

    static TextView button(Context c, CharSequence t, int bg, int fg, float sp) {
        TextView v = text(c, t, sp, fg, true);
        v.setGravity(Gravity.CENTER);
        v.setBackground(rounded(c, bg, bg == CARD ? BORDER : 0, 14));
        v.setPadding(dp(c, 14), dp(c, 12), dp(c, 14), dp(c, 12));
        v.setClickable(true);
        return v;
    }
}
