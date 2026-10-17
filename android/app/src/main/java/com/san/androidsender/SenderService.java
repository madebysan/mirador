package com.san.androidsender;

import android.app.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.*;
import org.json.JSONArray;
import org.json.JSONObject;
import static com.san.androidsender.PrivateServer.ApiError;

public final class SenderService extends Service {
    static final String ARM = "com.san.androidsender.ARM", WAIT = "com.san.androidsender.WAIT", STOP = "com.san.androidsender.STOP";
    private static final int NOTIFICATION = 41;
    static volatile SenderService instance;
    volatile boolean armed;
    volatile String failure = "";
    volatile Pairing pairing;
    private volatile StreamEngine engine;
    private volatile PrivateServer server;
    private volatile RelayLink relay;
    private android.net.ConnectivityManager.NetworkCallback networkWatch;
    private volatile boolean destroyed;
    private final Handler clock = new Handler(Looper.getMainLooper());
    private PowerManager.WakeLock awake;
    private WifiManager.WifiLock wifi;
    private String previousNotification = "";

    @Override public void onCreate() {
        super.onCreate(); instance = this;
        getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel("sender",
                "Mirador transmitter", NotificationManager.IMPORTANCE_LOW));
    }

    @Override public int onStartCommand(Intent intent, int flags, int id) {
        if (intent != null && STOP.equals(intent.getAction())) {
            getSharedPreferences("sender", MODE_PRIVATE).edit().putBoolean("enabled", false).commit();
            armed = false; stopSelf(); return START_NOT_STICKY;
        }
        boolean enabled = getSharedPreferences("sender", MODE_PRIVATE).getBoolean("enabled", false);
        if (intent != null && ARM.equals(intent.getAction())) {
            armed = true;
            getSharedPreferences("sender", MODE_PRIVATE).edit().putBoolean("enabled", true).commit();
        } else if (!enabled) { stopSelf(); return START_NOT_STICKY; }
        int types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE;
        if (armed) types |= ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE;
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION, notification("Starting Mirador…"), types);
            else startForeground(NOTIFICATION, notification("Starting Mirador…"));
        } catch (SecurityException error) {
            failure = "Open Sender and allow camera/microphone access."; armed = false; stopSelf(); return START_NOT_STICKY;
        }
        if (awake == null) {
            awake = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AndroidSender:Available");
            awake.setReferenceCounted(false);
            awake.acquire(600000);
            WifiManager manager = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
            wifi = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "AndroidSender:Wifi");
            wifi.acquire();
            new Thread(this::initialize, "sender-init").start();
        }
        return START_STICKY;
    }

    private void initialize() {
        try {
            Pairing createdPairing = new Pairing(this);
            StreamEngine createdEngine = new StreamEngine(this);
            PrivateServer createdServer = new PrivateServer(createdPairing, (method, path, body) -> request(method, path, body, false));
            // The internet relay is optional and configured at build time; without it Sender works on Wi-Fi and Tailscale only.
            RelayLink createdRelay = BuildConfig.RELAY_URL.startsWith("https://")
                    ? new RelayLink(BuildConfig.RELAY_URL, new RelayCrypto(createdPairing.token), (method, path, body) -> request(method, path, body, true))
                    : null;
            synchronized (this) {
                if (destroyed) { createdServer.close(); createdEngine.close(); if (createdRelay != null) createdRelay.close(); return; }
                pairing = createdPairing; engine = createdEngine; server = createdServer; relay = createdRelay;
            }
            if (relay != null) {
                networkWatch = new android.net.ConnectivityManager.NetworkCallback() {
                    @Override public void onAvailable(android.net.Network network) { RelayLink link = relay; if (link != null) link.nudge(); }
                };
                getSystemService(android.net.ConnectivityManager.class).registerDefaultNetworkCallback(networkWatch);
            }
            server.refresh(); clock.post(tick);
        } catch (Exception problem) {
            failure = "Mirador could not start. Tap Stop, then Enable.";
            android.util.Log.e("AndroidSender", "Initialization failed: " + problem.getClass().getSimpleName());
            clock.post(() -> getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(failure)));
        }
    }

    private JSONObject request(String method, String path, JSONObject body, boolean relayed) throws Exception {
        if (method.equals("GET") && path.equals("/v1/status")) return status();
        if (!method.equals("POST")) throw new ApiError(405, "Use GET status or POST controls.");
        if (!(path.equals("/v1/offer") || path.equals("/v1/control") || path.equals("/v1/ping") || path.equals("/v1/disconnect")))
            throw new ApiError(404, "Unknown endpoint.");
        if (!armed || engine == null || destroyed) throw new ApiError(403, "Open Mirador on the Android phone and tap Enable.");
        return engine.handle(path, body, relayed);
    }

    JSONObject status() throws Exception {
        JSONObject result = engine == null ? new JSONObject().put("viewer", false).put("video", false).put("microphone", false)
                : engine.status();
        return result.put("version", "0.1.0").put("armed", armed).put("running", !destroyed)
                .put("listeners", server == null ? 0 : server.endpoints().size()).put("service_error", failure)
                .put("network_error", server == null ? "" : server.error)
                .put("relay", relay != null && relay.connected());
    }

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (destroyed) return;
            if (awake != null) awake.acquire(600000);
            if (server != null) server.refresh();
            if (engine != null) engine.tick();
            try {
                JSONObject state = status();
                String text = !armed ? "Tap to enable camera and microphone"
                        : state.optBoolean("viewer") ? "Live • Camera " + (state.optBoolean("video") ? "on" : "off")
                        + " • Mic " + (state.optBoolean("microphone") ? "on" : "off")
                        : state.optInt("listeners") == 0 && !state.optBoolean("relay") ? "Waiting for a network connection"
                        : "Ready • Camera and microphone off";
                if (!text.equals(previousNotification)) {
                    previousNotification = text;
                    getSystemService(NotificationManager.class).notify(NOTIFICATION, notification(text));
                }
            } catch (Exception ignored) { }
            clock.postDelayed(this, 5000);
        }
    };

    private Notification notification(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, SenderService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, "sender").setSmallIcon(R.drawable.ic_sender).setContentTitle("Mirador")
                .setContentText(text).setContentIntent(open).setOngoing(true).setCategory(Notification.CATEGORY_SERVICE)
                .setOnlyAlertOnce(true).addAction(new Notification.Action.Builder(null, "Stop", stop).build()).build();
    }

    @Override public void onDestroy() {
        synchronized (this) { destroyed = true; armed = false; }
        clock.removeCallbacksAndMessages(null);
        if (networkWatch != null) {
            try { getSystemService(android.net.ConnectivityManager.class).unregisterNetworkCallback(networkWatch); } catch (Exception ignored) { }
        }
        if (relay != null) relay.close();
        if (server != null) server.close();
        if (engine != null) engine.close();
        if (wifi != null && wifi.isHeld()) wifi.release();
        if (awake != null && awake.isHeld()) awake.release();
        stopForeground(STOP_FOREGROUND_REMOVE); instance = null;
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
