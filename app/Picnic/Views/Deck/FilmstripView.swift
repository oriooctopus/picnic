import SwiftUI
import Photos

struct FilmstripView: View {
    let assets: [PHAsset]
    let currentIndex: Int
    let pendingDeleteIDs: Set<String>
    let onSelect: (Int) -> Void

    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        thumbnail(asset: asset, index: index)
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
            .frame(height: 56)
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

    private func thumbnail(asset: PHAsset, index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.15))
            if let image = thumbnails[asset.localIdentifier] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if pendingDeleteIDs.contains(asset.localIdentifier) {
                RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.35))
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
            }
        }
        .frame(width: index == currentIndex ? 48 : 40, height: index == currentIndex ? 48 : 40)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(index == currentIndex ? Color.white : .clear, lineWidth: 2)
        )
        .onTapGesture { onSelect(index) }
        .task {
            if thumbnails[asset.localIdentifier] == nil {
                thumbnails[asset.localIdentifier] = await ThumbnailLoader.thumbnail(
                    for: asset, targetSize: CGSize(width: 96, height: 96)
                )
            }
        }
    }
}
