import Foundation
import Darwin

public enum PairingError: Error, LocalizedError {
    case invalidCode
    public var errorDescription: String? { "That code is not a Mirador pairing code." }
}

public struct PairingPayload: Codable, Sendable {
    public let protocolName: String
    public let endpoints: [URL]
    public let token: String
    public let certificateSHA256: String

    private enum CodingKeys: String, CodingKey {
        case protocolName = "protocol", endpoints, token
        case certificateSHA256 = "certificate_sha256"
    }

    public var certificatePin: Data {
        var bytes = Data()
        for index in stride(from: 0, to: certificateSHA256.count, by: 2) {
            let begin = certificateSHA256.index(certificateSHA256.startIndex, offsetBy: index)
            let end = certificateSHA256.index(begin, offsetBy: 2)
            if let byte = UInt8(certificateSHA256[begin..<end], radix: 16) { bytes.append(byte) }
        }
        return bytes
    }

    public static func parse(_ data: Data) throws -> PairingPayload {
        guard data.count <= 16384,
              let value = try? JSONDecoder().decode(PairingPayload.self, from: data),
              value.protocolName == "android-sender-v1",
              // Zero private endpoints is valid: the transmitter can be reached through the internet relay alone.
              (0...12).contains(value.endpoints.count),
              Set(value.endpoints).count == value.endpoints.count,
              value.endpoints.allSatisfy(NetworkPolicy.isSenderEndpoint),
              value.token.utf8.count == 43,
              value.token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              value.certificateSHA256.utf8.count == 64,
              value.certificateSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw PairingError.invalidCode }
        let base64 = value.token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let secret = Data(base64Encoded: base64), secret.count == 32 else { throw PairingError.invalidCode }
        return value
    }
}

public enum NetworkPolicy {
    public static func isSenderEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == 8443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let host = parts.host else { return false }
        return isPrivateAddress(host)
    }

    public static func isPrivateAddress(_ literal: String) -> Bool {
        var host = literal
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.contains("%") else { return false }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return withUnsafeBytes(of: v6) { $0[0] & 0xfe == 0xfc }
        }
        return false
    }

    /// True for Tailscale's CGNAT IPv4 range (100.64.0.0/10) and its unique-local IPv6 prefix (fd7a:115c:a1e0::/48).
    public static func isTailscaleAddress(_ literal: String) -> Bool {
        var host = literal
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
        }
        return false
    }

    /// True when a local interface address belongs to this device's Tailscale tunnel. Carrier CGNAT also uses
    /// 100.64.0.0/10, so an IPv4 address counts only on a `utun` interface; Tailscale's IPv6 prefix counts anywhere.
    public static func isTailscaleInterface(name: String, address: String) -> Bool {
        guard isTailscaleAddress(address) else { return false }
        return address.contains(":") || name.hasPrefix("utun")
    }

    /// Whether this device currently has a Tailscale address, meaning Tailscale is connected here.
    public static func deviceHasTailscaleAddress() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let socket = entry.ifa_addr, [AF_INET, AF_INET6].contains(Int32(socket.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(socket.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(socket, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if isTailscaleInterface(name: String(cString: entry.ifa_name), address: String(cString: host)) { return true }
        }
        return false
    }

    /// Short user-facing name of the path a sender endpoint uses.
    public static func linkName(_ endpoint: URL) -> String {
        guard let host = endpoint.host else { return "network" }
        return isTailscaleAddress(host) ? "Tailscale" : "Wi-Fi"
    }

    public static func privateCandidates(_ sdp: String) -> String {
        sdp.components(separatedBy: .newlines).filter { line in
            guard line.hasPrefix("a=candidate:") else { return !line.isEmpty }
            let fields = line.split(separator: " ")
            return fields.count > 4 && isPrivateAddress(String(fields[4]))
        }.joined(separator: "\r\n") + "\r\n"
    }
}
