import Foundation
import ViewerCore

@main struct ViewerCheck {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--relay") else {
            print("Pass the private pairing file path, optionally followed by --relay <https URL>."); exit(2)
        }
        do {
            let pairing = try PairingPayload.parse(Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            if arguments.count == 4 {
                // Read-only relay check: room presence, a sealed status round trip and STUN/TURN availability.
                guard let base = RelayClient.validatedBase(arguments[3]) else { print("The relay must be an https URL."); exit(2) }
                let relay = RelayClient(base: base, keys: try RelayKeys(token: pairing.token))
                defer { relay.close() }
                guard let present = await relay.senderPresent(timeout: 8) else { print("Relay unreachable."); exit(1) }
                guard present else { print("Relay reachable. Android Sender is not connected to it."); exit(1) }
                let status = try await relay.status()
                print("Sealed relay status passed. Sender ready: \(status.running && status.armed). Sensors off: \(!status.video && !status.microphone).")
                print("Viewer connected: \(status.viewer). Media: \(status.connection). Camera: \(status.video ? status.camera : "off"). Microphone: \(status.microphone ? "on" : "off"). Frames sent: \(status.videoFrames).")
                if let width = status.sendWidth, width > 0 {
                    print("Sending \(width) × \(status.sendHeight ?? 0) at \(status.sendFps ?? 0) fps, target \(status.targetKbps ?? 0) kbps, limited by: \(status.qualityLimit ?? "unknown").")
                }
                let servers = try await relay.iceServers()
                print("Relay ICE: \(servers.flatMap(\.urls).count) URLs, TURN credentials: \(servers.contains { $0.username != nil }).")
                return
            }
            let client = PinnedSenderClient(pairing: pairing)
            defer { client.close() }
            var success = false
            for endpoint in pairing.endpoints {
                do {
                    let status = try await client.status(at: endpoint)
                    print("Pinned HTTPS passed. Sender ready: \(status.running && status.armed). Sensors off: \(!status.video && !status.microphone).")
                    success = true
                    break
                } catch { continue }
            }
            guard success else { print("No private sender endpoint responded."); exit(1) }
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pairing)) as! [String: Any]
            object["certificate_sha256"] = String(repeating: "0", count: 64)
            let wrong = try PairingPayload.parse(JSONSerialization.data(withJSONObject: object))
            let rejectedClient = PinnedSenderClient(pairing: wrong)
            defer { rejectedClient.close() }
            for endpoint in wrong.endpoints {
                do {
                    _ = try await rejectedClient.status(at: endpoint)
                    print("Wrong certificate was accepted."); exit(1)
                } catch { continue }
            }
            print("Wrong TLS fingerprint rejected.")
        } catch {
            print("Connection check failed: \(type(of: error)).")
            exit(1)
        }
    }
}
