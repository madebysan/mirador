import XCTest
@testable import ViewerCore

final class ControlTests: XCTestCase {
    func testSessionRepliesDoNotRequireServiceOnlyFields() throws {
        // /control, /ping and /disconnect return engine status, unlike GET /status.
        let response = Data("""
        {"viewer":true,"video":true,"microphone":false,"camera":"rear",
         "connection":"CONNECTED","audio_input_active":false,"video_frames":12,
         "audio_samples":0,"error":""}
        """.utf8)
        let status = try JSONDecoder().decode(SessionStatus.self, from: response)
        XCTAssertTrue(status.viewer)
        XCTAssertTrue(status.video)
        XCTAssertFalse(status.microphone)
        XCTAssertEqual(status.camera, "rear")
    }

    func testLensActionsPreserveListeningAndCanTurnVideoOff() {
        let microphoneOnly = StreamSelection(microphone: true)
        let rear = microphoneOnly.togglingCamera(.rear)
        XCTAssertTrue(rear.video); XCTAssertTrue(rear.microphone)
        let front = rear.togglingCamera(.front)
        XCTAssertEqual(front.camera, .front); XCTAssertTrue(front.video); XCTAssertTrue(front.microphone)
        let hidden = front.togglingCamera(.front)
        XCTAssertFalse(hidden.video); XCTAssertTrue(hidden.microphone); XCTAssertTrue(hidden.hasInput)
        XCTAssertFalse(hidden.togglingListening().hasInput)
    }

    func testListeningDoesNotChangeSelectedCameraOrVideo() {
        let cameraOnly = StreamSelection(camera: .front, video: true)
        let listening = cameraOnly.togglingListening()
        XCTAssertTrue(listening.video); XCTAssertTrue(listening.microphone)
        XCTAssertEqual(listening.camera, .front)
        XCTAssertEqual(listening.togglingListening(), cameraOnly)
    }

    func testOffersMatchAndroidContractWithoutSenderTracks() throws {
        let offer = StreamOffer(sdp: "receive-only-example", selection: StreamSelection(camera: .rear, video: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "offer")
        XCTAssertEqual(object["camera"] as? String, "rear")
        XCTAssertEqual(object["video"] as? Bool, true)
        XCTAssertEqual(object["microphone"] as? Bool, false)
    }

    func testLinkNamesDistinguishTailscaleFromLocalWiFi() throws {
        XCTAssertEqual(NetworkPolicy.linkName(try XCTUnwrap(URL(string: "https://100.101.102.103:8443"))), "Tailscale")
        XCTAssertEqual(NetworkPolicy.linkName(try XCTUnwrap(URL(string: "https://[fd7a:115c:a1e0::1234]:8443"))), "Tailscale")
        XCTAssertEqual(NetworkPolicy.linkName(try XCTUnwrap(URL(string: "https://192.168.1.2:8443"))), "Wi-Fi")
        XCTAssertEqual(NetworkPolicy.linkName(try XCTUnwrap(URL(string: "https://10.0.0.4:8443"))), "Wi-Fi")
        XCTAssertEqual(NetworkPolicy.linkName(try XCTUnwrap(URL(string: "https://[fd12:3456::1]:8443"))), "Wi-Fi")
        XCTAssertFalse(NetworkPolicy.isTailscaleAddress("100.128.0.1"))
    }

    func testOnlyTunnelInterfacesCountAsThisDevicesTailscale() {
        XCTAssertTrue(NetworkPolicy.isTailscaleInterface(name: "utun4", address: "100.101.102.103"))
        XCTAssertTrue(NetworkPolicy.isTailscaleInterface(name: "utun4", address: "fd7a:115c:a1e0::1234"))
        // A cellular carrier's CGNAT address shares 100.64.0.0/10 but is not Tailscale.
        XCTAssertFalse(NetworkPolicy.isTailscaleInterface(name: "pdp_ip0", address: "100.77.1.2"))
        XCTAssertFalse(NetworkPolicy.isTailscaleInterface(name: "en0", address: "192.168.1.20"))
    }

    func testMediaCandidatesExcludeInternetAndMDNS() {
        let sdp = "v=0\r\na=candidate:1 1 udp 100 192.168.1.2 5000 typ host\r\n"
            + "a=candidate:2 1 udp 90 fd7a:115c:a1e0::1 5001 typ host\r\n"
            + "a=candidate:3 1 udp 80 8.8.8.8 5002 typ srflx\r\n"
            + "a=candidate:4 1 udp 70 private.local 5003 typ host\r\na=end-of-candidates\r\n"
        let filtered = NetworkPolicy.privateCandidates(sdp)
        XCTAssertTrue(filtered.contains("192.168.1.2")); XCTAssertTrue(filtered.contains("fd7a:115c:a1e0::1"))
        XCTAssertFalse(filtered.contains("8.8.8.8")); XCTAssertFalse(filtered.contains("private.local"))
        XCTAssertTrue(filtered.contains("a=end-of-candidates"))
    }

    func testLightFollowsTheRearCamera() throws {
        let rear = StreamSelection(microphone: true).togglingCamera(.rear)
        XCTAssertTrue(rear.canUseTorch)
        let lit = rear.togglingTorch()
        XCTAssertTrue(lit.torch)
        XCTAssertTrue(lit.togglingListening().torch, "Listening changes keep the light")
        XCTAssertFalse(lit.togglingCamera(.front).torch, "Switching lens turns the light off")
        XCTAssertFalse(lit.togglingCamera(.rear).torch, "Turning video off turns the light off")
        XCTAssertFalse(StreamSelection(camera: .front, video: true).togglingTorch().torch, "The front camera has no light")
        let command = try JSONSerialization.jsonObject(with: JSONEncoder().encode(InputCommand(session: "s", selection: lit))) as? [String: Any]
        XCTAssertEqual(command?["torch"] as? Bool, true)
    }

    func testOlderSendersWithoutALightStillDecode() throws {
        let reply = try JSONDecoder().decode(SessionStatus.self, from: Data(#"{"viewer":true,"video":true,"microphone":false,"camera":"rear"}"#.utf8))
        XCTAssertNil(reply.torch)
        let lit = try JSONDecoder().decode(SessionStatus.self, from: Data(#"{"viewer":true,"video":true,"microphone":false,"camera":"rear","torch":true}"#.utf8))
        XCTAssertEqual(lit.torch, true)
    }

    func testZoomStaysBetweenFitAndFourTimesAndPanStaysInsideThePicture() {
        XCTAssertEqual(PreviewZoom.clampScale(0.5), 1)
        XCTAssertEqual(PreviewZoom.clampScale(9), 4)
        let fit = PreviewZoom.clampOffset(x: 40, y: -40, scale: 1, width: 300, height: 400)
        XCTAssertEqual(fit.x, 0); XCTAssertEqual(fit.y, 0)
        let zoomed = PreviewZoom.clampOffset(x: 500, y: -50, scale: 2, width: 300, height: 400)
        XCTAssertEqual(zoomed.x, 150); XCTAssertEqual(zoomed.y, -50)
    }
}
