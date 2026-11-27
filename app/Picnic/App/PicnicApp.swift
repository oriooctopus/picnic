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
                    // Refetch the library on every foreground (this also
                    // restarts the keeper): months and an open deck are
                    // otherwise snapshots from launch, so photos taken while
                    // the app sat suspended never showed up.
                    // Gated on access: the first .active of a cold launch
                    // comes before bootstrap's permission request answers,
                    // and bootstrap does its own first fetch.
                    if newPhase == .active {
                        let access = appState.photoLibrary.authorizationStatus
                        if access == .authorized || access == .limited {
                            appState.refreshMonths()
                        } else {
                            appState.restartOfflineKeeper()
                        }
                    }
                    Task { await appState.jobs.scenePhaseChanged(active: newPhase == .active) }
                }
        }
        .modelContainer(PersistenceController.container)
    }
}
