import SwiftUI
import Photos
import AVFoundation

struct DeckView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var outfitLog: OutfitLogStore
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: DeckViewModel

    @State private var currentImage: UIImage?
    /// The photo of the card underneath, shown dimmed as the top card is
    /// thrown clear — the reference reveals the real next picture, not a grey
    /// placeholder.
    @State private var nextImage: UIImage?
    /// Which asset `nextImage` was fetched for. Exists purely so
    /// `loadCurrentImage()` can tell "the photo I'm about to show already
    /// sits in `nextImage`" apart from "nothing has been prefetched for this
    /// photo yet" — see that function's promotion step for why this is the
    /// real fix for the hideSorted/filmstrip-tap flicker (onAdvance's
    /// existing promotion only ever fires from advance(), which markForDelete/
    /// markKept skip whenever hideSorted has already removed the swiped
    /// asset — see DeckViewModel.markForDelete's guard comment).
    @State private var nextImageAssetID: String?
    /// What the current photo card shows (see DeckCardImagePolicy). Drives the
    /// "in iCloud" badge and whether a delete swipe is allowed.
    @State private var imageState = DeckCardImageState()
    @State private var showHidePopover = false
    /// Plain @State on purpose: it holds the object without subscribing to it,
    /// so a drag repaints the tint and labels but never this view's body (and
    /// therefore never the filmstrip). See DeckDragState.
    @State private var dragState = DeckDragState()
    /// One AVPlayer for the whole deck session, its item swapped per video
    /// card (see VideoPlaybackController's doc comment) — never a new
    /// AVPlayer per swiped card. Plain @State, same reasoning as
    /// `dragState`: this publishes a ~10Hz time update that must repaint
    /// only VideoTimeLabel/VideoControlBar, never this view's own body.
    @State private var videoController = VideoPlaybackController()
    /// Bumped by the video card's "tap to retry"; part of the load task's id so it re-runs.
    @State private var videoRetryNonce = 0
    /// Long-press the month title to reveal the frame-rate readout. Hidden by
    /// default so it never intrudes on normal use, but present in the ad-hoc
    /// build because the phone is the only place the stutter reproduces.
    @State private var showPerfHUD = false
    /// One presentation slot for both modals. Two `.fullScreenCover`
    /// modifiers on the same view silently collapse into one in SwiftUI —
    /// the Compare cover never presented while a live-photo cover was also
    /// attached here.
    @State private var presentation: DeckPresentation?
    /// True while VideoTrimBar replaces the video controls + action row.
    /// Only flips on enter/exit, so it's fine for this to rebuild the body.
    @State private var isTrimming = false
    @State private var trimError: String?
    /// Transient note at the top of the deck: "Logged to Outfits | Review now",
    /// or the short failure note when Overland won't open.
    @State private var toast: DeckToast?
    @State private var toastDismissTask: Task<Void, Never>?

    enum DeckToast: Equatable {
        case logged(assetID: String)
        case openFailed
        case deleteBlocked
    }

    static let outfitLilac = Color(red: 201 / 255, green: 162 / 255, blue: 255 / 255)

    /// Every card — the live one and the dimmed peek underneath — renders at
    /// this fixed portrait ratio so the outline never changes shape between
    /// photos; landscape/square photos letterbox inside it instead. 4:5
    /// (width:height = 0.8) sits inside the 3:4–9:16 band, reads as a
    /// standard "portrait card" shape (matches common photo-app card ratios)
    /// and comfortably fits between the header and the bottom rows without
    /// clipping either.
    private let cardAspectRatio: CGFloat = 4.0 / 5.0

    enum DeckPresentation: Identifiable {
        // startAssetID: the deck card Compare was tapped from. Compare opens
        // on THAT member, not the group's first — tapping Compare on the
        // second burst photo used to land on the first one.
        case compare(CompareGroup, startAssetID: String)
        case livePhoto(PHLivePhoto)

        var id: String {
            switch self {
            case .compare(let group, _): return "compare-\(group.id)"
            case .livePhoto: return "livePhoto"
            }
        }
    }

    init(viewModel: DeckViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private var dateTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }

    var body: some View {
        VStack(spacing: 0) {
            // Remote-album deck only: the persistent "ALBUM · Oliver!" strip
            // with the server's kept/left counter. The local deck never
            // shows it, so the two decks can't be confused.
            if viewModel.isRemote {
                RemoteDeckBanner(counts: viewModel.remoteCounts)
            }

            topBar

            ZStack {
                // The card underneath, dimmed. Revealed as the top card is
                // thrown aside, which is what gives the deck its depth in the
                // reference — previously this was a pair of flat grey
                // rectangles with no picture in them.
                if viewModel.currentIndex + 1 < viewModel.visibleItems.count {
                    DeckPeekCard(image: nextImage, dragState: dragState, cardAspectRatio: cardAspectRatio)
                }

                if let item = viewModel.currentItem {
                    DeckCard(
                        item: item,
                        image: currentImage,
                        // REMOTE GATE (Compare): groupByAssetID is built only
                        // from local PHAssets, so a remote id never matches
                        // and the pill never shows.
                        compareGroup: viewModel.groupByAssetID[item.id].flatMap {
                            appState.sortStore.isGroupResolved($0.id) ? nil : $0
                        },
                        onCompare: { presentation = .compare($0, startAssetID: item.id) },
                        onLongPress: { presentLivePhotoIfNeeded(item) },
                        // REMOTE GATE (iCloud badge / delete-block): both come
                        // from PhotoKit's low-res-vs-full quality tracking,
                        // which a URL image never goes through. Forcing them
                        // off also keeps the left swipe live: deleteBlocked
                        // would otherwise remove `.left` from the card.
                        showsICloudBadge: !viewModel.isRemote && imageState.showsICloudBadge,
                        deleteBlocked: !viewModel.isRemote && imageState.deleteBlocked,
                        onBlockedDelete: { showToast(.deleteBlocked, seconds: 3) },
                        onDelete: { viewModel.markForDelete() },
                        onKeep: { viewModel.markKept() },
                        onDismiss: { Task { await exitDeck() } },
                        dragState: dragState,
                        cardAspectRatio: cardAspectRatio,
                        videoController: videoController,
                        onVideoRetry: { videoRetryNonce += 1 },
                        isRemote: viewModel.isRemote
                    )
                    .id(item.id)
                    // The photo itself is still assigned synchronously in
                    // onAdvance below (same run-loop turn as currentIndex
                    // moving — see advance()'s doc comment), so this never
                    // delays or flickers the wrong photo; it only eases the
                    // geometry of the newly-mounted card in from the peek
                    // card's own resting look (0.96 scale) up to full size,
                    // instead of popping straight to full size the instant
                    // the swipe commits.
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else if viewModel.isLoadingRemote {
                    ProgressView()
                        .tint(RemoteDeckStyle.accent)
                        .accessibilityIdentifier("deck.remoteLoading")
                } else {
                    emptyState
                }
            }
            .overlay { SwipeVerdictLabel(state: dragState, isRemote: viewModel.isRemote) }
            .frame(maxHeight: .infinity)
            // Gap below the two-line header so the card (and its stack-peek
            // layers) never overlaps the date/time subline (defect C1/C5).
            .padding(.top, 16)

            // Outside and below the card on purpose — see VideoControlBar's
            // doc comment: a scrub drag here must never compete with the
            // card's own swipe pan gesture.
            // REMOTE GATE (video/trim): `phAsset` is nil for a remote item, so
            // neither the trim bar nor the video control bar can show.
            if let asset = viewModel.currentItem?.phAsset, asset.mediaType == .video, isTrimming {
                VideoTrimBar(
                    controller: videoController,
                    onCancel: { endTrimming() },
                    onSave: { await saveTrim(asset: asset, window: $0) }
                )
            } else {
                if let asset = viewModel.currentItem?.phAsset, asset.mediaType == .video {
                    VideoControlBar(controller: videoController)
                        .padding(.horizontal, 28)
                        .padding(.top, 10)
                }

                bottomActionsRow
            }
            positionAndFilmstrip
            bottomControls
        }
        .background(DeckTintBackground(state: dragState, isRemote: viewModel.isRemote))
        .overlay(alignment: .topLeading) {
            if showPerfHUD {
                PerfHUD().padding(.leading, 12).padding(.top, 64)
            }
        }
        // Always mounted (invisible) so a UI test can read the numbers without
        // needing the HUD itself shown.
        .overlay(alignment: .topLeading) { PerfStatsProbe() }
        .overlay(alignment: .top) { toastView }
        // Warm the whole month's thumbnails in the background, starting at
        // the card the user is on and wrapping around, once per deck open.
        //
        // The id includes the item count because a remote deck starts empty
        // and fills once the server answers: keyed on monthKey alone this
        // would run once against zero items and never warm anything.
        .task(id: "\(viewModel.monthKey)#\(viewModel.orderedItems.count)") {
            // Drop thumbnails for photos sorted more than a day ago first.
            WarmThumbCache.purge(assetIDs: appState.sortStore.assetIDsSorted(
                before: Date().addingTimeInterval(-WarmThumbCache.retention)))
            let items = viewModel.visibleItems
            let start = min(viewModel.currentIndex, items.count)
            await ThumbnailLoader.warmCache(for: Array(items[start...] + items[..<start]))
        }
        // Remote deck: fetch the album (and its server-side decisions) once
        // on open. Local decks have nothing to load. A failure lands in
        // viewModel.remoteError and shows in the alert below; there is no
        // automatic retry, reopening the deck is the retry.
        .task {
            if viewModel.isRemote { await viewModel.loadRemote() }
        }
        .task(id: "\(viewModel.currentItem?.id ?? "")#\(videoRetryNonce)") {
            await loadCurrentImage()
        }
        // Swiping or tapping the filmstrip away mid-trim abandons the trim;
        // load(item:) for the next video already resets the loop window.
        .onChange(of: viewModel.currentItem?.id) { _, _ in
            isTrimming = false
        }
        // Frees the shared AVPlayer's current item when the deck itself
        // goes away — the other half of "no leaked AVPlayer" alongside
        // loadCurrentImage()'s per-card clear()/load() below.
        .onDisappear { videoController.clear() }
        // A modal covering the deck (Compare / a long-pressed live photo)
        // shouldn't leave a video still playing (and audible) underneath
        // it.
        .onChange(of: presentation?.id) { _, newValue in
            if newValue != nil {
                videoController.pause()
            } else {
                videoController.resume()
            }
        }
        .onAppear {
            // Same run-loop turn as currentIndex advancing (see advance()'s
            // doc comment in DeckViewModel) — promotes the already-loaded
            // peek image into currentImage before the async .task above even
            // starts, so the new card never shows the outgoing photo. If the
            // prefetch hadn't finished (nextImage nil), currentImage clears
            // to the card's black background instead — a brief blank is
            // correct, a brief WRONG photo is the bug this fixes.
            viewModel.onAdvance = {
                currentImage = nextImage
                imageState.begin(prefetched: nextImage != nil)
                nextImage = nil
                nextImageAssetID = nil
            }
        }
        .fullScreenCover(item: $presentation) { item in
            switch item {
            case .compare(let group, let startAssetID):
                CompareView(startAssetID: startAssetID, viewModel: CompareViewModel(
                    group: group,
                    photoLibrary: appState.photoLibrary,
                    onResolve: { toDelete, kept, groupID in
                        viewModel.resolveCompareGroup(toDelete: toDelete, keeping: kept, groupID: groupID)
                    }
                ))
            case .livePhoto(let livePhoto):
                LivePhotoPlayerView(livePhoto: livePhoto) { presentation = nil }
            }
        }
        .alert("Couldn't trim", isPresented: Binding(
            get: { trimError != nil },
            set: { if !$0 { trimError = nil } }
        )) {
            Button("OK") { trimError = nil }
        } message: {
            Text(trimError ?? "")
        }
        // Remote deck failures: album load, a decision POST (already
        // reverted by the view model), or the current card's image.
        .alert("Remote album error", isPresented: Binding(
            get: { viewModel.remoteError != nil },
            set: { if !$0 { viewModel.remoteError = nil } }
        )) {
            Button("OK") { viewModel.remoteError = nil }
        } message: {
            Text(viewModel.remoteError ?? "")
        }
        .alert("Couldn't delete", isPresented: Binding(
            get: { viewModel.commitError != nil },
            set: { if !$0 { viewModel.commitError = nil } }
        )) {
            Button("OK") { viewModel.commitError = nil }
        } message: {
            Text(viewModel.commitError ?? "")
        }
    }

    /// DEVICE-ONLY BUG (never reproduces in the simulator, at any month size —
    /// see ThumbnailLoader.fullImage's `fromICloud` doc comment): this is the
    /// only place `currentImage`/`nextImage` get assigned outside
    /// `onAdvance`, and `onAdvance` only fires from `DeckViewModel.advance()`
    /// — which `markForDelete`/`markKept` skip whenever hideSorted has
    /// already filtered the swiped asset out (see their guard comments). So
    /// under hideSorted, `currentItem` changes identity with NO synchronous
    /// image promotion at all, and this function's own first `await` is the
    /// only thing standing between the swipe and a correct photo — on a
    /// simulator's local library that await resolves in the same run-loop
    /// tick and the gap is invisible; on a real phone with Optimize Storage
    /// on it's a genuine network round trip, during which the card keeps
    /// showing `currentImage`'s OLD value: the just-swiped photo, frozen on
    /// screen while the "N OF M" counter has already moved on. Two
    /// independent fixes live in this one function:
    ///
    /// A1 — promote an already-prefetched `nextImage` synchronously, before
    /// the first `await` below, whenever it was fetched for the asset we're
    /// about to show. This is exactly what happens whenever hideSorted drops
    /// the swiped photo (the new `currentItem` is the same one `nextImage`
    /// was prefetched for two lines below) or when the filmstrip is tapped
    /// one photo forward — both cases this closes identically. `advance()`'s
    /// own promotion (DeckView.onAppear's `onAdvance` closure) is untouched
    /// and keeps handling every other advance.
    ///
    /// A2 — `ThumbnailLoader.fullImage` wraps `PHImageManager.requestImage`
    /// in `withCheckedContinuation` with no cancellation handling, so a
    /// `.task(id:)` restart (this function's own caller) does NOT stop an
    /// in-flight fetch — the continuation still resumes, and the code below
    /// still runs, even though a newer invocation of this same function may
    /// already be running (or have already finished) for a different asset.
    /// Left ungated, whichever of two overlapping iCloud fetches happens to
    /// return LAST wins, regardless of which asset it was actually for —
    /// swipe A→B→C quickly enough and the card showing C can end up
    /// permanently displaying A. `loadingID`/`startIndex` are captured before
    /// the first `await` specifically so every assignment below can be
    /// gated against the LIVE `viewModel.currentItem` rather than the
    /// (necessarily still-equal-to-itself) local `asset` — and `nextIndex`
    /// is derived from the captured `startIndex`, not a fresh read of
    /// `viewModel.currentIndex`, so a stale invocation can't prefetch for a
    /// position that has since moved.
    private func loadCurrentImage() async {
        guard let item = viewModel.currentItem else {
            currentImage = nil; nextImage = nil; nextImageAssetID = nil
            videoController.clear()
            return
        }

        // A1: see this function's doc comment. Must run before any `await`
        // — the whole point is closing the gap between currentItem changing
        // and the first suspension point below, not just shortening it.
        imageState.begin(prefetched: false)
        if nextImageAssetID == item.id, let prefetched = nextImage {
            currentImage = prefetched
            imageState.begin(prefetched: true)  // the 600x800 prefetch: pixels, but not the final image
            nextImage = nil
            nextImageAssetID = nil
        }

        // A2: captured now, used for every gate below.
        let loadingID = item.id
        let startIndex = viewModel.currentIndex

        if case .remote(let remote) = item {
            // REMOTE GATE (image source): a remote card is never a video and
            // never goes through PhotoKit/WarmThumbCache. Its image is the
            // server's cached thumbnail, fetched by URL (in-memory NSCache in
            // ThumbnailLoader). The PhotoKit quality state is ignored for
            // remote cards (see the body's deleteBlocked gate).
            videoController.clear()
            do {
                let image = try await ThumbnailLoader.remoteImage(url: remote.thumbnailURL)
                if viewModel.currentItem?.id == loadingID { currentImage = image }
            } catch {
                // A cancelled load means the card changed and a newer task
                // owns the state; only a real failure is worth an alert.
                if Task.isCancelled || error is CancellationError { return }
                viewModel.remoteError = "Couldn't load photo: \(error)"
            }
            if Task.isCancelled { return }
        } else if let asset = item.phAsset, asset.mediaType == .video {
            // Poster first, local data only so it shows at once, upgraded by a
            // network-allowed fetch that runs alongside the video item (never
            // queued behind an iCloud download). The poster stays on screen
            // until the video has a frame; a failed load keeps it and offers
            // retry instead of going black. Every async result is gated on
            // this card still being current (A2), and the controller gates
            // the item itself by asset id.
            // Video cards have their own load/retry UI; never delete-blocked.
            imageState.markVideo()
            videoController.beginLoading(assetID: loadingID)
            if let local = await ThumbnailLoader.localThumbnail(for: asset, targetSize: ThumbnailLoader.screenPixelSize),
               viewModel.currentItem?.id == loadingID {
                currentImage = local
            }
            async let upgraded = ThumbnailLoader.thumbnail(for: asset, targetSize: ThumbnailLoader.screenPixelSize)
            let controller = videoController
            let result = await VideoLoader.load(for: asset) { value in
                Task { @MainActor in controller.reportDownloadProgress(value, for: loadingID) }
            }
            switch result {
            case .item(let item): videoController.loadItem(item, for: loadingID)
            case .failed: videoController.failLoading(for: loadingID)
            }
            if let poster = await upgraded, viewModel.currentItem?.id == loadingID {
                currentImage = poster
            }
        } else if let asset = item.phAsset {
            // Not a video card: make sure nothing keeps playing/decoding
            // behind a plain photo.
            videoController.clear()
            await ThumbnailLoader.applySlowLoadDelayIfEnabled()
            // Instant placeholder from the warm-up cache while PhotoKit loads.
            if currentImage == nil, let cached = WarmThumbCache.image(for: loadingID) {
                currentImage = cached
            }
            // Low-res first, then full: each update replaces currentImage. The
            // stream ends on the final result, and cancelling this task (the
            // card changed) cancels the PhotoKit request behind it.
            for await update in ThumbnailLoader.imageUpdates(for: asset, targetSize: ThumbnailLoader.screenPixelSize) {
                // A2 gate: only trust this fetch if it's still for the asset
                // actually on screen — see the doc comment above.
                guard viewModel.currentItem?.id == loadingID else { break }
                if let image = update.image { currentImage = image }
                imageState.apply(update)
            }
            // Cancelled mid-load: the card changed and a new load owns the state.
            if Task.isCancelled { return }
        }

        // The card behind is dimmed and partly covered, so it is fetched at a
        // fraction of the size — enough to read, cheap enough not to compete
        // with the card actually being dragged. Derived from `startIndex`
        // (captured above `await`), not a fresh `viewModel.currentIndex`
        // read — see A2 in the doc comment.
        let nextIndex = startIndex + 1
        guard viewModel.visibleItems.indices.contains(nextIndex) else {
            if viewModel.currentItem?.id == loadingID { nextImage = nil; nextImageAssetID = nil }
            return
        }
        let nextItem = viewModel.visibleItems[nextIndex]
        let fetchedNext = await ThumbnailLoader.bestAvailableImage(for: nextItem, targetSize: CGSize(width: 600, height: 800))
        // A2 gate, same reasoning as the currentImage assignment above.
        if viewModel.currentItem?.id == loadingID {
            nextImage = fetchedNext
            nextImageAssetID = nextItem.id
        }
    }

    /// Top-right X (and the quiet drag-to-dismiss below): dismiss immediately
    /// when nothing is pending; when swipes are pending, commit first (the
    /// existing PhotoKit batch delete + system confirm) and only dismiss once
    /// that commit succeeds, so a declined/failed commit leaves the deck open
    /// with the pending count intact.
    private func exitDeck() async {
        guard !viewModel.pendingDeleteIDs.isEmpty else {
            dismiss()
            return
        }
        await viewModel.commitDeletions()
        if viewModel.commitError == nil {
            dismiss()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { viewModel.shuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color(white: 0.15)))
            }
            .accessibilityIdentifier("deck.shuffle")

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let item = viewModel.currentItem, let date = item.creationDate {
                    Text(dateTimeFormatter.string(from: date).uppercased())
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .accessibilityIdentifier("deck.title")
            .onLongPressGesture(minimumDuration: 0.8) {
                showPerfHUD.toggle()
                if showPerfHUD { PerfMonitor.shared.start() } else { PerfMonitor.shared.stop() }
            }

            Spacer()

            ZStack(alignment: .topTrailing) {
                Button {
                    Task { await exitDeck() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color(white: 0.15)))
                }
                .disabled(viewModel.isCommitting)
                .accessibilityIdentifier("deck.commit")

                if viewModel.pendingDeleteIDs.count > 0 {
                    Text("\(viewModel.pendingDeleteIDs.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.red))
                        .offset(x: 9, y: -9)
                        .accessibilityIdentifier("deck.pendingCount")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .contentShape(Rectangle())
        // Swipe-down-from-the-top exits the deck, same recipe AND same
        // unconditional bare dismiss() as Compare's own header
        // drag-to-dismiss (CompareView.header) — deliberately NOT routed
        // through exitDeck()'s commit-gated path. A quiet gesture-based
        // escape shouldn't ambush the user with PhotoKit's real delete
        // confirmation the way the X button legitimately does; anything
        // still pending stays pending (it's persisted — see
        // pendingDeleteIDs' relaunch fix) and waits for an explicit X tap.
        // Scoped to the top bar only so it can't compete with the card's
        // own left/right swipe or the filmstrip's horizontal scroll below.
        //
        // .highPriorityGesture, not .gesture: the title text underneath
        // carries its own .onLongPressGesture (perf HUD toggle), and a
        // plain child gesture wins touch priority over an ancestor's by
        // default in SwiftUI — a drag starting right on the title never
        // reached this one at all. minimumDistance: 20 means a stationary
        // tap/long-press still never trips this gesture's recognition, so
        // raising its priority doesn't block the buttons or the long-press.
        .highPriorityGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 60 && abs(value.translation.width) < 60 {
                        dismiss()
                    }
                }
        )
    }

    private func endTrimming() {
        videoController.setLoopWindow(nil)
        isTrimming = false
    }

    /// Writes the trim to Photos, then reloads the shared player from the
    /// edited asset so the card immediately plays the trimmed clip.
    /// Returns false (keeping trim mode open) on failure or when the user
    /// declines iOS's modify-permission prompt — that decline is a choice,
    /// not an error, so it gets no alert.
    private func saveTrim(asset: PHAsset, window: ClosedRange<Double>) async -> Bool {
        let range = CMTimeRange(
            start: CMTime(seconds: window.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: window.upperBound, preferredTimescale: 600)
        )
        do {
            try await VideoTrimmer.trim(asset: asset, to: range)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        } catch {
            trimError = error.localizedDescription
            return false
        }
        isTrimming = false
        // requestPlayerItem resolves the asset's current version by
        // identifier, so this returns the just-saved trimmed render
        // (test51 checks the reloaded length).
        if let item = await VideoLoader.playerItem(for: asset),
           viewModel.currentItem?.id == asset.localIdentifier {
            videoController.load(item: item)
        }
        return true
    }

    private func presentLivePhotoIfNeeded(_ item: DeckItem) {
        // REMOTE GATE (Live Photo): a remote item has no PHAsset, and the
        // server only caches a still thumbnail, so long-press does nothing.
        guard let asset = item.phAsset, asset.mediaSubtypes.contains(.photoLive) else { return }
        Task {
            guard let loaded = await LivePhotoLoader.load(asset: asset) else { return }
            presentation = .livePhoto(loaded)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("All sorted for \(viewModel.title)")
                .foregroundStyle(.white)
        }
    }

    // MARK: Bottom rows

    @ViewBuilder
    private var bottomActionsRow: some View {
        if viewModel.isRemote {
            // REMOTE GATE (favorite, outfit log, share, trim): all four need
            // a PHAsset (PhotoKit favorite flag, outfit import by local id,
            // share of the original file, video trim). The remote deck shows
            // an empty spacer of roughly the same height (22pt icons + 16pt
            // padding each side) so the layout does not jump.
            Color.clear.frame(height: 22 + 32)
        } else {
            localActionsRow
        }
    }

    private var localActionsRow: some View {
        HStack(spacing: 56) {
            Button {
                guard let item = viewModel.currentItem, item.phAsset != nil else { return }
                Task { await viewModel.toggleFavorite(item) }
            } label: {
                let isFav = viewModel.currentItem.map { viewModel.isFavorite($0) } ?? false
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .foregroundStyle(isFav ? .red : .white)
            }
            outfitButton
            Button {
                guard let asset = viewModel.currentItem?.phAsset else { return }
                ShareSheetPresenter.present(asset: asset)
            } label: {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.white)
            }
            if viewModel.currentItem?.phAsset?.mediaType == .video {
                Button { isTrimming = true } label: {
                    Image(systemName: "scissors").foregroundStyle(.white)
                }
                .accessibilityIdentifier("deck.trim")
            }
        }
        .font(.system(size: 22))
        .padding(.vertical, 16)
    }

    /// One-tap "Log as outfit". Outline until the photo is logged, then lilac;
    /// tapping a logged photo opens Review instead of re-importing. Photos only.
    private var outfitButton: some View {
        // Only reachable from localActionsRow, so the item is always local.
        let asset = viewModel.currentItem?.phAsset
        let isVideo = asset?.mediaType == .video
        let isLogged = asset.map { outfitLog.isLogged($0) } ?? false
        return Button {
            guard let asset else { return }
            if isLogged {
                outfitLog.relog(assetID: asset.localIdentifier)
                openReview(assetID: asset.localIdentifier)
            } else {
                outfitLog.log(assetID: asset.localIdentifier, takenAt: asset.creationDate ?? Date())
                showToast(.logged(assetID: asset.localIdentifier), seconds: 4)
            }
        } label: {
            Image(systemName: "hanger")
                .foregroundStyle(isVideo ? .white.opacity(0.3) : (isLogged ? Self.outfitLilac : .white))
        }
        .disabled(isVideo)
        .accessibilityIdentifier("deck.logOutfit")
        .accessibilityValue(isLogged ? "logged" : "not logged")
    }

    private func showToast(_ new: DeckToast, seconds: Double) {
        toastDismissTask?.cancel()
        withAnimation { toast = new }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private func openReview(assetID: String) {
        Task {
            let opened = await UIApplication.shared.open(OutfitReview.url(forAssetID: assetID))
            if !opened { showToast(.openFailed, seconds: 3) }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: 12) {
                switch toast {
                case .logged(let assetID):
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(red: 60 / 255, green: 230 / 255, blue: 176 / 255))
                    Text("Logged to Outfits").foregroundStyle(Color(red: 240 / 255, green: 234 / 255, blue: 251 / 255))
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 18)
                    Button { openReview(assetID: assetID) } label: {
                        Text("Review now").fontWeight(.bold).foregroundStyle(Self.outfitLilac)
                    }
                    .accessibilityIdentifier("deck.outfitToast.review")
                case .openFailed:
                    Text("Couldn't open Overland").foregroundStyle(Color(red: 240 / 255, green: 234 / 255, blue: 251 / 255))
                case .deleteBlocked:
                    Text(DeckCardImagePolicy.blockedDeleteMessage).foregroundStyle(Color(red: 240 / 255, green: 234 / 255, blue: 251 / 255))
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Capsule().fill(Color(red: 30 / 255, green: 22 / 255, blue: 48 / 255).opacity(0.92)))
            .overlay(Capsule().stroke(Self.outfitLilac.opacity(0.5), lineWidth: 1))
            .padding(.top, 60)
            .transition(.opacity)
        }
    }

    private var positionAndFilmstrip: some View {
        VStack(spacing: 6) {
            FilmstripView(
                items: viewModel.visibleItems,
                currentIndex: viewModel.currentIndex,
                pendingDeleteIDs: viewModel.pendingDeleteIDs,
                isKept: { viewModel.isKept($0) }
            ) { index in
                viewModel.currentIndex = index
            }
            if !viewModel.visibleItems.isEmpty {
                Text("\(viewModel.currentIndex + 1) OF \(viewModel.visibleItems.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityIdentifier("deck.position")
            }
        }
    }

    private var bottomControls: some View {
        HStack {
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(white: 0.15)))
            }
            .disabled(viewModel.undoStack.isEmpty)
            .accessibilityIdentifier("deck.undo")

            Spacer()

            Button { showHidePopover = true } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(white: 0.15)))
            }
            .accessibilityIdentifier("deck.filter")
            .popover(isPresented: $showHidePopover) {
                // REMOTE GATE (mark sorted till here): hidden for a remote deck,
                // where it would mass-keep (= queue downloads for) everything
                // before the current card. markSortedUpToCurrent also no-ops
                // for remote as a second line of defense.
                HideSortedPopover(hideSorted: $viewModel.hideSorted, markSortedToHere: {
                    viewModel.markSortedUpToCurrent()
                    showHidePopover = false
                }, showsMarkSortedToHere: !viewModel.isRemote)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 16)
    }
}

/// The swipeable card. Drag/offset/rotation/spring-back and the swipe commit
/// decision are now owned entirely by Shuffle's `SwipeCard` (see
/// `PicnicSwipeCard`), reached through a `UIViewRepresentable`. This struct
/// is just the SwiftUI-side wiring: closures in, a live translation reading
/// out to `dragState` so `DeckTintBackground`/`SwipeVerdictLabel` keep
/// tracking the drag exactly as before.
private struct DeckCard: View {
    let item: DeckItem
    let image: UIImage?
    /// Already filtered for group-resolved by the caller; non-nil means show
    /// the pill.
    let compareGroup: CompareGroup?
    let onCompare: (CompareGroup) -> Void
    let onLongPress: () -> Void
    let showsICloudBadge: Bool
    let deleteBlocked: Bool
    let onBlockedDelete: () -> Void
    let onDelete: () -> Void
    let onKeep: () -> Void
    let onDismiss: () -> Void
    /// Shared so the tint and the verdict labels track the same drag. Held as
    /// @ObservedObject here because this view genuinely must repaint per
    /// frame; DeckView deliberately does not observe it.
    @ObservedObject var dragState: DeckDragState
    let cardAspectRatio: CGFloat
    /// Plain `let`, not `@ObservedObject`: this view must NOT resubscribe
    /// to the controller's ~10Hz time updates (that's VideoTimeLabel's job,
    /// added as a separate observing view below) — only asset.mediaType
    /// switching what's passed to `ShuffleCardRepresentable` is read here.
    let videoController: VideoPlaybackController
    let onVideoRetry: () -> Void
    /// Draws the remote-album accent frame on the card (RemoteDeckStyle).
    let isRemote: Bool

    var body: some View {
        // Same order as the dimmed peek card below it (aspectRatio, THEN
        // padding): fitting the ratio first and padding second means the
        // 20pt margin comes out of the box the ratio was computed against,
        // so the UIKit representable actually ends up sized/shaped like the
        // 4:5 card. Doing it the other way — padding applied inside this
        // view's body while `.aspectRatio` sat on the call site outside —
        // let the representable size itself off the full, unpadded deck
        // width, so the photo (and its black letterbox) spilled past the
        // card's own rounded rect and the dimmed peek card showed through
        // above/below instead of being covered by opaque black.
        // REMOTE GATE (video / Live Photo flags): nil phAsset means neither.
        let isVideo = item.phAsset?.mediaType == .video
        ShuffleCardRepresentable(
            image: image,
            isLivePhoto: item.phAsset?.mediaSubtypes.contains(.photoLive) ?? false,
            compareCount: compareGroup?.assets.count,
            cardAspectRatio: cardAspectRatio,
            videoPlayer: isVideo ? videoController.player : nil,
            onCompare: { if let compareGroup { onCompare(compareGroup) } },
            onLongPress: onLongPress,
            showsICloudBadge: showsICloudBadge,
            deleteBlocked: deleteBlocked,
            onBlockedDelete: onBlockedDelete,
            onDelete: onDelete,
            onKeep: onKeep,
            onDismiss: onDismiss,
            onTranslationChange: { dragState.translation = $0 },
            isRemote: isRemote
        )
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        // 8pt, not 20pt: the reference app runs its card almost edge to edge
        // (~9pt margin each side). `.aspectRatio(fit)` inside this
        // `maxHeight: .infinity` ZStack already picks whichever of the
        // width- or height-derived box is smaller on its own — no extra
        // GeometryReader math needed, shrinking this padding is enough to
        // let the box grow.
        .padding(.horizontal, 8)
        .overlay(alignment: .bottomLeading) {
            if isVideo {
                VideoTimeLabel(controller: videoController)
            }
        }
        .overlay {
            if isVideo {
                VideoLoadOverlay(controller: videoController, onRetry: onVideoRetry)
            }
        }
    }
}

/// Bridges `PicnicSwipeCard` (UIKit) into the SwiftUI tree. Live-photo badge
/// and Compare pill live as real subviews of the UIKit card itself (see
/// `PicnicSwipeCard`) so they ride along with Shuffle's own transform —
/// nothing here needs to re-derive an offset for them.
private struct ShuffleCardRepresentable: UIViewRepresentable {
    let image: UIImage?
    let isLivePhoto: Bool
    let compareCount: Int?
    let cardAspectRatio: CGFloat
    let videoPlayer: AVPlayer?
    let onCompare: () -> Void
    let onLongPress: () -> Void
    let showsICloudBadge: Bool
    let deleteBlocked: Bool
    let onBlockedDelete: () -> Void
    let onDelete: () -> Void
    let onKeep: () -> Void
    let onDismiss: () -> Void
    let onTranslationChange: (CGSize) -> Void
    let isRemote: Bool

    func makeUIView(context: Context) -> PicnicSwipeCard {
        PicnicSwipeCard()
    }

    func updateUIView(_ card: PicnicSwipeCard, context: Context) {
        card.configure(
            image: image, isLivePhoto: isLivePhoto, compareCount: compareCount, videoPlayer: videoPlayer,
            showsICloudBadge: showsICloudBadge, deleteBlocked: deleteBlocked,
            isRemote: isRemote
        )
        card.onBlockedDelete = onBlockedDelete
        card.onCompare = onCompare
        card.onLongPress = onLongPress
        card.onDelete = onDelete
        card.onKeep = onKeep
        card.onDismiss = onDismiss
        card.onTranslationChange = onTranslationChange
    }

    /// A plain `UIViewRepresentable` reports no size preference of its own,
    /// so the ancestor `.aspectRatio(cardAspectRatio, contentMode: .fit)`
    /// (DeckCard.body above) can't reason about this view's flexibility and
    /// just hands it the full proposed width from the outer `ZStack` —
    /// which is how the top card ended up rendering wider than both its own
    /// 4:5 box and the correctly-boxed peek card behind it (ff5bcca only
    /// reordered the modifiers; it never gave the representable a size
    /// preference to negotiate with). Deriving a fitted size straight from
    /// the proposal using the same `cardAspectRatio` the peek card is
    /// boxed to is what makes both cards agree on one box.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PicnicSwipeCard, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width > 0, height > 0 else { return nil }
        if width / height > cardAspectRatio {
            return CGSize(width: height * cardAspectRatio, height: height)
        } else {
            return CGSize(width: width, height: width / cardAspectRatio)
        }
    }
}
