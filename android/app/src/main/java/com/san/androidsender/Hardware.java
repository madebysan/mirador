package com.san.androidsender;

import android.animation.AnimatorSet;
import android.animation.ObjectAnimator;
import android.animation.StateListAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.LayerDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

/**
 * The hardware look shared with the iPhone viewer: a light enclosure, raised plates, a dark display bezel,
 * a blue-grey LCD, recessed housings with physical keys, and indicator lamps.
 */
final class Hardware {
    static final int ENCLOSURE_TOP = Color.rgb(230, 230, 230), ENCLOSURE_BOTTOM = Color.rgb(212, 212, 212);
    static final int PLATE = Color.rgb(240, 240, 240), BEZEL = Color.rgb(31, 31, 33);
    static final int LCD_TOP = Color.rgb(186, 214, 227), LCD_BOTTOM = Color.rgb(163, 196, 212);
    static final int INK = Color.rgb(26, 38, 46), LABEL = Color.rgb(41, 41, 43);
    static final int TALLY = Color.rgb(219, 13, 26), GO = Color.rgb(46, 190, 84), LAMP_OFF = Color.rgb(168, 168, 168);

    private final Context context;
    private final float density;

    Hardware(Context context) { this.context = context; density = context.getResources().getDisplayMetrics().density; }

    int dp(float value) { return Math.round(value * density); }

    static GradientDrawable shape(float radius, int... colors) {
        GradientDrawable drawable = colors.length == 1 ? new GradientDrawable() : new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, colors);
        if (colors.length == 1) drawable.setColor(colors[0]);
        drawable.setCornerRadius(radius);
        return drawable;
    }

    Drawable enclosure() { return new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[]{ENCLOSURE_TOP, ENCLOSURE_BOTTOM}); }

    /** A raised panel that holds the display or the controls. */
    Drawable plate(float radius) {
        GradientDrawable plate = shape(dp(radius), PLATE);
        plate.setStroke(dp(1), Color.WHITE);
        return plate;
    }

    Drawable bezel(float radius) {
        GradientDrawable bezel = shape(dp(radius), BEZEL);
        bezel.setStroke(dp(1), Color.rgb(58, 58, 61));
        return bezel;
    }

    /** The LCD glass, with a darker rim standing in for an inner shadow. */
    Drawable lcd() {
        GradientDrawable rim = shape(dp(12), Color.rgb(120, 146, 158));
        GradientDrawable glass = shape(dp(12), LCD_TOP, LCD_BOTTOM);
        LayerDrawable layers = new LayerDrawable(new Drawable[]{rim, glass});
        layers.setLayerInset(1, dp(1), dp(2), 0, 0);
        return layers;
    }

    /** The recessed well that keys sit in: a shadowed top edge and a light bottom lip. */
    Drawable housing(float radius) {
        GradientDrawable lip = shape(dp(radius), Color.WHITE);
        GradientDrawable shadow = shape(dp(radius), Color.rgb(170, 170, 170));
        GradientDrawable well = shape(dp(radius), Color.rgb(205, 205, 205), Color.rgb(214, 214, 214));
        LayerDrawable layers = new LayerDrawable(new Drawable[]{lip, shadow, well});
        layers.setLayerInset(1, 0, 0, 0, dp(1));
        layers.setLayerInset(2, dp(1), dp(2.5f), dp(1), dp(1));
        return layers;
    }

    /** A key face for the normal and held-down states; latched toggles stay held down. */
    Drawable keyFace(float radius, boolean dark, boolean latched) {
        StateListDrawable states = new StateListDrawable();
        states.addState(new int[]{android.R.attr.state_pressed}, face(radius, dark, true));
        states.addState(new int[]{}, face(radius, dark, latched));
        return states;
    }

    private Drawable face(float radius, boolean dark, boolean down) {
        GradientDrawable face = dark
                ? shape(dp(radius), down ? Color.rgb(34, 34, 36) : Color.rgb(70, 70, 72), down ? Color.rgb(50, 50, 52) : Color.rgb(38, 38, 40))
                : shape(dp(radius), down ? Color.rgb(222, 222, 222) : Color.rgb(254, 254, 254), down ? Color.rgb(236, 236, 236) : Color.rgb(229, 229, 229));
        face.setStroke(dp(1), dark ? Color.rgb(20, 20, 22) : Color.rgb(200, 200, 200));
        return face;
    }

    /** Gives a key travel, a soft shadow that shrinks while pressed, and a light haptic click. */
    void physical(View key, float radius, boolean dark, boolean latched) {
        key.setBackground(keyFace(radius, dark, latched));
        key.setElevation(latched ? dp(0.5f) : dp(2.5f));
        key.setClickable(true);
        StateListAnimator travel = new StateListAnimator();
        AnimatorSet down = new AnimatorSet();
        down.playTogether(ObjectAnimator.ofFloat(key, "translationY", dp(1)), ObjectAnimator.ofFloat(key, "translationZ", -dp(2)));
        down.setDuration(60);
        AnimatorSet up = new AnimatorSet();
        up.playTogether(ObjectAnimator.ofFloat(key, "translationY", 0), ObjectAnimator.ofFloat(key, "translationZ", 0));
        up.setDuration(90);
        travel.addState(new int[]{android.R.attr.state_pressed}, down);
        travel.addState(new int[]{}, up);
        key.setStateListAnimator(travel);
        key.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN && view.isEnabled())
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP);
            return false;
        });
    }

    /** Dims a key's engraving when it cannot be used, like an unlit legend. */
    static void setUsable(View key, boolean usable) {
        key.setEnabled(usable);
        if (key instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) key;
            for (int i = 0; i < group.getChildCount(); i++) {
                View child = group.getChildAt(i);
                if (!(child instanceof Lamp)) child.setAlpha(usable ? 1f : 0.32f);
            }
        } else key.setAlpha(usable ? 1f : 0.32f);
    }

    /** Uppercase legend printed on the enclosure. */
    TextView engraved(String value) {
        TextView text = text(value, 12, Color.argb(220, Color.red(LABEL), Color.green(LABEL), Color.blue(LABEL)), true);
        text.setLetterSpacing(0.06f);
        text.setShadowLayer(0.01f, 0, dp(1), Color.WHITE);
        text.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return text;
    }

    TextView text(String value, float size, int color, boolean bold) {
        TextView text = new TextView(context);
        text.setText(value); text.setTextSize(size); text.setTextColor(color);
        text.setTypeface(Typeface.create("sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL));
        text.setIncludeFontPadding(false);
        return text;
    }

    /** A small indicator lamp that glows when lit. */
    static final class Lamp extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private int color = LAMP_OFF;
        private boolean lit;

        Lamp(Context context) { super(context); setLayerType(LAYER_TYPE_SOFTWARE, null); setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO); }

        void set(boolean on, int litColor) {
            if (on == lit && litColor == color) return;
            lit = on; color = litColor; invalidate();
        }

        @Override protected void onDraw(Canvas canvas) {
            float radius = Math.min(getWidth(), getHeight()) / 4f;
            float cx = getWidth() / 2f, cy = getHeight() / 2f;
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(lit ? color : LAMP_OFF);
            if (lit) paint.setShadowLayer(radius * 1.6f, 0, 0, color); else paint.clearShadowLayer();
            canvas.drawCircle(cx, cy, radius, paint);
            paint.clearShadowLayer();
            paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(1);
            paint.setColor(Color.argb(64, 0, 0, 0));
            canvas.drawCircle(cx, cy, radius, paint);
        }
    }
}
