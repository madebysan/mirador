package com.san.androidsender;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import org.json.JSONArray;
import org.json.JSONObject;

final class PrivateServer implements AutoCloseable {
    static final int PORT = 8443;
    interface Handler { JSONObject handle(String method, String path, JSONObject body) throws Exception; }
    private final Pairing pairing;
    private final Handler handler;
    private final Map<String, SSLServerSocket> sockets = new HashMap<>();
    private final Set<SSLSocket> clients = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(4, 4, 0, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(12), new ThreadPoolExecutor.AbortPolicy());
    private boolean closed;
    volatile String error = "";
    private volatile int accepted, tlsFailures;

    PrivateServer(Pairing pairing, Handler handler) { this.pairing = pairing; this.handler = handler; }

    synchronized void refresh() {
        if (closed) return;
        Set<String> addresses = new HashSet<>();
        addresses.add("127.0.0.1"); // Authenticated local diagnostics through the already trusted ADB connection.
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback() || !SenderPolicy.isLocalInterface(network.getName())) continue;
                for (InetAddress address : Collections.list(network.getInetAddresses()))
                    if (SenderPolicy.isPrivateAddress(address.getHostAddress())) addresses.add(address.getHostAddress());
            }
            for (String old : new ArrayList<>(sockets.keySet())) {
                if (!addresses.contains(old)) { sockets.remove(old).close(); }
            }
            for (String address : addresses) {
                if (sockets.containsKey(address)) continue;
                SSLServerSocket socket = (SSLServerSocket) pairing.tls.getServerSocketFactory()
                        .createServerSocket(PORT, 8, InetAddress.getByName(address));
                List<String> protocols = new ArrayList<>();
                for (String protocol : socket.getSupportedProtocols())
                    if (protocol.equals("TLSv1.2") || protocol.equals("TLSv1.3")) protocols.add(protocol);
                socket.setEnabledProtocols(protocols.toArray(new String[0]));
                sockets.put(address, socket);
                new Thread(() -> accept(socket), "sender-https").start();
            }
            error = endpoints().isEmpty() ? "Connect to Wi-Fi or Tailscale." : "";
        } catch (Exception problem) { error = "Private listener unavailable. Check your network and restart Sender."; }
        pairing.prefs.edit().putString("endpoints", new JSONArray(endpoints()).toString()).apply();
    }

    synchronized List<String> endpoints() {
        List<String> result = new ArrayList<>();
        for (String address : sockets.keySet()) if (!address.equals("127.0.0.1"))
            result.add("https://" + (address.contains(":") ? "[" + address + "]" : address) + ":" + PORT);
        Collections.sort(result);
        return result;
    }

    private void accept(SSLServerSocket server) {
        while (!server.isClosed()) {
            try {
                SSLSocket client = (SSLSocket) server.accept();
                accepted++;
                pairing.prefs.edit().putInt("diagnostic_accepted", accepted).apply();
                client.setSoTimeout(10000);
                clients.add(client);
                try { workers.execute(() -> serve(client)); }
                catch (RejectedExecutionException busy) { clients.remove(client); client.close(); }
            } catch (IOException stopped) { return; }
        }
    }

    private void serve(SSLSocket client) {
        try (SSLSocket socket = client) {
            socket.startHandshake();
            HttpRequest request = HttpRequest.read(socket.getInputStream());
            if (!SenderPolicy.authorized(request.headers.get("authorization"), pairing.token)) {
                respond(socket, 401, new JSONObject().put("error", "Pair this receiver first."));
                return;
            }
            if (!request.body.isEmpty() && !request.headers.getOrDefault("content-type", "").startsWith("application/json")) {
                respond(socket, 400, new JSONObject().put("error", "JSON required.")); return;
            }
            try {
                JSONObject body = request.body.isEmpty() ? new JSONObject() : new JSONObject(request.body);
                respond(socket, 200, handler.handle(request.method, request.path, body));
            } catch (ApiError error) { respond(socket, error.code, new JSONObject().put("error", error.getMessage())); }
            catch (Exception error) { respond(socket, 400, new JSONObject().put("error", "Request failed. Reconnect the receiver.")); }
        } catch (Exception ignored) {
            tlsFailures++;
            pairing.prefs.edit().putInt("diagnostic_tls_failures", tlsFailures)
                    .putString("diagnostic_failure_type", ignored.getClass().getSimpleName())
                    .putString("diagnostic_tls_error", ignored instanceof javax.net.ssl.SSLException ? ignored.getMessage() : "").apply();
            // Invalid/abandoned requests are closed; credentials and SDP are never logged.
        } finally { clients.remove(client); }
    }

    private void respond(SSLSocket socket, int code, JSONObject result) throws IOException {
        byte[] data = result.toString().getBytes(StandardCharsets.UTF_8);
        OutputStream output = socket.getOutputStream();
        output.write(("HTTP/1.1 " + code + " " + (code == 200 ? "OK" : "Error") + "\r\nContent-Type: application/json\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\nContent-Length: " + data.length + "\r\n\r\n")
                .getBytes(StandardCharsets.US_ASCII));
        output.write(data); output.flush();
    }

    @Override public synchronized void close() {
        closed = true;
        for (SSLServerSocket socket : sockets.values()) try { socket.close(); } catch (IOException ignored) { }
        sockets.clear();
        for (SSLSocket socket : clients) try { socket.close(); } catch (IOException ignored) { }
        clients.clear(); workers.shutdownNow();
        pairing.prefs.edit().putString("endpoints", "[]").apply();
    }

    static final class ApiError extends Exception {
        final int code;
        ApiError(int code, String message) { super(message); this.code = code; }
    }
}
