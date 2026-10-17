package com.san.androidsender;

import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import org.junit.Test;

/** Vectors shared with the iPhone's RelayTests so both apps derive the same room and keys. */
public class RelayCryptoTest {
    private static final String TOKEN = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    private static final String REQUEST = "{\"id\":1,\"method\":\"GET\",\"path\":\"/v1/status\",\"body\":{},\"ts\":1700000000000}";
    private static final String SEALED = "AAECAwQFBgcICQoLk/bGtdN7KOV7ILAQn6vKV5FdPsV2OhiGRnouRM1HBZicxbZ30ITUpAvOvs8rqKroEK0u8kVcIBQh2mL7OJbsibsBWqpLWsI0tlQ37gwBm5xN7PnfFQHtnA==";

    @Test public void roomAndKeysMatchSharedVectors() throws Exception {
        RelayCrypto crypto = new RelayCrypto(TOKEN);
        assertEquals("4400acf0b5d78b5151e4bf0e28efd1fdfae4f8819be21bbfe8eba149210a9339", crypto.roomId);
        assertEquals("31405359255ee11de7dab703191a69ce97ba75b1b8016e14bf70afe32a9e1378", RelayCrypto.hex(crypto.viewerToSenderKeyForTest()));
        assertEquals("35908ef084d7cb5392f3714013a81f4509a9b7b762eb584363ed6968157c9525", RelayCrypto.hex(crypto.senderToViewerKeyForTest()));
    }

    @Test public void opensTheIPhonesSealedRequestVector() throws Exception {
        assertEquals(REQUEST, new String(new RelayCrypto(TOKEN).openRequest(SEALED), StandardCharsets.UTF_8));
    }

    @Test public void rejectsAlteredRequestsAndReflectedReplies() throws Exception {
        RelayCrypto crypto = new RelayCrypto(TOKEN);
        char[] altered = SEALED.toCharArray(); altered[30] = altered[30] == 'A' ? 'B' : 'A';
        assertThrows(Exception.class, () -> crypto.openRequest(new String(altered)));
        // A reply reflected back by the relay is sealed with the other direction's key and must not open.
        String reply = crypto.sealReply(REQUEST.getBytes(StandardCharsets.UTF_8));
        assertThrows(Exception.class, () -> crypto.openRequest(reply));
    }

    @Test public void replayGuardRejectsStaleAndRepeatedRequests() {
        RelayCrypto.ReplayGuard guard = new RelayCrypto.ReplayGuard();
        long now = 1_700_000_000_000L;
        assertTrue(guard.accept("a", now, now));
        assertFalse(guard.accept("a", now, now + 1000));
        assertFalse(guard.accept("b", now - 121_000, now));
        assertFalse(guard.accept("", now, now));
        assertTrue(guard.accept("b", now, now));
    }
}
