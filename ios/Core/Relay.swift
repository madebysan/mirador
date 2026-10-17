import Foundation
import CryptoKit

/// Keys for the internet relay, all derived from the existing pairing secret so no new pairing is needed.
/// The relay sees only the room ID; requests and replies are sealed with direction-specific AES-GCM keys,
/// so it cannot read them, forge them or reflect one direction into the other.
public struct RelayKeys: Sendable {
    public let roomID: String
    let viewerToSender: SymmetricKey
    let senderToViewer: SymmetricKey

    public init(token: String) throws {
        let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let secret = Data(base64Encoded: base64), secret.count == 32 else { throw PairingError.invalidCode }
        let key = SymmetricKey(data: secret)
        roomID = Data(HMAC<SHA256>.authenticationCode(for: Data("android-viewer/room/v1".utf8), using: key))
            .map { String(format: "%02x", $0) }.joined()
        let salt = Data("android-viewer/relay/v1".utf8)
        viewerToSender = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("viewer-to-sender".utf8), outputByteCount: 32)
        senderToViewer = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Data("sender-to-viewer".utf8), outputByteCount: 32)
    }

    func sealForSender(_ plaintext: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        guard let combined = try AES.GCM.seal(plaintext, using: viewerToSender, nonce: nonce).combined else { throw SenderClientError.invalidResponse }
        return combined.base64EncodedString()
    }

    func openFromSender(_ box: String) throws -> Data {
        guard let data = Data(base64Encoded: box) else { throw SenderClientError.invalidResponse }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: senderToViewer)
    }
}

/// STUN/TURN settings handed out by the relay for one session.
public struct RelayIceServer: Codable, Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
}

/// The viewer's connection to the relay room. Requests mirror the direct HTTPS API, travel sealed through
/// one WebSocket, and are matched to replies by a random ID.
public final class RelayClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public let keys: RelayKeys
    private let base: URL
    private var session: URLSession!
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var keepalive: Timer?
    private var pending = [String: CheckedContinuation<Data, Error>]()
    private var presence: Bool?
    private var presenceWaiters = [CheckedContinuation<Bool?, Never>]()
    /// Called on any thread when the relay reports the Android sender online or offline.
    public var onPresence: ((Bool) -> Void)?

    public init(base: URL, keys: RelayKeys) {
        self.base = base; self.keys = keys
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Only https relays are accepted, plus plain http on this machine's loopback for local testing.
    public static func validatedBase(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), let host = url.host, url.query == nil, url.fragment == nil else { return nil }
        if url.scheme == "https" { return url }
        return url.scheme == "http" && (host == "127.0.0.1" || host == "localhost") ? url : nil
    }

    private func roomURL(_ action: String, scheme: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = base.scheme == "http" ? (scheme == "wss" ? "ws" : "http") : scheme
        parts.path = "/v1/room/\(keys.roomID)/\(action)"
        return parts.url
    }

    /// Opens the room if needed and returns whether the sender is present, or nil if the relay is unreachable.
    public func senderPresent(timeout seconds: Double = 6) async -> Bool? {
        connectIfNeeded()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            lock.lock()
            if let presence { lock.unlock(); continuation.resume(returning: presence); return }
            presenceWaiters.append(continuation)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resolvePresenceWaiters(with: nil) }
        }
    }

    public func status() async throws -> SenderStatus { try await request("GET", "/v1/status", body: Optional<SessionCommand>.none) }

    public func post<Response: Decodable, Body: Encodable>(path: String, body: Body) async throws -> Response {
        try await request("POST", path, body: body)
    }

    /// Fetches short-lived STUN/TURN settings for a new session.
    public func iceServers() async throws -> [RelayIceServer] {
        guard let url = roomURL("ice", scheme: "https") else { throw SenderClientError.invalidEndpoint }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16384 else { throw SenderClientError.network }
        struct Reply: Decodable { let iceServers: [RelayIceServer] }
        return try JSONDecoder().decode(Reply.self, from: data).iceServers
    }

    public func close() {
        lock.lock()
        let old = socket; socket = nil; presence = nil
        let failed = pending; pending = [:]
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.keepalive?.invalidate(); self?.keepalive = nil }
        old?.cancel(with: .normalClosure, reason: nil)
        failed.values.forEach { $0.resume(throwing: SenderClientError.network) }
        resolvePresenceWaiters(with: nil)
    }

    private func request<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        connectIfNeeded()
        let id = UUID().uuidString
        var message: [String: Any] = ["id": id, "method": method, "path": path, "ts": Int64(Date().timeIntervalSince1970 * 1000)]
        if let body { message["body"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) }
        let sealed = try keys.sealForSender(JSONSerialization.data(withJSONObject: message))
        let frame = String(decoding: try JSONSerialization.data(withJSONObject: ["box": sealed]), as: UTF8.self)
        let timeout: Double = path == "/v1/offer" ? 30 : 12
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let socket else { lock.unlock(); continuation.resume(throwing: SenderClientError.network); return }
            pending[id] = continuation
            lock.unlock()
            socket.send(.string(frame)) { [weak self] error in if error != nil { self?.fail(id) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fail(id) }
        }
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let code = object["code"] as? Int else { throw SenderClientError.invalidResponse }
        guard code == 200 else { throw SenderClientError.server(code, "Request rejected.") }
        let payload = try JSONSerialization.data(withJSONObject: object["body"] as? [String: Any] ?? [:])
        guard let decoded = try? JSONDecoder().decode(Response.self, from: payload) else { throw SenderClientError.invalidResponse }
        return decoded
    }

    private func fail(_ id: String) {
        lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
        continuation?.resume(throwing: SenderClientError.network)
    }

    private func connectIfNeeded() {
        lock.lock()
        guard socket == nil, let url = roomURL("viewer", scheme: "wss") else { lock.unlock(); return }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 65536
        socket = task; presence = nil
        lock.unlock()
        task.resume()
        receive(on: task)
        DispatchQueue.main.async { [weak self] in
            self?.keepalive?.invalidate()
            // Keeps carrier NAT mappings alive and notices a dead connection.
            self?.keepalive = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.ping() }
        }
    }

    private func ping() {
        lock.lock(); let current = socket; lock.unlock()
        current?.send(.string("ping")) { [weak self] error in if error != nil { self?.dropped(current) } }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .failure: self.dropped(task)
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ text: String) {
        guard text != "pong", let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["relay"] as? String == "presence", let online = object["sender"] as? Bool {
            lock.lock(); presence = online; lock.unlock()
            resolvePresenceWaiters(with: online); onPresence?(online); return
        }
        guard let box = object["box"] as? String, let plain = try? keys.openFromSender(box),
              let reply = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let id = reply["id"] as? String else { return }
        lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
        continuation?.resume(returning: plain)
    }

    private func dropped(_ task: URLSessionWebSocketTask?) {
        lock.lock()
        guard let task, socket === task else { lock.unlock(); return }
        socket = nil; presence = nil
        let failed = pending; pending = [:]
        lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
        failed.values.forEach { $0.resume(throwing: SenderClientError.network) }
        resolvePresenceWaiters(with: nil)
    }

    private func resolvePresenceWaiters(with value: Bool?) {
        lock.lock(); let waiters = presenceWaiters; presenceWaiters = []; lock.unlock()
        waiters.forEach { $0.resume(returning: value) }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { dropped(webSocketTask) }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = task as? URLSessionWebSocketTask { dropped(socket) }
    }
}
