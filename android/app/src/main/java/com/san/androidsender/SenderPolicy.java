package com.san.androidsender;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

final class SenderPolicy {
    static boolean isLocalInterface(String name) {
        return name != null && (name.startsWith("wlan") || name.startsWith("wifi")
                || name.startsWith("eth") || name.startsWith("tun"));
    }
    static boolean isPrivateAddress(String address) {
        if (address != null && address.contains(":") && address.matches("[0-9a-fA-F:]+")) {
            try {
                byte[] bytes = java.net.InetAddress.getByName(address).getAddress();
                return bytes.length == 16 && ((bytes[0] & 0xfe) == 0xfc);
            } catch (java.net.UnknownHostException invalid) { return false; }
        }
        if (address == null || !address.matches("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+")) return false;
        String[] parts = address.split("\\.");
        int[] bytes = new int[4];
        try {
            for (int i = 0; i < 4; i++) {
                bytes[i] = Integer.parseInt(parts[i]);
                if (bytes[i] > 255) return false;
            }
        } catch (NumberFormatException error) { return false; }
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
    }

    /** Tailscale's CGNAT IPv4 range (100.64.0.0/10) or its IPv6 prefix (fd7a:115c:a1e0::/48). */
    static boolean isTailscaleAddress(String address) {
        if (address == null) return false;
        if (address.toLowerCase(java.util.Locale.ROOT).startsWith("fd7a:115c:a1e0:")) return true;
        if (!address.matches("100\\.[0-9]+\\.[0-9]+\\.[0-9]+")) return false;
        int second = Integer.parseInt(address.split("\\.")[1]);
        return second >= 64 && second <= 127;
    }

    /** Cloudflare STUN/TURN URLs that a relayed session may use. */
    static boolean isRelayIceUrl(String url) {
        return url != null && url.matches("(stun|turns?):(stun|turn)\\.cloudflare\\.com:[0-9]{2,5}(\\?transport=(udp|tcp))?");
    }

    static boolean authorized(String authorization, String token) {
        if (authorization == null || token == null || token.length() != 43) return false;
        return MessageDigest.isEqual(authorization.getBytes(StandardCharsets.UTF_8),
                ("Bearer " + token).getBytes(StandardCharsets.UTF_8));
    }
}
