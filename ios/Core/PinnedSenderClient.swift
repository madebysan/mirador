import Foundation
import Security
import CryptoKit

public enum SenderClientError: Error, LocalizedError {
    case invalidEndpoint, network, invalidResponse, server(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Pair this Android phone again."
        case .network: "Cannot reach Mirador on Android. Check both phones’ Wi-Fi or Tailscale connection."
        case .invalidResponse: "Mirador on Android returned an unexpected response."
        case let .server(code, _):
            switch code {
            case 401: "Pair this Android phone again."
            case 403: "Open Mirador on the Android phone and tap Enable."
            case 409: "Another receiver is connected. Close it or reconnect."
            default: "The input could not start. Check Mirador on Android and try again."
            }
        }
    }
}

public final class PinnedSenderClient: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let pairing: PairingPayload
    private var session: URLSession!
    #if DEBUG
    private let diagnosticsLock = NSLock()
    private var lastFailureCodes = [String: Int]()
    public var diagnosticFailureCodes: [String: Int] { diagnosticsLock.withLock { lastFailureCodes } }
    #endif

    public init(pairing: PairingPayload) {
        self.pairing = pairing
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func close() { session.invalidateAndCancel() }

    public func status(at endpoint: URL) async throws -> SenderStatus {
        try await send(at: endpoint, path: "/v1/status", data: nil)
    }

    public func post<Response: Decodable, Body: Encodable>(at endpoint: URL, path: String, body: Body) async throws -> Response {
        try await send(at: endpoint, path: path, data: JSONEncoder().encode(body))
    }

    private func send<Response: Decodable>(at endpoint: URL, path: String, data: Data?) async throws -> Response {
        guard pairing.endpoints.contains(endpoint), NetworkPolicy.isSenderEndpoint(endpoint),
              ["/v1/status", "/v1/offer", "/v1/control", "/v1/ping", "/v1/disconnect"].contains(path),
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw SenderClientError.invalidEndpoint }
        parts.path = path
        guard let url = parts.url else { throw SenderClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = data == nil ? "GET" : "POST"
        request.httpBody = data
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, bytes.count <= 262144 else { throw SenderClientError.invalidResponse }
            guard response.statusCode == 200 else {
                #if DEBUG
                diagnosticsLock.withLock { lastFailureCodes["http_status"] = response.statusCode }
                #endif
                throw SenderClientError.server(response.statusCode, "Request rejected.")
            }
            guard let decoded = try? JSONDecoder().decode(Response.self, from: bytes) else { throw SenderClientError.invalidResponse }
            return decoded
        } catch let known as SenderClientError { throw known }
        catch is CancellationError { throw CancellationError() }
        catch {
            #if DEBUG
            // Native self-check diagnostics contain only codes and a permission flag.
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let networkPath = String(describing: failure.userInfo["_NSURLErrorNWPathKey"] ?? underlying?.userInfo["_NSURLErrorNWPathKey"])
            diagnosticsLock.withLock {
                lastFailureCodes["transport_error"] = failure.code
                lastFailureCodes["underlying_error"] = underlying?.code ?? 0
                lastFailureCodes["local_network_denied"] = networkPath.contains("localNetworkDenied") ? 1 : 0
            }
            #endif
            throw SenderClientError.network
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
        let expected = pairing.certificatePin
        var difference: UInt8 = 0
        guard digest.count == expected.count else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        for (left, right) in zip(digest, expected) { difference |= left ^ right }
        // The scanned leaf certificate is the trust anchor for this private, self-signed sender.
        completionHandler(difference == 0 ? .useCredential : .cancelAuthenticationChallenge,
                          difference == 0 ? URLCredential(trust: trust) : nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
