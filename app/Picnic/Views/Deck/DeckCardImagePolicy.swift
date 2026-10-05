import Foundation

/// What a photo card is showing and what that allows, as pure values so the
/// decisions are unit-testable without PhotoKit. The deck loads each photo
/// opportunistically (cached low-res first, then the full image), and an
/// iCloud-only photo on a phone without signal may never get past low-res, or
/// get no pixels at all.
enum DeckCardImagePolicy {
    /// ASSUMPTION (flip here): with NO image at all (nothing cached locally and
    /// iCloud unreachable) the card is still swipeable for keep, but a delete
    /// swipe is blocked with a short explanation, because deleting a photo the
    /// user cannot see is a blind destructive action. Set to false to allow
    /// delete swipes on such cards.
    static let blockDeleteWithoutLocalImage = true

    enum Quality: Equatable {
        /// No result from PhotoKit yet. Deletes stay allowed so a card that is
        /// merely slow to load is never locked.
        case loading
        /// PhotoKit finished and had no pixels to show.
        case none
        /// Pixels on screen, but only the cached low-res/degraded version.
        case partial
        case full

        var hasPixels: Bool { self == .partial || self == .full }
    }

    /// Folds one PhotoKit callback into the card's quality. A final nil result
    /// after a low-res image was already shown (the iCloud download failed)
    /// keeps the low-res image on screen, so it stays `.partial`.
    static func next(after current: Quality, hasImage: Bool, isDegraded: Bool) -> Quality {
        if hasImage { return isDegraded ? .partial : .full }
        if isDegraded { return current }
        return current.hasPixels ? current : .none
    }

    /// The small "in iCloud" badge: only while the low-res stand-in is what is
    /// shown and PhotoKit says the real image lives in iCloud.
    static func showsICloudBadge(quality: Quality, isInCloud: Bool) -> Bool {
        quality == .partial && isInCloud
    }

    static func deleteBlocked(quality: Quality) -> Bool {
        blockDeleteWithoutLocalImage && quality == .none
    }

    /// Compare's delete gate: only a member with pixels on screen may be cued
    /// for delete (`.loading` is NOT enough here, see CompareResolutionPlan).
    static func compareDeleteAllowed(quality: Quality) -> Bool {
        !blockDeleteWithoutLocalImage || quality.hasPixels
    }

    static let blockedDeleteMessage = "Not downloaded yet. Go online to delete this photo."
}

/// What the current deck card knows about its image: the fold of every PhotoKit
/// callback, and the two things the card derives from it. DeckView owns one and
/// passes `showsICloudBadge` / `deleteBlocked` straight to the card, so the
/// wiring from loader updates to card flags is testable without a view.
struct DeckCardImageState: Equatable {
    private(set) var quality: DeckCardImagePolicy.Quality = .loading
    private(set) var isInCloud = false

    /// A new card became current. A prefetched stand-in is pixels on screen, but
    /// not the final image.
    mutating func begin(prefetched: Bool) {
        quality = prefetched ? .partial : .loading
        isInCloud = false
    }

    /// Video cards have their own load/retry UI and are never delete-blocked.
    mutating func markVideo() { quality = .full }

    mutating func apply(_ update: DeckImageUpdate) {
        quality = DeckCardImagePolicy.next(after: quality, hasImage: update.image != nil, isDegraded: update.isDegraded)
        isInCloud = update.isInCloud
    }

    var showsICloudBadge: Bool { DeckCardImagePolicy.showsICloudBadge(quality: quality, isInCloud: isInCloud) }
    var deleteBlocked: Bool { DeckCardImagePolicy.deleteBlocked(quality: quality) }
}
