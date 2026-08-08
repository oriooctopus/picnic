import SwiftUI
import Photos

@MainActor
final class CompareViewModel: ObservableObject {
    let group: CompareGroup
    private let monthKey: String
    private let sortStore: SortStore
    private let photoLibrary: PhotoLibraryService
    /// Hands rejected assets to the deck's own pending-delete cue instead of
    /// deleting them here — see confirmResolution()'s doc comment.
    private let onResolve: ([PHAsset]) -> Void

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
        monthKey: String,
        sortStore: SortStore,
        photoLibrary: PhotoLibraryService,
        onResolve: @escaping ([PHAsset]) -> Void
    ) {
        self.group = group
        self.monthKey = monthKey
        self.sortStore = sortStore
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

        onResolve(toDelete)
        if let kept {
            sortStore.setState(.kept, for: kept, monthKey: monthKey)
        }
        sortStore.markGroupResolved(group.id)
        isResolved = true
    }
}
