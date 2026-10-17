import AVFoundation
import os
@preconcurrency import WebRTC

/// Receive-only playback. No input node, microphone permission, or recording callback is used.
final class PlaybackAudioDevice: NSObject, RTCAudioDevice {
    // The audio device owns this bridge until terminateDevice releases it.
    private var rtcDelegate: RTCAudioDeviceDelegate?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var listening = false
    private let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: 4096)
    private let sampleCounter = OSAllocatedUnfairLock(initialState: UInt64(0))
    var renderedSamples: UInt64 { sampleCounter.withLock { $0 } }
    private let peakHold = OSAllocatedUnfairLock(initialState: Float(0))
    /// Decaying peak of recent playback, 0...1. Used only for the on-screen meter.
    var peakLevel: Float { peakHold.withLock { $0 } }
    private var routeObserver: NSObjectProtocol?
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }
    var deviceInputSampleRate: Double { 48000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { 48000 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    var onFailure: (() -> Void)?

    override init() {
        super.init()
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .routeConfigurationChange,
                  let self, let delegate = self.rtcDelegate else { return }
            delegate.dispatchAsync { [weak self] in
                guard let self, self.listening, self.isPlaying else { return }
                self.stopEngine()
                if !self.startEngine() { self.onFailure?() }
            }
        }
    }
    deinit { if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }; pcm.deallocate() }
    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        rtcDelegate = delegate; isInitialized = true; return true
    }
    func terminateDevice() -> Bool {
        stopEngine(); rtcDelegate = nil; isInitialized = false; isPlayoutInitialized = false; isPlaying = false
        return true
    }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func startPlayout() -> Bool {
        isPlaying = true
        if listening && !startEngine() { onFailure?(); return false }
        return true
    }
    func stopPlayout() -> Bool { isPlaying = false; stopEngine(); return true }
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }

    func setListening(_ enabled: Bool) {
        guard let delegate = rtcDelegate else { listening = enabled; return }
        delegate.dispatchAsync { [weak self] in
            guard let self else { return }
            self.listening = enabled
            if enabled && self.isPlaying { if !self.startEngine() { self.onFailure?() } }
            else if !enabled { self.stopEngine() }
        }
    }

    private func startEngine() -> Bool {
        if engine?.isRunning == true { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            let audio = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let node = AVAudioSourceNode(format: format) { [weak self] _, timestamp, count, output -> OSStatus in
                guard let self, let delegate = self.rtcDelegate, count <= 4096 else {
                    for buffer in UnsafeMutableAudioBufferListPointer(output) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    return noErr
                }
                var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                    mDataByteSize: count * 2, mData: self.pcm))
                var flags: AudioUnitRenderActionFlags = []
                let result = delegate.getPlayoutData(&flags, timestamp, 0, count, &buffer)
                var peak: Float = 0
                if result == noErr { for index in 0..<Int(count) { peak = max(peak, abs(Float(self.pcm[index]))) } }
                let level = peak / 32768
                self.peakHold.withLock { $0 = max(level, $0 * 0.9) }
                for out in UnsafeMutableAudioBufferListPointer(output) {
                    guard let data = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for index in 0..<Int(count) { data[index] = result == noErr ? Float(self.pcm[index]) / 32768 : 0 }
                }
                self.sampleCounter.withLock { $0 &+= UInt64(count) }
                return noErr
            }
            audio.attach(node)
            audio.connect(node, to: audio.mainMixerNode, format: format)
            // A restarted engine can use a new render thread. Reset the native
            // thread binding and parameters before its first playback callback.
            rtcDelegate?.dispatchSync { [weak self] in
                self?.rtcDelegate?.notifyAudioOutputInterrupted()
                self?.rtcDelegate?.notifyAudioOutputParametersChange()
            }
            audio.prepare(); try audio.start()
            engine = audio; source = node
            return true
        } catch { stopEngine(); return false }
    }

    private func stopEngine() {
        engine?.stop()
        if let node = source { engine?.detach(node) }
        source = nil; engine = nil
        peakHold.withLock { $0 = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
