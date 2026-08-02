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
                RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.08))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isAccepted ? Color.green : (isRejected ? Color.red : .clear), lineWidth: 3)
            )
            .padding(.horizontal, 16)

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

            HStack(spacing: 40) {
                Button(action: onReject) {
                    Image(systemName: "trash.fill").foregroundStyle(isRejected ? .red : .white)
                }
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 20)
                Button(action: onAccept) {
                    Image(systemName: "hand.thumbsup.fill").foregroundStyle(isAccepted ? .green : .white)
                }
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart").foregroundStyle(isFavorite ? .red : .white)
                }
            }
            .font(.system(size: 20))
        }
        .task {
            image = await ThumbnailLoader.fullImage(for: asset, targetSize: CGSize(width: 1000, height: 1300))
        }
    }
}
