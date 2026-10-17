import XCTest
@testable import ViewerCore

final class PairingTests: XCTestCase {
    private let token = String(repeating: "A", count: 43)
    private let pin = String(repeating: "a", count: 64)

    private func payload(endpoints: [String], token: String? = nil, pin: String? = nil, protocolName: String = "android-sender-v1") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["protocol": protocolName, "endpoints": endpoints,
            "token": token ?? self.token, "certificate_sha256": pin ?? self.pin])
    }

    func testReadsAndroidPrivatePairingContract() throws {
        let pairing = try PairingPayload.parse(payload(endpoints: ["https://192.168.1.2:8443", "https://[fd7a:115c:a1e0::1]:8443"]))
        XCTAssertEqual(pairing.endpoints.count, 2)
        XCTAssertEqual(pairing.token, token)
        XCTAssertEqual(pairing.certificatePin.count, 32)
    }

    func testAcceptsRelayOnlyPairingWithoutPrivateEndpoints() throws {
        // A transmitter on mobile data has no Wi-Fi or Tailscale address; the relay still reaches it.
        XCTAssertEqual(try PairingPayload.parse(payload(endpoints: [])).endpoints.count, 0)
    }

    func testRejectsPublicOrCredentialBearingEndpoints() throws {
        for endpoint in ["http://192.168.1.2:8443", "https://example.com:8443", "https://8.8.8.8:8443",
                         "https://user:secret@192.168.1.2:8443", "https://192.168.1.2:8443/?token=example",
                         "https://192.168.1.2:8443/#fragment", "https://192.168.1.2:8443/another-api",
                         "https://127.0.0.1:8443", "https://[fe80::1]:8443", "https://192.168.1.2:443"] {
            XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: [endpoint])), endpoint)
        }
    }

    func testRejectsMalformedCredentialsAndUnknownProtocols() throws {
        let endpoint = ["https://192.168.1.2:8443"]
        XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: endpoint, token: "short")))
        XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: endpoint, token: String(repeating: "!", count: 43))))
        XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: endpoint, pin: String(repeating: "z", count: 64))))
        XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: endpoint, protocolName: "another-protocol")))
        XCTAssertThrowsError(try PairingPayload.parse(payload(endpoints: endpoint + endpoint)))
    }
}
