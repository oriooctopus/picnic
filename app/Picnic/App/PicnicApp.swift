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
                    // See JobRuntime.scenePhaseChanged (tested): foreground drains,
                    // polling stops when we leave .active.
                    Task { await appState.jobs.scenePhaseChanged(active: newPhase == .active) }
                }
        }
        .modelContainer(PersistenceController.container)
    }
}
