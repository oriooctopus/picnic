import Photos
import UIKit
import QuartzCore
import AVFoundation

/// One delivery from `ThumbnailLoader.imageUpdates`.
struct DeckImageUpdate: @unchecked Sendable {
    let image: UIImage?
    /// PhotoKit's low-res stand-in; the full image may still follow.
    let isDegraded: Bool
    /// The full image lives in iCloud and is not on the device.
    let isInCloud: Bool
}

/// PHImageManager wrappers. The continuation-based ones use `.highQualityFormat`
/// deliberately — `.opportunistic` calls its result handler twice (low-res,
/// then high-res), which would resume a checked continuation more than once
/// and crash. `imageUpdates` is the opportunistic one and is a stream for
/// exactly that reason.
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

    /// UI-test-only: a simulator library is always local, so the offline-iCloud
    /// card states can never occur naturally. `--simulate-undownloaded-images`
    /// answers every load with "no pixels, image lives in iCloud";
    /// `--simulate-icloud-lowres` answers deck loads with only a degraded
    /// stand-in. Same DEBUG-only, read-once pattern as `--slow-image-loads`.
    static let simulateUndownloaded = ProcessInfo.processInfo.arguments.contains("--simulate-undownloaded-images")
    static let simulateICloudLowRes = ProcessInfo.processInfo.arguments.contains("--simulate-icloud-lowres")

    static func simulatedUpdates() -> [DeckImageUpdate]? {
        if simulateUndownloaded {
            return [DeckImageUpdate(image: nil, isDegraded: false, isInCloud: true)]
        }
        if simulateICloudLowRes {
            let standIn = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80)).image { ctx in
                UIColor.gray.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            }
            return [
                DeckImageUpdate(image: standIn, isDegraded: true, isInCloud: true),
                DeckImageUpdate(image: nil, isDegraded: false, isInCloud: true),
            ]
        }
        return nil
    }
    #endif

    /// The request options for `imageUpdates`: opportunistic so a cached low-res
    /// image arrives first (an iCloud-only photo offline still shows something),
    /// network allowed so the full image can follow. Extracted so the choice is
    /// pinned by a test: `.highQualityFormat` here would leave an offline
    /// iCloud card blank instead of low-res.
    static func opportunisticOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        // Same reason as fullImage: without .exact the card holds a full-resolution bitmap.
        options.resizeMode = .exact
        return options
    }

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
        #if DEBUG
        if simulateUndownloaded { return nil }
        #endif
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

    /// Poster for a video card, local data only (no iCloud fetch), so the card
    /// shows something immediately; the network-allowed `thumbnail` then upgrades it.
    static func localThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
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

    /// Best-effort, LOCAL-ONLY capture used only for the pre-delete mirror-
    /// queue thumbnail (DeckViewModel.commitDeletions). Deliberately does NOT
    /// call the `thumbnail(for:targetSize:)` above and reuse its options:
    /// that method's `isNetworkAccessAllowed = true` is the right call for
    /// rendering a card the user is actively looking at, but wrong here.
    /// commitDeletions() calls this for every asset in the batch, in
    /// parallel (see `deletionThumbnails(for:targetSize:)` below), BEFORE
    /// the actual PhotoKit delete, and holds `isCommitting` (blocking the
    /// commit UI) for the whole call. On a library with "Optimize iPhone
    /// Storage" on, allowing network access here would let PHImageManager
    /// fire real iCloud downloads with no timeout — a single stalled fetch
    /// would hang the entire commit indefinitely, meaning the user's actual
    /// deletion (the feature) never happens because a debugging aid (the
    /// thumbnail) is stuck waiting on iCloud. `isNetworkAccessAllowed =
    /// false` + `.fastFormat` means this can only ever return what PhotoKit
    /// already has on-disk, immediately — never worth "fixing" back to the
    /// shared method, which would silently reintroduce that hang. A cache
    /// miss just yields nil, which callers already treat as "ship no
    /// thumbnail for this asset," never a reason to block or retry.
    /// In practice this usually succeeds anyway: by the time the user can
    /// commit a delete, DeckView has already rendered this exact asset as a
    /// card, so PhotoKit has it cached locally.
    static func deletionThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
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

    /// Concurrent batch wrapper around `deletionThumbnail(for:targetSize:)`,
    /// returning base64-encoded JPEGs keyed by localIdentifier (skipping any
    /// asset that yielded nil or failed to encode). Runs the fetches as a
    /// `withTaskGroup` rather than a sequential loop so a batch of N pending
    /// deletes costs roughly one PhotoKit round trip, not N of them, while
    /// commitDeletions() has `isCommitting` blocking the UI. `ThumbnailLoader`
    /// carries no actor isolation of its own (it's a plain enum of static
    /// funcs), so this can build and await its task group freely even though
    /// its only caller, DeckViewModel.commitDeletions(), is @MainActor —
    /// gathering the whole batch happens off the main actor, and only the
    /// final `[String: String]` crosses back into DeckViewModel's isolation.
    static func deletionThumbnails(for assets: [PHAsset], targetSize: CGSize) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for asset in assets {
                group.addTask {
                    guard let image = await deletionThumbnail(for: asset, targetSize: targetSize),
                          let data = image.jpegData(compressionQuality: 0.7) else {
                        return (asset.localIdentifier, nil)
                    }
                    return (asset.localIdentifier, data.base64EncodedString())
                }
            }
            var result: [String: String] = [:]
            for await (id, base64) in group {
                if let base64 { result[id] = base64 }
            }
            return result
        }
    }

    /// Debug-only `--slow-image-loads` delay, see `slowImageLoadsEnabled`.
    static func applySlowLoadDelayIfEnabled() async {
        #if DEBUG
        if slowImageLoadsEnabled {
            try? await Task.sleep(nanoseconds: slowImageLoadDelay)
        }
        #endif
    }

    /// Deck card loading: the cached low-res image first (an iCloud-only photo
    /// on a phone with no signal still shows something), then the full image,
    /// each as one update. The stream finishes after the final result (or when
    /// PhotoKit reports a cancel); cancelling the consuming task, or dropping
    /// out of the `for await`, cancels the underlying PHImageManager request,
    /// so a card that is swiped away stops downloading.
    static func imageUpdates(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<DeckImageUpdate> {
        AsyncStream { continuation in
            #if DEBUG
            if let simulated = simulatedUpdates() {
                for update in simulated { continuation.yield(update) }
                continuation.finish()
                return
            }
            #endif
            let options = opportunisticOptions()
            let started = CACurrentMediaTime()
            let requestID = PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.finish()
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                continuation.yield(DeckImageUpdate(image: image, isDegraded: isDegraded, isInCloud: isInCloud))
                // A degraded image is followed by another callback; anything else is final.
                if !(isDegraded && image != nil) {
                    let pixels = image.map { CGSize(width: $0.size.width * $0.scale,
                                                    height: $0.size.height * $0.scale) } ?? .zero
                    PerfMonitor.shared.recordImageLoad(
                        seconds: CACurrentMediaTime() - started, fromICloud: isInCloud, pixelSize: pixels
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    /// The best image PhotoKit can give for `asset` right now: the final one
    /// if it arrives, else the low-res stand-in. For the dimmed card behind
    /// the deck, which must show something offline too.
    static func bestAvailableImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        var best: UIImage?
        for await update in imageUpdates(for: asset, targetSize: targetSize) {
            if let image = update.image { best = image }
        }
        return best
    }

    /// Background warm-up for a month: pulls a small version of every asset
    /// from iCloud into PhotoKit's on-disk cache so swiping never waits on a
    /// network round trip. Runs at utility priority, two fetches at a time
    /// (a wider fan-out competes with the card the user is actually
    /// loading), and stops as soon as the calling task is cancelled.
    /// Results are discarded; the point is PhotoKit keeping the downloaded
    /// derivative, which the later full-size request then upgrades from.
    static func warmCache(for assets: [PHAsset], targetSize: CGSize = CGSize(width: 400, height: 533)) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = assets.makeIterator()
            func addNext() {
                guard !Task.isCancelled, let asset = iterator.next() else { return }
                group.addTask(priority: .utility) {
                    _ = await thumbnail(for: asset, targetSize: targetSize)
                }
            }
            addNext(); addNext()
            while await group.next() != nil { addNext() }
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
enum VideoItemResult {
    case item(AVPlayerItem)
    case failed
}

enum VideoLoader {
    /// A request failed when PhotoKit returned no item, or reports an error or a cancel.
    static func didFail(hasItem: Bool, info: [AnyHashable: Any]?) -> Bool {
        if !hasItem { return true }
        if info?[PHImageErrorKey] != nil { return true }
        if (info?[PHImageCancelledKey] as? Bool) == true { return true }
        return false
    }

    /// Like `playerItem(for:)` but surfaces iCloud download progress (0...1) and
    /// distinguishes failure from success instead of returning a bare nil.
    static func load(for asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async -> VideoItemResult {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            options.progressHandler = { value, _, _, _ in progress(value) }
            var didResume = false
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                guard !didResume else { return }
                didResume = true
                if let item, !didFail(hasItem: true, info: info) {
                    continuation.resume(returning: .item(item))
                } else {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }

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
