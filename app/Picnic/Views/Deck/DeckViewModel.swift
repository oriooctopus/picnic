import SwiftUI
import Photos

struct UndoEntry {
    let assetID: String
    let previousState: SortState
}

@MainActor
final class DeckViewModel: ObservableObject {
    let month: MonthBucket
    private let sortStore: SortStore
    private let photoLibrary: PhotoLibraryService
    private let mirrorQueue: MirrorQueueStore

    @Published var orderedAssets: [PHAsset]
    @Published var hideSorted = false
    @Published var currentIndex = 0
    /// Swipe-left cues — a CUE ONLY. Nothing is deleted until commitDeletions()
    /// runs, which is only reachable from the explicit X-button tap.
    @Published var pendingDeleteIDs: Set<String> = []
    @Published var undoStack: [UndoEntry] = []
    @Published var favoritedOverrides: [String: Bool] = [:]
    @Published var isCommitting = false
    @Published var commitError: String?

    init(month: MonthBucket, sortStore: SortStore, photoLibrary: PhotoLibraryService, mirrorQueue: MirrorQueueStore) {
        self.month = month
        self.sortStore = sortStore
        self.photoLibrary = photoLibrary
        self.mirrorQueue = mirrorQueue
        self.orderedAssets = month.assets
    }

    var visibleAssets: [PHAsset] {
        orderedAssets.filter { asset in
            if pendingDeleteIDs.contains(asset.localIdentifier) { return true }
            if hideSorted, sortStore.state(for: asset) == .kept { return false }
            return true
        }
    }

    var currentAsset: PHAsset? {
        guard visibleAssets.indices.contains(currentIndex) else { return nil }
        return visibleAssets[currentIndex]
    }

    func isFavorite(_ asset: PHAsset) -> Bool {
        favoritedOverrides[asset.localIdentifier] ?? asset.isFavorite
    }

    func toggleFavorite(_ asset: PHAsset) async {
        let newValue = !isFavorite(asset)
        do {
            try await photoLibrary.setFavorite(asset, isFavorite: newValue)
            favoritedOverrides[asset.localIdentifier] = newValue
        } catch {
            commitError = "\(error)"
        }
    }

    func shuffle() {
        orderedAssets.shuffle()
        currentIndex = 0
    }

    /// Swipe left: mark for delete. This is a CUE ONLY (SPEC.md interaction
    /// semantics #1) — the X commit button performs the real PhotoKit delete.
    func markForDelete() {
        guard let asset = currentAsset else { return }
        undoStack.append(UndoEntry(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
        pendingDeleteIDs.insert(asset.localIdentifier)
        sortStore.setState(.markedForDelete, for: asset, monthKey: month.key)
        advance()
    }

    /// Swipe right: keep. No PhotoKit action needed — nothing is deleted.
    func markKept() {
        guard let asset = currentAsset else { return }
        undoStack.append(UndoEntry(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
        sortStore.setState(.kept, for: asset, monthKey: month.key)
        advance()
    }

    private func advance() {
        if currentIndex < visibleAssets.count - 1 {
            currentIndex += 1
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        pendingDeleteIDs.remove(last.assetID)
        if let asset = orderedAssets.first(where: { $0.localIdentifier == last.assetID }) {
            sortStore.setState(last.previousState, for: asset, monthKey: month.key)
        }
        currentIndex = max(0, currentIndex - 1)
    }

    /// The single X commit: one PhotoKit batch delete (system confirm dialog
    /// is automatic), then every deleted asset is queued for the mirror POST.
    func commitDeletions() async {
        let toDelete = orderedAssets.filter { pendingDeleteIDs.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            let filenames = Dictionary(
                uniqueKeysWithValues: toDelete.map { ($0.localIdentifier, photoLibrary.originalFilename(for: $0)) }
            )
            try await photoLibrary.deleteAssets(toDelete)
            mirrorQueue.enqueue(assets: toDelete, filenames: filenames)
            for asset in toDelete {
                sortStore.setState(.deleted, for: asset, monthKey: month.key)
            }
            pendingDeleteIDs.removeAll()
            undoStack.removeAll()
            await mirrorQueue.drainQueue()
        } catch {
            // If the user declines the system confirm dialog (or the delete
            // otherwise fails), pendingDeleteIDs stays intact so nothing is
            // silently lost and the X badge keeps showing the count.
            commitError = "\(error)"
        }
    }
}
