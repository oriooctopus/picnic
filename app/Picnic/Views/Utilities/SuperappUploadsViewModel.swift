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

    private let loadItems: () async throws -> [Item]
    /// Where the kept picks persist between visits; nil = every load starts with nothing kept.
    private let keptStore: (defaults: UserDefaults, key: String)?
    private let deleteAssets: ([String]) async throws -> Void
    private let resolve: ([String], SuperappUploadsClient.Action) async throws -> Void

    /// Generic batch-delete list. `keptStore` is for lists with no server to
    /// record "kept" on: without it a kept tile would come back marked for
    /// deletion on the next visit, one careless confirm away from being lost.
    init(
        loadItems: @escaping () async throws -> [Item],
        keptStore: (defaults: UserDefaults, key: String)? = nil,
        deleteAssets: @escaping ([String]) async throws -> Void,
        resolve: @escaping ([String], SuperappUploadsClient.Action) async throws -> Void
    ) {
        self.loadItems = loadItems
        self.keptStore = keptStore
        self.deleteAssets = deleteAssets
        self.resolve = resolve
    }

    /// Superapp uploads still in the library, optionally narrowed by `assetFilter`.
    convenience init(
        loadMatched: @escaping () async throws -> (uploads: [SuperappUpload], matches: [SuperappMatch]) = SuperappLibraryMatcher.loadMatched,
        assetFilter: @escaping (String) -> Bool = { _ in true },
        deleteAssets: @escaping ([String]) async throws -> Void,
        resolve: @escaping ([String], SuperappUploadsClient.Action) async throws -> Void = { try await SuperappUploadsClient.resolve(ids: $0, action: $1) }
    ) {
        self.init(
            loadItems: {
                let (uploads, matches) = try await loadMatched()
                let assetByUpload = Dictionary(uniqueKeysWithValues: matches.filter { assetFilter($0.assetID) }.map { ($0.uploadID, $0.assetID) })
                return uploads.compactMap { upload in
                    assetByUpload[upload.id].map { Item(id: upload.id, assetID: $0) }
                }
            },
            deleteAssets: deleteAssets, resolve: resolve
        )
    }

    /// The real PhotoKit-backed model; `assetFilter` limits which matched assets are listed.
    static func live(photoLibrary: PhotoLibraryService, assetFilter: @escaping (String) -> Bool = { _ in true }) -> SuperappUploadsViewModel {
        SuperappUploadsViewModel(
            assetFilter: assetFilter,
            deleteAssets: { try await liveDelete($0, photoLibrary: photoLibrary) },
            resolve: { ids, action in
                #if DEBUG
                if SuperappSeed.isEnabled { return }
                #endif
                try await SuperappUploadsClient.resolve(ids: ids, action: action)
            }
        )
    }

    /// Every asset of a smart collection (not only uploaded ones), keyed by
    /// asset id. Nothing to tell the server, so kept picks persist locally.
    static func liveCollection(photoLibrary: PhotoLibraryService, kind: SmartCollectionKind) -> SuperappUploadsViewModel {
        SuperappUploadsViewModel(
            loadItems: {
                var source = kind
                #if DEBUG
                // PhotoKit cannot create screenshot-subtype assets, so the seeded
                // simulator library would always show an empty grid.
                if SuperappSeed.isEnabled { source = .photos }
                #endif
                return await photoLibrary.fetchSmartCollection(source).map { Item(id: $0.localIdentifier, assetID: $0.localIdentifier) }
            },
            keptStore: (.standard, "batchDelete.kept.\(kind)"),
            deleteAssets: { try await liveDelete($0, photoLibrary: photoLibrary) },
            resolve: { _, _ in }
        )
    }

    /// One PhotoKit delete for the batch; a no-op in `--superapp-seed` mode.
    private static func liveDelete(_ ids: [String], photoLibrary: PhotoLibraryService) async throws {
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
        #if DEBUG
        if SuperappSeed.isEnabled { return }
        #endif
        try await photoLibrary.deleteAssets(assets)
    }

    var deleteCount: Int { items.count - kept.count }

    func isKept(_ item: Item) -> Bool { kept.contains(item.id) }

    func toggle(_ item: Item) {
        guard state == .loaded else { return }
        if kept.contains(item.id) { kept.remove(item.id) } else { kept.insert(item.id) }
        if let keptStore { keptStore.defaults.set(Array(kept), forKey: keptStore.key) }
    }

    func load() async {
        state = .loading
        actionMessage = nil
        do {
            items = try await loadItems()
            // Intersect with the current items so ids of deleted assets drop out.
            let stored = keptStore.flatMap { $0.defaults.stringArray(forKey: $0.key) } ?? []
            kept = Set(stored).intersection(items.map(\.id))
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
