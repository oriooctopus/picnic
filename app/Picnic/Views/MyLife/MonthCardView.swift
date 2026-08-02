import SwiftUI
import Photos

struct MonthCardView: View {
    @EnvironmentObject var appState: AppState
    let month: MonthBucket

    @State private var coverImage: UIImage?

    private var remainingCount: Int {
        max(0, month.assets.count - appState.sortStore.addressedCount(for: month.assets))
    }

    private var isSorted: Bool {
        appState.sortStore.isMonthManuallySorted(month.key) || (month.assets.isEmpty == false && remainingCount == 0)
    }

    // Portrait ~2:3 per PARITY.md.
    private let cardAspectRatio: CGFloat = 2.0 / 3.0
    private let cornerRadius: CGFloat = 16

    var body: some View {
        // GeometryReader pins an EXACT pixel width/height for every layer
        // (background fill, cover image, gradient) instead of letting the
        // ZStack infer its own size from the cover Image's intrinsic aspect
        // ratio. Without this, a `.resizable().aspectRatio(.fill)` Image with
        // no explicit frame can leak its source aspect ratio upward through
        // the ZStack and override the LazyVGrid's flexible column width —
        // that's what produced the overlapping, wildly-different-width cards.
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(white: 0.15))

                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }

                LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)

                VStack(alignment: .leading, spacing: 2) {
                    Text(month.monthAbbreviation)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if isSorted {
                        Text("Sorted").font(.subheadline.bold()).foregroundStyle(.green)
                    } else {
                        Text("\(remainingCount)").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(10)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        // Single AX element for the whole card, sized to the true rendered
        // frame (post GeometryReader/clipShape) — not one element per inner
        // layer (cover Image + both Texts), which is what let XCUITest
        // resolve taps/presses to a stale, unclipped Image frame instead of
        // the actual card location.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("monthCard.\(month.key)")
        .accessibilityLabel("\(month.monthAbbreviation), \(isSorted ? "Sorted" : "\(remainingCount) remaining")")
        .contextMenu {
            Button {
                appState.sortStore.setMonthManuallySorted(true, monthKey: month.key)
            } label: {
                Label("Mark as sorted", systemImage: "hand.thumbsup.fill")
            }
            .accessibilityIdentifier("month.markSorted")
            Button {
                appState.sortStore.setMonthManuallySorted(false, monthKey: month.key)
            } label: {
                Label("Mark as unsorted", systemImage: "circle")
            }
            .accessibilityIdentifier("month.markUnsorted")
        }
        .task {
            coverImage = await ThumbnailLoader.thumbnail(for: month.coverAsset, targetSize: CGSize(width: 240, height: 300))
        }
    }
}
