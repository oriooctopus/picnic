import SwiftUI
import Photos

struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: CompareViewModel
    @State private var pageIndex = 0
    /// Backs `.scrollPosition(id:)` — kept separate from `pageIndex` because
    /// the scroll view can only report/accept an Int?, while `pageIndex`
    /// (used by the thumbnail strip below) needs a non-optional default.
    @State private var scrollPosition: Int?

    init(viewModel: CompareViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // One card fills the viewport edge-to-edge, snapping one at a
            // time — no neighboring-card peek. `.containerRelativeFrame`
            // was tried first but reserves ~24pt it doesn't account for
            // inside this ScrollView/LazyHStack combo, silently bleeding
            // the next card through the gap; an explicit GeometryReader
            // width sidesteps that entirely.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(viewModel.group.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                            ComparePhotoCardView(
                                asset: asset,
                                isBest: asset.localIdentifier == viewModel.bestAssetID,
                                fileSize: viewModel.fileSizes[asset.localIdentifier],
                                isAccepted: viewModel.acceptedAssetID == asset.localIdentifier,
                                isRejected: viewModel.rejectedAssetIDs.contains(asset.localIdentifier),
                                isFavorite: viewModel.favoritedAssetIDs.contains(asset.localIdentifier),
                                onReject: { viewModel.reject(asset) },
                                onAccept: { viewModel.accept(asset) },
                                onFavorite: { Task { await viewModel.toggleFavorite(asset) } }
                            )
                            .frame(width: proxy.size.width)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollPosition)
                .onChange(of: scrollPosition) { _, newValue in
                    if let newValue { pageIndex = newValue }
                }
                .onChange(of: pageIndex) { _, newValue in
                    if scrollPosition != newValue {
                        withAnimation { scrollPosition = newValue }
                    }
                }
            }

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

            Spacer()

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
                        Circle()
                            .fill(asset.localIdentifier == viewModel.acceptedAssetID ? Color.green : .clear)
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Spacer()

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
        .task {
            image = await ThumbnailLoader.thumbnail(for: asset, targetSize: CGSize(width: 88, height: 120))
        }
    }
}
