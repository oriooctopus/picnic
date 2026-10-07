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
    /// SortStore month key and the title shown in the deck header. Local deck:
    /// the month's own key/title. Remote deck: "remote:<albumId>" (never a My
    /// Life month, see SortStore.setState) and the album's name.
    let monthKey: String
    let title: String
    private let sortStore: SortStore
    /// REMOTE GATE: nil for a remote-album deck. Delete and mirror-queue work
    /// is structurally unreachable there — `commitDeletions` and
    /// `toggleFavorite` need these, and a remote deck has none to give them.
    private let photoLibrary: PhotoLibraryService?
    private let mirrorQueue: MirrorQueueStore?
    /// Non-nil exactly when this deck triages a remote Google Photos album.
    private let remote: RemoteAlbumService?
    var isRemote: Bool { remote != nil }

    /// Remote only: the server's own totals (GET /album/:id, then every
    /// POST .../decision response). The "N kept · M left" counter reads this,
    /// never SortStore, because the server is the source of truth.
    @Published private(set) var remoteCounts: RemoteAlbumCounts?
    /// Remote only: last load/decision failure, shown as an alert.
    @Published var remoteError: String?
    /// Remote only: true until the first listing arrives (or fails).
    @Published private(set) var isLoadingRemote = false

    @Published var orderedItems: [DeckItem] { didSet { refresh(follow: nil) } }
    /// Persisted directly via UserDefaults rather than @AppStorage: this
    /// class is a plain ObservableObject (not a View), and @AppStorage's
    /// dynamic-property machinery only works when hosted inside SwiftUI's
    /// View update cycle.
    static let hideSortedDefaultsKey = "deck.hideSorted"
    @Published var hideSorted = UserDefaults.standard.bool(forKey: DeckViewModel.hideSortedDefaultsKey) {
        didSet {
            UserDefaults.standard.set(hideSorted, forKey: DeckViewModel.hideSortedDefaultsKey)
            // Read before refresh: visibleItems/currentIndex still reflect
            // the pre-toggle list at this point in didSet — refresh() is
            // what overwrites them, so the read has to happen first.
            refresh(follow: currentItem?.id)
        }
    }
    @Published var currentIndex = 0
    /// Trims saved this session, by DeckItem id. The server listing is the
    /// source of truth (`RemoteAlbumItem.trim`), but the in-memory items are
    /// immutable snapshots, so a save is overlaid here until the next
    /// `loadRemote` replaces the snapshot (which then already carries it).
    private var remoteTrimOverrides: [String: RemoteTrim] = [:]
    /// Swipe-left cues — a CUE ONLY. Nothing is deleted until commitDeletions()
    /// runs, which is only reachable from the explicit X-button tap.
    /// `private(set)`, not independently mutated: every write used to be a
    /// direct `.insert`/`.remove`/`.removeAll` at each call site, which is
    /// how this drifted out of sync with SortStore (the actual persisted
    /// source — see `marks` and `refresh(follow:)` below, which is now the
    /// only place this Set is written). Still a stored Set, not a computed
    /// property: DeckView's body reads `.count` on every render, and a
    /// per-render rebuild over hundreds of assets is exactly the cost
    /// `visibleItems` below already exists to avoid.
    @Published private(set) var pendingDeleteIDs: Set<String> = []
    @Published var undoStack: [UndoEntry] = []
    @Published var favoritedOverrides: [String: Bool] = [:]
    @Published var isCommitting = false
    @Published var commitError: String?

    /// Fired synchronously, in the same call as `currentIndex` moving forward
    /// (by one, or more when offline skipping passes videos; see `advance()`), so the view can promote its already
    /// -loaded next-image into current-image before any async reload runs.
    /// Without this the new card mounts showing the OLD `currentImage` until
    /// `loadCurrentImage()`'s await returns — a ~0.1s flicker of the wrong
    /// photo.
    var onAdvance: (() -> Void)?

    /// What the offline video-skip did, for the view to toast.
    enum VideoSkip: Equatable {
        case skipped(count: Int)
        case onlyVideosLeft
    }
    /// Fired when an offline swipe passed over video cards (or found only
    /// videos ahead). Never fires online.
    var onVideoSkip: ((VideoSkip) -> Void)?
    /// Videos are left alone offline (big iCloud downloads that can't
    /// complete), so natural advancement and "mark sorted up to here" bypass
    /// them. A closure rather than a direct singleton read so tests can pin it.
    var isOffline: () -> Bool = { !Connectivity.shared.isOnline }

    private func isVideo(_ item: DeckItem) -> Bool {
        // Remote items have no phAsset and are never videos.
        item.phAsset?.mediaType == .video
    }

    init(month: MonthBucket, sortStore: SortStore, photoLibrary: PhotoLibraryService, mirrorQueue: MirrorQueueStore) {
        self.monthKey = month.key
        self.title = month.title
        self.sortStore = sortStore
        self.photoLibrary = photoLibrary
        self.mirrorQueue = mirrorQueue
        self.remote = nil
        self.orderedItems = month.assets.map(DeckItem.local)
        // didSet doesn't fire for assignments inside init, so seed it here.
        // This is also what makes pendingDeleteIDs (and every other mark)
        // survive relaunch for free: refresh() derives them from
        // sortStore.state(for:), which is backed by SwiftData, not from any
        // separately-seeded in-memory state that could fall out of sync
        // with it the way pendingDeleteIDs used to before this redesign.
        refresh(follow: nil)
    }

    /// Remote-album deck. Starts empty (`isLoadingRemote`) until `loadRemote()`
    /// delivers the listing; no PhotoLibraryService / MirrorQueueStore is
    /// accepted at all (see the REMOTE GATE note on those properties).
    init(remoteAlbum: RemoteAlbumService, title: String, sortStore: SortStore) {
        self.monthKey = SortStore.remoteMonthKeyPrefix + remoteAlbum.albumId
        self.title = title
        self.sortStore = sortStore
        self.photoLibrary = nil
        self.mirrorQueue = nil
        self.remote = remoteAlbum
        self.orderedItems = []
        self.isLoadingRemote = true
        refresh(follow: nil)
    }

    /// Fetches the server's listing and makes it the deck. The server is the
    /// source of truth: every item's SortStore entry is OVERWRITTEN from the
    /// server's decision (including back to .unsorted), so a stale local cache
    /// (e.g. the album was reset server-side) can never hide an undecided item.
    /// Opens on the first undecided item so a resumed triage continues where
    /// it left off. Failure is surfaced via `remoteError`, not retried.
    func loadRemote() async {
        guard let remote else { return }
        isLoadingRemote = true
        defer { isLoadingRemote = false }
        do {
            let snapshot = try await remote.load()
            for item in snapshot.items {
                let state: SortState
                switch item.decision {
                case .keep: state = .kept
                case .skip: state = .skipped
                case nil: state = .unsorted
                }
                sortStore.setState(state, forID: item.id, monthKey: monthKey, recordsActivity: false)
            }
            remoteCounts = snapshot.counts
            remoteTrimOverrides = [:]
            // orderedItems' didSet runs refresh(), which rebuilds visibleItems
            // (honoring hideSorted); the index below is into THAT list.
            orderedItems = snapshot.items.map(DeckItem.remote)
            currentIndex = visibleItems.firstIndex { sortStore.state(forID: $0.id) == .unsorted } ?? 0
        } catch {
            remoteError = "\(error)"
        }
    }

    /// The saved kept-range of a remote video (this session's save, else the
    /// server's), nil when untrimmed or not a remote video.
    func remoteTrim(for item: DeckItem) -> RemoteTrim? {
        remoteTrimOverrides[item.id] ?? item.remoteItem?.trim
    }

    /// POSTs a remote video's kept range and remembers it. False (with the
    /// error in `remoteError`) when the server refused, so the trim bar stays
    /// open instead of pretending the trim was saved.
    func saveRemoteTrim(_ trim: RemoteTrim, on item: DeckItem) async -> Bool {
        guard let remote, let remoteItem = item.remoteItem else { return false }
        do {
            try await remote.saveTrim(mediaKey: remoteItem.mediaKey, trim)
            remoteTrimOverrides[item.id] = trim
            return true
        } catch {
            remoteError = "Couldn't save trim: \(error)"
            return false
        }
    }

    /// Stored, not computed. The deck's view body reads this several times per
    /// evaluation (stack peek, current card, filmstrip, position label), so as
    /// a computed property it re-filtered the entire month's assets on every
    /// one of those reads. Recomputed only when an input actually changes.
    @Published private(set) var visibleItems: [DeckItem] = []

    /// assetLocalIdentifier → the compare group it belongs to. Built with
    /// visibleItems because `GroupingService.group(containing:in:)` sorts and
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
        marks = Dictionary(uniqueKeysWithValues: orderedItems.map {
            ($0.id, sortStore.state(forID: $0.id))
        })
        pendingDeleteIDs = Set(marks.filter { $0.value == .markedForDelete }.keys)

        // hideSorted is an "anything marked" filter, not a "hide kept"
        // filter: from the user's perspective any non-.unsorted photo is
        // sorted, so ANY mark — kept or X'd — drops it out of the deck and
        // filmstrip when the toggle is on. With the toggle off, marked
        // photos stay visible (with their badge) so they're still
        // reviewable/undoable up until an explicit commit.
        visibleItems = hideSorted
            ? orderedItems.filter { (marks[$0.id] ?? .unsorted) == .unsorted }
            : orderedItems

        // Grouped over orderedItems, NOT visibleItems: a burst is defined by
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
        //
        // REMOTE GATE (compare groups): GroupingService clusters PHAssets and
        // CompareView renders them through PhotoKit, so only local items take
        // part; a remote deck gets an empty lookup and never offers Compare.
        var lookup: [String: CompareGroup] = [:]
        for group in GroupingService.groups(in: orderedItems.compactMap(\.phAsset)) {
            for member in group.assets {
                lookup[member.localIdentifier] = group
            }
        }
        groupByAssetID = lookup

        reanchorCurrentIndex(toFollow: assetID)
    }

    var currentItem: DeckItem? {
        guard visibleItems.indices.contains(currentIndex) else { return nil }
        return visibleItems[currentIndex]
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
            currentIndex = min(currentIndex, max(0, visibleItems.count - 1))
            return
        }
        if let newIndex = visibleItems.firstIndex(where: { $0.id == assetID }) {
            currentIndex = newIndex
            return
        }
        guard let orderedIndex = orderedItems.firstIndex(where: { $0.id == assetID }) else {
            currentIndex = min(currentIndex, max(0, visibleItems.count - 1))
            return
        }
        let orderedIndexByID = Dictionary(uniqueKeysWithValues: orderedItems.enumerated().map { ($1.id, $0) })
        currentIndex = visibleItems.firstIndex { item in
            (orderedIndexByID[item.id] ?? Int.max) >= orderedIndex
        } ?? max(0, visibleItems.count - 1)
    }

    /// REMOTE GATE (favorite): PhotoKit's favorite flag only exists on a
    /// PHAsset; a remote item is never favorited.
    func isFavorite(_ item: DeckItem) -> Bool {
        guard let asset = item.phAsset else { return false }
        return favoritedOverrides[item.id] ?? asset.isFavorite
    }

    func toggleFavorite(_ item: DeckItem) async {
        // Remote items (and a remote deck, which has no photoLibrary) have
        // nothing to favorite; DeckView also hides the button.
        guard let asset = item.phAsset, let photoLibrary else { return }
        let newValue = !isFavorite(item)
        do {
            try await photoLibrary.setFavorite(asset, isFavorite: newValue)
            favoritedOverrides[item.id] = newValue
        } catch {
            commitError = "\(error)"
        }
    }

    func shuffle() {
        orderedItems.shuffle()
        currentIndex = 0
    }

    /// Swipe left: mark for delete. This is a CUE ONLY (SPEC.md interaction
    /// semantics #1) — the X commit button performs the real PhotoKit delete.
    func markForDelete() {
        guard let item = currentItem else { return }
        // REMOTE GATE (delete): in a remote deck a left swipe is a "skip"
        // decision POSTed to the server and NOTHING else — never
        // .markedForDelete, never a PhotoKit delete, never a mirror job.
        if item.isRemote {
            decideRemote(.skip, on: item)
            return
        }
        undoStack.append(UndoEntry(
            changes: [.init(assetID: item.id, previousState: sortStore.state(forID: item.id))],
            compareGroupID: nil
        ))
        sortStore.setState(.markedForDelete, forID: item.id, monthKey: monthKey)
        // follow: nil, not this asset's ID: when hideSorted filters it out,
        // reanchorCurrentIndex's nil branch just clamps currentIndex into
        // the (now shorter) range instead of trying to keep showing an
        // asset that's meant to disappear. That clamp is also what fixes
        // the empty-deck bug (D2): if this was the LAST visible asset,
        // currentIndex would otherwise sit one past the end and
        // `currentItem` would go nil, flipping the deck to its "All
        // sorted" empty state while unsorted photos remain.
        refresh(follow: nil)
        // With hideSorted off (or this photo not the one hidden), the next
        // photo hasn't slid into this slot yet, so it's still safe — and
        // necessary — to advance explicitly. When hideSorted DID remove
        // this asset, the next photo already occupies currentIndex (or the
        // refresh above just clamped onto it), so this check correctly
        // skips a redundant advance that would otherwise double-skip.
        advanceOrSettle(afterSwipeOf: item)
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
    func resolveCompareGroup(toDelete: [PHAsset], keeping kept: [PHAsset], groupID: String) {
        // REMOTE GATE (compare): only reachable from CompareView, which a
        // remote deck never presents (groupByAssetID is empty there).
        precondition(!isRemote, "Compare is local-only")
        // Captured before the marks (and therefore visibleItems) change:
        // if the batch includes assets sitting before currentIndex, letting
        // those disappear under hideSorted shifts every later index down —
        // reanchoring by this identity is what keeps the deck showing the
        // same photo instead of silently jumping to a neighbor.
        let previousItemID = currentItem?.id
        var changes: [UndoEntry.Change] = []
        for asset in toDelete {
            // Previous state read BEFORE the write, same as every other
            // undo-recording call site — reading it after would just record
            // "was already markedForDelete" for everything.
            changes.append(.init(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
            sortStore.setState(.markedForDelete, for: asset, monthKey: monthKey)
        }
        for asset in kept {
            changes.append(.init(assetID: asset.localIdentifier, previousState: sortStore.state(for: asset)))
            sortStore.setState(.kept, for: asset, monthKey: monthKey)
        }
        undoStack.append(UndoEntry(changes: changes, compareGroupID: groupID))
        sortStore.markGroupResolved(groupID)
        refresh(follow: previousItemID)
    }

    /// Swipe right: keep. No PhotoKit action needed — nothing is deleted.
    func isKept(_ item: DeckItem) -> Bool {
        marks[item.id] == .kept
    }

    func markKept() {
        guard let item = currentItem else { return }
        // Remote: right swipe is a "keep" decision POSTed to the server (the
        // server CLI downloads kept items later). Nothing local to do.
        if item.isRemote {
            decideRemote(.keep, on: item)
            return
        }
        undoStack.append(UndoEntry(
            changes: [.init(assetID: item.id, previousState: sortStore.state(forID: item.id))],
            compareGroupID: nil
        ))
        sortStore.setState(.kept, forID: item.id, monthKey: monthKey)
        // See markForDelete()'s comment: follow: nil clamps currentIndex
        // into range, which both keeps a hideSorted-filtered photo's next
        // neighbor in place AND fixes the empty-deck bug (D2) when this was
        // the last visible photo.
        refresh(follow: nil)
        // When hideSorted filtered this photo out, the slot at currentIndex is
        // already occupied by the next photo, so advancing again would skip
        // one.
        advanceOrSettle(afterSwipeOf: item)
    }

    /// Remote-album swipe: writes the SortStore cache optimistically, advances
    /// like a local swipe, and POSTs the decision. If the POST fails the cache
    /// write is reverted and the deck goes back to that item, with the error
    /// in `remoteError` (an alert) — the server is the source of truth, so the
    /// UI must not keep a decision the server never recorded. No undo entry is
    /// ever pushed: the server API cannot un-decide, so `undoStack` stays
    /// empty and DeckView's undo button stays disabled. No retry queue; a
    /// failed swipe is simply redone by the user.
    private func decideRemote(_ decision: RemoteDecision, on item: DeckItem) {
        guard let remote, let remoteItem = item.remoteItem else { return }
        let previous = sortStore.state(forID: item.id)
        sortStore.setState(decision == .keep ? .kept : .skipped, forID: item.id, monthKey: monthKey)
        refresh(follow: nil)
        if visibleItems.indices.contains(currentIndex), visibleItems[currentIndex].id == item.id {
            advance()
        }
        Task {
            do {
                remoteCounts = try await remote.decide(mediaKey: remoteItem.mediaKey, decision)
            } catch {
                sortStore.setState(previous, forID: item.id, monthKey: monthKey, recordsActivity: false)
                refresh(follow: item.id)
                remoteError = "Couldn't save \(decision.rawValue): \(error)"
            }
        }
    }

    /// Marks every still-unsorted photo before the current one (in deck
    /// order) as kept, as one undo batch. The current photo stays unsorted.
    /// Returns how many were marked.
    @discardableResult
    func markSortedUpToCurrent() -> Int {
        // REMOTE GATE (mark sorted till here): this would mass-"keep" every
        // earlier item, i.e. queue up to ~1600 server downloads from one tap.
        // The popover hides the button for a remote deck; this is the backstop.
        guard !isRemote else { return 0 }
        guard let current = currentItem,
              let end = orderedItems.firstIndex(where: { $0.id == current.id })
        else { return 0 }
        // Offline, videos are left unsorted: the user never got to see them
        // (the deck skips them), so marking them kept would silently sort
        // media they haven't reviewed. Online keeps the original behaviour.
        let offline = isOffline()
        let toMark = orderedItems[..<end].filter {
            sortStore.state(forID: $0.id) == .unsorted && !(offline && isVideo($0))
        }
        guard !toMark.isEmpty else { return 0 }
        let changes = toMark.map { UndoEntry.Change(assetID: $0.id, previousState: .unsorted) }
        for item in toMark { sortStore.setState(.kept, forID: item.id, monthKey: monthKey) }
        undoStack.append(UndoEntry(changes: changes, compareGroupID: nil))
        refresh(follow: current.id)
        return toMark.count
    }

    /// Shared tail of a local swipe: advance explicitly when the swiped card
    /// is still in the deck; otherwise hideSorted already slid the next card
    /// into `currentIndex` without `advance()` running, so the offline video
    /// skip has to be applied to that slot here instead.
    private func advanceOrSettle(afterSwipeOf item: DeckItem) {
        if visibleItems.indices.contains(currentIndex),
           visibleItems[currentIndex].id == item.id {
            advance()
        } else {
            settleOffVideoIfOffline()
        }
    }

    /// Offline, with a video at `currentIndex` after hideSorted removed the
    /// swiped card: move to the next non-video ahead, else the nearest one
    /// behind (the clamp after swiping the last card lands there), else stay
    /// because the deck is all videos. No `onAdvance()`: the prefetch is for
    /// the wrong card, and DeckView's per-card load handles a moved
    /// `currentIndex` the same way it does for the unskipped slide.
    private func settleOffVideoIfOffline() {
        guard isOffline(), let current = currentItem, isVideo(current) else { return }
        if let ahead = visibleItems.indices.dropFirst(currentIndex + 1).first(where: { !isVideo(visibleItems[$0]) }) {
            let skipped = ahead - currentIndex
            currentIndex = ahead
            onVideoSkip?(.skipped(count: skipped))
        } else {
            if let behind = visibleItems.indices[..<currentIndex].last(where: { !isVideo(visibleItems[$0]) }) {
                currentIndex = behind
            }
            onVideoSkip?(.onlyVideosLeft)
        }
    }

    private func advance() {
        guard currentIndex < visibleItems.count - 1 else { return }
        var target = currentIndex + 1
        if isOffline() {
            // Natural advance passes over videos; only a filmstrip tap (which
            // sets currentIndex directly) can land on one.
            while target < visibleItems.count, isVideo(visibleItems[target]) { target += 1 }
            let skipped = target - (currentIndex + 1)
            if target == visibleItems.count {
                // Only videos ahead: stay on the swiped card rather than
                // advancing into them.
                onVideoSkip?(.onlyVideosLeft)
                return
            }
            if skipped > 0 { onVideoSkip?(.skipped(count: skipped)) }
        }
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
            currentIndex = target
            onAdvance?()
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
            if orderedItems.contains(where: { $0.id == change.assetID }) {
                sortStore.setState(change.previousState, forID: change.assetID, monthKey: monthKey)
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
        // Un-sorting an asset can grow visibleItems back (the restored photo
        // reappearing under hideSorted), which shifts every later index up —
        // a blind currentIndex - 1 would land on an arbitrary neighbor
        // instead of the photo that was just undone. Reanchor by the first
        // change's identity, same idea as the hideSorted-toggle path above
        // (any member of the batch would do; the first is as good as any).
        refresh(follow: last.changes.first?.assetID)
    }

    /// The single X commit: one PhotoKit batch delete (system confirm dialog
    /// is automatic); every asset's mirror job is armed before it and promoted after.
    func commitDeletions() async {
        // REMOTE GATE (delete + mirror queue): a remote deck has no
        // photoLibrary/mirrorQueue (nil), no PHAssets, and its skips are
        // .skipped (never .markedForDelete), so pendingDeleteIDs is empty and
        // this returns before touching either. Both guards are the structural
        // proof a remote swipe can never delete or enqueue a mirror job.
        guard let photoLibrary, let mirrorQueue else { return }
        let toDelete = orderedItems.compactMap(\.phAsset).filter { pendingDeleteIDs.contains($0.localIdentifier) }
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
            // next to the deleteWithMirror call below, would silently ship
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
            // Mirror jobs are persisted "armed" BEFORE the delete and flipped
            // to pending after it (see MirrorQueueStore.deleteWithMirror), so
            // a kill mid-commit cannot lose the Google mirror.
            try await mirrorQueue.deleteWithMirror(
                toDelete.map(MirrorAssetInfo.init), filenames: filenames, thumbnails: thumbnails
            ) {
                try await photoLibrary.deleteAssets(toDelete)
            }
            for asset in toDelete {
                sortStore.setState(.deleted, for: asset, monthKey: monthKey)
            }
            undoStack.removeAll()
            // pendingDeleteIDs no longer needs an explicit removeAll(): every
            // asset just written above now reads back as .deleted, not
            // .markedForDelete, so refresh() derives an already-empty (of
            // these assets) pendingDeleteIDs on its own.
            refresh(follow: currentItem?.id)
            // Not awaited: a hung POST would keep isCommitting true (deck
            // locked) for up to a minute per job. See scheduleDrain().
            mirrorQueue.scheduleDrain()
        } catch {
            // If the user declines the system confirm dialog (or the delete
            // otherwise fails), pendingDeleteIDs stays intact so nothing is
            // silently lost and the X badge keeps showing the count.
            commitError = "\(error)"
        }
    }
}
