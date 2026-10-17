import SwiftUI

@main struct AndroidViewerApp: App {
    @State private var viewer = ViewerModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ViewerScreen(model: viewer)
                .onChange(of: scenePhase) { old, phase in
                    if phase == .background { viewer.stop(); viewer.suspendRelay() }
                    // Returning from Settings or the Tailscale app may have changed the network path.
                    if phase == .active, old == .background { viewer.refreshIfIdle() }
                }
                .task {
                    await viewer.prepare()
                    #if DEBUG
                    if CommandLine.arguments.contains("--self-check") {
                        await ViewerSelfCheck.run(viewer)
                    }
                    #endif
                }
        }
    }
}
