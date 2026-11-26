import SwiftUI
import SwiftData

@main
struct PicnicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        // BGTaskScheduler requires registration before launch finishes, i.e.
        // here, not in a view's .task.
        OfflineKeeperBackground.register { task in
            Task { @MainActor in await state.refillOfflinePhotosInBackground(task) }
        }
    }

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
                    if newPhase == .active { appState.offlineDownloader.resumeIfInterrupted() }
                    // The keeper only (re)starts in the foreground; on leaving
                    // it, a running pass gets iOS's grace period and a
                    // background task is queued to refill later.
                    appState.offlineKeeper.setActive(newPhase == .active)
                    if newPhase == .background {
                        appState.offlineKeeper.beginGracePeriod()
                        OfflineKeeperBackground.schedule()
                    }
                    if newPhase == .active { appState.restartOfflineKeeper() }
                    Task { await appState.jobs.scenePhaseChanged(active: newPhase == .active) }
                }
        }
        .modelContainer(PersistenceController.container)
    }
}
