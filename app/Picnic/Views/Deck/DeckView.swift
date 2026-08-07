import SwiftUI
import Photos

struct DeckView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: DeckViewModel

    @State private var currentImage: UIImage?
    /// The photo of the card underneath, shown dimmed as the top card is
    /// thrown clear — the reference reveals the real next picture, not a grey
    /// placeholder.
    @State private var nextImage: UIImage?
    @State private var showHidePopover = false
    /// Plain @State on purpose: it holds the object without subscribing to it,
    /// so a drag repaints the tint and labels but never this view's body (and
    /// therefore never the filmstrip). See DeckDragState.
    @State private var dragState = DeckDragState()
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
                        cardAspectRatio: cardAspectRatio
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
            }
        }
        .fullScreenCover(item: $presentation) { item in
            switch item {
            case .compare(let group):
                CompareView(viewModel: CompareViewModel(
                    group: group,
                    monthKey: viewModel.month.key,
                    sortStore: appState.sortStore,
                    photoLibrary: appState.photoLibrary,
                    mirrorQueue: appState.mirrorQueue
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

    private func loadCurrentImage() async {
        guard let asset = viewModel.currentAsset else { currentImage = nil; nextImage = nil; return }
        currentImage = await ThumbnailLoader.fullImage(for: asset, targetSize: CGSize(width: 1200, height: 1600))

        // The card behind is dimmed and partly covered, so it is fetched at a
        // fraction of the size — enough to read, cheap enough not to compete
        // with the card actually being dragged.
        let nextIndex = viewModel.currentIndex + 1
        guard viewModel.visibleAssets.indices.contains(nextIndex) else { nextImage = nil; return }
        nextImage = await ThumbnailLoader.fullImage(
            for: viewModel.visibleAssets[nextIndex], targetSize: CGSize(width: 600, height: 800)
        )
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
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
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
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
                        .offset(x: 6, y: -6)
                        .accessibilityIdentifier("deck.pendingCount")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
                pendingDeleteIDs: viewModel.pendingDeleteIDs
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
        ShuffleCardRepresentable(
            image: image,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            compareCount: compareGroup?.assets.count,
            cardAspectRatio: cardAspectRatio,
            onCompare: { if let compareGroup { onCompare(compareGroup) } },
            onLongPress: onLongPress,
            onDelete: onDelete,
            onKeep: onKeep,
            onDismiss: onDismiss,
            onTranslationChange: { dragState.translation = $0 }
        )
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        .padding(.horizontal, 20)
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
        card.configure(image: image, isLivePhoto: isLivePhoto, compareCount: compareCount)
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
