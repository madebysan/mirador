package com.san.androidsender;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.view.View;
import android.view.WindowInsetsController;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.*;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.common.BitMatrix;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;

public final class MainActivity extends Activity {
    private Hardware hw;
    private TextView badge, clock, cameraReadout, micReadout, headline, detail, enableLegend, backgroundLegend;
    private TextView wifiLink, tailscaleLink, internetLink;
    private LinearLayout enableKey, stopKey, pairKey, backgroundKey;
    private Hardware.Lamp enableLamp, cameraLamp, micLamp, backgroundLamp;
    private Boolean enableLatched;
    private final Handler clockTick = new Handler(Looper.getMainLooper());
    private final int white = Color.WHITE, muted = Color.argb(158, 255, 255, 255);

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        hw = new Hardware(this);
        ScrollView scroll = new ScrollView(this);
        scroll.setBackground(hw.enclosure()); scroll.setFillViewport(true);
        boolean landscape = getResources().getConfiguration().orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE;
        LinearLayout page = landscape ? horizontal() : vertical();
        if (landscape) page.setGravity(Gravity.TOP);
        page.setPadding(dp(14), dp(12), dp(14), dp(20)); scroll.addView(page);
        if (landscape) {
            // Like the iPhone viewer in landscape: display on the left, controls on the right.
            page.addView(display(), new LinearLayout.LayoutParams(0, -2, 1));
            LinearLayout.LayoutParams right = new LinearLayout.LayoutParams(0, -2, 1); right.setMarginStart(dp(14));
            page.addView(deck(), right);
        } else {
            page.addView(display(), params(-1, -2, 0, 0));
            page.addView(deck(), params(-1, -2, 0, 12));
        }
        setContentView(scroll);
        getWindow().setStatusBarColor(Hardware.ENCLOSURE_TOP);
        getWindow().setNavigationBarColor(Hardware.ENCLOSURE_BOTTOM);
        WindowInsetsController bars = getWindow().getInsetsController();
        int light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
        if (bars != null) bars.setSystemBarsAppearance(light, light);
    }

    // Display: LCD and readout inside a dark bezel on a raised plate.
    private View display() {
        LinearLayout bezel = vertical(); bezel.setBackground(hw.bezel(24)); bezel.setPadding(dp(10), dp(10), dp(10), dp(12));
        LinearLayout lcd = vertical(); lcd.setBackground(hw.lcd()); lcd.setPadding(dp(12), dp(10), dp(12), dp(10));
        LinearLayout top = horizontal();
        badge = hw.text("OFF", 12, Hardware.LCD_TOP, true); badge.setLetterSpacing(0.05f);
        badge.setBackground(Hardware.shape(dp(5), Hardware.INK)); badge.setPadding(dp(7), dp(3), dp(7), dp(3));
        top.addView(badge);
        View spacer = new View(this); top.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1));
        wifiLink = link("WI-FI"); tailscaleLink = link("TAILSCALE"); internetLink = link("INTERNET");
        for (TextView link : new TextView[]{wifiLink, tailscaleLink, internetLink}) top.addView(link, params(-2, -2, 8, 0));
        lcd.addView(top);
        clock = hw.text("", 40, Hardware.INK, false); clock.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        clock.setFontFeatureSettings("tnum"); clock.setText(clockText(0)); clock.setAlpha(0.28f);
        lcd.addView(clock, params(-1, -2, 0, 6));
        LinearLayout strip = horizontal(); strip.setPadding(dp(9), dp(5), dp(9), dp(5));
        GradientDrawable border = Hardware.shape(dp(6), Color.argb(18, 26, 38, 46)); border.setStroke(dp(1.2f), Hardware.INK); strip.setBackground(border);
        cameraReadout = hw.text("CAMERA OFF", 13, Hardware.INK, true); cameraReadout.setLetterSpacing(0.04f);
        micReadout = hw.text("MIC OFF", 13, Hardware.INK, true); micReadout.setLetterSpacing(0.04f);
        strip.addView(cameraReadout, new LinearLayout.LayoutParams(0, -2, 1)); strip.addView(micReadout);
        lcd.addView(strip, params(-1, -2, 0, 6));
        bezel.addView(lcd);
        headline = hw.text("", 17, white, true); headline.setPadding(dp(6), 0, dp(6), 0);
        detail = hw.text("", 14, muted, false); detail.setPadding(dp(6), 0, dp(6), 0); detail.setLineSpacing(dp(2), 1);
        bezel.addView(headline, params(-1, -2, 0, 10)); bezel.addView(detail, params(-1, -2, 0, 4));
        LinearLayout plate = vertical(); plate.setBackground(hw.plate(30)); plate.setPadding(dp(6), dp(6), dp(6), dp(6));
        plate.setElevation(dp(1.5f)); plate.addView(bezel);
        return plate;
    }

    // Control deck: Stop and Enable, sensor lamps, Pair and background permission.
    private View deck() {
        LinearLayout deck = vertical(); deck.setBackground(hw.plate(28)); deck.setPadding(dp(16), dp(16), dp(16), dp(16)); deck.setElevation(dp(1.5f));

        LinearLayout transport = horizontal(); transport.setBackground(hw.housing(33)); transport.setPadding(dp(5), dp(5), dp(5), dp(5));
        stopKey = horizontal(); stopKey.setGravity(Gravity.CENTER);
        View square = new View(this); square.setBackground(Hardware.shape(dp(3), Hardware.LABEL)); stopKey.addView(square, params(dp(17), dp(17), 0, 0, true));
        hw.physical(stopKey, 28, false, false); stopKey.setContentDescription("Stop");
        stopKey.setOnClickListener(view -> startService(new Intent(this, SenderService.class).setAction(SenderService.STOP)));
        transport.addView(stopKey, params(dp(56), dp(56), 0, 0, true));
        enableKey = horizontal(); enableKey.setGravity(Gravity.CENTER);
        enableLamp = new Hardware.Lamp(this); enableKey.addView(enableLamp, params(dp(18), dp(18), 0, 0, true));
        TextView enableText = hw.text("ENABLE", 15, Hardware.LABEL, true); enableText.setLetterSpacing(0.08f);
        enableKey.addView(enableText, params(-2, -2, 8, 0));
        hw.physical(enableKey, 28, false, false); enableKey.setContentDescription("Enable camera and microphone");
        enableKey.setOnClickListener(view -> enable());
        LinearLayout.LayoutParams wide = new LinearLayout.LayoutParams(0, dp(56), 1); wide.setMarginStart(dp(6));
        transport.addView(enableKey, wide);
        deck.addView(transport);
        LinearLayout legends = horizontal();
        TextView stopLegend = hw.engraved("STOP"); stopLegend.setGravity(Gravity.CENTER);
        legends.addView(stopLegend, params(dp(66), -2, 0, 0, true));
        enableLegend = hw.engraved(""); enableLegend.setGravity(Gravity.CENTER);
        legends.addView(enableLegend, new LinearLayout.LayoutParams(0, -2, 1));
        deck.addView(legends, params(-1, -2, 0, 8));

        LinearLayout lamps = horizontal(); lamps.setBackground(hw.housing(18)); lamps.setPadding(dp(5), dp(5), dp(5), dp(5));
        cameraLamp = new Hardware.Lamp(this); micLamp = new Hardware.Lamp(this);
        lamps.addView(lampCell(cameraLamp, "CAMERA"), new LinearLayout.LayoutParams(0, dp(46), 1));
        LinearLayout.LayoutParams second = new LinearLayout.LayoutParams(0, dp(46), 1); second.setMarginStart(dp(6));
        lamps.addView(lampCell(micLamp, "MICROPHONE"), second);
        deck.addView(lamps, params(-1, -2, 0, 14));

        pairKey = horizontal(); pairKey.setGravity(Gravity.CENTER);
        TextView pairText = hw.text("PAIR A RECEIVER", 15, Hardware.LABEL, true); pairText.setLetterSpacing(0.08f); pairKey.addView(pairText);
        hw.physical(pairKey, 24, false, false); pairKey.setContentDescription("Pair a Receiver");
        pairKey.setOnClickListener(view -> showPairing());
        deck.addView(pairKey, params(-1, dp(48), 0, 14));

        backgroundKey = horizontal(); backgroundKey.setGravity(Gravity.CENTER);
        backgroundLamp = new Hardware.Lamp(this); backgroundKey.addView(backgroundLamp, params(dp(16), dp(16), 0, 0, true));
        backgroundLegend = hw.text("ALLOW BACKGROUND", 13, Hardware.LABEL, true); backgroundLegend.setLetterSpacing(0.06f);
        backgroundKey.addView(backgroundLegend, params(-2, -2, 8, 0));
        hw.physical(backgroundKey, 21, false, false);
        backgroundKey.setOnClickListener(view -> {
            PowerManager manager = getSystemService(PowerManager.class);
            if (manager.isIgnoringBatteryOptimizations(getPackageName())) {
                new AlertDialog.Builder(this).setMessage("Background operation is already allowed.").setPositiveButton("OK", null).show();
            } else startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
        });
        LinearLayout utility = horizontal();
        utility.addView(backgroundKey, new LinearLayout.LayoutParams(0, dp(42), 1));
        LinearLayout helpKey = horizontal(); helpKey.setGravity(Gravity.CENTER);
        TextView helpGlyph = hw.text("i", 18, Hardware.LABEL, true); helpGlyph.setTypeface(Typeface.create("serif", Typeface.BOLD));
        helpKey.addView(helpGlyph);
        hw.physical(helpKey, 21, false, false); helpKey.setContentDescription("How Mirador works");
        helpKey.setOnClickListener(view -> startActivity(new Intent(this, HelpActivity.class)));
        LinearLayout.LayoutParams round = new LinearLayout.LayoutParams(dp(42), dp(42)); round.setMarginStart(dp(10));
        utility.addView(helpKey, round);
        deck.addView(utility, params(-1, -2, 0, 12));

        TextView note = hw.text("Mirador stays available when you leave this screen. Camera and microphone turn on only for a paired receiver. Nothing is recorded. After restarting the phone, open this app and tap Enable again.",
                13, Color.argb(170, 41, 41, 43), false);
        note.setLineSpacing(dp(2), 1); note.setShadowLayer(0.01f, 0, dp(1), Color.WHITE);
        deck.addView(note, params(-1, -2, 0, 14));
        return deck;
    }

    private View lampCell(Hardware.Lamp lamp, String label) {
        LinearLayout cell = horizontal(); cell.setGravity(Gravity.CENTER);
        cell.setBackground(Hardware.shape(dp(13), Color.rgb(236, 236, 236), Color.rgb(226, 226, 226)));
        cell.addView(lamp, params(dp(18), dp(18), 0, 0, true));
        TextView text = hw.engraved(label); cell.addView(text, params(-2, -2, 8, 0));
        cell.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        return cell;
    }

    private TextView link(String value) { TextView text = hw.text(value, 11, Hardware.INK, true); text.setLetterSpacing(0.05f); text.setAlpha(0.25f); return text; }

    private static CharSequence clockText(long seconds) {
        SpannableStringBuilder out = new SpannableStringBuilder();
        String[][] parts = {{String.valueOf(seconds / 3600), "h"}, {String.format(java.util.Locale.ROOT, "%02d", seconds / 60 % 60), "m"},
                {String.format(java.util.Locale.ROOT, "%02d", seconds % 60), "s"}};
        for (String[] part : parts) {
            out.append(part[0]);
            int start = out.length(); out.append(part[1]);
            out.setSpan(new RelativeSizeSpan(0.5f), start, out.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return out;
    }

    private void enable() {
        ArrayList<String> missing = new ArrayList<>();
        for (String permission : new String[]{Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO})
            if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) missing.add(permission);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            missing.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!missing.isEmpty()) requestPermissions(missing.toArray(new String[0]), 1);
        else startForegroundService(new Intent(this, SenderService.class).setAction(SenderService.ARM));
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == 1) {
            if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                    && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                startForegroundService(new Intent(this, SenderService.class).setAction(SenderService.ARM));
            else new AlertDialog.Builder(this).setMessage("Camera and microphone permission are needed for live viewing.").setPositiveButton("OK", null).show();
        }
    }

    private void showPairing() {
        SenderService sender = SenderService.instance;
        if (sender == null || sender.pairing == null) return;
        try {
            Pairing pairing = sender.pairing;
            JSONObject data = new JSONObject().put("protocol", "android-sender-v1")
                    .put("endpoints", new JSONArray(pairing.prefs.getString("endpoints", "[]")))
                    .put("token", pairing.token).put("certificate_sha256", pairing.fingerprint);
            BitMatrix bits = new QRCodeWriter().encode(data.toString(), BarcodeFormat.QR_CODE, 720, 720);
            Bitmap image = Bitmap.createBitmap(720, 720, Bitmap.Config.ARGB_8888);
            for (int y = 0; y < 720; y++) for (int x = 0; x < 720; x++) image.setPixel(x, y, bits.get(x, y) ? Color.BLACK : Color.WHITE);
            LinearLayout content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setPadding(dp(20), 0, dp(20), dp(16));
            ImageView qr = new ImageView(this); qr.setImageBitmap(image); qr.setAdjustViewBounds(true);
            qr.setMaxHeight(getResources().getDisplayMetrics().heightPixels / 3);
            qr.setScaleType(ImageView.ScaleType.FIT_CENTER); content.addView(qr);
            add(content, text("Scan with Mirador on the iPhone. Keep this pairing code private: it grants live access while Sender is enabled.", 14, muted), 16);
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Pair a Receiver").setView(content).setPositiveButton("Done", null).create();
            dialog.getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE); dialog.show();
        } catch (Exception problem) { new AlertDialog.Builder(this).setMessage("Pairing is not ready. Check the network and try again.").setPositiveButton("OK", null).show(); }
    }

    private final Runnable render = new Runnable() {
        @Override public void run() {
            SenderService sender = SenderService.instance;
            try {
                JSONObject state = sender == null ? new JSONObject() : sender.status();
                boolean running = sender != null, armed = running && sender.armed;
                boolean failed = running && !sender.failure.isEmpty();
                boolean viewer = state.optBoolean("viewer"), video = state.optBoolean("video"), mic = state.optBoolean("microphone");
                boolean relay = state.optBoolean("relay"), wifi = false, tailscale = false;
                if (running && sender.pairing != null) {
                    JSONArray endpoints = new JSONArray(sender.pairing.prefs.getString("endpoints", "[]"));
                    for (int i = 0; i < endpoints.length(); i++) {
                        String host = Uri.parse(endpoints.getString(i)).getHost();
                        if (host != null && SenderPolicy.isTailscaleAddress(host.replace("[", "").replace("]", ""))) tailscale = true; else wifi = true;
                    }
                }
                if (!running) badge.setText("OFF");
                else if (failed) badge.setText("ATTENTION");
                else if (!armed) badge.setText("STANDBY");
                else if (viewer) {
                    SpannableStringBuilder live = new SpannableStringBuilder("● LIVE");
                    live.setSpan(new ForegroundColorSpan(Hardware.TALLY), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                    badge.setText(live);
                } else badge.setText("READY");
                wifiLink.setAlpha(wifi ? 1f : 0.25f); tailscaleLink.setAlpha(tailscale ? 1f : 0.25f); internetLink.setAlpha(relay ? 1f : 0.25f);
                clock.setText(clockText(viewer ? state.optLong("session_seconds") : 0)); clock.setAlpha(viewer ? 1f : 0.28f);
                cameraReadout.setText(video ? "CAMERA " + state.optString("camera", "rear").toUpperCase(java.util.Locale.ROOT) : "CAMERA OFF");
                micReadout.setText(mic ? "MIC ON" : "MIC OFF");
                boolean anyNetwork = state.optInt("listeners") > 0 || relay;
                headline.setText(!running ? "Stopped" : failed ? "Needs attention" : !armed ? "Enable to go live" : viewer ? "Live" : "Ready");
                detail.setText(!running ? "Tap Enable to accept a receiver." : failed ? sender.failure
                        : !armed ? "Listener is running. Tap Enable to allow camera and microphone."
                        : viewer ? "Paired receiver connected." : !anyNetwork ? "Waiting for a network connection."
                        : "Waiting for a paired receiver. You can leave this screen.");
                enableLamp.set(armed, Hardware.GO); cameraLamp.set(video, Hardware.TALLY); micLamp.set(mic, Hardware.TALLY);
                if (enableLatched == null || enableLatched != armed) {
                    enableLatched = armed;
                    hw.physical(enableKey, 28, false, armed);
                }
                ((TextView) enableKey.getChildAt(1)).setText(armed ? "ENABLED" : "ENABLE");
                Hardware.setUsable(enableKey, !armed);
                Hardware.setUsable(stopKey, running);
                // The relay can carry pairing too, so a phone on mobile data alone can pair.
                Hardware.setUsable(pairKey, armed && sender.pairing != null && anyNetwork);
                boolean background = getSystemService(PowerManager.class).isIgnoringBatteryOptimizations(getPackageName());
                backgroundLamp.set(background, Hardware.GO);
                backgroundLegend.setText(background ? "BACKGROUND ALLOWED" : "ALLOW BACKGROUND");
                ((View) cameraLamp.getParent()).setContentDescription(video ? "Camera on" : "Camera off");
                ((View) micLamp.getParent()).setContentDescription(mic ? "Microphone on" : "Microphone off");
            } catch (Exception ignored) { }
            clockTick.postDelayed(this, 1000);
        }
    };
    @Override public void onResume() { super.onResume(); clockTick.post(render); }
    @Override public void onPause() { clockTick.removeCallbacksAndMessages(null); super.onPause(); }
    private TextView text(String value, int size, int color) { TextView text = hw.text(value, size, color, false); text.setLineSpacing(dp(3), 1); return text; }
    private LinearLayout vertical() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout horizontal() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }
    /** Layout params in dp for margins; width/height are -1 match, -2 wrap, or pixels when {@code pixels} is true. */
    private LinearLayout.LayoutParams params(int width, int height, int startMargin, int topMargin) { return params(width, height, startMargin, topMargin, false); }
    private LinearLayout.LayoutParams params(int width, int height, int startMargin, int topMargin, boolean pixels) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(width, height);
        params.setMarginStart(dp(startMargin)); params.topMargin = dp(topMargin);
        return params;
    }
    private void add(LinearLayout layout, android.view.View view, int top) { layout.addView(view, params(-1, -2, 0, top)); }
    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
