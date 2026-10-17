package com.san.androidsender;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

final class HttpRequest {
    final String method, path;
    final Map<String, String> headers;
    final String body;

    private HttpRequest(String method, String path, Map<String, String> headers, String body) {
        this.method = method; this.path = path; this.headers = headers; this.body = body;
    }

    static HttpRequest read(InputStream input) throws IOException {
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        int ending = 0;
        while (ending != 4) {
            int value = input.read();
            if (value == -1) throw new IOException("Incomplete request");
            head.write(value);
            if (head.size() > 8192) throw new IOException("Headers too large");
            int[] expected = {'\r', '\n', '\r', '\n'};
            ending = value == expected[ending] ? ending + 1 : (value == '\r' ? 1 : 0);
        }
        String[] lines = head.toString(StandardCharsets.US_ASCII.name()).split("\r\n");
        String[] first = lines[0].split(" ");
        if (first.length != 3 || !first[2].equals("HTTP/1.1") || !first[1].startsWith("/"))
            throw new IOException("Invalid request");
        Map<String, String> headers = new HashMap<>();
        for (int i = 1; i < lines.length; i++) {
            int colon = lines[i].indexOf(':');
            if (colon <= 0) throw new IOException("Invalid header");
            String key = lines[i].substring(0, colon).toLowerCase(Locale.ROOT);
            if (headers.put(key, lines[i].substring(colon + 1).trim()) != null)
                throw new IOException("Duplicate header");
        }
        if (headers.containsKey("transfer-encoding")) throw new IOException("Transfer encoding unsupported");
        int length;
        try { length = Integer.parseInt(headers.getOrDefault("content-length", "0")); }
        catch (NumberFormatException error) { throw new IOException("Invalid content length"); }
        if (length < 0 || length > 131072) throw new IOException("Body too large");
        byte[] body = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(body, offset, length - offset);
            if (count < 0) throw new IOException("Incomplete body");
            offset += count;
        }
        return new HttpRequest(first[0], first[1], headers, new String(body, StandardCharsets.UTF_8));
    }
}
