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
    // True from app init through the end of bootstrap()'s seeding work, for
    // any launch that requested a --seed-* stage. MyLifeView's one-shot
    // "scroll to the most recent month" reads this rather than just
    // "monthBuckets is non-empty" — see the comment below for why that
    // distinction is load-bearing. Computed synchronously in init(), not
    // inside bootstrap(): bootstrap's first suspension point is
    // `await photoLibrary.requestAuthorization()`, and MyLifeView's own
    // `.onAppear { appState.refreshMonths() }` can run before that await
    // ever resumes — setting this flag any later than init() reopens the
    // exact race it exists to close.
    @Published private(set) var isSeeding: Bool

    private let modelContext: ModelContext

    init() {
        modelContext = ModelContext(PersistenceController.container)
        sortStore = SortStore(context: modelContext)
        mirrorQueue = MirrorQueueStore(context: modelContext)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        isSeeding = args.contains("--seed-library") || args.contains("--seed-large-month")
        #else
        isSeeding = false
        #endif
    }

    func bootstrap() async {
        await photoLibrary.requestAuthorization()
        guard photoLibrary.authorizationStatus == .authorized
                || photoLibrary.authorizationStatus == .limited else { return }
        #if DEBUG
        // Debug-only seed path for the visual-walk CI job — never compiled
        // into the ad-hoc/Release build. See SeedLibrary.swift.
        //
        // isSeeding matters here because the CI simulator's PhotoKit library
        // is not actually empty at launch — Simulator ships a handful of
        // built-in stock photos (dated across scattered past years, e.g.
        // 2009/2011/2012/2018) — so the very first refreshMonths() call
        // already returns a few non-empty month buckets, well before any of
        // our seeding has run. MyLifeView's initial-scroll-to-bottom is
        // one-shot (hasScrolledToInitialBottom): if it fires on that
        // premature, stock-only bucket list, it never fires again, and the
        // view stays anchored wherever that short list happened to render
        // (which looked identical to "scrolled to top", since 4 stock months
        // fit on one screen with room to spare). Everything seeded
        // afterwards — including the base seed's small control month,
        // monthCard.2025-05 — then sits below the fold forever, outside the
        // LazyVGrid's realized range, invisible to accessibility no matter
        // how long a test waits for it. isSeeding lets MyLifeView tell "real
        // content, seeding done" apart from "PhotoKit answered with whatever
        // was already on the sim". Confirmed via run 31148040886's
        // sim-recording: the frame at the point of failure shows exactly
        // the stock 2009/2011/2012/2018 months, not the seeded ones.
        let willSeed = ProcessInfo.processInfo.arguments.contains("--seed-library")
        let willSeedLargeMonth = ProcessInfo.processInfo.arguments.contains("--seed-large-month")
        if willSeed {
            do {
                try await SeedLibrary.seedIfNeeded()
            } catch {
                print("SeedLibrary: seeding failed: \(error)")
            }
        }
        refreshMonths()
        // Opt-in: only the deck perf test wants a month large enough for
        // per-asset work to be measurable.
        if willSeedLargeMonth {
            do {
                try await SeedLibrary.seedLargeMonthIfNeeded()
            } catch {
                print("SeedLibrary: large-month seeding failed: \(error)")
            }
            refreshMonths()
        }
        isSeeding = false
        #else
        refreshMonths()
        #endif
        await mirrorQueue.drainQueue()
    }

    func refreshMonths() {
        monthBuckets = photoLibrary.fetchMonthBuckets()
    }
}
