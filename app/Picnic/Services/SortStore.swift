import Foundation
import SwiftData
import Photos

/// Owns all per-asset / per-month persisted state: sort marks, manual
/// "mark sorted" overrides, the streak counter, and resolved compare groups.
@MainActor
final class SortStore: ObservableObject {
    private let context: ModelContext
    @Published var streakCount: Int = 0

    /// `state(for:)` and `isGroupResolved(_:)` are called from view bodies —
    /// once per asset per render, so on every drag frame while swiping a
    /// deck. A SwiftData fetch per call there was the actual cause of the
    /// laggy swipe (a disk round-trip per asset, 60+ times a second while
    /// dragging). Kept as the in-memory read path; every write still goes
    /// through `context` first so it stays the source of truth.
    private var stateCache: [String: SortState] = [:]
    private var resolvedGroupCache: Set<String> = []

    /// Published, unlike the caches above: MonthCardView observes SortStore
    /// and reads this in its body, so the long-press "Mark as sorted /
    /// unsorted" menu has to trigger a redraw. Reading MonthSortMeta straight
    /// from SwiftData published nothing, so the card kept its old label.
    @Published private(set) var manuallySortedMonths: Set<String> = []

    /// UserDefaults, not SwiftData: this is a single "where was I" pointer,
    /// not sort-of-record data, so it doesn't need a model/migration. Read by
    /// AppState on cold launch to reopen the month the user was actually
    /// swiping in, instead of always the calendar-latest one.
    static let lastSwipedMonthKeyDefaultsKey = "SortStore.lastSwipedMonthKey"

    var lastSwipedMonthKey: String? {
        UserDefaults.standard.string(forKey: Self.lastSwipedMonthKeyDefaultsKey)
    }

    init(context: ModelContext) {
        self.context = context
        streakCount = (try? fetchOrCreateStreak())?.count ?? 0
        stateCache = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<AssetSortRecord>())) ?? [])
                .map { ($0.assetLocalID, $0.state) }
        )
        resolvedGroupCache = Set(
            ((try? context.fetch(FetchDescriptor<CompareGroupResolution>())) ?? []).map(\.groupKey)
        )
        manuallySortedMonths = Set(
            ((try? context.fetch(FetchDescriptor<MonthSortMeta>())) ?? [])
                .filter(\.manuallyMarkedSorted)
                .map(\.monthKey)
        )
    }

    // MARK: Streak

    private func fetchOrCreateStreak() throws -> StreakRecord {
        let descriptor = FetchDescriptor<StreakRecord>()
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let record = StreakRecord()
        context.insert(record)
        try context.save()
        return record
    }

    func recordActivity() {
        guard let record = try? fetchOrCreateStreak() else { return }
        let today = Calendar.current.startOfDay(for: Date())
        let lastDay = Calendar.current.startOfDay(for: record.lastActiveDay)
        if lastDay == today {
            // already counted today, no-op
        } else if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today),
                  lastDay == yesterday {
            record.count += 1
            record.lastActiveDay = today
        } else {
            record.count = 1
            record.lastActiveDay = today
        }
        try? context.save()
        streakCount = record.count
    }

    // MARK: Per-asset sort state

    private func record(for asset: PHAsset) -> AssetSortRecord? {
        let id = asset.localIdentifier
        let descriptor = FetchDescriptor<AssetSortRecord>(predicate: #Predicate { $0.assetLocalID == id })
        return try? context.fetch(descriptor).first
    }

    func state(for asset: PHAsset) -> SortState {
        stateCache[asset.localIdentifier] ?? .unsorted
    }

    func setState(_ state: SortState, for asset: PHAsset, monthKey: String) {
        if let existing = record(for: asset) {
            existing.state = state
            existing.updatedAt = Date()
        } else {
            context.insert(AssetSortRecord(assetLocalID: asset.localIdentifier, monthKey: monthKey, state: state))
        }
        try? context.save()
        stateCache[asset.localIdentifier] = state
        UserDefaults.standard.set(monthKey, forKey: Self.lastSwipedMonthKeyDefaultsKey)
        if state != .unsorted { recordActivity() }
    }

    /// Reads `stateCache`, the same in-memory map `state(for:)` uses — not a
    /// SwiftData fetch. This is called from MonthCardView's body (three times
    /// per render: `isSorted`, the count label, and the accessibility label),
    /// so for a month with hundreds of assets a live `#Predicate` fetch with a
    /// captured ID set here was a synchronous disk round-trip on the main
    /// thread every time the grid redrew — including the redraw the tap that
    /// opens the deck triggers, which is what stalled deck-open on a large
    /// month.
    func addressedCount(for assets: [PHAsset]) -> Int {
        assets.reduce(into: 0) { count, asset in
            if let state = stateCache[asset.localIdentifier], state != .unsorted {
                count += 1
            }
        }
    }

    // MARK: Per-month manual override

    func isMonthManuallySorted(_ monthKey: String) -> Bool {
        manuallySortedMonths.contains(monthKey)
    }

    func setMonthManuallySorted(_ sorted: Bool, monthKey: String) {
        let descriptor = FetchDescriptor<MonthSortMeta>(predicate: #Predicate { $0.monthKey == monthKey })
        if let existing = try? context.fetch(descriptor).first {
            existing.manuallyMarkedSorted = sorted
            existing.updatedAt = Date()
        } else {
            context.insert(MonthSortMeta(monthKey: monthKey, manuallyMarkedSorted: sorted))
        }
        try? context.save()
        if sorted {
            manuallySortedMonths.insert(monthKey)
        } else {
            manuallySortedMonths.remove(monthKey)
        }
    }

    /// "Mark as unsorted" needs more than clearing the manual flag: once
    /// every asset in the month has been individually swiped
    /// (.kept/.markedForDelete), MonthCardView's remainingCount is already 0
    /// on its own, so the card kept reading "Sorted" even with the flag
    /// cleared — clearing a flag that isn't what's holding it sorted is a
    /// no-op. This resets every non-.unsorted, non-.deleted asset in the
    /// month back to .unsorted so remainingCount becomes true again.
    /// .deleted is left alone — those assets are actually gone from
    /// PhotoKit, re-surfacing them as "to sort" would dangle.
    func markMonthUnsorted(monthKey: String, assets: [PHAsset]) {
        setMonthManuallySorted(false, monthKey: monthKey)
        for asset in assets {
            let state = stateCache[asset.localIdentifier] ?? .unsorted
            guard state != .unsorted, state != .deleted else { continue }
            setState(.unsorted, for: asset, monthKey: monthKey)
        }
        // setMonthManuallySorted only republishes manuallySortedMonths, and
        // setState above doesn't touch any @Published property at all (see
        // stateCache's own doc comment) — so without an explicit republish
        // here, a month whose assets were all reset but whose manual flag
        // was never set would show no observable change and the card would
        // stay stuck on its stale "Sorted" label, same class of bug commit
        // 3ebf330 fixed for the flag-only case.
        objectWillChange.send()
    }

    // MARK: Compare group resolution

    func isGroupResolved(_ groupKey: String) -> Bool {
        resolvedGroupCache.contains(groupKey)
    }

    func markGroupResolved(_ groupKey: String) {
        context.insert(CompareGroupResolution(groupKey: groupKey))
        try? context.save()
        resolvedGroupCache.insert(groupKey)
    }

    /// Inverse of `markGroupResolved` — for undoing a Compare confirm, so the
    /// group goes back to offering its "Compare" pill instead of staying
    /// permanently resolved. Deletes the persisted row AND drops the key
    /// from `resolvedGroupCache`: `isGroupResolved` below reads exclusively
    /// from the cache (see its own doc comment on why), so a version of this
    /// that only deleted the SwiftData row would leave the cache stale and
    /// undo would silently do nothing — the exact class of cache/read-path
    /// split that bit `AppState.init`'s SortStore construction ordering
    /// earlier this project.
    func unresolveGroup(_ groupKey: String) {
        let descriptor = FetchDescriptor<CompareGroupResolution>(predicate: #Predicate { $0.groupKey == groupKey })
        for resolution in (try? context.fetch(descriptor)) ?? [] {
            context.delete(resolution)
        }
        try? context.save()
        resolvedGroupCache.remove(groupKey)
    }
}
