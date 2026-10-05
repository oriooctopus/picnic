import SwiftUI
import Photos

@MainActor
final class CompareViewModel: ObservableObject {
    let group: CompareGroup
    private let photoLibrary: PhotoLibraryService
    /// Hands the WHOLE resolution — every rejected asset, every accepted
    /// asset, and the group's own id — to the deck's single mutation choke
    /// point (`DeckViewModel.resolveCompareGroup`) instead of writing
    /// SortState here. This view model used to call `sortStore.setState`
    /// for the accepted photos directly, which made that half of a Compare
    /// confirm invisible to the deck's undo stack — see
    /// resolveCompareGroup's doc comment for why that mattered. There is now
    /// no `SortStore` reference in this file at all: every persisted write a
    /// Compare confirm causes goes through this one closure.
    private let onResolve: (_ toDelete: [PHAsset], _ kept: [PHAsset], _ groupID: String) -> Void

    @Published var fileSizes: [String: Int64] = [:]
    @Published var acceptedAssetIDs: Set<String> = []
    @Published var rejectedAssetIDs: Set<String> = []
    @Published var favoritedAssetIDs: Set<String> = []
    @Published var isResolving = false
    @Published var resolveError: String?
    @Published var isResolved = false
    /// What actually displayed for each member, reported by its card. Absent = never loaded.
    @Published private(set) var imageQuality: [String: DeckCardImagePolicy.Quality] = [:]
    /// Set when a confirm kept members because their image never displayed;
    /// the view shows it, then `acknowledgeNotice()` finishes the dismiss.
    @Published var resolveNotice: String?

    /// Reported by a member's page card and by its bottom-strip thumbnail. A
    /// member that displayed pixels in either place stays "seen": a later
    /// no-pixels report from the other place never un-sees it.
    func imageQualityChanged(_ assetID: String, _ quality: DeckCardImagePolicy.Quality) {
        if let existing = imageQuality[assetID], existing.hasPixels, !quality.hasPixels { return }
        imageQuality[assetID] = quality
    }

    func acknowledgeNotice() {
        resolveNotice = nil
        isResolved = true
    }

    var bestAssetID: String? {
        fileSizes.max(by: { $0.value < $1.value })?.key
    }

    var canConfirm: Bool {
        !acceptedAssetIDs.isEmpty || !rejectedAssetIDs.isEmpty
    }

    init(
        group: CompareGroup,
        photoLibrary: PhotoLibraryService,
        onResolve: @escaping (_ toDelete: [PHAsset], _ kept: [PHAsset], _ groupID: String) -> Void
    ) {
        self.group = group
        self.photoLibrary = photoLibrary
        self.onResolve = onResolve
    }

    func loadFileSizes() {
        fileSizes = BestPhotoResolver.fileSizes(for: group.assets)
    }

    /// Thumbs-up: a per-photo toggle, not a group-wide keeper election.
    /// Accepting used to set a single `acceptedAssetID` and wipe every
    /// reject, so a group could only ever carry one mark in total — tapping
    /// thumbs-up on a second photo silently un-marked the first. Marks are
    /// now independent per photo: the only cross-set rule is that a photo
    /// can't be both kept and deleted, so accepting clears this photo's own
    /// reject (and tapping again un-marks it).
    ///
    /// Returns whether this tap ADDED a mark (vs. toggled one off) — the
    /// view uses that to auto-advance to the next card. Un-marking must not
    /// advance: the user is correcting the photo in front of them, and
    /// paging away from it is the opposite of what they asked for.
    @discardableResult
    func accept(_ asset: PHAsset) -> Bool {
        let id = asset.localIdentifier
        rejectedAssetIDs.remove(id)
        if acceptedAssetIDs.contains(id) {
            acceptedAssetIDs.remove(id)
            return false
        }
        acceptedAssetIDs.insert(id)
        return true
    }

    /// Trash: a per-photo toggle, mirroring `accept`. Rejecting one member no
    /// longer cues the whole group for deletion — that made "delete this one
    /// bad shot out of five" impossible to express.
    ///
    /// Returns whether this tap ADDED a mark, same contract as `accept`.
    @discardableResult
    func reject(_ asset: PHAsset) -> Bool {
        let id = asset.localIdentifier
        acceptedAssetIDs.remove(id)
        if rejectedAssetIDs.contains(id) {
            rejectedAssetIDs.remove(id)
            return false
        }
        rejectedAssetIDs.insert(id)
        return true
    }

    func toggleFavorite(_ asset: PHAsset) async {
        let id = asset.localIdentifier
        let newValue = !favoritedAssetIDs.contains(id)
        do {
            try await photoLibrary.setFavorite(asset, isFavorite: newValue)
            if newValue { favoritedAssetIDs.insert(id) } else { favoritedAssetIDs.remove(id) }
        } catch {
            resolveError = "\(error)"
        }
    }

    /// Per-photo resolution: every rejected member is cued for deletion and
    /// every accepted member is marked kept, in one undoable batch.
    ///
    /// Unmarked members depend on which marks were made:
    /// - Accepts only (no trash marks): "keep these, lose the rest" — every
    ///   unmarked member is cued for deletion. This is the core Compare
    ///   gesture (thumbs-up the best shot, confirm, duplicates gone). The
    ///   2026-09-04 multi-select rewrite dropped it by accident, leaving
    ///   accept-one-and-confirm a no-op for the rest of the group.
    /// - Any trash mark present: unmarked members stay unsorted. The user
    ///   is picking out specific bad shots ("delete just this one of
    ///   five"), so sweeping the untouched ones into the bin would delete
    ///   photos they never judged.
    ///
    /// Rejected members go
    /// into the deck's pending-delete cue via `onResolve`, exactly like a
    /// swipe-left, and are only actually deleted later when the user presses
    /// the deck's X. `onResolve` alone carries every write this resolution
    /// causes — see its doc comment above for why this view model no longer
    /// touches SortStore itself.
    func confirmResolution() async {
        guard canConfirm else { return }
        isResolving = true
        defer { isResolving = false }

        // Gate on what actually displayed (imageQuality), never a fresh PhotoKit query.
        let plan = CompareResolutionPlan.make(
            memberIDs: group.assets.map(\.localIdentifier),
            accepted: acceptedAssetIDs, rejected: rejectedAssetIDs, quality: imageQuality
        )
        let toDelete = group.assets.filter { plan.deleteIDs.contains($0.localIdentifier) }
        let kept = group.assets.filter { plan.keptIDs.contains($0.localIdentifier) }

        onResolve(toDelete, kept, group.id)
        if let notice = plan.notice {
            resolveNotice = notice
        } else {
            isResolved = true
        }
    }
}
