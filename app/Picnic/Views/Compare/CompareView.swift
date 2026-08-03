import SwiftUI
import Photos

struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: CompareViewModel
    @State private var pageIndex = 0

    init(viewModel: CompareViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $pageIndex) {
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
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Inset the paging container itself (not the card) so the
            // adjacent pages, which sit flush against this container's own
            // edges, peek into the screen once clipping is disabled —
            // matches the reference's edge-peeking carousel.
            .padding(.horizontal, 24)
            .scrollClipDisabled()

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
