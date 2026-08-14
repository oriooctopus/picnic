import Photos
import UIKit
import QuartzCore
import AVFoundation

/// PHImageManager wrappers. Both use `.highQualityFormat` deliberately —
/// `.opportunistic` calls its result handler twice (low-res, then high-res),
/// which would resume a checked continuation more than once and crash.
enum ThumbnailLoader {
    #if DEBUG
    /// UI-test-only fault injection for the hideSorted-flicker bug (see
    /// DeckView.loadCurrentImage's doc comment): a simulator's PhotoKit
    /// library answers `requestImage` from local storage in the same
    /// run-loop tick, so no CI run could ever land in the async gap that bug
    /// lives in. `--slow-image-loads` stands in for a real device's iCloud
    /// round trip (the same `fromICloud` case `fullImage` below already
    /// measures) by delaying every full-image fetch. Read once into a
    /// `static let` rather than re-checked per call: `ProcessInfo.arguments`
    /// is fixed for the process's whole lifetime, so per-call re-scanning
    /// would just be repeated work with no behavioral difference — and
    /// `#if DEBUG` keeps this entirely out of the Release build the owner
    /// installs, so it can never fire outside a test run.
    static let slowImageLoadsEnabled = ProcessInfo.processInfo.arguments.contains("--slow-image-loads")
    /// How long `--slow-image-loads` delays each full-image fetch. Long
    /// enough that a UI test's "immediately after the swipe" screenshot
    /// (taken well under a second later) reliably lands before this elapses,
    /// short enough that a test suite exercising it twice per test (current
    /// + prefetch, sequential awaits — see DeckView.loadCurrentImage)
    /// doesn't balloon CI time.
    static let slowImageLoadDelay: UInt64 = 2_500_000_000
    #endif

    /// The device's real physical pixel dimensions (not points) — the
    /// correct upper-bound targetSize for any card that renders close to
    /// full-screen. The deck card and Compare's photo card were both
    /// requesting fixed sizes (1200x1600 / 1000x1300) chosen before the
    /// cards were made bigger to fill more of the screen; neither constant
    /// was revisited afterward, so PhotoKit was handing back an image
    /// smaller than the box it got stretched into — a real, measurable
    /// upsample, not a rendering artifact. Deriving this from the screen
    /// itself means it can't go stale the next time a card's size changes.
    static var screenPixelSize: CGSize { UIScreen.main.nativeBounds.size }

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
        #if DEBUG
        if slowImageLoadsEnabled {
            try? await Task.sleep(nanoseconds: slowImageLoadDelay)
        }
        #endif
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

/// Fetches a directly-playable `AVPlayerItem` for a video `PHAsset`, same
/// checked-continuation shape as `ThumbnailLoader`/`LivePhotoLoader` above.
enum VideoLoader {
    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: item)
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
