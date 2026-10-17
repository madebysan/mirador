package com.san.androidsender;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsetsController;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** "How Mirador works" for the Android phone: which role it plays, Enable and Stop, privacy, connections and pairing. */
public final class HelpActivity extends Activity {
    private Hardware hw;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        hw = new Hardware(this);
        ScrollView scroll = new ScrollView(this);
        scroll.setBackground(hw.enclosure());
        LinearLayout page = vertical(); page.setPadding(hw.dp(16), hw.dp(12), hw.dp(16), hw.dp(24));
        scroll.addView(page);

        LinearLayout header = horizontal();
        TextView title = hw.engraved("HOW MIRADOR WORKS");
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        LinearLayout done = horizontal(); done.setGravity(Gravity.CENTER); done.setPadding(hw.dp(18), 0, hw.dp(18), 0);
        TextView doneText = hw.text("Done", 15, Hardware.LABEL, true); done.addView(doneText);
        hw.physical(done, 18, false, false); done.setContentDescription("Done");
        done.setOnClickListener(view -> finish());
        header.addView(done, new LinearLayout.LayoutParams(-2, hw.dp(38)));
        page.addView(header);

        LinearLayout lcd = vertical(); lcd.setBackground(hw.lcd()); lcd.setPadding(hw.dp(14), hw.dp(12), hw.dp(14), hw.dp(14));
        TextView badge = hw.text("TX", 12, Hardware.LCD_TOP, true); badge.setLetterSpacing(0.05f);
        badge.setBackground(Hardware.shape(hw.dp(5), Hardware.INK)); badge.setPadding(hw.dp(7), hw.dp(3), hw.dp(7), hw.dp(3));
        lcd.addView(badge, new LinearLayout.LayoutParams(-2, -2));
        TextView role = hw.text("This phone is the transmitter.", 22, Hardware.INK, true);
        lcd.addView(role, margins(-1, 8));
        TextView roleDetail = hw.text("It sends its camera and microphone to Mirador on your iPhone, the receiver.", 15, Hardware.INK, false);
        roleDetail.setLineSpacing(hw.dp(2), 1); lcd.addView(roleDetail, margins(-1, 6));
        LinearLayout bezel = vertical(); bezel.setBackground(hw.bezel(20)); bezel.setPadding(hw.dp(8), hw.dp(8), hw.dp(8), hw.dp(8));
        bezel.addView(lcd);
        bezel.setFocusable(true);
        bezel.setContentDescription("This phone is the transmitter. It sends its camera and microphone to Mirador on your iPhone, the receiver.");
        page.addView(bezel, margins(-1, 14));

        section(page, "Enable and Stop",
                "Enable lets your paired iPhone use this phone's camera and microphone.",
                "Stop turns Mirador off completely.",
                "After the phone restarts or Mirador updates, open it and tap Enable once.");
        section(page, "Privacy",
                "Nothing turns on until your paired iPhone asks.",
                "The red Camera and Microphone lights, and the notification, show what is live.",
                "Your iPhone can turn on this phone's flashlight while it watches the rear camera.",
                "Nothing is recorded or saved. On the internet route, everything is encrypted between your two phones.");
        section(page, "Connections",
                "WI-FI, TAILSCALE and INTERNET light up for each way your iPhone can reach this phone. Any one is enough.",
                "INTERNET works from anywhere this phone has Wi-Fi or mobile data.");
        section(page, "Pairing",
                "Pair a Receiver shows a private code for Mirador on your iPhone to scan.",
                "Anyone with that code could watch while Mirador is enabled, so never share or screenshot it.",
                "Pairing works on any network this phone is connected to.");
        section(page, "Staying available",
                "Allow Background helps Mirador keep running when the screen is off. Keep its notification; it shows Mirador is ready.");
        TextView version = hw.text("Mirador " + versionName(), 12, Color.argb(128, 41, 41, 43), false);
        version.setGravity(Gravity.CENTER); page.addView(version, margins(-1, 16));

        setContentView(scroll);
        getWindow().setStatusBarColor(Hardware.ENCLOSURE_TOP);
        getWindow().setNavigationBarColor(Hardware.ENCLOSURE_BOTTOM);
        WindowInsetsController bars = getWindow().getInsetsController();
        int light = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
        if (bars != null) bars.setSystemBarsAppearance(light, light);
    }

    private void section(LinearLayout page, String title, String... lines) {
        LinearLayout plate = vertical(); plate.setBackground(hw.plate(20)); plate.setElevation(hw.dp(1.5f));
        plate.setPadding(hw.dp(16), hw.dp(14), hw.dp(16), hw.dp(16));
        TextView header = hw.engraved(title.toUpperCase(java.util.Locale.ROOT));
        header.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES); header.setAccessibilityHeading(true);
        plate.addView(header);
        for (String line : lines) {
            TextView text = hw.text(line, 15, Hardware.LABEL, false);
            text.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL)); text.setLineSpacing(hw.dp(2), 1);
            plate.addView(text, margins(-1, 8));
        }
        page.addView(plate, margins(-1, 12));
    }

    private String versionName() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception missing) { return ""; }
    }

    private LinearLayout vertical() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); return layout; }
    private LinearLayout horizontal() { LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout; }
    private LinearLayout.LayoutParams margins(int width, int top) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(width, -2); params.topMargin = hw.dp(top); return params;
    }
}
