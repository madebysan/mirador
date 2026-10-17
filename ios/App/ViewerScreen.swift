import SwiftUI
@preconcurrency import WebRTC

struct ViewerScreen: View {
    @Bindable var model: ViewerModel
    @State private var scanning = false
    @State private var confirmForget = false
    @State private var controlsHidden = false
    @State private var showingHelp = false

    var body: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width > geometry.size.height
            let immersive = horizontal && controlsHidden && model.selection.video
            ZStack {
                Hardware.enclosure.ignoresSafeArea()
                if immersive { Color.black.ignoresSafeArea() }
                if horizontal {
                    HStack(spacing: 14) {
                        display(horizontal: true, immersive: immersive)
                        if !immersive { deck.frame(width: min(350, geometry.size.width * 0.44)) }
                    }
                    .padding(immersive ? 0 : 12)
                } else {
                    VStack(spacing: 12) {
                        display(horizontal: false, immersive: false)
                        deck
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: immersive)
            .onChange(of: horizontal) { _, _ in controlsHidden = false }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(controlsHidden && model.selection.video)
        .persistentSystemOverlays(controlsHidden && model.selection.video ? .hidden : .automatic)
        .onChange(of: model.selection.video) { _, live in if !live { controlsHidden = false } }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScanner { value in scanning = false; model.acceptPairing(Data(value.utf8)) }
                    .navigationTitle("Scan Pairing Code").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
        .sheet(isPresented: $showingHelp) { HelpSheet() }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("--design-help") { showingHelp = true } }
        #endif
        .alert("Forget this Android phone?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Phone", role: .destructive) { model.forget() }
        } message: { Text("Live input stops and its pairing key is removed from this iPhone.") }
    }

    // MARK: Display: LCD, readout line and the video screen inside a dark bezel

    private func display(horizontal: Bool, immersive: Bool) -> some View {
        VStack(spacing: 8) {
            if !immersive { lcd; readout }
            screen(horizontal: horizontal, immersive: immersive)
        }
        .padding(immersive ? 0 : 10)
        .background {
            if !immersive {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Hardware.bezel)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            }
        }
        .padding(immersive ? 0 : 6)
        .background { if !immersive { Plate(radius: 30) } }
    }

    private var lcd: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                LCDBadge(text: phaseBadge, dot: model.phase == .live ? Hardware.tally : nil)
                if model.selection.video { LCDBadge(text: model.selection.camera == .rear ? "REAR" : "FRONT", outlined: true) }
                Spacer(minLength: 4)
                if !model.linkName.isEmpty {
                    Label(model.linkName.uppercased(), systemImage: model.linkName == "Tailscale" ? "point.3.connected.trianglepath.dotted" : model.linkName == "Internet" ? "globe" : "wifi")
                        .font(.caption.weight(.bold)).tracking(0.5).lineLimit(1)
                }
            }
            clock
            HStack(spacing: 8) {
                Text(videoReadout)
                Spacer(minLength: 4)
                Text("MIC")
                Image(systemName: model.selection.microphone ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .font(.footnote.weight(.semibold).monospacedDigit()).tracking(0.4).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hardware.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Hardware.ink, lineWidth: 1.2))
        }
        .foregroundStyle(Hardware.ink)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LCDGlass())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("senderStatus")
    }

    @ViewBuilder private var clock: some View {
        if let since = model.liveSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                LCDClock(seconds: max(0, Int(context.date.timeIntervalSince(since))), lit: true)
            }
        } else {
            LCDClock(seconds: 0, lit: false)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.message).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.white.opacity(0.62)).lineLimit(3)
                    .accessibilityIdentifier("connectionError")
            } else if !model.paired {
                Text("Open Mirador on the Android phone, tap Pair a Receiver, then scan its code here.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.62)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
    }

    private func screen(horizontal: Bool, immersive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: immersive ? 0 : 14, style: .continuous)
        let tapToHide = horizontal && model.selection.video
        return ZStack {
            shape.fill(Color.black)
            if model.selection.video, let track = model.videoTrack {
                // A new lens starts at fit.
                ZoomableVideo(track: track).id(model.selection.camera).clipShape(shape)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.selection.microphone ? "waveform" : "video").font(.system(size: 32, weight: .light))
                    Text(model.selection.microphone ? "Listening to Android" : model.paired ? "Choose Rear or Front" : "Live from your Android phone")
                        .font(.footnote.weight(.semibold)).tracking(0.8).textCase(.uppercase).multilineTextAlignment(.center)
                }.foregroundStyle(.white.opacity(0.45)).padding(20)
            }
            if model.selection.video, model.receivedVideoFrames == 0 {
                VStack(spacing: 12) { ProgressView().tint(.white); Text("Waiting for video…").font(.callout) }
                    .foregroundStyle(.white).padding(22).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay { if !immersive { shape.strokeBorder(.white.opacity(0.07), lineWidth: 1) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 120)
        .contentShape(Rectangle())
        .onTapGesture { if tapToHide { controlsHidden.toggle() } }
        .accessibilityLabel(model.selection.video ? "Live \(model.selection.camera.rawValue) camera" : "Camera preview off")
        .accessibilityHint(tapToHide ? (controlsHidden ? "Shows the controls" : "Hides the controls") : "")
        .accessibilityAddTraits(tapToHide ? .isButton : [])
        .accessibilityIdentifier("previewArea")
    }

    private var phaseBadge: String {
        switch model.phase {
        case .unpaired: "NO PAIR"
        case .checking: "CHECKING"
        case .ready: "READY"
        case .connecting: "LINKING"
        case .live: "LIVE"
        case .unavailable: "OFFLINE"
        }
    }

    private var videoReadout: String {
        guard model.selection.video else { return "VIDEO OFF" }
        return model.frameSize.isEmpty ? "WAITING" : model.frameSize
    }

    // MARK: Control deck: transport keys, VU meter, lens keys and utilities

    private var deck: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                transport
                VUMeter(active: model.selection.microphone) { model.audioLevel() }
                    .frame(width: 92, height: 92)
            }
            lensKeys
            utilityRow
        }
        .padding(16)
        .background(Plate())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var transport: some View {
        let listening = model.selection.microphone
        return VStack(spacing: 7) {
            KeyHousing(radius: 33) {
                HStack(spacing: 6) {
                    Button { model.stop() } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).frame(width: 17, height: 17)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(HardwareKeyStyle(radius: 28))
                    .disabled(!(model.selection.hasInput || model.busy))
                    .accessibilityLabel("Stop All").accessibilityIdentifier("stopAllButton")

                    Button { model.listening() } label: {
                        HStack(spacing: 10) {
                            LED(on: listening)
                            Image(systemName: listening ? "speaker.wave.2.fill" : "speaker.wave.2").font(.title3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(HardwareKeyStyle(radius: 28, latched: listening))
                    .disabled(model.busy || !model.paired)
                    .accessibilityLabel(listening ? "Stop Listening" : "Listen to Microphone")
                    .accessibilityValue(listening ? "Live" : "Off")
                    .accessibilityIdentifier("listeningButton")
                }
            }
            HStack(spacing: 6) {
                EngravedLabel(text: "STOP").frame(width: 66)
                EngravedLabel(text: listening ? "LISTENING" : "LISTEN").frame(maxWidth: .infinity)
            }
        }
    }

    private var lensKeys: some View {
        KeyHousing(radius: 18) {
            HStack(spacing: 6) {
                lensKey(.rear, title: "Rear", symbol: "camera")
                lensKey(.front, title: "Front", symbol: "person.crop.rectangle")
                if model.torchAvailable { lightKey }
            }
        }
    }

    /// The Android rear camera's light, for dark rooms. Shown only when the Android phone has one.
    private var lightKey: some View {
        let lit = model.selection.torch
        return Button { model.light() } label: {
            Image(systemName: lit ? "flashlight.on.fill" : "flashlight.off.fill").font(.body.weight(.medium))
                .frame(width: 52, height: 48)
                .overlay(alignment: .topTrailing) { LED(on: lit).padding(8) }
        }
        .buttonStyle(HardwareKeyStyle(radius: 13, latched: lit))
        .disabled(model.busy || !model.selection.canUseTorch)
        .accessibilityLabel("Light")
        .accessibilityValue(lit ? "On" : "Off")
        .accessibilityHint("Turns on the Android phone’s light. Works with the rear camera.")
        .accessibilityIdentifier("lightButton")
    }

    private func lensKey(_ lens: CameraLens, title: String, symbol: String) -> some View {
        let live = model.selection.video && model.selection.camera == lens
        return Button { model.camera(lens) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.body.weight(.medium))
                Text(title).font(.callout.weight(.semibold)).tracking(0.6).textCase(.uppercase)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay(alignment: .topTrailing) { LED(on: live).padding(8) }
        }
        .buttonStyle(HardwareKeyStyle(radius: 13, latched: live))
        .disabled(model.busy || !model.paired)
        .accessibilityLabel("\(title) Preview")
        .accessibilityIdentifier(lens.rawValue + "CameraButton")
        .accessibilityValue(live ? "Live" : "Off")
        .accessibilityHint(live ? "Stops this preview" : "Starts this camera preview")
    }

    @ViewBuilder private var utilityRow: some View {
        if model.paired {
            let reconnecting = model.reconnectSelection != nil && !model.selection.hasInput && !model.busy
            HStack(spacing: 10) {
                Button {
                    if reconnecting { model.reconnect() } else { Task { await model.probe() } }
                } label: {
                    Label(reconnecting ? "Reconnect" : "Check Link", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold)).tracking(0.5).textCase(.uppercase).lineLimit(1)
                        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(HardwareKeyStyle(radius: 20, tone: reconnecting ? .accent : .standard))
                .disabled(!reconnecting && (model.selection.hasInput || model.busy || model.phase == .checking))
                .accessibilityIdentifier(reconnecting ? "reconnectButton" : "checkConnectionButton")

                helpKey
                Menu {
                    Button("Pair Another Phone", systemImage: "qrcode.viewfinder") { model.stop(); scanning = true }
                    Button("Forget Phone", systemImage: "trash", role: .destructive) { confirmForget = true }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Hardware.label)
                        .frame(width: 40, height: 40).background(KeyFace(radius: 20))
                }
                .accessibilityLabel("Phone Options")
            }
        } else {
            HStack(spacing: 10) {
            Button { scanning = true } label: {
                Label("Pair Android Phone", systemImage: "qrcode.viewfinder")
                    .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(HardwareKeyStyle(radius: 23, tone: .accent))
            .accessibilityIdentifier("pairPhoneButton")
            helpKey
            }
        }
    }

    /// Opens "How Mirador works".
    private var helpKey: some View {
        Button { showingHelp = true } label: {
            Image(systemName: "info").font(.body.weight(.bold)).frame(width: 40, height: 40)
        }
        .buttonStyle(HardwareKeyStyle(radius: 20))
        .accessibilityLabel("How Mirador works")
        .accessibilityIdentifier("helpButton")
    }
}

/// Live video with pinch to zoom (fit to 4×), drag to look around while zoomed, and a key that returns to fit.
private struct ZoomableVideo: View {
    let track: RTCVideoTrack
    @State private var scale: Double = 1
    @State private var offset = CGSize.zero
    @GestureState private var pinch: Double = 1
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let current = PreviewZoom.clampScale(scale * pinch)
            let shift = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), scale: current, in: size)
            VideoSurface(track: track)
                .frame(width: size.width, height: size.height)
                .scaleEffect(current)
                .offset(shift)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        let settled = PreviewZoom.clampScale(scale * value.magnification)
                        scale = settled < PreviewZoom.snapToFit ? 1 : settled
                        offset = clamped(offset, scale: scale, in: size)
                    })
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .updating($drag) { value, state, _ in if scale > 1 { state = value.translation } }
                    .onEnded { value in
                        guard scale > 1 else { return }
                        offset = clamped(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height), scale: scale, in: size)
                    })
                .overlay(alignment: .bottomTrailing) {
                    if current > 1.01 {
                        Button { withAnimation(.easeOut(duration: 0.2)) { scale = 1; offset = .zero } } label: {
                            Text(current.formatted(.number.precision(.fractionLength(1))) + "×")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(minWidth: 56, minHeight: 36)
                                .background(.black.opacity(0.6), in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .padding(8)
                        .accessibilityLabel("Zoomed \(current.formatted(.number.precision(.fractionLength(1)))) times")
                        .accessibilityHint("Returns to the full picture")
                    }
                }
                .accessibilityZoomAction { action in
                    scale = PreviewZoom.clampScale(scale + (action.direction == .zoomIn ? 1 : -1))
                    offset = clamped(offset, scale: scale, in: size)
                }
        }
    }

    private func clamped(_ value: CGSize, scale: Double, in size: CGSize) -> CGSize {
        let limit = PreviewZoom.clampOffset(x: value.width, y: value.height, scale: scale, width: size.width, height: size.height)
        return CGSize(width: limit.x, height: limit.y)
    }
}

private struct VideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero); view.videoContentMode = .scaleAspectFit
        context.coordinator.attach(track, to: view); return view
    }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) { context.coordinator.attach(track, to: uiView) }
    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) { coordinator.detach(from: uiView) }
    final class Coordinator {
        private var track: RTCVideoTrack?
        func attach(_ next: RTCVideoTrack, to view: RTCMTLVideoView) {
            guard track !== next else { return }; track?.remove(view); track = next; next.add(view)
        }
        func detach(from view: RTCMTLVideoView) { track?.remove(view); track = nil }
    }
}
