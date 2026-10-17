import Foundation

#if DEBUG
@MainActor enum ViewerSelfCheck {
    static func run(_ model: ViewerModel) async {
        var checks = [String]()
        var metrics = [String: Any]()
        var passed = false
        defer {
            model.stop()
            let report: [String: Any] = ["passed": passed, "checks": checks, "metrics": metrics, "media_saved": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                try? data.write(to: folder.appendingPathComponent("ViewerSelfCheck.json"), options: .atomic)
            }
        }
        do {
            try await wait { model.phase == .ready && !model.busy }
            model.camera(.rear)
            try await wait { !model.busy && model.receivedVideoFrames >= 5 }
            checks.append("rear video delivered")
            metrics = await model.diagnostics()
            guard (metrics["video_packetsReceived"] as? Int ?? 0) > 0 else { throw CheckFailed() }
            model.listening()
            try await wait { !model.busy && model.selection.microphone }
            try await Task.sleep(for: .seconds(3))
            metrics = await model.diagnostics()
            guard (metrics["audio_packetsReceived"] as? Int ?? 0) > 0,
                  (metrics["audio_rendered_samples"] as? Int ?? 0) > 0,
                  (metrics["local_microphone_recording"] as? Int) == 0 else { throw CheckFailed() }
            checks.append("Android audio received and rendered without local microphone")
            let count = model.receivedVideoFrames
            model.camera(.front)
            try await wait { !model.busy && model.selection.camera == .front && model.receivedVideoFrames > count + 5 }
            guard model.selection.microphone else { throw CheckFailed() }
            checks.append("front switching keeps listening")
            model.camera(.front)
            try await wait { !model.busy && !model.selection.video && model.selection.microphone }
            let samples = (await model.diagnostics())["audio_rendered_samples"] as? Int ?? 0
            try await Task.sleep(for: .seconds(2))
            guard ((await model.diagnostics())["audio_rendered_samples"] as? Int ?? 0) > samples else { throw CheckFailed() }
            checks.append("video off keeps listening")
            model.camera(.rear)
            try await wait { !model.busy && model.selection.video }
            model.listening()
            try await wait { !model.busy && !model.selection.microphone && model.selection.video }
            let frames = model.receivedVideoFrames
            try await Task.sleep(for: .seconds(2))
            guard model.receivedVideoFrames > frames else { throw CheckFailed() }
            checks.append("listening off keeps video")
            metrics = await model.diagnostics()
            metrics["received_frame_size"] = model.frameSize
            model.stop()
            guard !model.selection.hasInput && model.videoTrack == nil else { throw CheckFailed() }
            checks.append("Stop clears both inputs and preview")
            passed = true
        } catch {
            metrics = await model.diagnostics()
            metrics["failure_type"] = String(describing: type(of: error))
            metrics["paired"] = model.paired
            metrics["status_message"] = model.message
            metrics["status_error"] = model.errorMessage ?? ""
        }
    }

    private static func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < end {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CheckFailed()
    }
    private struct CheckFailed: Error {}
}
#endif
