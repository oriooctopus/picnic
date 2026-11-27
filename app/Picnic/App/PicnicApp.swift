import SwiftUI
import SwiftData
import Photos

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
                .onChange(of: scenePhase) { oldPhase, newPhase in
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
                    // Refetch the library on a return from the background
                    // (this also restarts the keeper); any other .active only
                    // restarts the keeper. See ForegroundRefetch for why.
                    if newPhase == .active {
                        if ForegroundRefetch.shouldRefetch(
                            from: oldPhase, access: appState.photoLibrary.authorizationStatus
                        ) {
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

/// Decides whether a scene becoming .active refetches the whole Photos
/// library. Months and an open deck are otherwise snapshots from launch, so
/// photos taken while the app sat suspended never showed up: a return from
/// .background refetches.
///
/// Only from .background, never .inactive -> .active. The fetch enumerates
/// every asset synchronously on the main thread (seconds on a big library),
/// and .inactive -> .active fires for every system alert: iOS's "Allow Picnic
/// to modify" prompt when a trim or crop save finishes, the delete
/// confirmation, Control Center, a notification pulled down. Refetching
/// there froze the deck right after Skip on "Saving trim…".
///
/// Gated on access too: the first .active of a cold launch comes before
/// bootstrap's permission request answers, and bootstrap does its own first
/// fetch.
enum ForegroundRefetch {
    static func shouldRefetch(from oldPhase: ScenePhase, access: PHAuthorizationStatus) -> Bool {
        oldPhase == .background && (access == .authorized || access == .limited)
    }
}
