import SwiftUI
import Photos

struct DeckView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: DeckViewModel

    @State private var currentImage: UIImage?
    @State private var dragOffset: CGSize = .zero
    @State private var showHidePopover = false
    @State private var showLivePhoto = false
    @State private var livePhoto: PHLivePhoto?
    @State private var activeCompareGroup: CompareGroup?

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
                if let asset = viewModel.currentAsset {
                    cardView(for: asset).id(asset.localIdentifier)
                } else {
                    emptyState
                }
            }
            .frame(maxHeight: .infinity)

            bottomActionsRow
            positionAndFilmstrip
            bottomControls
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: viewModel.currentAsset?.localIdentifier) {
            await loadCurrentImage()
        }
        .fullScreenCover(item: $activeCompareGroup) { group in
            CompareView(viewModel: CompareViewModel(
                group: group,
                monthKey: viewModel.month.key,
                sortStore: appState.sortStore,
                photoLibrary: appState.photoLibrary,
                mirrorQueue: appState.mirrorQueue
            ))
        }
        .fullScreenCover(isPresented: $showLivePhoto) {
            if let livePhoto {
                LivePhotoPlayerView(livePhoto: livePhoto) { showLivePhoto = false }
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
        guard let asset = viewModel.currentAsset else { currentImage = nil; return }
        currentImage = await ThumbnailLoader.fullImage(for: asset, targetSize: CGSize(width: 1200, height: 1600))
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
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Card

    private func cardView(for asset: PHAsset) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.08))

            if let currentImage {
                Image(uiImage: currentImage)
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

            VStack {
                Spacer()
                if let group = GroupingService.group(containing: asset, in: viewModel.visibleAssets),
                   !appState.sortStore.isGroupResolved(group.id) {
                    Button {
                        activeCompareGroup = group
                    } label: {
                        HStack(spacing: 6) {
                            Text("Compare \(group.assets.count)")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.55)))
                    }
                    .accessibilityIdentifier("deck.comparePill")
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .offset(dragOffset)
        .rotationEffect(.degrees(Double(dragOffset.width / 20)))
        .accessibilityIdentifier("deck.card")
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in handleSwipeEnd(value) }
        )
        .onLongPressGesture(minimumDuration: 0.35) {
            presentLivePhotoIfNeeded(asset)
        }
    }

    private func handleSwipeEnd(_ value: DragGesture.Value) {
        let threshold: CGFloat = 110
        let dismissThreshold: CGFloat = 140

        // Quiet secondary exit: a plain downward drag on the card, distinct
        // from the horizontal delete/keep swipes, with no visible chrome.
        // Reuses the same commit-then-dismiss logic as the top-right X.
        if value.translation.height > dismissThreshold && abs(value.translation.width) < 80 {
            withAnimation(.spring) { dragOffset = .zero }
            Task { await exitDeck() }
            return
        }

        if value.translation.width < -threshold {
            withAnimation(.spring) { dragOffset = CGSize(width: -600, height: value.translation.height) }
            viewModel.markForDelete()
            resetDragAfterSwipe()
        } else if value.translation.width > threshold {
            withAnimation(.spring) { dragOffset = CGSize(width: 600, height: value.translation.height) }
            viewModel.markKept()
            resetDragAfterSwipe()
        } else {
            withAnimation(.spring) { dragOffset = .zero }
        }
    }

    private func resetDragAfterSwipe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            dragOffset = .zero
        }
    }

    private func presentLivePhotoIfNeeded(_ asset: PHAsset) {
        guard asset.mediaSubtypes.contains(.photoLive) else { return }
        Task {
            livePhoto = await LivePhotoLoader.load(asset: asset)
            showLivePhoto = livePhoto != nil
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
