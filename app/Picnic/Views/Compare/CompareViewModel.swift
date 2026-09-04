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

    func loadFileSizes() async {
        fileSizes = await BestPhotoResolver.fileSizes(for: group.assets)
    }

    /// Thumbs-up: a per-photo toggle, not a group-wide keeper election.
    /// Accepting used to set a single `acceptedAssetID` and wipe every
    /// reject, so a group could only ever carry one mark in total — tapping
    /// thumbs-up on a second photo silently un-marked the first. Marks are
    /// now independent per photo: the only cross-set rule is that a photo
    /// can't be both kept and deleted, so accepting clears this photo's own
    /// reject (and tapping again un-marks it).
    func accept(_ asset: PHAsset) {
        let id = asset.localIdentifier
        rejectedAssetIDs.remove(id)
        if acceptedAssetIDs.contains(id) {
            acceptedAssetIDs.remove(id)
        } else {
            acceptedAssetIDs.insert(id)
        }
    }

    /// Trash: a per-photo toggle, mirroring `accept`. Rejecting one member no
    /// longer cues the whole group for deletion — that made "delete this one
    /// bad shot out of five" impossible to express.
    func reject(_ asset: PHAsset) {
        let id = asset.localIdentifier
        acceptedAssetIDs.remove(id)
        if rejectedAssetIDs.contains(id) {
            rejectedAssetIDs.remove(id)
        } else {
            rejectedAssetIDs.insert(id)
        }
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
    /// Unmarked members are deliberately left untouched — they stay
    /// unsorted in the deck rather than being inferred into either bucket,
    /// which is what makes marking a subset meaningful. Rejected members go
    /// into the deck's pending-delete cue via `onResolve`, exactly like a
    /// swipe-left, and are only actually deleted later when the user presses
    /// the deck's X. `onResolve` alone carries every write this resolution
    /// causes — see its doc comment above for why this view model no longer
    /// touches SortStore itself.
    func confirmResolution() async {
        guard canConfirm else { return }
        isResolving = true
        defer { isResolving = false }

        let toDelete = group.assets.filter { rejectedAssetIDs.contains($0.localIdentifier) }
        let kept = group.assets.filter { acceptedAssetIDs.contains($0.localIdentifier) }

        onResolve(toDelete, kept, group.id)
        isResolved = true
    }
}
