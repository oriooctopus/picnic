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
                .environmentObject(appState.outfitLog)
                .preferredColorScheme(.dark)
                .task {
                    await appState.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // Retry unsent jobs on launch/foreground/network-restore
                    // only (no background URLSession in v1) — persisted jobs
                    // survive offline and drain the next time the app is
                    // active. DrainCoordinator skips the .active that iOS
                    // reports right at launch: bootstrap's own drain covers it.
                    // Server-backlog polling follows the same launch/
                    // foreground-only rule and is stopped again the moment
                    // we leave .active, so it never fires against a
                    // suspended process.
                    if newPhase == .active {
                        Task { await appState.drainCoordinator.sceneBecameActive() }
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
