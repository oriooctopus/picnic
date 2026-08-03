import SwiftUI

struct SmartCollectionTile: View {
    @EnvironmentObject var appState: AppState
    let kind: SmartCollectionKind
    let count: Int

    @State private var coverImage: UIImage?

    private var countString: String {
        count.formatted(.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Standard cell pattern (see MonthCardView): Color.clear drives
            // sizing via .aspectRatio(.fit) off the grid's own flexible
            // column width, no GeometryReader involved.
            Color.clear
                .aspectRatio(0.85, contentMode: .fit)
                .overlay {
                    if let coverImage {
                        Image(uiImage: coverImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(white: 0.15)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .padding(8)
                }
            Text(kind.title).font(.subheadline.bold()).foregroundStyle(.white)
            Text(countString).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        // Single AX element for the whole tile — without this, the identifier
        // applied at the call site bleeds onto the icon overlay and both Text
        // layers as separate elements with their own (mismatched) frames.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("smartCollection.tile.\(kind.rawValue)")
        .accessibilityLabel("\(kind.title), \(count)")
        .task(id: count) {
            // Genuinely-empty collections keep the plain dark card per
            // PARITY.md — only fetch a cover when there's something to show.
            guard count > 0, let asset = appState.photoLibrary.coverAsset(for: kind) else {
                coverImage = nil
                return
            }
            coverImage = await ThumbnailLoader.thumbnail(for: asset, targetSize: CGSize(width: 240, height: 280))
        }
    }
}
