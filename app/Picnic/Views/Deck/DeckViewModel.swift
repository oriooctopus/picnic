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

    @Published var orderedAssets: [PHAsset] { didSet { recomputeVisibleAssets() } }
    /// Persisted directly via UserDefaults rather than @AppStorage: this
    /// class is a plain ObservableObject (not a View), and @AppStorage's
    /// dynamic-property machinery only works when hosted inside SwiftUI's
    /// View update cycle.
    static let hideSortedDefaultsKey = "deck.hideSorted"
    @Published var hideSorted = UserDefaults.standard.bool(forKey: DeckViewModel.hideSortedDefaultsKey) {
        didSet {
            UserDefaults.standard.set(hideSorted, forKey: DeckViewModel.hideSortedDefaultsKey)
            // Read before recompute: visibleAssets/currentIndex still
            // reflect the pre-toggle list at this point in didSet.
            let previousAssetID = currentAsset?.localIdentifier
            recomputeVisibleAssets()
            reanchorCurrentIndex(toFollow: previousAssetID)
        }
    }
    @Published var currentIndex = 0
    /// Swipe-left cues — a CUE ONLY. Nothing is deleted until commitDeletions()
    /// runs, which is only reachable from the explicit X-button tap.
    @Published var pendingDeleteIDs: Set<String> = [] { didSet { recomputeVisibleAssets() } }
    @Published var undoStack: [UndoEntry] = []
    @Published var favoritedOverrides: [String: Bool] = [:]
    @Published var isCommitting = false
    @Published var commitError: String?

    /// Fired synchronously, in the same call as `currentIndex` moving forward
    /// by exactly one (see `advance()`), so the view can promote its already
    /// -loaded next-image into current-image before any async reload runs.
    /// Without this the new card mounts showing the OLD `currentImage` until
    /// `loadCurrentImage()`'s await returns — a ~0.1s flicker of the wrong
    /// photo.
    var onAdvance: (() -> Void)?

    init(month: MonthBucket, sortStore: SortStore, photoLibrary: PhotoLibraryService, mirrorQueue: MirrorQueueStore) {
        self.month = month
        self.sortStore = sortStore
        self.photoLibrary = photoLibrary
        self.mirrorQueue = mirrorQueue
        self.orderedAssets = month.assets
        // Kept state survives relaunch because sortStore.state(for:) is read
        // live everywhere. pendingDeleteIDs doesn't get that for free — it's
        // a plain in-memory Set — so without this, X-marked photos lost both
        // their filmstrip indicator AND their place in the X commit count
        // the moment the app was closed and reopened, even though the
        // underlying .markedForDelete state was sitting in SortStore the
        // whole time.
        self.pendingDeleteIDs = Set(
            month.assets
                .filter { sortStore.state(for: $0) == .markedForDelete }
                .map(\.localIdentifier)
        )
        // didSet doesn't fire for assignments inside init, so seed it here.
        recomputeVisibleAssets()
    }

    /// Stored, not computed. The deck's view body reads this several times per
    /// evaluation (stack peek, current card, filmstrip, position label), so as
    /// a computed property it re-filtered the entire month's assets on every
    /// one of those reads. Recomputed only when an input actually changes.
    @Published private(set) var visibleAssets: [PHAsset] = []

    /// assetLocalIdentifier → the compare group it belongs to. Built with
    /// visibleAssets because `GroupingService.group(containing:in:)` sorts and
    /// re-clusters the entire list on each call, which the deck was paying per
    /// card change.
    @Published private(set) var groupByAssetID: [String: CompareGroup] = [:]

    private func recomputeVisibleAssets() {
        visibleAssets = orderedAssets.filter { asset in
            // hideSorted hides BOTH kept and pending-delete/X'd photos — from
            // the user's perspective both are "sorted", so both should drop
            // out of the deck/filmstrip. When hideSorted is off, a
            // pending-delete photo is force-shown unconditionally so it stays
            // reviewable/undoable up until the X-button commits it.
            if hideSorted, pendingDeleteIDs.contains(asset.localIdentifier) { return false }
            if pendingDeleteIDs.contains(asset.localIdentifier) { return true }
            if hideSorted, sortStore.state(for: asset) == .kept { return false }
            return true
        }
        var lookup: [String: CompareGroup] = [:]
        for group in GroupingService.groups(in: visibleAssets) {
            for member in group.assets {
                lookup[member.localIdentifier] = group
            }
        }
        groupByAssetID = lookup
    }

    var currentAsset: PHAsset? {
        guard visibleAssets.indices.contains(currentIndex) else { return nil }
        return visibleAssets[currentIndex]
    }

    /// Keeps the deck showing the same photo across a hideSorted toggle when
    /// that photo is still visible, and lands on the next remaining one
    /// (by original month order, not raw array index) when it isn't —
    /// e.g. turning hideSorted on while sitting on a kept photo. Reusing the
    /// old numeric currentIndex directly into the now-shorter array was the
    /// bug: any kept photo sitting BEFORE the current one shifted every
    /// later index down by one, which silently skipped past still-unsorted
    /// photos instead of landing on the very next one.
    private func reanchorCurrentIndex(toFollow assetID: String?) {
        guard let assetID else {
            currentIndex = min(currentIndex, max(0, visibleAssets.count - 1))
            return
        }
        if let newIndex = visibleAssets.firstIndex(where: { $0.localIdentifier == assetID }) {
            currentIndex = newIndex
            return
        }
        guard let orderedIndex = orderedAssets.firstIndex(where: { $0.localIdentifier == assetID }) else {
            currentIndex = min(currentIndex, max(0, visibleAssets.count - 1))
            return
        }
        let orderedIndexByID = Dictionary(uniqueKeysWithValues: orderedAssets.enumerated().map { ($1.localIdentifier, $0) })
        currentIndex = visibleAssets.firstIndex { asset in
            (orderedIndexByID[asset.localIdentifier] ?? Int.max) >= orderedIndex
        } ?? max(0, visibleAssets.count - 1)
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
        // pendingDeleteIDs' didSet already triggers recomputeVisibleAssets(),
        // and — now that hideSorted also filters pending-delete assets out —
        // that recompute can shift this asset's slot at currentIndex the same
        // way markKept()'s does (see its comment). Blindly calling advance()
        // here would double-skip: the next photo already slid into
        // currentIndex, and advancing again jumps past it.
        pendingDeleteIDs.insert(asset.localIdentifier)
        sortStore.setState(.markedForDelete, for: asset, monthKey: month.key)
        if visibleAssets.indices.contains(currentIndex),
           visibleAssets[currentIndex].localIdentifier == asset.localIdentifier {
            advance()
        }
    }

    /// Compare's confirm: mark an arbitrary batch of assets pending-delete,
    /// same cue semantics as `markForDelete()` (CUE ONLY, no PhotoKit call
    /// here) but for assets Compare picked, not `currentAsset` — so this
    /// deliberately skips the undo stack and `advance()`, neither of which
    /// make sense for a batch that doesn't come from swiping the current
    /// card.
    func markPendingDelete(_ assets: [PHAsset]) {
        for asset in assets {
            pendingDeleteIDs.insert(asset.localIdentifier)
            sortStore.setState(.markedForDelete, for: asset, monthKey: month.key)
        }
    }

    /// Swipe right: keep. No PhotoKit action needed — nothing is deleted.
    func isKept(_ asset: PHAsset) -> Bool {
        sortStore.state(for: asset) == .kept
    }

    func markKept() {
        guard let asset = currentAsset else { return }
        undoStack.append(UndoEntry(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
        sortStore.setState(.kept, for: asset, monthKey: month.key)
        // The sort state lives in SortStore, not in one of the @Published
        // inputs, so nothing above triggers the didSet recompute — without
        // this, marking a photo kept while "Hide sorted pics" is on left it
        // sitting in the deck.
        recomputeVisibleAssets()
        // When hideSorted filtered this photo out, the slot at currentIndex is
        // already occupied by the next photo, so advancing again would skip
        // one.
        if visibleAssets.indices.contains(currentIndex),
           visibleAssets[currentIndex].localIdentifier == asset.localIdentifier {
            advance()
        }
    }

    private func advance() {
        if currentIndex < visibleAssets.count - 1 {
            // withAnimation only wraps the resulting SwiftUI view diff — the
            // currentIndex mutation and onAdvance() itself still run
            // synchronously, in this same call, on this same run-loop turn.
            // That's what keeps this compatible with onAdvance's own
            // contract (see its doc comment): the new photo is assigned
            // before any animated frame renders, so the promoted card can
            // never show the outgoing photo. This only lets DeckView's
            // `.transition` on the newly-mounted card (see DeckCard's call
            // site) ease in instead of cutting.
            withAnimation(.easeOut(duration: 0.28)) {
                currentIndex += 1
                onAdvance?()
            }
        }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        pendingDeleteIDs.remove(last.assetID)
        if let asset = orderedAssets.first(where: { $0.localIdentifier == last.assetID }) {
            sortStore.setState(last.previousState, for: asset, monthKey: month.key)
            // Restoring a .kept photo to .unsorted brings it back into view
            // when hideSorted is on; SortStore changes don't fire the didSet.
            recomputeVisibleAssets()
        }
        // Un-sorting an asset can grow visibleAssets back (the restored photo
        // reappearing under hideSorted), which shifts every later index up —
        // a blind currentIndex - 1 would land on an arbitrary neighbor
        // instead of the photo that was just undone. Reanchor by identity,
        // same as the hideSorted-toggle path above.
        reanchorCurrentIndex(toFollow: last.assetID)
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
