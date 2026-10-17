package com.san.androidsender;

import org.junit.Test;
import static org.junit.Assert.*;

public class StreamContractTest {
    @Test public void mediaCandidatesStayOnPrivateNetworks() {
        String sdp = "v=0\r\n"
                + "a=candidate:1 1 udp 100 192.168.1.2 5000 typ host\r\n"
                + "a=candidate:2 1 udp 90 fd7a:115c:a1e0::1 5001 typ host\r\n"
                + "a=candidate:3 1 udp 80 8.8.8.8 5002 typ srflx\r\n"
                + "a=candidate:4 1 udp 70 hidden.local 5003 typ host\r\n"
                + "a=end-of-candidates\r\n";
        String filtered = StreamEngine.privateCandidates(sdp);
        assertTrue(filtered.contains("192.168.1.2"));
        assertTrue(filtered.contains("fd7a:115c:a1e0::1"));
        assertTrue(filtered.contains("a=end-of-candidates"));
        assertFalse(filtered.contains("8.8.8.8"));
        assertFalse(filtered.contains("hidden.local"));
    }
}
