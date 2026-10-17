package com.san.androidsender;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Keys for the internet relay, derived from the existing pairing token so no new pairing is needed.
 * The relay sees only the room ID. Requests (viewer to sender) and replies (sender to viewer) are sealed with
 * separate AES-GCM keys, so the relay cannot read, forge or reflect them. Matches the iPhone's RelayKeys.
 */
final class RelayCrypto {
    final String roomId;
    private final byte[] viewerToSender, senderToViewer;
    private final SecureRandom random = new SecureRandom();

    RelayCrypto(String token) throws GeneralSecurityException {
        byte[] secret = Base64.getUrlDecoder().decode(token);
        if (secret.length != 32) throw new GeneralSecurityException("Invalid pairing token");
        roomId = hex(hmac(secret, "android-viewer/room/v1".getBytes(StandardCharsets.UTF_8)));
        byte[] salt = "android-viewer/relay/v1".getBytes(StandardCharsets.UTF_8);
        viewerToSender = hkdf(secret, salt, "viewer-to-sender");
        senderToViewer = hkdf(secret, salt, "sender-to-viewer");
    }

    /** Opens a request sealed by the viewer. Throws if it was altered or sealed with another key. */
    byte[] openRequest(String box) throws GeneralSecurityException {
        byte[] data = Base64.getDecoder().decode(box);
        if (data.length < 12 + 16) throw new GeneralSecurityException("Short box");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(viewerToSender, "AES"), new GCMParameterSpec(128, data, 0, 12));
        return cipher.doFinal(data, 12, data.length - 12);
    }

    /** Seals a reply for the viewer as nonce || ciphertext || tag, base64-encoded. */
    String sealReply(byte[] plaintext) throws GeneralSecurityException {
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        return seal(senderToViewer, nonce, plaintext);
    }

    static String seal(byte[] key, byte[] nonce, byte[] plaintext) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        byte[] sealed = cipher.doFinal(plaintext);
        byte[] box = Arrays.copyOf(nonce, nonce.length + sealed.length);
        System.arraycopy(sealed, 0, box, nonce.length, sealed.length);
        return Base64.getEncoder().encodeToString(box);
    }

    byte[] viewerToSenderKeyForTest() { return viewerToSender.clone(); }
    byte[] senderToViewerKeyForTest() { return senderToViewer.clone(); }

    private static byte[] hmac(byte[] key, byte[] message) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(message);
    }

    /** RFC 5869 HKDF-SHA256 for a single 32-byte block. */
    private static byte[] hkdf(byte[] input, byte[] salt, String info) throws GeneralSecurityException {
        byte[] prk = hmac(salt, input);
        byte[] infoBytes = info.getBytes(StandardCharsets.UTF_8);
        byte[] block = Arrays.copyOf(infoBytes, infoBytes.length + 1);
        block[infoBytes.length] = 1;
        return hmac(prk, block);
    }

    static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte value : bytes) out.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return out.toString();
    }

    /** Rejects stale requests and replays of a request the relay already delivered. */
    static final class ReplayGuard {
        static final long WINDOW_MS = 120_000;
        private final Map<String, Long> seen = new LinkedHashMap<>();

        synchronized boolean accept(String id, long timestamp, long now) {
            if (id == null || id.isEmpty() || id.length() > 64 || Math.abs(now - timestamp) > WINDOW_MS) return false;
            seen.values().removeIf(at -> now - at > 2 * WINDOW_MS);
            if (seen.containsKey(id)) return false;
            if (seen.size() > 1024) return false;
            seen.put(id, now);
            return true;
        }
    }
}
