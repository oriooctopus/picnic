import SwiftUI
import Photos
import SwiftData

/// Root object wiring together PhotoKit access, local persistence, and the
/// mirror queue. Owned once by PicnicApp and injected as an EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    let photoLibrary = PhotoLibraryService()
    let sortStore: SortStore
    let mirrorQueue: MirrorQueueStore

    @Published var monthBuckets: [MonthBucket] = []
    // v1 placeholder profile tab always shows the red-dot badge seen in the
    // reference screenshots; there is no real notification model yet.
    @Published var hasUnviewedProfileBadge = true

    private let modelContext: ModelContext

    init() {
        modelContext = ModelContext(PersistenceController.container)
        sortStore = SortStore(context: modelContext)
        mirrorQueue = MirrorQueueStore(context: modelContext)
    }

    func bootstrap() async {
        await photoLibrary.requestAuthorization()
        guard photoLibrary.authorizationStatus == .authorized
                || photoLibrary.authorizationStatus == .limited else { return }
        #if DEBUG
        // Debug-only seed path for the visual-walk CI job — never compiled
        // into the ad-hoc/Release build. See SeedLibrary.swift.
        if ProcessInfo.processInfo.arguments.contains("--seed-library") {
            do {
                try await SeedLibrary.seedIfNeeded()
            } catch {
                print("SeedLibrary: seeding failed: \(error)")
            }
        }
        #endif
        // Refresh as soon as the base seed (if any) is in, rather than
        // waiting until the large-month seed below also finishes. See the
        // large-month branch for why this matters.
        refreshMonths()
        #if DEBUG
        // Opt-in: only the deck perf test wants a month large enough for
        // per-asset work to be measurable.
        if ProcessInfo.processInfo.arguments.contains("--seed-large-month") {
            do {
                try await SeedLibrary.seedLargeMonthIfNeeded()
            } catch {
                print("SeedLibrary: large-month seeding failed: \(error)")
            }
            // Large-month seeding (300 chunked, detached photo encodes) can
            // take far longer than the base seed. Before this second
            // refresh existed, refreshMonths() ran exactly once, after BOTH
            // seed stages — so every already-seeded month, including the
            // base seed's small control month, stayed invisible to the UI
            // (monthBuckets empty) until the entire large-month seed
            // finished too. That's what made monthCard.2025-05 (base seed,
            // architecturally unrelated to --seed-large-month) vanish once
            // the large-month encode work moved to Task.detached and
            // started taking real wall-clock time instead of blocking (and
            // thus bounding) bootstrap's total duration via the main
            // thread.
            refreshMonths()
        }
        #endif
        await mirrorQueue.drainQueue()
    }

    func refreshMonths() {
        monthBuckets = photoLibrary.fetchMonthBuckets()
    }
}
