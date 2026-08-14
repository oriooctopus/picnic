import SwiftUI
import Photos

@MainActor
final class CompareViewModel: ObservableObject {
    let group: CompareGroup
    private let photoLibrary: PhotoLibraryService
    /// Hands the WHOLE resolution — rejected assets, the accepted keeper (if
    /// any), and the group's own id — to the deck's single mutation choke
    /// point (`DeckViewModel.resolveCompareGroup`) instead of writing
    /// SortState here. This view model used to call `sortStore.setState`
    /// for the accepted photo directly, which made that half of a Compare
    /// confirm invisible to the deck's undo stack — see
    /// resolveCompareGroup's doc comment for why that mattered. There is now
    /// no `SortStore` reference in this file at all: every persisted write a
    /// Compare confirm causes goes through this one closure.
    private let onResolve: (_ toDelete: [PHAsset], _ kept: PHAsset?, _ groupID: String) -> Void

    @Published var fileSizes: [String: Int64] = [:]
    @Published var acceptedAssetID: String?
    @Published var rejectedAssetIDs: Set<String> = []
    @Published var favoritedAssetIDs: Set<String> = []
    @Published var isResolving = false
    @Published var resolveError: String?
    @Published var isResolved = false

    var bestAssetID: String? {
        fileSizes.max(by: { $0.value < $1.value })?.key
    }

    var canConfirm: Bool {
        acceptedAssetID != nil || !rejectedAssetIDs.isEmpty
    }

    init(
        group: CompareGroup,
        photoLibrary: PhotoLibraryService,
        onResolve: @escaping (_ toDelete: [PHAsset], _ kept: PHAsset?, _ groupID: String) -> Void
    ) {
        self.group = group
        self.photoLibrary = photoLibrary
        self.onResolve = onResolve
    }

    func loadFileSizes() async {
        fileSizes = await BestPhotoResolver.fileSizes(for: group.assets)
    }

    /// Thumbs-up: this photo becomes the group's keeper, superseding any
    /// prior reject choice — "deleting one deletes them all" is a stronger
    /// claim than a not-yet-confirmed accept.
    func accept(_ asset: PHAsset) {
        acceptedAssetID = asset.localIdentifier
        rejectedAssetIDs.removeAll()
    }

    /// Trash: rejecting ANY single photo in the group resolves the WHOLE
    /// group for deletion (SPEC.md interaction semantics #2), superseding any
    /// prior accept choice.
    func reject(_ asset: PHAsset) {
        rejectedAssetIDs.insert(asset.localIdentifier)
        acceptedAssetID = nil
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

    /// Total-group resolution, triggered only by the explicit checkmark
    /// confirm: accepting one keeps it and deletes every other member;
    /// rejecting any one deletes the entire group. No member is ever left
    /// dangling. This is NOT an exception to the deck's "only the X commit
    /// deletes" rule anymore — rejected members go into the deck's own
    /// pending-delete cue via `onResolve`, exactly like a swipe-left, and are
    /// only actually deleted later when the user presses the deck's X.
    /// `onResolve` alone carries every write this resolution causes (cued
    /// deletes, the kept photo, and marking the group resolved) — see the
    /// `onResolve` doc comment above for why this view model no longer
    /// touches SortStore itself.
    func confirmResolution() async {
        guard canConfirm else { return }
        isResolving = true
        defer { isResolving = false }

        let toDelete: [PHAsset]
        let kept: PHAsset?
        if let acceptedID = acceptedAssetID {
            toDelete = group.assets.filter { $0.localIdentifier != acceptedID }
            kept = group.assets.first { $0.localIdentifier == acceptedID }
        } else {
            toDelete = group.assets
            kept = nil
        }

        onResolve(toDelete, kept, group.id)
        isResolved = true
    }
}
