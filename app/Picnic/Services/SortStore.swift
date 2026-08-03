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

    func addressedCount(for assets: [PHAsset]) -> Int {
        let ids = Set(assets.map(\.localIdentifier))
        let descriptor = FetchDescriptor<AssetSortRecord>(
            predicate: #Predicate { ids.contains($0.assetLocalID) && $0.stateRaw != "unsorted" }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
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
}
