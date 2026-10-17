package com.san.androidsender;

import android.os.Handler;
import android.os.HandlerThread;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import org.json.JSONObject;
import static com.san.androidsender.PrivateServer.ApiError;

/**
 * Keeps an outgoing connection to the relay room so a viewer on another network can reach this sender.
 * Nothing listens on the internet: the phone only connects out. Requests arrive sealed, are checked for
 * freshness and replays, and are answered by the same handler as the private HTTPS listener.
 */
final class RelayLink implements AutoCloseable {
    interface Handler { JSONObject handle(String method, String path, JSONObject body) throws Exception; }

    private final String url;
    private final RelayCrypto crypto;
    private final Handler handler;
    private final RelayCrypto.ReplayGuard replays = new RelayCrypto.ReplayGuard();
    private final OkHttpClient http = new OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS).connectTimeout(10, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS).build();
    private final ExecutorService requests = Executors.newFixedThreadPool(2);
    private final HandlerThread thread = new HandlerThread("sender-relay");
    private final android.os.Handler retry;
    private WebSocket socket;
    private long backoff = 1000;
    private volatile boolean closed, connected;

    RelayLink(String baseUrl, RelayCrypto crypto, Handler handler) {
        this.url = baseUrl.replaceFirst("^https://", "wss://") + "/v1/room/" + crypto.roomId + "/sender";
        this.crypto = crypto; this.handler = handler;
        thread.start(); retry = new android.os.Handler(thread.getLooper());
        retry.post(this::connect);
    }

    boolean connected() { return connected; }

    /** Reconnects promptly, for example after the phone changes networks. */
    void nudge() { retry.post(() -> { if (!connected && socket == null) { retry.removeCallbacksAndMessages(null); connect(); } }); }

    private void connect() {
        if (closed || socket != null) return;
        socket = http.newWebSocket(new Request.Builder().url(url).build(), new WebSocketListener() {
            @Override public void onOpen(WebSocket ws, Response response) { retry.post(() -> { connected = true; backoff = 1000; }); }
            @Override public void onMessage(WebSocket ws, String text) { receive(ws, text); }
            @Override public void onClosing(WebSocket ws, int code, String reason) { ws.close(1000, null); dropped(ws); }
            @Override public void onClosed(WebSocket ws, int code, String reason) { dropped(ws); }
            @Override public void onFailure(WebSocket ws, Throwable error, Response response) { dropped(ws); }
        });
    }

    private void dropped(WebSocket ws) {
        retry.post(() -> {
            if (socket != ws) return;
            socket = null; connected = false;
            if (closed) return;
            retry.postDelayed(this::connect, backoff);
            backoff = Math.min(backoff * 2, 15000);
        });
    }

    private void receive(WebSocket ws, String text) {
        if (text.length() > 65536 || "pong".equals(text)) return;
        requests.execute(() -> {
            try {
                JSONObject frame = new JSONObject(text);
                if (!frame.has("box")) return; // Relay presence and other metadata are not for the sender.
                JSONObject request = new JSONObject(new String(crypto.openRequest(frame.getString("box")), StandardCharsets.UTF_8));
                String id = request.optString("id");
                if (!replays.accept(id, request.optLong("ts"), System.currentTimeMillis())) return;
                JSONObject reply = new JSONObject().put("id", id).put("ts", System.currentTimeMillis());
                try {
                    JSONObject body = request.optJSONObject("body");
                    reply.put("code", 200).put("body", handler.handle(request.optString("method"), request.optString("path"),
                            body == null ? new JSONObject() : body));
                } catch (ApiError error) {
                    reply.put("code", error.code).put("body", new JSONObject().put("error", error.getMessage()));
                } catch (Exception error) {
                    reply.put("code", 400).put("body", new JSONObject().put("error", "Request failed. Reconnect the receiver."));
                }
                ws.send(new JSONObject().put("box", crypto.sealReply(reply.toString().getBytes(StandardCharsets.UTF_8))).toString());
            } catch (Exception ignored) {
                // Unsealed, altered, stale or replayed frames are dropped without a reply. Nothing is logged.
            }
        });
    }

    @Override public void close() {
        closed = true;
        retry.post(() -> { if (socket != null) socket.close(1000, null); socket = null; connected = false; });
        retry.removeCallbacksAndMessages(null);
        thread.quitSafely(); requests.shutdownNow();
        http.dispatcher().executorService().shutdown(); http.connectionPool().evictAll();
    }
}
