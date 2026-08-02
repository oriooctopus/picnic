import SwiftUI
import Photos

@MainActor
final class CompareViewModel: ObservableObject {
    let group: CompareGroup
    private let monthKey: String
    private let sortStore: SortStore
    private let photoLibrary: PhotoLibraryService
    private let mirrorQueue: MirrorQueueStore

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
        mirrorQueue: MirrorQueueStore
    ) {
        self.group = group
        self.monthKey = monthKey
        self.sortStore = sortStore
        self.photoLibrary = photoLibrary
        self.mirrorQueue = mirrorQueue
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
    /// dangling. This is the one exception in the app where a delete happens
    /// outside the deck's X commit — it is still gated on an explicit user
    /// confirm, and PhotoKit still shows its own system confirmation dialog.
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

        do {
            let filenames = Dictionary(
                uniqueKeysWithValues: toDelete.map { ($0.localIdentifier, photoLibrary.originalFilename(for: $0)) }
            )
            try await photoLibrary.deleteAssets(toDelete)
            mirrorQueue.enqueue(assets: toDelete, filenames: filenames)
            for asset in toDelete {
                sortStore.setState(.deleted, for: asset, monthKey: monthKey)
            }
            if let kept {
                sortStore.setState(.kept, for: kept, monthKey: monthKey)
            }
            sortStore.markGroupResolved(group.id)
            await mirrorQueue.drainQueue()
            isResolved = true
        } catch {
            resolveError = "\(error)"
        }
    }
}
