import SwiftUI
import Photos

struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: CompareViewModel
    @State private var pageIndex: Int

    /// startAssetID: the group member Compare was opened from (the deck card
    /// under the Compare pill), so the pager starts on that photo rather
    /// than always on the group's first. The deck only offers Compare for
    /// the current card's own group, so the id is always a member.
    init(startAssetID: String, viewModel: CompareViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        guard let start = viewModel.group.assets.firstIndex(where: { $0.localIdentifier == startAssetID }) else {
            preconditionFailure("Compare opened from an asset outside its own group: \(startAssetID)")
        }
        _pageIndex = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // TabView(.page) is the primitive actually built for "one page
            // exactly fills the view, swipe to the next, nothing else
            // visible" — a hand-rolled ScrollView(.horizontal) +
            // .scrollTargetBehavior(.viewAligned) was tried first (twice:
            // once with containerRelativeFrame, once with an explicit
            // GeometryReader width) and both left an identical ~24pt strip
            // of the next card bleeding in on the trailing edge — that
            // reservation turned out to be inherent to .viewAligned itself,
            // not the card's sizing, so no amount of width-fixing touched
            // it. TabView(.page) doesn't have that behavior.
            TabView(selection: $pageIndex) {
                ForEach(Array(viewModel.group.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                    ComparePhotoCardView(
                        asset: asset,
                        isBest: asset.localIdentifier == viewModel.bestAssetID,
                        fileSize: viewModel.fileSizes[asset.localIdentifier],
                        isAccepted: viewModel.acceptedAssetIDs.contains(asset.localIdentifier),
                        isRejected: viewModel.rejectedAssetIDs.contains(asset.localIdentifier),
                        isFavorite: viewModel.favoritedAssetIDs.contains(asset.localIdentifier),
                        onReject: { viewModel.reject(asset) },
                        onAccept: { viewModel.accept(asset) },
                        onFavorite: { Task { await viewModel.toggleFavorite(asset) } }
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .task { await viewModel.loadFileSizes() }
        .onChange(of: viewModel.isResolved) { _, resolved in
            if resolved { dismiss() }
        }
        .alert("Couldn't resolve group", isPresented: Binding(
            get: { viewModel.resolveError != nil },
            set: { if !$0 { viewModel.resolveError = nil } }
        )) {
            Button("OK") { viewModel.resolveError = nil }
        } message: {
            Text(viewModel.resolveError ?? "")
        }
    }

    private var header: some View {
        ZStack {
            Text("Compare").font(.title3.bold()).foregroundStyle(.white)
            HStack {
                Spacer()
                Image(systemName: "square.on.square").foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
        .contentShape(Rectangle())
        // Swipe-down-from-the-top exits Compare, mirroring the deck's own
        // quiet drag-to-dismiss. Unconditional (unlike the X button, which
        // stays gated on canConfirm to match the reference's grayed-out
        // chrome) — a gesture-based escape shouldn't require a photo to
        // already be sorted. Scoped to the header only, so it can't compete
        // with the card carousel's own horizontal drag.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 60 && abs(value.translation.width) < 60 {
                        dismiss()
                    }
                }
        )
    }

    /// X, the group thumbnail strip, and the confirm check all sit in one
    /// row — matches the reference, where they share a single baseline
    /// rather than the thumbnails forming their own row above the controls.
    private var bottomBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color(white: 0.15)))
            }
            .disabled(!viewModel.canConfirm)
            .opacity(viewModel.canConfirm ? 1 : 0.35)
            .accessibilityIdentifier("compare.dismiss")

            Spacer(minLength: 8)

            // Horizontally scrollable, not a plain HStack: a burst group can
            // run to 7+ photos, and a fixed-width row that long (7 * 44pt +
            // spacing) overflows a phone-width screen — without a
            // ScrollView to absorb that overflow, the X and confirm buttons
            // on either side get squeezed off-screen for exactly the groups
            // this feature exists to handle.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.group.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        VStack(spacing: 4) {
                            CompareThumbnailView(asset: asset)
                                .frame(width: 44, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(index == pageIndex ? Color.white : .clear, lineWidth: 2)
                                )
                                .onTapGesture { withAnimation { pageIndex = index } }
                            // Green = kept, red = cued for deletion. The
                            // reject case used to have no dot at all (only
                            // `acceptedAssetID` was consulted), so tapping
                            // trash left the strip looking untouched and the
                            // only feedback was the card's own red border,
                            // which is off-screen for every group member the
                            // pager isn't currently showing.
                            Circle()
                                .fill(viewModel.acceptedAssetIDs.contains(asset.localIdentifier)
                                      ? Color.green
                                      : (viewModel.rejectedAssetIDs.contains(asset.localIdentifier) ? Color.red : .clear))
                                .frame(width: 6, height: 6)
                        }
                        // Mark state exposed the same way FilmstripThumbnail
                        // does it (accessibilityValue, never frames — this
                        // repo's AX frames don't track real geometry), so a
                        // UI test can assert the dot actually appeared rather
                        // than only that the tap was accepted.
                        .accessibilityValue(
                            viewModel.acceptedAssetIDs.contains(asset.localIdentifier) ? "kept"
                            : (viewModel.rejectedAssetIDs.contains(asset.localIdentifier) ? "pending" : "unsorted")
                        )
                        // Deterministic page-jump target for UI tests: swipe-based
                        // paging on the TabView(.page) card can't reliably target
                        // "page N" (adjacent pages may or may not be realized in
                        // the AX tree during a transition), but this thumbnail's
                        // own onTapGesture above sets pageIndex directly and
                        // synchronously — tapping it is a deterministic way to
                        // land on a specific group member's card.
                        .accessibilityIdentifier("compare.thumb.\(index)")
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.confirmResolution() }
            } label: {
                if viewModel.isResolving {
                    ProgressView().tint(.black)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.white))
                } else {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.white))
                }
            }
            .disabled(!viewModel.canConfirm || viewModel.isResolving)
            .opacity(viewModel.canConfirm ? 1 : 0.35)
            .accessibilityIdentifier("compare.confirm")
        }
        .padding()
    }
}

private struct CompareThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.15))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        // Self-clip so this view never depends on the caller applying
        // .frame before .clipShape to contain an aspect-fill landscape
        // source — same overflow-into-neighbours failure mode as
        // FilmstripThumbnail, just guarded here instead of relying on
        // call-site modifier order.
        .clipped()
        .task {
            image = await ThumbnailLoader.thumbnail(for: asset, targetSize: CGSize(width: 88, height: 120))
        }
    }
}
