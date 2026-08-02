import Foundation
import SwiftData

/// Per-asset sort state. `.deleted` marks assets that were actually removed
/// via a committed PhotoKit delete (deck commit or a resolved compare group)
/// — kept as a historical record even though the PHAsset no longer exists.
enum SortState: String, Codable {
    case unsorted
    case markedForDelete
    case kept
    case deleted
}

@Model
final class AssetSortRecord {
    @Attribute(.unique) var assetLocalID: String
    var monthKey: String
    var stateRaw: String
    var updatedAt: Date

    var state: SortState {
        get { SortState(rawValue: stateRaw) ?? .unsorted }
        set { stateRaw = newValue.rawValue }
    }

    init(assetLocalID: String, monthKey: String, state: SortState = .unsorted) {
        self.assetLocalID = assetLocalID
        self.monthKey = monthKey
        self.stateRaw = state.rawValue
        self.updatedAt = Date()
    }
}

/// Manual "Mark as sorted / unsorted" override from the My Life long-press
/// menu, independent of whether every individual asset has been addressed.
@Model
final class MonthSortMeta {
    @Attribute(.unique) var monthKey: String
    var manuallyMarkedSorted: Bool
    var updatedAt: Date

    init(monthKey: String, manuallyMarkedSorted: Bool = false) {
        self.monthKey = monthKey
        self.manuallyMarkedSorted = manuallyMarkedSorted
        self.updatedAt = Date()
    }
}

/// Singleton streak counter, incremented at most once per calendar day the
/// user addresses at least one photo.
@Model
final class StreakRecord {
    @Attribute(.unique) var id: String
    var count: Int
    var lastActiveDay: Date

    init(count: Int = 0, lastActiveDay: Date = .distantPast) {
        self.id = "singleton"
        self.count = count
        self.lastActiveDay = lastActiveDay
    }
}

/// One pending (or already-sent) POST to the Google Photos mirror queue.
/// Created only after a PhotoKit delete has actually succeeded.
@Model
final class MirrorJobRecord {
    @Attribute(.unique) var id: UUID
    var filename: String
    var creationDateISO8601: String
    var pixelWidth: Int
    var pixelHeight: Int
    var mediaType: String
    var isLivePhoto: Bool
    var createdAt: Date
    var attemptCount: Int
    var lastError: String?
    /// "pending" | "sent"
    var status: String

    init(
        id: UUID,
        filename: String,
        creationDateISO8601: String,
        pixelWidth: Int,
        pixelHeight: Int,
        mediaType: String,
        isLivePhoto: Bool,
        status: String
    ) {
        self.id = id
        self.filename = filename
        self.creationDateISO8601 = creationDateISO8601
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mediaType = mediaType
        self.isLivePhoto = isLivePhoto
        self.createdAt = Date()
        self.attemptCount = 0
        self.lastError = nil
        self.status = status
    }
}

/// Marks a Compare group (keyed by its sorted member local-identifiers) as
/// already resolved, so it stops surfacing a "Compare" pill in the deck.
@Model
final class CompareGroupResolution {
    @Attribute(.unique) var groupKey: String
    var resolvedAt: Date

    init(groupKey: String) {
        self.groupKey = groupKey
        self.resolvedAt = Date()
    }
}
