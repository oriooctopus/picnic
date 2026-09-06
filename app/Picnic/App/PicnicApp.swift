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
                    // Server-backlog polling follows the same launch/
                    // foreground-only rule and is stopped again the moment
                    // we leave .active, so it never fires against a
                    // suspended process.
                    if newPhase == .active {
                        Task { await appState.mirrorQueue.drainQueue() }
                        Task { await appState.mirrorQueue.refreshServerStatus() }
                        appState.mirrorQueue.startPolling()
                    } else {
                        appState.mirrorQueue.stopPolling()
                    }
                }
        }
        .modelContainer(PersistenceController.container)
    }
}
