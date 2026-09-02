import SwiftUI
import Photos

struct FilmstripView: View {
    let assets: [PHAsset]
    let currentIndex: Int
    let pendingDeleteIDs: Set<String>
    let isKept: (PHAsset) -> Bool
    let onSelect: (Int) -> Void

    /// nil when `currentIndex` is out of range (e.g. the deck just emptied).
    /// See the `.onChange(of: currentAssetID)` below for why this is keyed
    /// on identity rather than the raw index.
    ///
    /// DELIBERATELY REINSTATED BUG (identity-only, no count) for CI run #2
    /// of the test40FilmstripRecentersOnCurrentPhotoAfterUnhideAtScale
    /// regression proof — see the fixed version kept at
    /// /tmp/FilmstripView.swift.fixed on the implementer's machine. Restore
    /// the fixed version before this is done.
    private var currentAssetID: String? {
        assets.indices.contains(currentIndex) ? assets[currentIndex].localIdentifier : nil
    }

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
                            isKept: isKept(asset),
                            onTap: { onSelect(index) }
                        )
                        // NOT .id(index): SwiftUI already keys each cell's
                        // *identity* on localIdentifier via the ForEach
                        // above (that's what lets FilmstripThumbnail own a
                        // stable @State image — see its doc comment below).
                        // .id(index) used to override that identity back to
                        // raw array position, so removing any item (e.g. a
                        // hideSorted-triggered filter) shifted every later
                        // cell's index, and SwiftUI read that as "this is a
                        // brand new view" for every shifted cell — tearing
                        // it down and rebuilding it with `image` reset to
                        // nil. That's what read as blank gray thumbnails
                        // until each cell's `.task` re-fetched. Scroll-to-
                        // current below now looks up the id by asset
                        // identifier instead, so nothing needs the index
                        // as an id anymore.
                        .id(asset.localIdentifier)
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
                // has changed yet. Scrolls by asset identifier, matching the
                // .id() each cell now carries above — currentIndex is only
                // used to look up which asset that is.
                if assets.indices.contains(currentIndex) {
                    proxy.scrollTo(assets[currentIndex].localIdentifier, anchor: .center)
                }
            }
            // Keyed on the current asset's IDENTITY, not its numeric index,
            // AND on the strip's length. Each half fixes a distinct way the
            // scroll offset used to be left stranded:
            //
            // IDENTITY (device-only bug; see DeckView.loadCurrentImage's doc
            // comment for the sibling half of this same report): under
            // hideSorted, the swiped asset is removed from `assets` and the
            // NEXT asset slides into the same numeric slot, so `currentIndex`
            // itself often never changes value across an entire sorting
            // session — an `.onChange(of: currentIndex)` then never fires at
            // all, and `proxy.scrollTo` never runs again after the very first
            // `.onAppear` scroll. Meanwhile every cell after the removed one
            // shifts one slot left (still keyed by asset id — see the
            // ForEach's own doc comment above) while the scroll offset stays
            // put, so the current-cell border visibly walks toward the
            // leading edge, one cell per swipe, for the rest of the session.
            //
            // COUNT: the exact mirror image, and the owner's "unhiding sends
            // the bar back to the beginning" report. Toggling hideSorted OFF
            // deliberately keeps the deck on the same photo
            // (DeckViewModel.reanchorCurrentIndex), so `assetID` alone does
            // NOT change — while every previously-filtered sorted photo is
            // re-inserted around it, most of them BEFORE it. The identity
            // half stays silent, the stale content offset survives, and
            // because the list grew ahead of the current cell that offset now
            // points near the strip's start instead of at the current photo.
            // `count` changes on any such re-composition, so this fires and
            // re-centers.
            //
            // Animated only when the current photo actually changed (a
            // navigation — a swipe or a filmstrip tap, including the
            // hideSorted swipes where the count moves too). A pure
            // re-composition under a stationary photo is a filter toggle:
            // there the strip should just already be where it belongs, so it
            // re-centers without animating rather than visibly sliding.
            .onChange(of: currentAssetID) { _, newValue in
                guard let newValue else { return }
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
    let isKept: Bool
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
            } else if isKept {
                RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.35))
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
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
        // Exposes badge state for UI tests without touching geometry: this
        // repo's own precedent (check_filmstrip_overlap.py's doc comment)
        // is that XCUITest's reported AX *frames* stop tracking real
        // rendered geometry, so a test can never trust "is the red X badge
        // actually drawn" from a frame read. accessibilityValue carries no
        // geometry at all — it's a plain string the cell reports on demand —
        // so it's safe to assert on for "is this cell pending/kept/plain"
        // the same way `pendingBadge.label` already is for the numeric
        // count above it.
        .accessibilityValue(isPendingDelete ? "pending" : (isKept ? "kept" : "unsorted"))
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
