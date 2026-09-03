import SwiftUI
import Photos

/// One reversible batch of SortState writes, plus (optionally) the Compare
/// group those writes resolved. A plain swipe (markForDelete/markKept)
/// always pushes a one-element `changes` array, so its own undo behavior is
/// unchanged from before this became a batch type. Compare's confirm is the
/// reason this is a batch at all: it can cue 4+ photos for delete (plus mark
/// one kept) in a single confirm tap, and the old shape — one assetID, one
/// previousState — could only ever describe ONE of those writes. That's why
/// a Compare confirm used to record no undo entry whatsoever (see
/// `markPendingDelete`'s old doc comment, since replaced by
/// `resolveCompareGroup` below): there was no way to push "reverse these 5
/// writes as a unit" onto a stack shaped for exactly 1. `compareGroupID` is
/// nil for a swipe (nothing to un-resolve) and carries the group's id when
/// the batch came from Compare, so `undo()` knows to also call
/// `SortStore.unresolveGroup` and let Compare offer that group again.
struct UndoEntry {
    struct Change {
        let assetID: String
        let previousState: SortState
    }
    let changes: [Change]
    let compareGroupID: String?
}

@MainActor
final class DeckViewModel: ObservableObject {
    let month: MonthBucket
    private let sortStore: SortStore
    private let photoLibrary: PhotoLibraryService
    private let mirrorQueue: MirrorQueueStore

    @Published var orderedAssets: [PHAsset] { didSet { refresh(follow: nil) } }
    /// Persisted directly via UserDefaults rather than @AppStorage: this
    /// class is a plain ObservableObject (not a View), and @AppStorage's
    /// dynamic-property machinery only works when hosted inside SwiftUI's
    /// View update cycle.
    static let hideSortedDefaultsKey = "deck.hideSorted"
    @Published var hideSorted = UserDefaults.standard.bool(forKey: DeckViewModel.hideSortedDefaultsKey) {
        didSet {
            UserDefaults.standard.set(hideSorted, forKey: DeckViewModel.hideSortedDefaultsKey)
            // Read before refresh: visibleAssets/currentIndex still reflect
            // the pre-toggle list at this point in didSet — refresh() is
            // what overwrites them, so the read has to happen first.
            refresh(follow: currentAsset?.localIdentifier)
        }
    }
    @Published var currentIndex = 0
    /// Swipe-left cues — a CUE ONLY. Nothing is deleted until commitDeletions()
    /// runs, which is only reachable from the explicit X-button tap.
    /// `private(set)`, not independently mutated: every write used to be a
    /// direct `.insert`/`.remove`/`.removeAll` at each call site, which is
    /// how this drifted out of sync with SortStore (the actual persisted
    /// source — see `marks` and `refresh(follow:)` below, which is now the
    /// only place this Set is written). Still a stored Set, not a computed
    /// property: DeckView's body reads `.count` on every render, and a
    /// per-render rebuild over hundreds of assets is exactly the cost
    /// `visibleAssets` below already exists to avoid.
    @Published private(set) var pendingDeleteIDs: Set<String> = []
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
        // didSet doesn't fire for assignments inside init, so seed it here.
        // This is also what makes pendingDeleteIDs (and every other mark)
        // survive relaunch for free: refresh() derives them from
        // sortStore.state(for:), which is backed by SwiftData, not from any
        // separately-seeded in-memory state that could fall out of sync
        // with it the way pendingDeleteIDs used to before this redesign.
        refresh(follow: nil)
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

    /// One derived snapshot of every asset's SortStore state, rebuilt in the
    /// same place as everything downstream of it (see `refresh(follow:)`).
    /// Before this redesign, "is this marked" had two independent sources —
    /// this dictionary's job was split between the `pendingDeleteIDs` Set
    /// (X badge) and live `sortStore.state(for:)` reads (checkmark badge and
    /// filter), which could disagree whenever a call site updated one but
    /// not the other. `sortStore.state(for:)` already returns `.unsorted`
    /// for an asset with no record, so every key here always resolves to a
    /// real state — no separate "absent means unsorted" branch is needed at
    /// any read site.
    @Published private(set) var marks: [String: SortState] = [:]

    /// The single choke point for every mutation that can change what's
    /// sorted, what's visible, or which photo the deck is pointing at.
    /// Replaces the scattered `recomputeVisibleAssets()` calls that used to
    /// sit next to each mutation — missing one of those (or, as in the old
    /// `undo()`, calling one against marks that hadn't been written to
    /// SortStore yet) is exactly how stale-filmstrip and empty-deck bugs
    /// shipped. Every mutating method below calls this exactly once, after
    /// writing to SortStore. `follow` is the identifier of the asset the
    /// deck should try to keep showing (nil just clamps currentIndex back
    /// into range instead) — see `reanchorCurrentIndex(toFollow:)`.
    private func refresh(follow assetID: String?) {
        marks = Dictionary(uniqueKeysWithValues: orderedAssets.map {
            ($0.localIdentifier, sortStore.state(for: $0))
        })
        pendingDeleteIDs = Set(marks.filter { $0.value == .markedForDelete }.keys)

        // hideSorted is an "anything marked" filter, not a "hide kept"
        // filter: from the user's perspective any non-.unsorted photo is
        // sorted, so ANY mark — kept or X'd — drops it out of the deck and
        // filmstrip when the toggle is on. With the toggle off, marked
        // photos stay visible (with their badge) so they're still
        // reviewable/undoable up until an explicit commit.
        visibleAssets = hideSorted
            ? orderedAssets.filter { (marks[$0.localIdentifier] ?? .unsorted) == .unsorted }
            : orderedAssets

        // Grouped over orderedAssets, NOT visibleAssets: a burst is defined by
        // when the photos were taken, not by how far through sorting you are.
        // Building this from the filtered list meant that with hideSorted on,
        // a burst of 4 where 2 were already sorted presented as a 2-photo
        // group — or stopped offering Compare at all, since a group needs
        // more than one member — so the comparison silently lost the very
        // photos you were comparing against. Compare deliberately shows every
        // member including filtered ones (CompareView renders
        // `viewModel.group.assets` directly), and this is what makes that
        // whole. hideSorted still governs what the DECK steps through; it
        // just no longer redefines what a group is.
        var lookup: [String: CompareGroup] = [:]
        for group in GroupingService.groups(in: orderedAssets) {
            for member in group.assets {
                lookup[member.localIdentifier] = group
            }
        }
        groupByAssetID = lookup

        reanchorCurrentIndex(toFollow: assetID)
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
        undoStack.append(UndoEntry(
            changes: [.init(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset))],
            compareGroupID: nil
        ))
        sortStore.setState(.markedForDelete, for: asset, monthKey: month.key)
        // follow: nil, not this asset's ID: when hideSorted filters it out,
        // reanchorCurrentIndex's nil branch just clamps currentIndex into
        // the (now shorter) range instead of trying to keep showing an
        // asset that's meant to disappear. That clamp is also what fixes
        // the empty-deck bug (D2): if this was the LAST visible asset,
        // currentIndex would otherwise sit one past the end and
        // `currentAsset` would go nil, flipping the deck to its "All
        // sorted" empty state while unsorted photos remain.
        refresh(follow: nil)
        // With hideSorted off (or this photo not the one hidden), the next
        // photo hasn't slid into this slot yet, so it's still safe — and
        // necessary — to advance explicitly. When hideSorted DID remove
        // this asset, the next photo already occupies currentIndex (or the
        // refresh above just clamped onto it), so this check correctly
        // skips a redundant advance that would otherwise double-skip.
        if visibleAssets.indices.contains(currentIndex),
           visibleAssets[currentIndex].localIdentifier == asset.localIdentifier {
            advance()
        }
    }

    /// Compare's confirm: the deck's single choke point for everything one
    /// Compare resolution writes — every rejected member cued for delete,
    /// the accepted member (if any) marked kept, and the group itself marked
    /// resolved — captured into exactly ONE undo batch. Previously
    /// (`markPendingDelete`, this method's old name/shape) this only handled
    /// the cued assets and deliberately skipped the undo stack entirely,
    /// while CompareViewModel wrote the kept photo's SortState directly —
    /// two separate mutation paths, neither undoable, for what the user
    /// experiences as a single action. That made Compare's confirm the
    /// least reversible action in the app (it can cue 4+ photos at once) and
    /// also the one action with NO undo at all. Routing both writes through
    /// here — the same choke point the swipe paths above already use — is
    /// what lets `undo()` reverse a whole resolution in one tap, and what
    /// keeps every SortState write behind this single source of truth (the
    /// same rule `refresh(follow:)`'s doc comment establishes).
    func resolveCompareGroup(toDelete: [PHAsset], keeping kept: PHAsset?, groupID: String) {
        // Captured before the marks (and therefore visibleAssets) change:
        // if the batch includes assets sitting before currentIndex, letting
        // those disappear under hideSorted shifts every later index down —
        // reanchoring by this identity is what keeps the deck showing the
        // same photo instead of silently jumping to a neighbor.
        let previousAssetID = currentAsset?.localIdentifier
        var changes: [UndoEntry.Change] = []
        for asset in toDelete {
            // Previous state read BEFORE the write, same as every other
            // undo-recording call site — reading it after would just record
            // "was already markedForDelete" for everything.
            changes.append(.init(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
            sortStore.setState(.markedForDelete, for: asset, monthKey: month.key)
        }
        if let kept {
            changes.append(.init(assetID: kept.localIdentifier, previousState: sortStore.state(for: kept)))
            sortStore.setState(.kept, for: kept, monthKey: month.key)
        }
        undoStack.append(UndoEntry(changes: changes, compareGroupID: groupID))
        sortStore.markGroupResolved(groupID)
        refresh(follow: previousAssetID)
    }

    /// Swipe right: keep. No PhotoKit action needed — nothing is deleted.
    func isKept(_ asset: PHAsset) -> Bool {
        marks[asset.localIdentifier] == .kept
    }

    func markKept() {
        guard let asset = currentAsset else { return }
        undoStack.append(UndoEntry(
            changes: [.init(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset))],
            compareGroupID: nil
        ))
        sortStore.setState(.kept, for: asset, monthKey: month.key)
        // See markForDelete()'s comment: follow: nil clamps currentIndex
        // into range, which both keeps a hideSorted-filtered photo's next
        // neighbor in place AND fixes the empty-deck bug (D2) when this was
        // the last visible photo.
        refresh(follow: nil)
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
        // Write every change in the batch to SortStore, THEN refresh exactly
        // once — not once per change. This used to remove(_:) from
        // pendingDeleteIDs first (firing its own didSet recompute against a
        // marks state that hadn't been written to SortStore yet — i.e.
        // against stale data) and only then write SortStore and recompute a
        // second time. pendingDeleteIDs is now purely derived inside
        // refresh(), so there's nothing to mutate ahead of the SortStore
        // writes, and exactly one refresh runs, against already-consistent
        // state, regardless of whether the batch has 1 change or several.
        for change in last.changes {
            if let asset = orderedAssets.first(where: { $0.localIdentifier == change.assetID }) {
                sortStore.setState(change.previousState, for: asset, monthKey: month.key)
            }
        }
        // A Compare-confirm batch also resolved the group (markGroupResolved
        // in resolveCompareGroup above) — reversing every asset's SortState
        // without also un-resolving the group would half-undo the action:
        // the photos come back, but the deck's own isGroupResolved() read
        // (see DeckView's compareGroup computation) would still hide the
        // Compare pill forever, leaving no way to re-run the comparison.
        // Runs before refresh() below so SortStore's resolvedGroupCache is
        // already updated by the time refresh()'s @Published writes trigger
        // DeckView's next body evaluation (that's where isGroupResolved()
        // is actually read).
        if let groupID = last.compareGroupID {
            sortStore.unresolveGroup(groupID)
        }
        // Un-sorting an asset can grow visibleAssets back (the restored photo
        // reappearing under hideSorted), which shifts every later index up —
        // a blind currentIndex - 1 would land on an arbitrary neighbor
        // instead of the photo that was just undone. Reanchor by the first
        // change's identity, same idea as the hideSorted-toggle path above
        // (any member of the batch would do; the first is as good as any).
        refresh(follow: last.changes.first?.assetID)
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
            // MUST happen before deleteAssets() below, same reason filenames
            // is gathered above rather than after: once PHAssetChangeRequest
            // .deleteAssets commits, PhotoKit can no longer produce an image
            // for that asset at all (it is not recoverable from the phone's
            // Recently Deleted the way the Photos app can show it — this app
            // has no access to that surface). Reading thumbnails after the
            // delete, the way it might look "cleaner" to fold this loop in
            // next to the mirrorQueue.enqueue call below, would silently ship
            // a mirror queue with every thumbnail nil.
            //
            // Uses deletionThumbnail(s) — a network-disabled path — not the
            // shared thumbnail(for:targetSize:) used for card rendering: this
            // call sits BEFORE the delete with isCommitting blocking the UI,
            // so allowing PhotoKit to fall back to an iCloud fetch here could
            // hang the whole commit on a stalled download and block the
            // user's actual deletion behind a debugging aid. See
            // ThumbnailLoader.deletionThumbnail's doc comment. A miss (asset
            // not cached locally, or encode failure) just yields no entry in
            // the map, which is fine — the thumbnail is best-effort and must
            // never block this asset's delete or its mirror job.
            let thumbnails = await ThumbnailLoader.deletionThumbnails(
                for: toDelete, targetSize: CGSize(width: 200, height: 200)
            )
            try await photoLibrary.deleteAssets(toDelete)
            mirrorQueue.enqueue(assets: toDelete, filenames: filenames, thumbnails: thumbnails)
            for asset in toDelete {
                sortStore.setState(.deleted, for: asset, monthKey: month.key)
            }
            undoStack.removeAll()
            // pendingDeleteIDs no longer needs an explicit removeAll(): every
            // asset just written above now reads back as .deleted, not
            // .markedForDelete, so refresh() derives an already-empty (of
            // these assets) pendingDeleteIDs on its own.
            refresh(follow: currentAsset?.localIdentifier)
            await mirrorQueue.drainQueue()
        } catch {
            // If the user declines the system confirm dialog (or the delete
            // otherwise fails), pendingDeleteIDs stays intact so nothing is
            // silently lost and the X badge keeps showing the count.
            commitError = "\(error)"
        }
    }
}
