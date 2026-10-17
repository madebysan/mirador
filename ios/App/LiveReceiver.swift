import Foundation
@preconcurrency import WebRTC

enum ReceiverError: Error { case negotiation, closed }

@MainActor final class LiveReceiver: NSObject {
    let audio = PlaybackAudioDevice()
    private var factory: RTCPeerConnectionFactory!
    private var peer: RTCPeerConnection?
    private var gathering: CheckedContinuation<Void, Error>?
    private var gatheringTimeout: Task<Void, Never>?
    private var disconnectGrace: Task<Void, Never>?
    /// How long an ICE "disconnected" state may last before it is treated as a failure.
    static let disconnectGraceSeconds = 8
    private var frameCounter: FrameCounter?
    private var relayed = false
    private(set) var videoTrack: RTCVideoTrack?
    var onVideoTrack: ((RTCVideoTrack?) -> Void)?
    var onVideoFrame: ((Int, Int) -> Void)?
    var onConnection: ((Bool) -> Void)?
    var onFailure: (() -> Void)?

    override init() {
        super.init()
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(), audioDevice: audio)
        audio.onFailure = { [weak self] in Task { @MainActor in self?.onFailure?() } }
    }

    /// `relayed` sessions use the relay's STUN/TURN servers and keep public candidates; private sessions keep only
    /// Wi-Fi and Tailscale addresses.
    func makeOffer(iceServers: [RelayIceServer] = [], relayed: Bool = false) async throws -> String {
        self.relayed = relayed
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw ReceiverError.negotiation
        }
        peer = connection
        for media in [RTCRtpMediaType.video, .audio] {
            let receive = RTCRtpTransceiverInit(); receive.direction = .recvOnly
            _ = connection.addTransceiver(of: media, init: receive)
        }
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if error != nil || description == nil { continuation.resume(throwing: ReceiverError.negotiation) }
                else { continuation.resume(returning: description!) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if error != nil { continuation.resume(throwing: ReceiverError.negotiation) }
                else { continuation.resume() }
            }
        }
        if connection.iceGatheringState != .complete {
            try await withCheckedThrowingContinuation { continuation in
                gathering = continuation
                let relayed = self.relayed
                gatheringTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(relayed ? 8 : 6))
                    guard !Task.isCancelled, let self, let pending = self.gathering else { return }
                    // Slow TURN allocations should not block a relayed session; offer what has been gathered.
                    self.gathering = nil
                    if relayed { pending.resume() } else { pending.resume(throwing: ReceiverError.negotiation) }
                }
            }
        }
        guard peer === connection, let offer = connection.localDescription else { throw ReceiverError.closed }
        return relayed ? offer.sdp : NetworkPolicy.privateCandidates(offer.sdp)
    }

    func accept(_ answer: StreamAnswer) async throws {
        guard let peer, answer.type == "answer" else { throw ReceiverError.negotiation }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: relayed ? answer.sdp : NetworkPolicy.privateCandidates(answer.sdp))) { error in
                if error != nil { continuation.resume(throwing: ReceiverError.negotiation) }
                else { continuation.resume() }
            }
        }
        attachTracks()
    }

    func setListening(_ enabled: Bool) { audio.setListening(enabled) }

    private func attachTracks() {
        guard let track = peer?.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first,
              videoTrack !== track else { return }
        videoTrack = track
        let counter = FrameCounter { [weak self] width, height in
            Task { @MainActor in self?.onVideoFrame?(width, height) }
        }
        frameCounter = counter; track.add(counter); onVideoTrack?(track)
    }

    func close() {
        gatheringTimeout?.cancel(); gatheringTimeout = nil
        disconnectGrace?.cancel(); disconnectGrace = nil
        gathering?.resume(throwing: ReceiverError.closed); gathering = nil
        if let counter = frameCounter { videoTrack?.remove(counter) }
        videoTrack = nil; frameCounter = nil; onVideoTrack?(nil)
        audio.setListening(false)
        peer?.close(); peer = nil
    }

    func metrics() async -> [String: Int] {
        guard let peer else { return [:] }
        let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
            peer.statistics { continuation.resume(returning: $0) }
        }
        var values = ["audio_rendered_samples": Int(audio.renderedSamples), "local_microphone_recording": audio.isRecording ? 1 : 0]
        for stat in report.statistics.values where stat.type == "inbound-rtp" {
            let kind = stat.values["kind"] as? String ?? stat.values["mediaType"] as? String ?? "media"
            for key in ["packetsReceived", "framesDecoded", "bytesReceived"] {
                if let value = stat.values[key] as? NSNumber { values[kind + "_" + key] = value.intValue }
            }
        }
        return values
    }
}

extension LiveReceiver: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { Task { @MainActor [weak self] in self?.attachTracks() } }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .connected, .completed:
                self.disconnectGrace?.cancel(); self.disconnectGrace = nil
                self.onConnection?(true)
            case .disconnected:
                // WebRTC often recovers from a brief "disconnected"; only give up after the grace period.
                guard self.disconnectGrace == nil else { return }
                self.onConnection?(false)
                self.disconnectGrace = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.disconnectGraceSeconds))
                    guard !Task.isCancelled, let self, self.peer === peerConnection else { return }
                    self.disconnectGrace = nil; self.onFailure?()
                }
            case .failed:
                self.disconnectGrace?.cancel(); self.disconnectGrace = nil
                self.onFailure?()
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection, newState == .complete else { return }
            self.gatheringTimeout?.cancel(); self.gatheringTimeout = nil
            self.gathering?.resume(); self.gathering = nil
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak self] in self?.attachTracks() }
    }
}

private final class FrameCounter: NSObject, RTCVideoRenderer {
    private let received: (Int, Int) -> Void
    init(received: @escaping (Int, Int) -> Void) { self.received = received }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        // Report the displayed size: a quarter-turn rotation swaps the buffer's width and height.
        let turned = frame.rotation == ._90 || frame.rotation == ._270
        received(Int(turned ? frame.height : frame.width), Int(turned ? frame.width : frame.height))
    }
}
