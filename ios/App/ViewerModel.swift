import Foundation
import Observation
import UIKit
import AVFoundation
import Network
@preconcurrency import WebRTC

@MainActor @Observable final class ViewerModel {
    enum Phase: Equatable { case unpaired, checking, ready, connecting, live, unavailable }
    var phase: Phase = .unpaired
    var selection = StreamSelection()
    var message = "Pair your Android phone to begin."
    var errorMessage: String?
    var busy = false
    var videoTrack: RTCVideoTrack?
    var receivedVideoFrames = 0
    var frameSize = ""
    var paired = false
    /// Whether the paired Android phone can turn on its rear-camera light.
    var torchAvailable = false
    /// Name of the network path carrying control traffic, for example "Wi-Fi" or "Tailscale".
    var linkName = ""
    /// The selection that was live when the connection last dropped, offered as a manual Reconnect.
    var reconnectSelection: StreamSelection?
    /// When the current session first reached live, for the elapsed-time readout.
    var liveSince: Date?
    @ObservationIgnored private var pairing: PairingPayload?
    @ObservationIgnored private var client: PinnedSenderClient?
    /// How the viewer reaches Android: a private endpoint on Wi-Fi or Tailscale, or the internet relay.
    enum Route: Equatable { case direct(URL), relay }
    @ObservationIgnored private var route: Route? {
        didSet {
            switch route {
            case .direct(let url): linkName = NetworkPolicy.linkName(url)
            case .relay: linkName = "Internet"
            case nil: linkName = ""
            }
        }
    }
    @ObservationIgnored private var relay: RelayClient?
    /// The relay address baked into this build, or nil when the relay is not configured.
    @ObservationIgnored private let relayBase = RelayClient.validatedBase(Bundle.main.object(forInfoDictionaryKey: "AVRelayURL") as? String)
    /// What the relay last said about Android: online, offline, or nil if the relay itself was unreachable.
    @ObservationIgnored private var relayPresence: Bool?
    @ObservationIgnored private var receiver: LiveReceiver?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var interruption: NSObjectProtocol?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var lastPath: String?

    init() {
        pairing = PairingStore.load()
        if let pairing { paired = true; client = PinnedSenderClient(pairing: pairing); phase = .checking; makeRelay(for: pairing) }
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.selection.microphone else { return }
                // Only listening uses the audio session; a live camera preview can continue.
                self.listening()
                self.errorMessage = "Listening was interrupted. Start it again when you’re ready."
            }
        }
        // Joining or leaving Wi-Fi, or turning Tailscale on or off, changes which Android address can answer.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let summary = path.status == .satisfied
                ? path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",") : "offline"
            Task { @MainActor in self?.networkChanged(summary) }
        }
        pathMonitor.start(queue: .main)
    }

    private func makeRelay(for pairing: PairingPayload) {
        relay?.close(); relay = nil
        guard let relayBase, let keys = try? RelayKeys(token: pairing.token) else { return }
        relay = RelayClient(base: relayBase, keys: keys)
    }

    /// Closes the relay connection while the app is in the background; it reopens on the next check.
    func suspendRelay() { relay?.close() }

    private func networkChanged(_ summary: String) {
        defer { lastPath = summary }
        guard let previous = lastPath, previous != summary else { return }
        refreshIfIdle()
    }

    /// Re-checks the sender when nothing is live. Never starts camera or microphone input.
    func refreshIfIdle() {
        guard paired, !selection.hasInput, !busy, phase != .checking else { return }
        #if DEBUG
        if designDemo { return }
        #endif
        route = nil
        Task { await probe() }
    }

    /// Explains an unreachable sender in terms of the two supported paths.
    private func unreachableMessage() -> String {
        if relay != nil {
            switch relayPresence {
            case false?: return "Mirador on Android is offline. Check that it shows Ready and that the Android phone has Wi-Fi or mobile data."
            case nil: return "This iPhone can’t reach the internet relay. Check Wi-Fi or mobile data."
            case true?: return "Mirador on Android didn’t answer through the internet relay. Try again in a moment."
            }
        }
        guard pairing?.endpoints.contains(where: { NetworkPolicy.isTailscaleAddress($0.host ?? "") }) == true else {
            return "Android isn’t answering on this Wi-Fi, and this pairing has no Tailscale address. Turn on Tailscale on Android, then pair again to connect from other networks."
        }
        return NetworkPolicy.deviceHasTailscaleAddress()
            ? "Android isn’t answering over Wi-Fi or Tailscale. Check that Mirador is open on Android and Tailscale is on for the Android phone."
            : "Android isn’t answering on this Wi-Fi. Away from the Android’s network, turn on Tailscale on this iPhone."
    }

    func prepare() async {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--design-demo") {
            applyDesignDemo(index + 1 < arguments.count ? arguments[index + 1] : "live")
            if arguments.contains("--design-landscape"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            return
        }
        if CommandLine.arguments.contains("--pairing-bootstrap") {
            let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PairingBootstrap.json")
            if let data = try? Data(contentsOf: file) {
                acceptPairing(data); try? FileManager.default.removeItem(at: file); return
            }
        }
        #endif
        if paired { await probe() }
    }

    func acceptPairing(_ data: Data) {
        do {
            let value = try PairingPayload.parse(data)
            stop(); try PairingStore.save(value)
            client?.close(); pairing = value; client = PinnedSenderClient(pairing: value); makeRelay(for: value)
            paired = true; phase = .checking; errorMessage = nil; route = nil; reconnectSelection = nil
            Task { await probe() }
        } catch { errorMessage = PairingError.invalidCode.localizedDescription }
    }

    private enum ProbeResult: Sendable { case reached(Route, SenderStatus), relayPresence(Bool?) }

    /// Asks every private endpoint and the relay at once. A private path wins if it answers; the relay is used
    /// only after giving private paths a short head start, so home Wi-Fi and Tailscale keep priority.
    private func firstReachableRoute() async -> (route: Route, status: SenderStatus)? {
        guard let pairing, let client else { return nil }
        let relay = self.relay
        let outcome: (Route, SenderStatus)? = await withTaskGroup(of: ProbeResult?.self) { group in
            for address in pairing.endpoints {
                group.addTask { (try? await client.status(at: address)).map { .reached(.direct(address), $0) } }
            }
            if let relay {
                group.addTask {
                    let present = await relay.senderPresent()
                    guard present == true else { return .relayPresence(present) }
                    do { try await Task.sleep(for: .milliseconds(1500)) } catch { return nil }
                    guard let status = try? await relay.status() else { return .relayPresence(true) }
                    return .reached(.relay, status)
                }
            }
            var winner: (Route, SenderStatus)?
            for await result in group {
                switch result {
                case .reached(let route, let status)?: winner = (route, status); group.cancelAll()
                case .relayPresence(let present)?: await MainActor.run { self.relayPresence = present }
                case nil: break
                }
                if winner != nil { break }
            }
            return winner
        }
        if outcome?.0 == .relay { relayPresence = true }
        return outcome.map { (route: $0.0, status: $0.1) }
    }

    func probe() async {
        guard pairing != nil, client != nil else { return }
        let current = generation
        phase = .checking; message = "Checking Android…"
        relayPresence = nil
        let result = await firstReachableRoute()
        guard current == generation, !selection.hasInput else { return }
        guard let result else {
            route = nil
            phase = .unavailable; message = "Android unavailable"
            errorMessage = unreachableMessage()
            return
        }
        route = result.route
        torchAvailable = result.status.torchAvailable ?? false
        if result.status.armed && result.status.running {
            phase = .ready; message = "Android ready via \(linkName)"; errorMessage = nil
        } else {
            phase = .unavailable; message = "Enable Mirador on Android"
            errorMessage = "Open Mirador on the Android phone and tap Enable."
        }
    }

    private func post<Response: Decodable & Sendable, Body: Encodable & Sendable>(via route: Route, _ path: String, _ body: Body) async throws -> Response {
        switch route {
        case .direct(let url):
            guard let client else { throw SenderClientError.network }
            return try await client.post(at: url, path: path, body: body)
        case .relay:
            guard let relay else { throw SenderClientError.network }
            return try await relay.post(path: path, body: body)
        }
    }

    /// Sends a session request, switching once to another reachable route if the current one is down.
    private func send<Response: Decodable & Sendable, Body: Encodable & Sendable>(_ path: String, _ body: Body) async throws -> Response {
        guard let route else { throw SenderClientError.network }
        do { return try await post(via: route, path, body) }
        catch SenderClientError.network {
            guard let next = await firstReachableRoute() else { throw SenderClientError.network }
            self.route = next.route
            return try await post(via: next.route, path, body)
        }
    }

    func camera(_ lens: CameraLens) { update(selection.togglingCamera(lens)) }
    func listening() { update(selection.togglingListening()) }
    func light() {
        guard selection.canUseTorch, torchAvailable else { return }
        #if DEBUG
        if designDemo { selection = selection.togglingTorch(); return }
        #endif
        update(selection.togglingTorch())
    }
    func reconnect() {
        guard let previous = reconnectSelection else { return }
        reconnectSelection = nil; update(previous)
    }

    private func update(_ requested: StreamSelection) {
        guard !busy, paired else { return }
        // A new session starts with the light off; it can be turned on once the rear camera is live.
        let next = sessionID == nil
            ? StreamSelection(camera: requested.camera, video: requested.video, microphone: requested.microphone) : requested
        if !next.hasInput { stop(); return }
        busy = true; errorMessage = nil
        let current = generation
        operation = Task { [self] in
            defer { if current == generation { busy = false; operation = nil } }
            do {
                if sessionID == nil {
                    if route == nil { await probe() }
                    guard let route, current == generation else { throw SenderClientError.network }
                    let relayed = route == .relay
                    let iceServers = relayed ? try await relay?.iceServers() ?? [] : []
                    guard current == generation, !Task.isCancelled else { throw CancellationError() }
                    selection = next; phase = .connecting; message = "Connecting live input…"
                    let live = LiveReceiver()
                    receiver = live
                    live.onVideoTrack = { [weak self] track in self?.videoTrack = track }
                    live.onVideoFrame = { [weak self] width, height in
                        guard let self, self.generation == current else { return }
                        self.receivedVideoFrames += 1
                        let size = "\(width) × \(height)"
                        if self.frameSize != size, width > 0, height > 0 {
                            self.frameSize = size
                        }
                    }
                    live.onConnection = { [weak self] connected in
                        guard let self, self.generation == current else { return }
                        if connected {
                            if self.liveSince == nil { self.liveSince = .now }
                            self.phase = .live; self.message = "Live from Android via \(self.linkName)"; self.reconnectSelection = nil
                        } else if self.phase == .live {
                            self.phase = .connecting; self.message = "Reconnecting…"
                        }
                    }
                    live.onFailure = { [weak self] in self?.failed("Live input disconnected.", generation: current) }
                    let sdp = try await live.makeOffer(iceServers: iceServers, relayed: relayed)
                    guard current == generation, !Task.isCancelled else { throw CancellationError() }
                    // The offer is not retried on another path: a timed-out offer may already hold the sender's single viewer slot.
                    let answer: StreamAnswer = try await post(via: route, "/v1/offer",
                        StreamOffer(sdp: sdp, selection: next, iceServers: relayed ? iceServers : nil))
                    guard current == generation, !Task.isCancelled else {
                        let _: SessionStatus? = try? await post(via: route, "/v1/disconnect", SessionCommand(session: answer.session))
                        throw CancellationError()
                    }
                    sessionID = answer.session
                    try await live.accept(answer)
                    live.setListening(next.microphone)
                    startHeartbeat(generation: current)
                } else if let sessionID {
                    if !next.microphone { receiver?.setListening(false) }
                    let status: SessionStatus = try await send("/v1/control", InputCommand(session: sessionID, selection: next))
                    guard current == generation else { return }
                    selection = next; selection.torch = next.torch && status.torch == true
                    receiver?.setListening(next.microphone)
                    if next.torch && !selection.torch { errorMessage = "The Android phone’s light didn’t turn on." }
                }
                UIApplication.shared.isIdleTimerDisabled = next.hasInput
            } catch is CancellationError { }
            catch {
                if case SenderClientError.network = error {
                    route = nil
                    failed(unreachableMessage(), generation: current)
                } else {
                    failed((error as? LocalizedError)?.errorDescription ?? "The live input could not start. Try again.", generation: current)
                }
            }
        }
    }

    private func startHeartbeat(generation current: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.generation == current, let session = self.sessionID else { return }
                do {
                    let status: SessionStatus = try await self.send("/v1/ping", SessionCommand(session: session))
                    if !status.viewer { throw SenderClientError.invalidResponse }
                } catch { self.failed("Android disconnected. Check the connection and try again.", generation: current); return }
            }
        }
    }

    private func failed(_ text: String, generation current: Int) {
        guard generation == current else { return }
        let previous = selection
        stop()
        // Re-check every path before the next attempt; the one that failed may be gone.
        route = nil
        reconnectSelection = previous.hasInput ? previous : nil
        phase = .unavailable; errorMessage = text; message = "Connection stopped"
    }

    func stop() {
        generation += 1
        operation?.cancel(); operation = nil; heartbeat?.cancel(); heartbeat = nil
        receiver?.close(); receiver = nil; videoTrack = nil
        let oldSession = sessionID; sessionID = nil
        if let oldSession, let route {
            Task { let _: SessionStatus? = try? await post(via: route, "/v1/disconnect", SessionCommand(session: oldSession)) }
        }
        selection.video = false; selection.microphone = false; selection.torch = false; busy = false; reconnectSelection = nil
        receivedVideoFrames = 0; frameSize = ""; liveSince = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = paired ? .ready : .unpaired
        message = paired ? "Choose a camera or start listening." : "Pair your Android phone to begin."
    }

    func forget() {
        stop(); PairingStore.forget(); client?.close(); client = nil; relay?.close(); relay = nil; pairing = nil; route = nil
        paired = false; phase = .unpaired; message = "Pair your Android phone to begin."
    }

    /// Recent playback peak (0...1) of the Android microphone, for the level meter.
    func audioLevel() -> Float {
        #if DEBUG
        if designDemo, selection.microphone {
            let time = Date.now.timeIntervalSinceReferenceDate
            return Float(0.05 + 0.05 * abs(sin(time * 2.3)) + 0.03 * abs(sin(time * 7.1)))
        }
        #endif
        guard selection.microphone else { return 0 }
        return receiver?.audio.peakLevel ?? 0
    }

    #if DEBUG
    @ObservationIgnored private var designDemo = false
    /// Debug-only static states for checking the layout in the simulator. Starts no network or media.
    func applyDesignDemo(_ variant: String) {
        designDemo = true; paired = true
        switch variant {
        case "offline":
            phase = .unavailable; message = "Connection stopped"
            errorMessage = "Android disconnected. Check the connection and try again."
            reconnectSelection = StreamSelection(camera: .rear, video: true, microphone: true)
        case "ready":
            phase = .ready; linkName = "Wi-Fi"; message = "Android ready via Wi-Fi"
        default:
            phase = .live; selection = StreamSelection(camera: .rear, video: true, microphone: true)
            linkName = "Tailscale"; message = "Live from Android via Tailscale"; torchAvailable = true
            frameSize = "720 × 1280"; receivedVideoFrames = 1; liveSince = Date(timeIntervalSinceNow: -754)
        }
    }
    #endif

    func diagnostics() async -> [String: Any] {
        var metrics: [String: Any] = await receiver?.metrics() ?? [:]
        metrics["video_frames_received"] = receivedVideoFrames
        metrics["video_requested"] = selection.video; metrics["microphone_requested"] = selection.microphone
        metrics["phase"] = String(describing: phase)
        metrics["link"] = linkName
        #if DEBUG
        metrics["network_failure_codes"] = client?.diagnosticFailureCodes ?? [:]
        #endif
        return metrics
    }
}
