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
                LazyHStack(spacing: 6) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        FilmstripThumbnail(
                            asset: asset,
                            isCurrent: index == currentIndex,
                            isPendingDelete: pendingDeleteIDs.contains(asset.localIdentifier),
                            onTap: { onSelect(index) }
                        )
                        .id(index)
                        .accessibilityIdentifier("filmstrip.thumb.\(index)")
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
                // `.aspectRatio(contentMode: .fill)` deliberately reports an
                // ideal LAYOUT size bigger than its proposed size when the
                // source aspect ratio doesn't match (that's how "fill" then
                // relies on an ancestor clip to work at all) — for the
                // 900x500 landscape source that's 65.33x36, not 24x36. The
                // outer ZStack's `.frame(24,36).clipShape(...)` already
                // clips what's RENDERED, but accessibility's merged-element
                // geometry (`.accessibilityElement(children: .ignore)`
                // below) is the union of descendants' own reported layout
                // frames, which isn't affected by an ancestor's clip. Giving
                // the Image its own `.frame(24,36).clipped()` makes ITS
                // reported frame 24x36 too, so the union — and therefore
                // XCUITest's read of the cell — matches what's on screen.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 36)
                    .clipped()
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
        // Clip AFTER the frame, on the ZStack itself — not on the Image
        // while it's still unconstrained. An aspect-fill landscape source
        // lays out wider than this 24pt frame; clipping the Image alone
        // clips its own oversized bounds, not the 24x36 box, so the
        // overflow bled into neighbouring thumbnails in the filmstrip.
        // Clipping the already-framed ZStack trims whatever overflows it,
        // for any source aspect ratio.
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            // .strokeBorder draws entirely inside the shape's bounds (unlike
            // .stroke, which centres the line ON the edge and bleeds half its
            // width outside the frame) — a 2pt .stroke was eating 1pt of the
            // gap to each neighbour on every side, which is what read as the
            // thumbnails overlapping.
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2)
        )
        // Without this, SwiftUI's automatic accessibility synthesis attaches
        // the .accessibilityIdentifier applied at the call site to an
        // auto-generated element inside this view's tree (the Image), whose
        // layout frame is its pre-clip, aspect-filled size — not this ZStack's
        // clipped 24x36 frame. Making the ZStack a single opaque accessibility
        // element means XCUITest reads its own (post-clip) frame instead.
        .accessibilityElement(children: .ignore)
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
