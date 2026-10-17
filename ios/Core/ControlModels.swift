import Foundation

public enum CameraLens: String, Codable, CaseIterable, Sendable {
    case rear, front
}

public struct StreamSelection: Equatable, Sendable {
    public var camera: CameraLens
    public var video: Bool
    public var microphone: Bool
    /// The Android rear camera's light. Only meaningful while the rear camera is live.
    public var torch: Bool
    public init(camera: CameraLens = .rear, video: Bool = false, microphone: Bool = false, torch: Bool = false) {
        self.camera = camera; self.video = video; self.microphone = microphone
        self.torch = torch && video && camera == .rear
    }
    public var hasInput: Bool { video || microphone }
    public var canUseTorch: Bool { video && camera == .rear }
    /// Switching lens or turning video off also turns the light off.
    public func togglingCamera(_ lens: CameraLens) -> StreamSelection {
        StreamSelection(camera: lens, video: !(video && camera == lens), microphone: microphone)
    }
    public func togglingListening() -> StreamSelection {
        StreamSelection(camera: camera, video: video, microphone: !microphone, torch: torch)
    }
    public func togglingTorch() -> StreamSelection {
        StreamSelection(camera: camera, video: video, microphone: microphone, torch: !torch)
    }
}

public struct SenderStatus: Decodable, Sendable {
    public let armed: Bool
    public let running: Bool
    public let viewer: Bool
    public let video: Bool
    public let microphone: Bool
    public let camera: String
    public let connection: String
    public let audioInputActive: Bool
    public let videoFrames: Int
    public let audioSamples: Int
    public let error: String
    /// What the sender's encoder is producing right now; absent from older senders.
    public let sendWidth: Int?, sendHeight: Int?, sendFps: Int?, targetKbps: Int?, qualityLimit: String?
    /// Whether the Android rear camera has a light; absent from older senders, which have no light control.
    public let torchAvailable: Bool?
    private enum CodingKeys: String, CodingKey {
        case armed, running, viewer, video, microphone, camera, connection, error, torchAvailable = "torch_available"
        case audioInputActive = "audio_input_active", videoFrames = "video_frames", audioSamples = "audio_samples"
        case sendWidth = "send_width", sendHeight = "send_height", sendFps = "send_fps", targetKbps = "target_kbps", qualityLimit = "quality_limit"
    }
}

/// Control and heartbeat replies describe the live session, without service readiness fields.
public struct SessionStatus: Decodable, Sendable {
    public let viewer: Bool
    public let video: Bool
    public let microphone: Bool
    public let camera: String
    /// Whether the light is actually on; absent from older senders.
    public let torch: Bool?
}

public struct StreamOffer: Encodable, Sendable {
    public let type = "offer"
    public let sdp: String
    public let camera: CameraLens
    public let video: Bool
    public let microphone: Bool
    /// STUN/TURN settings for a relayed session. Absent on Wi-Fi and Tailscale, where only private paths are used.
    public let iceServers: [RelayIceServer]?
    private enum CodingKeys: String, CodingKey { case type, sdp, camera, video, microphone, iceServers = "ice_servers" }
    public init(sdp: String, selection: StreamSelection, iceServers: [RelayIceServer]? = nil) {
        self.sdp = sdp; camera = selection.camera; video = selection.video; microphone = selection.microphone
        self.iceServers = iceServers
    }
}

public struct StreamAnswer: Decodable, Sendable {
    public let type: String
    public let sdp: String
    public let session: String
}

public struct SessionCommand: Encodable, Sendable {
    public let session: String
    public init(session: String) { self.session = session }
}

public struct InputCommand: Encodable, Sendable {
    public let session: String
    public let camera: CameraLens
    public let video: Bool
    public let microphone: Bool
    public let torch: Bool
    public init(session: String, selection: StreamSelection) {
        self.session = session; camera = selection.camera; video = selection.video; microphone = selection.microphone
        torch = selection.torch
    }
}

/// Pinch-to-zoom limits for the live preview: 1× (fit) to 4×, with panning kept inside the zoomed picture.
public enum PreviewZoom {
    public static let maximum: Double = 4
    /// Below this the preview snaps back to fit.
    public static let snapToFit: Double = 1.05

    public static func clampScale(_ scale: Double) -> Double { min(max(scale, 1), maximum) }

    /// Limits a pan so the zoomed picture always covers the preview area of the given size.
    public static func clampOffset(x: Double, y: Double, scale: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        let limitX = max(0, (scale - 1) * width / 2), limitY = max(0, (scale - 1) * height / 2)
        return (min(max(x, -limitX), limitX), min(max(y, -limitY), limitY))
    }
}
