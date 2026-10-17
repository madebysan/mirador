package com.san.androidsender;

import org.junit.Test;
import static org.junit.Assert.*;

public class SenderPolicyTest {
    @Test public void cellularInterfacesAreNotListeners() {
        assertTrue(SenderPolicy.isLocalInterface("wlan0"));
        assertTrue(SenderPolicy.isLocalInterface("tun0"));
        assertTrue(SenderPolicy.isLocalInterface("eth0"));
        assertFalse(SenderPolicy.isLocalInterface("rmnet_data1"));
        assertFalse(SenderPolicy.isLocalInterface("lo"));
        assertFalse(SenderPolicy.isLocalInterface(null));
    }
    @Test public void listenersStayOnPrivateNetworks() {
        assertTrue(SenderPolicy.isPrivateAddress("192.168.1.5"));
        assertTrue(SenderPolicy.isPrivateAddress("10.2.3.4"));
        assertTrue(SenderPolicy.isPrivateAddress("172.16.1.5"));
        assertTrue(SenderPolicy.isPrivateAddress("100.64.0.1"));
        assertTrue(SenderPolicy.isPrivateAddress("100.127.255.254"));
        assertFalse(SenderPolicy.isPrivateAddress("100.128.0.1"));
        assertFalse(SenderPolicy.isPrivateAddress("172.32.0.1"));
        assertFalse(SenderPolicy.isPrivateAddress("8.8.8.8"));
        assertFalse(SenderPolicy.isPrivateAddress("0.0.0.0"));
        assertFalse(SenderPolicy.isPrivateAddress("192.168.1.5.attacker.test"));
        assertFalse(SenderPolicy.isPrivateAddress("192.168.1.256"));
        assertTrue(SenderPolicy.isPrivateAddress("fd7a:115c:a1e0::1"));
        assertTrue(SenderPolicy.isPrivateAddress("fc00::2"));
        assertFalse(SenderPolicy.isPrivateAddress("2001:4860:4860::8888"));
        assertFalse(SenderPolicy.isPrivateAddress("fe80::1"));
        assertFalse(SenderPolicy.isPrivateAddress("::1"));
        assertFalse(SenderPolicy.isPrivateAddress("fd7a:example.test"));
    }
    @Test public void onlyExactBearerCredentialsAreAccepted() {
        String key = "a".repeat(43);
        assertTrue(SenderPolicy.authorized("Bearer " + key, key));
        assertFalse(SenderPolicy.authorized(null, key));
        assertFalse(SenderPolicy.authorized("Bearer " + key + "b", key));
        assertFalse(SenderPolicy.authorized("Bearer " + "b".repeat(43), key));
        assertFalse(SenderPolicy.authorized("Basic " + key, key));
        assertFalse(SenderPolicy.authorized("Bearer short", "short"));
    }
}
