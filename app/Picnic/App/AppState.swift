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
        // LOAD-BEARING ORDERING: sortStore/mirrorQueue are constructed AFTER
        // the debug reset block below, not here. SortStore.init eagerly reads
        // every AssetSortRecord into its in-memory `stateCache`, and
        // `state(for:)` serves exclusively from that cache — so constructing
        // it first made --reset-sort-state delete the SwiftData rows while
        // the app went on reporting the deleted marks from memory for the
        // rest of the launch. The reset looked like a no-op and two tests
        // (test29/test30) failed on a "clean" store that wasn't clean.
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        isSeeding = args.contains("--seed-library") || args.contains("--seed-large-month")
        // Debug-only, UI-test-only: DeckViewModel.hideSorted is backed by a
        // UserDefaults key that survives both app relaunches and — since the
        // simulator's defaults plist isn't wiped between test methods — every
        // earlier test in the same CI run. Tests that need a known starting
        // state (rather than reading and branching on whatever the previous
        // test method left behind) launch with this argument to clear it
        // before anything reads it. Must run before any DeckViewModel is
        // constructed, hence here in init() rather than in bootstrap().
        if args.contains("--reset-hide-sorted") {
            UserDefaults.standard.removeObject(forKey: DeckViewModel.hideSortedDefaultsKey)
        }
        // Debug-only, UI-test-only: unlike hideSorted's single UserDefaults
        // key, actual sort progress (kept/markedForDelete marks, per-month
        // "manually sorted" flags, and resolved compare-group choices) lives
        // in SwiftData and persists across relaunch() within a test run —
        // same as the simulator not wiping UserDefaults, the SwiftData store
        // isn't reset between test methods either. Tests whose assertions
        // require starting from a genuinely clean sort state (e.g. counting
        // unsorted photos) were breaking when an earlier test method in the
        // same CI run legitimately left marks behind. Must run BEFORE
        // SortStore is constructed — see the ordering comment above; running
        // it afterwards silently does nothing observable.
        if args.contains("--reset-sort-state") {
            for record in (try? modelContext.fetch(FetchDescriptor<AssetSortRecord>())) ?? [] {
                modelContext.delete(record)
            }
            for meta in (try? modelContext.fetch(FetchDescriptor<MonthSortMeta>())) ?? [] {
                modelContext.delete(meta)
            }
            for resolution in (try? modelContext.fetch(FetchDescriptor<CompareGroupResolution>())) ?? [] {
                modelContext.delete(resolution)
            }
            try? modelContext.save()
        }
        #else
        isSeeding = false
        #endif
        // Constructed here, after the reset block above — see the
        // LOAD-BEARING ORDERING comment at the top of init().
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
