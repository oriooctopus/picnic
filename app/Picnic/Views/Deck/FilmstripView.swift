import SwiftUI
import Photos

struct FilmstripView: View {
    let assets: [PHAsset]
    let currentIndex: Int
    let pendingDeleteIDs: Set<String>
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy, not a plain HStack: a plain one builds a thumbnail view
                // for every asset in the month the moment the deck opens, and
                // fires every thumbnail fetch at once. On a real month of a few
                // hundred photos that alone made swiping stutter.
                LazyHStack(spacing: 3) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        FilmstripThumbnail(
                            asset: asset,
                            isCurrent: index == currentIndex,
                            isPendingDelete: pendingDeleteIDs.contains(asset.localIdentifier),
                            onTap: { onSelect(index) }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                // When the strip's content is narrower than the available
                // width (few thumbnails, or scrolled to the very start/end),
                // a horizontal ScrollView leaves it flush against the
                // leading edge by default (defect C4). Growing this wrapper
                // to fill the ScrollView's width and centering the HStack
                // within it fixes that for the narrow case while leaving
                // normal leading-aligned scroll behavior intact once the
                // content overflows.
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: 36)
            .onAppear {
                // Without this, the strip sits at its natural leading-edge
                // scroll position (current thumbnail flush left, half cut
                // off by the frame) until currentIndex first changes — the
                // .onChange below never fires on initial load since nothing
                // has changed yet.
                proxy.scrollTo(currentIndex, anchor: .center)
            }
            .onChange(of: currentIndex) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }
}

/// One filmstrip cell, owning its own loaded image. Previously every cell wrote
/// into a single dictionary held by FilmstripView, so each finished fetch
/// invalidated the strip and rebuilt every other cell — N loads costing N
/// rebuilds of N views. Keeping the image here means a finished load repaints
/// only the cell it belongs to.
private struct FilmstripThumbnail: View {
    let asset: PHAsset
    let isCurrent: Bool
    let isPendingDelete: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if isPendingDelete {
                RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.35))
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
            }
        }
        // Matches the reference app: every thumbnail is the same size —
        // unlike the old 40pt/48pt jump, nothing enlarges on selection here,
        // only the stroke below marks which one is current.
        .frame(width: 24, height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.white : .clear, lineWidth: 2)
        )
        .onTapGesture { onTap() }
        .task {
            if image == nil {
                image = await ThumbnailLoader.thumbnail(
                    for: asset, targetSize: CGSize(width: 72, height: 72)
                )
            }
        }
    }
}
