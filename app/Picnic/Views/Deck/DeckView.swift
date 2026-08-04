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
                    ZStack {
                        RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.08))
                        if let nextImage {
                            Image(uiImage: nextImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                        RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.55))
                    }
                    .padding(.horizontal, 20)
                    .scaleEffect(0.96)
                    .offset(y: -6)
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
                        dragState: dragState
                    )
                    .id(asset.localIdentifier)
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

/// The swipeable card, extracted so the in-flight drag offset lives here
/// rather than on DeckView. As @State on DeckView it invalidated that whole
/// body on every drag frame — which rebuilt the entire filmstrip's ForEach
/// and re-read visibleAssets several times per frame, and was the actual
/// cause of the laggy swipe. Confining it here means a drag repaints only
/// this card.
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

    /// What the card is actually offset by: the finger's travel amplified, so
    /// the card leads the hand rather than sticking to it.
    private var visualOffset: CGSize {
        CGSize(width: dragState.translation.width * DeckSwipeMetrics.travelMultiplier,
               height: dragState.translation.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.08))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            }

            if asset.mediaSubtypes.contains(.photoLive) {
                Image(systemName: "livephoto")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .padding(12)
            }
        }
        // Single AX element for the card's own frame (fill image + live-photo
        // badge collapsed into one) — the Compare pill below is a real
        // control and stays out of this ignored subtree so it remains its
        // own tappable, separately-identified element rather than bleeding
        // the "deck.card" identifier onto multiple inner layers.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("deck.card")
        // Drag + long-press are scoped to ONLY this base layer (image +
        // live-photo badge), not to the composite that includes the Compare
        // pill below. An ancestor .gesture(DragGesture()) sitting over a
        // nested Button gets first refusal on touch-down, and
        // .onLongPressGesture in particular installs a recognizer that holds
        // the touch waiting to see if it becomes a long-press, delaying (and
        // in practice swallowing) the Button's own tap recognition.
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .gesture(
            DragGesture()
                .onChanged { value in dragState.translation = value.translation }
                .onEnded { value in handleSwipeEnd(value) }
        )
        .onLongPressGesture(minimumDuration: 0.35) { onLongPress() }
        .overlay(alignment: .bottom) {
            if let compareGroup {
                Button {
                    onCompare(compareGroup)
                } label: {
                    HStack(spacing: 6) {
                        Text("Compare \(compareGroup.assets.count)")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deck.comparePill")
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 20)
        .offset(visualOffset)
        .rotationEffect(.degrees(Double(visualOffset.width / 26)))
    }

    private func handleSwipeEnd(_ value: DragGesture.Value) {
        // Judged on the finger's real travel, not the amplified card position:
        // amplifying the visuals should make the deck feel livelier, not make
        // it commit off a shorter gesture than before.
        let threshold = DeckSwipeMetrics.threshold
        let dismissThreshold: CGFloat = 140

        // Judge the swipe by where the drag was HEADED, not where the finger
        // happened to lift. A quick flick — the normal way people sort a
        // deck — ends with a small raw translation but a large predicted
        // one; using raw translation alone makes flicks silently do nothing.
        let translation = CGSize(
            width: max(abs(value.translation.width), abs(value.predictedEndTranslation.width))
                * (value.translation.width < 0 ? -1 : 1),
            height: max(abs(value.translation.height), abs(value.predictedEndTranslation.height))
                * (value.translation.height < 0 ? -1 : 1)
        )

        // Quiet secondary exit: a plain downward drag on the card, distinct
        // from the horizontal delete/keep swipes, with no visible chrome.
        // Reuses the same commit-then-dismiss logic as the top-right X.
        if translation.height > dismissThreshold && abs(translation.width) < 80 {
            withAnimation(.spring) { dragState.translation = .zero }
            onDismiss()
            return
        }

        if translation.width < -threshold {
            withAnimation(.spring) { dragState.translation = CGSize(width: -600, height: value.translation.height) }
            onDelete()
            resetDragAfterSwipe()
        } else if translation.width > threshold {
            withAnimation(.spring) { dragState.translation = CGSize(width: 600, height: value.translation.height) }
            onKeep()
            resetDragAfterSwipe()
        } else {
            withAnimation(.spring) { dragState.translation = .zero }
        }
    }

    private func resetDragAfterSwipe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dragState.translation = .zero
        }
    }
}
