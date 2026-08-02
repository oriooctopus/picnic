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
        // Standard cell pattern: Color.clear drives layout sizing via
        // .aspectRatio(.fit), so the card's frame comes from the LazyVGrid's
        // flexible column width the same way every other cell in the grid
        // does. GeometryReader previously computed its own width/height and
        // stamped it onto every inner layer; that size could settle a frame
        // apart from what UIKit/AX actually reported for the cell, which is
        // what sent taps/long-presses to the neighboring month. With no
        // GeometryReader, there's only one source of truth for the frame —
        // the layout system's — so the accessibility element's reported
        // frame always matches the rendered cell.
        Color.clear
            .aspectRatio(cardAspectRatio, contentMode: .fit)
            .overlay {
                if let coverImage {
                    Image(uiImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(white: 0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 64)
                        .frame(maxWidth: .infinity, alignment: .bottom)

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
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            // Single AX element for the whole card, sized to the true
            // rendered frame — not one element per inner layer (cover Image
            // + both Texts), which is what let XCUITest resolve taps/presses
            // to a stale, mis-sized frame instead of the actual card location.
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
