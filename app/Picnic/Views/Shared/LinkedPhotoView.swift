import Photos
import SwiftUI

/// Full-screen view of the photo a `PhotoLink` points at.
struct LinkedPhotoView: View {
    let assetID: String
    let onClose: () -> Void

    @State private var asset: PHAsset?
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityIdentifier("linkedPhoto.image")
                } else if missing {
                    Text("Photo not found")
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityIdentifier("linkedPhoto.missing")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 24) {
                if let asset {
                    Button { ShareSheetPresenter.present(asset: asset) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(action: onClose) { Image(systemName: "xmark") }
                    .accessibilityIdentifier("linkedPhoto.close")
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .padding(20)
        }
        .task(id: assetID) { await load() }
    }

    private func load() async {
        guard let found = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            missing = true
            return
        }
        asset = found
        let scale = UIScreen.main.scale
        let size = UIScreen.main.bounds.size
        image = await ThumbnailLoader.fullImage(for: found, targetSize: CGSize(width: size.width * scale, height: size.height * scale))
        if image == nil { missing = true }
    }
}
