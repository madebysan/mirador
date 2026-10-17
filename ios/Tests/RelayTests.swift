import XCTest
import CryptoKit
@testable import ViewerCore

/// Vectors shared with the Android sender's RelayCryptoTest so both apps derive the same room and keys.
final class RelayTests: XCTestCase {
    private let token = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }

    func testRoomAndKeysMatchSharedVectors() throws {
        let keys = try RelayKeys(token: token)
        XCTAssertEqual(keys.roomID, "4400acf0b5d78b5151e4bf0e28efd1fdfae4f8819be21bbfe8eba149210a9339")
        XCTAssertEqual(hex(keys.viewerToSender), "31405359255ee11de7dab703191a69ce97ba75b1b8016e14bf70afe32a9e1378")
        XCTAssertEqual(hex(keys.senderToViewer), "35908ef084d7cb5392f3714013a81f4509a9b7b762eb584363ed6968157c9525")
    }

    func testSealedRequestMatchesSharedVector() throws {
        let keys = try RelayKeys(token: token)
        let plain = Data(#"{"id":1,"method":"GET","path":"/v1/status","body":{},"ts":1700000000000}"#.utf8)
        let box = try keys.sealForSender(plain, nonce: AES.GCM.Nonce(data: Data(0..<12)))
        XCTAssertEqual(box, "AAECAwQFBgcICQoLk/bGtdN7KOV7ILAQn6vKV5FdPsV2OhiGRnouRM1HBZicxbZ30ITUpAvOvs8rqKroEK0u8kVcIBQh2mL7OJbsibsBWqpLWsI0tlQ37gwBm5xN7PnfFQHtnA==")
    }

    func testRepliesMustComeFromTheSenderDirection() throws {
        let keys = try RelayKeys(token: token)
        // A request reflected back by the relay must not open as a reply.
        let reflected = try keys.sealForSender(Data("{}".utf8))
        XCTAssertThrowsError(try keys.openFromSender(reflected))
        let reply = try XCTUnwrap(AES.GCM.seal(Data("{}".utf8), using: keys.senderToViewer).combined).base64EncodedString()
        XCTAssertEqual(try keys.openFromSender(reply), Data("{}".utf8))
    }

    func testOnlyHTTPSRelaysAreAccepted() {
        XCTAssertNotNil(RelayClient.validatedBase("https://relay.example.workers.dev"))
        XCTAssertNil(RelayClient.validatedBase("http://relay.example.workers.dev"))
        XCTAssertNotNil(RelayClient.validatedBase("http://127.0.0.1:8787"))
        XCTAssertNil(RelayClient.validatedBase(""))
        XCTAssertNil(RelayClient.validatedBase(nil))
    }
}
