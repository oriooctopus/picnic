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
        let descriptor = FetchDescriptor<MonthSortMeta>(predicate: #Predicate { $0.monthKey == monthKey })
        return (try? context.fetch(descriptor).first)?.manuallyMarkedSorted ?? false
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
