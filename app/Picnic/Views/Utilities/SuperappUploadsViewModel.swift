import Foundation
import Photos

/// State for the "Uploaded" screen: library photos already uploaded to the
/// desktop. Everything starts selected for deletion; `kept` holds the tiles
/// the user tapped back to keep.
@MainActor
final class SuperappUploadsViewModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        /// The server's upload id.
        let id: String
        let assetID: String
    }

    enum State: Equatable {
        case loading
        case loaded
        case deleting
        case failed(String)
        case done
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var kept: Set<String> = []
    @Published private(set) var state: State = .loading
    @Published private(set) var actionMessage: String?

    private let loadMatched: () async throws -> (uploads: [SuperappUpload], matches: [SuperappMatch])
    private let assetFilter: (String) -> Bool
    private let deleteAssets: ([String]) async throws -> Void
    private let resolve: ([String], SuperappUploadsClient.Action) async throws -> Void

    init(
        loadMatched: @escaping () async throws -> (uploads: [SuperappUpload], matches: [SuperappMatch]) = SuperappLibraryMatcher.loadMatched,
        assetFilter: @escaping (String) -> Bool = { _ in true },
        deleteAssets: @escaping ([String]) async throws -> Void,
        resolve: @escaping ([String], SuperappUploadsClient.Action) async throws -> Void = { try await SuperappUploadsClient.resolve(ids: $0, action: $1) }
    ) {
        self.loadMatched = loadMatched
        self.assetFilter = assetFilter
        self.deleteAssets = deleteAssets
        self.resolve = resolve
    }

    /// The real PhotoKit-backed model; `assetFilter` limits which matched assets are listed.
    static func live(photoLibrary: PhotoLibraryService, assetFilter: @escaping (String) -> Bool = { _ in true }) -> SuperappUploadsViewModel {
        SuperappUploadsViewModel(
            assetFilter: assetFilter,
            deleteAssets: { ids in
                var assets: [PHAsset] = []
                PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
                #if DEBUG
                if SuperappSeed.isEnabled { return }
                #endif
                try await photoLibrary.deleteAssets(assets)
            },
            resolve: { ids, action in
                #if DEBUG
                if SuperappSeed.isEnabled { return }
                #endif
                try await SuperappUploadsClient.resolve(ids: ids, action: action)
            }
        )
    }

    var deleteCount: Int { items.count - kept.count }

    func isKept(_ item: Item) -> Bool { kept.contains(item.id) }

    func toggle(_ item: Item) {
        guard state == .loaded else { return }
        if kept.contains(item.id) { kept.remove(item.id) } else { kept.insert(item.id) }
    }

    func load() async {
        state = .loading
        actionMessage = nil
        do {
            let (uploads, matches) = try await loadMatched()
            let assetByUpload = Dictionary(uniqueKeysWithValues: matches.filter { assetFilter($0.assetID) }.map { ($0.uploadID, $0.assetID) })
            items = uploads.compactMap { upload in
                assetByUpload[upload.id].map { Item(id: upload.id, assetID: $0) }
            }
            kept = []
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Deletes the selected batch in one PhotoKit call (one iOS prompt), then
    /// tells the server which ids were deleted and which kept. A cancelled
    /// prompt changes nothing.
    func confirm() async {
        guard state == .loaded, deleteCount > 0 else { return }
        let toDelete = items.filter { !kept.contains($0.id) }
        let toKeep = items.filter { kept.contains($0.id) }
        state = .deleting
        actionMessage = nil
        do {
            try await deleteAssets(toDelete.map(\.assetID))
        } catch {
            state = .loaded
            if (error as? PHPhotosError)?.code != .userCancelled {
                actionMessage = "Delete failed: \(error.localizedDescription)"
            }
            return
        }
        do {
            try await resolve(toDelete.map(\.id), .deleted)
            try await resolve(toKeep.map(\.id), .kept)
            state = .done
        } catch {
            state = .failed("Deleted, but syncing failed: \(error.localizedDescription)")
        }
    }
}
