import SwiftUI
import SwiftData

@main
struct PicnicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    await appState.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Retry unsent mirror jobs on launch/foreground only (no
                    // background URLSession in v1) — persisted jobs survive
                    // offline and drain the next time the app is active.
                    if newPhase == .active {
                        Task { await appState.mirrorQueue.drainQueue() }
                    }
                }
        }
        .modelContainer(PersistenceController.container)
    }
}
