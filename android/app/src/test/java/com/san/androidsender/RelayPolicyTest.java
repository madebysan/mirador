package com.san.androidsender;

import static org.junit.Assert.*;
import org.junit.Test;

public class RelayPolicyTest {
    @Test public void acceptsOnlyCloudflareStunAndTurn() {
        assertTrue(SenderPolicy.isRelayIceUrl("stun:stun.cloudflare.com:3478"));
        assertTrue(SenderPolicy.isRelayIceUrl("turn:turn.cloudflare.com:3478?transport=udp"));
        assertTrue(SenderPolicy.isRelayIceUrl("turns:turn.cloudflare.com:443?transport=tcp"));
        assertFalse(SenderPolicy.isRelayIceUrl("turn:evil.example.com:3478?transport=udp"));
        assertFalse(SenderPolicy.isRelayIceUrl("turn:turn.cloudflare.com.evil.example:3478"));
        assertFalse(SenderPolicy.isRelayIceUrl("stun:stun.cloudflare.com:3478 extra"));
        assertFalse(SenderPolicy.isRelayIceUrl(null));
    }

    @Test public void recognisesTailscaleAddressesOnly() {
        assertTrue(SenderPolicy.isTailscaleAddress("100.101.102.103"));
        assertTrue(SenderPolicy.isTailscaleAddress("fd7a:115c:a1e0::1234"));
        assertFalse(SenderPolicy.isTailscaleAddress("100.128.0.1"));
        assertFalse(SenderPolicy.isTailscaleAddress("192.168.1.20"));
        assertFalse(SenderPolicy.isTailscaleAddress("fd12:3456::1"));
    }
}
