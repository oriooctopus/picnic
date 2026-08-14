import SwiftUI
import Photos
import AVFoundation

struct DeckView: View {
    @EnvironmentObject var appState: AppState
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
    /// Long-press the month title to reveal the frame-rate readout. Hidden by
    /// default so it never intrudes on normal use, but present in the ad-hoc
    /// build because the phone is the only place the stutter reproduces.
    @State private var showPerfHUD = false
    /// One presentation slot for both modals. Two `.fullScreenCover`
    /// modifiers on the same view silently collapse into one in SwiftUI —
    /// the Compare cover never presented while a live-photo cover was also
    /// attached here.
    @State private var presentation: DeckPresentation?

    /// Every card — the live one and the dimmed peek underneath — renders at
    /// this fixed portrait ratio so the outline never changes shape between
    /// photos; landscape/square photos letterbox inside it instead. 4:5
    /// (width:height = 0.8) sits inside the 3:4–9:16 band, reads as a
    /// standard "portrait card" shape (matches common photo-app card ratios)
    /// and comfortably fits between the header and the bottom rows without
    /// clipping either.
    private let cardAspectRatio: CGFloat = 4.0 / 5.0

    enum DeckPresentation: Identifiable {
        case compare(CompareGroup)
        case livePhoto(PHLivePhoto)

        var id: String {
            switch self {
            case .compare(let group): return "compare-\(group.id)"
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
            topBar

            ZStack {
                // The card underneath, dimmed. Revealed as the top card is
                // thrown aside, which is what gives the deck its depth in the
                // reference — previously this was a pair of flat grey
                // rectangles with no picture in them.
                if viewModel.currentIndex + 1 < viewModel.visibleAssets.count {
                    DeckPeekCard(image: nextImage, dragState: dragState, cardAspectRatio: cardAspectRatio)
                }

                if let asset = viewModel.currentAsset {
                    DeckCard(
                        asset: asset,
                        image: currentImage,
                        compareGroup: viewModel.groupByAssetID[asset.localIdentifier].flatMap {
                            appState.sortStore.isGroupResolved($0.id) ? nil : $0
                        },
                        onCompare: { presentation = .compare($0) },
                        onLongPress: { presentLivePhotoIfNeeded(asset) },
                        onDelete: { viewModel.markForDelete() },
                        onKeep: { viewModel.markKept() },
                        onDismiss: { Task { await exitDeck() } },
                        dragState: dragState,
                        cardAspectRatio: cardAspectRatio,
                        videoController: videoController
                    )
                    .id(asset.localIdentifier)
                    // The photo itself is still assigned synchronously in
                    // onAdvance below (same run-loop turn as currentIndex
                    // moving — see advance()'s doc comment), so this never
                    // delays or flickers the wrong photo; it only eases the
                    // geometry of the newly-mounted card in from the peek
                    // card's own resting look (0.96 scale) up to full size,
                    // instead of popping straight to full size the instant
                    // the swipe commits.
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    emptyState
                }
            }
            .overlay { SwipeVerdictLabel(state: dragState) }
            .frame(maxHeight: .infinity)
            // Gap below the two-line header so the card (and its stack-peek
            // layers) never overlaps the date/time subline (defect C1/C5).
            .padding(.top, 16)

            // Outside and below the card on purpose — see VideoControlBar's
            // doc comment: a scrub drag here must never compete with the
            // card's own swipe pan gesture.
            if let asset = viewModel.currentAsset, asset.mediaType == .video {
                VideoControlBar(controller: videoController)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
            }

            bottomActionsRow
            positionAndFilmstrip
            bottomControls
        }
        .background(DeckTintBackground(state: dragState))
        .overlay(alignment: .topLeading) {
            if showPerfHUD {
                PerfHUD().padding(.leading, 12).padding(.top, 64)
            }
        }
        // Always mounted (invisible) so a UI test can read the numbers without
        // needing the HUD itself shown.
        .overlay(alignment: .topLeading) { PerfStatsProbe() }
        .task(id: viewModel.currentAsset?.localIdentifier) {
            await loadCurrentImage()
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
                nextImage = nil
                nextImageAssetID = nil
            }
        }
        .fullScreenCover(item: $presentation) { item in
            switch item {
            case .compare(let group):
                CompareView(viewModel: CompareViewModel(
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
    /// under hideSorted, `currentAsset` changes identity with NO synchronous
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
    /// the swiped photo (the new `currentAsset` is the same one `nextImage`
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
    /// gated against the LIVE `viewModel.currentAsset` rather than the
    /// (necessarily still-equal-to-itself) local `asset` — and `nextIndex`
    /// is derived from the captured `startIndex`, not a fresh read of
    /// `viewModel.currentIndex`, so a stale invocation can't prefetch for a
    /// position that has since moved.
    private func loadCurrentImage() async {
        guard let asset = viewModel.currentAsset else {
            currentImage = nil; nextImage = nil; nextImageAssetID = nil
            videoController.clear()
            return
        }

        // A1: see this function's doc comment. Must run before any `await`
        // — the whole point is closing the gap between currentAsset changing
        // and the first suspension point below, not just shortening it.
        if nextImageAssetID == asset.localIdentifier, let prefetched = nextImage {
            currentImage = prefetched
            nextImage = nil
            nextImageAssetID = nil
        }

        // A2: captured now, used for every gate below.
        let loadingID = asset.localIdentifier
        let startIndex = viewModel.currentIndex

        if asset.mediaType == .video {
            // Poster frame first (cheap, shows immediately), then swap the
            // shared player onto this asset's item once PhotoKit hands one
            // back.
            currentImage = await ThumbnailLoader.thumbnail(for: asset, targetSize: ThumbnailLoader.screenPixelSize)
            if let item = await VideoLoader.playerItem(for: asset) {
                videoController.load(item: item)
            } else {
                videoController.clear()
            }
        } else {
            // Not a video card: make sure nothing keeps playing/decoding
            // behind a plain photo.
            videoController.clear()
            let fetched = await ThumbnailLoader.fullImage(for: asset, targetSize: ThumbnailLoader.screenPixelSize)
            // A2 gate: only trust this fetch if it's still for the asset
            // actually on screen — see the doc comment above.
            if viewModel.currentAsset?.localIdentifier == loadingID {
                currentImage = fetched
            }
        }

        // The card behind is dimmed and partly covered, so it is fetched at a
        // fraction of the size — enough to read, cheap enough not to compete
        // with the card actually being dragged. Derived from `startIndex`
        // (captured above `await`), not a fresh `viewModel.currentIndex`
        // read — see A2 in the doc comment.
        let nextIndex = startIndex + 1
        guard viewModel.visibleAssets.indices.contains(nextIndex) else {
            if viewModel.currentAsset?.localIdentifier == loadingID { nextImage = nil; nextImageAssetID = nil }
            return
        }
        let nextAsset = viewModel.visibleAssets[nextIndex]
        let fetchedNext = await ThumbnailLoader.fullImage(for: nextAsset, targetSize: CGSize(width: 600, height: 800))
        // A2 gate, same reasoning as the currentImage assignment above.
        if viewModel.currentAsset?.localIdentifier == loadingID {
            nextImage = fetchedNext
            nextImageAssetID = nextAsset.localIdentifier
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
                Text(viewModel.month.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let asset = viewModel.currentAsset, let date = asset.creationDate {
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

    private func presentLivePhotoIfNeeded(_ asset: PHAsset) {
        guard asset.mediaSubtypes.contains(.photoLive) else { return }
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
            Text("All sorted for \(viewModel.month.title)")
                .foregroundStyle(.white)
        }
    }

    // MARK: Bottom rows

    private var bottomActionsRow: some View {
        HStack(spacing: 56) {
            Button {
                guard let asset = viewModel.currentAsset else { return }
                Task { await viewModel.toggleFavorite(asset) }
            } label: {
                let isFav = viewModel.currentAsset.map { viewModel.isFavorite($0) } ?? false
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .foregroundStyle(isFav ? .red : .white)
            }
            // Add-to-album: present but disabled, per SPEC.md v1 scope cuts.
            Image(systemName: "text.badge.plus")
                .foregroundStyle(.white.opacity(0.3))
            Button {
                guard let asset = viewModel.currentAsset else { return }
                ShareSheetPresenter.present(asset: asset)
            } label: {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.white)
            }
        }
        .font(.system(size: 22))
        .padding(.vertical, 14)
    }

    private var positionAndFilmstrip: some View {
        VStack(spacing: 6) {
            FilmstripView(
                assets: viewModel.visibleAssets,
                currentIndex: viewModel.currentIndex,
                pendingDeleteIDs: viewModel.pendingDeleteIDs,
                isKept: { viewModel.isKept($0) }
            ) { index in
                viewModel.currentIndex = index
            }
            if !viewModel.visibleAssets.isEmpty {
                Text("\(viewModel.currentIndex + 1) OF \(viewModel.visibleAssets.count)")
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
                HideSortedPopover(hideSorted: $viewModel.hideSorted)
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
    let asset: PHAsset
    let image: UIImage?
    /// Already filtered for group-resolved by the caller; non-nil means show
    /// the pill.
    let compareGroup: CompareGroup?
    let onCompare: (CompareGroup) -> Void
    let onLongPress: () -> Void
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
        let isVideo = asset.mediaType == .video
        ShuffleCardRepresentable(
            image: image,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            compareCount: compareGroup?.assets.count,
            cardAspectRatio: cardAspectRatio,
            videoPlayer: isVideo ? videoController.player : nil,
            onCompare: { if let compareGroup { onCompare(compareGroup) } },
            onLongPress: onLongPress,
            onDelete: onDelete,
            onKeep: onKeep,
            onDismiss: onDismiss,
            onTranslationChange: { dragState.translation = $0 }
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
    let onDelete: () -> Void
    let onKeep: () -> Void
    let onDismiss: () -> Void
    let onTranslationChange: (CGSize) -> Void

    func makeUIView(context: Context) -> PicnicSwipeCard {
        PicnicSwipeCard()
    }

    func updateUIView(_ card: PicnicSwipeCard, context: Context) {
        card.configure(image: image, isLivePhoto: isLivePhoto, compareCount: compareCount, videoPlayer: videoPlayer)
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
