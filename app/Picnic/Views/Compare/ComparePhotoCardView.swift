import SwiftUI
import Photos

struct ComparePhotoCardView: View {
    let asset: PHAsset
    let isBest: Bool
    let fileSize: Int64?
    let isAccepted: Bool
    let isRejected: Bool
    let isFavorite: Bool
    let onReject: () -> Void
    let onAccept: () -> Void
    let onFavorite: () -> Void

    @State private var image: UIImage?

    private var dateString: String {
        guard let date = asset.creationDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm:ss a"
        return f.string(from: date)
    }

    private var sizeString: String {
        guard let fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.08))
                if let image {
                    // .fit, not .fill, to match the deck card
                    // (PicnicSwipeCard.imageView.contentMode = .scaleAspectFit):
                    // .fill cropped every photo whose aspect ratio differed
                    // from this box, so the same photo looked zoomed-in here
                    // vs. the deck. Landscape/square sources letterbox onto
                    // the dark rounded fill instead.
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            // .frame BEFORE .clipShape, on the ZStack itself: an unframed
            // aspect-ratio'd Image reports its own oversized ideal
            // layout size (its intrinsic pixel dimensions) whenever the
            // source's aspect ratio doesn't match the box, not just its
            // drawn/clipped size — same defect class as the deck filmstrip
            // and letterbox bugs. With no frame at all here, that inflated
            // size propagated straight up through this VStack, pushing the
            // caption row, the reject/accept/favorite row, and the whole
            // bottomBar in CompareView off the bottom of the screen for
            // any source photo tall/wide enough to trigger it — "some of
            // the compares" have buttons that are missing, not hidden.
            // maxWidth/maxHeight: .infinity caps this view at whatever
            // space TabView actually proposed instead of the image's own
            // ideal size winning that negotiation.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(isAccepted ? Color.green : (isRejected ? Color.red : .clear), lineWidth: 3)
            )

            HStack(spacing: 6) {
                if isBest {
                    Image(systemName: "star.fill").foregroundStyle(.purple)
                    Text("BEST").foregroundStyle(.purple).bold()
                    Text("·").foregroundStyle(.white.opacity(0.5))
                }
                Text(dateString).foregroundStyle(.white.opacity(0.8))
                if !sizeString.isEmpty {
                    Text("· \(sizeString)").foregroundStyle(.white.opacity(0.8))
                }
            }
            .font(.footnote)
            .textCase(.uppercase)

            HStack(spacing: 40) {
                Button(action: onReject) {
                    Image(systemName: isRejected ? "trash.fill" : "trash").foregroundStyle(isRejected ? .red : .white)
                }
                .accessibilityIdentifier("compare.reject")
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 20)
                Button(action: onAccept) {
                    Image(systemName: isAccepted ? "hand.thumbsup.fill" : "hand.thumbsup").foregroundStyle(isAccepted ? .green : .white)
                }
                .accessibilityIdentifier("compare.accept")
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart").foregroundStyle(isFavorite ? .red : .white)
                }
                .accessibilityIdentifier("compare.favorite")
            }
            .font(.system(size: 20))
        }
        .task {
            image = await ThumbnailLoader.fullImage(for: asset, targetSize: ThumbnailLoader.screenPixelSize)
        }
    }
}
