import Photos
import UIKit
import QuartzCore

/// PHImageManager wrappers. Both use `.highQualityFormat` deliberately —
/// `.opportunistic` calls its result handler twice (low-res, then high-res),
/// which would resume a checked continuation more than once and crash.
enum ThumbnailLoader {
    static func thumbnail(for asset: PHAsset?, targetSize: CGSize) async -> UIImage? {
        guard let asset else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options
            ) { image, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    static func fullImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let started = CACurrentMediaTime()
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            // Without this the deck card holds a full-resolution photo.
            // resizeMode defaults to .none, which tells PhotoKit not to resize
            // at all — targetSize becomes a lower bound and a 12-megapixel
            // original comes back whole. The card then re-renders that bitmap,
            // masked by clipShape and transformed by offset/rotation, on every
            // frame of a drag, which is what made swiping stutter on a real
            // library. The sibling thumbnail() above already sets .fast; this
            // one was simply missed.
            options.resizeMode = .exact
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, info in
                guard !didResume else { return }
                didResume = true
                // Whether PhotoKit had to pull this from iCloud rather than
                // local storage. On a phone with Optimize Storage on, this is
                // a network round trip per card — and it can never happen on a
                // simulator, whose library is always local, so no CI run can
                // surface it.
                let fromICloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                // Pixel size is reported so the resizeMode above is verifiable
                // on the device rather than taken on trust: if the HUD shows a
                // card image anywhere near camera resolution, PhotoKit is
                // handing back the original again.
                let pixels = image.map { CGSize(width: $0.size.width * $0.scale,
                                                height: $0.size.height * $0.scale) } ?? .zero
                PerfMonitor.shared.recordImageLoad(
                    seconds: CACurrentMediaTime() - started,
                    fromICloud: fromICloud,
                    pixelSize: pixels
                )
                continuation.resume(returning: image)
            }
        }
    }
}

enum LivePhotoLoader {
    static func load(asset: PHAsset) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1600),
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded, livePhoto != nil {
                    // Wait for the follow-up full-quality callback.
                    return
                }
                didResume = true
                continuation.resume(returning: livePhoto)
            }
        }
    }
}

enum ShareSheetPresenter {
    @MainActor
    static func present(asset: PHAsset) {
        Task {
            guard let image = await ThumbnailLoader.fullImage(for: asset, targetSize: PHImageManagerMaximumSize) else { return }
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            root.present(activityVC, animated: true)
        }
    }
}
