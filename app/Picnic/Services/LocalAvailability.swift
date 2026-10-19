import Photos
import UIKit

/// Answers "can this deck card render at full quality with no network?" for
/// offline-only mode, and remembers the answers.
///
/// Why a probe at all: PhotoKit has no public "is this asset's original on
/// the device" flag. The only honest test is to ask for the exact derivative
/// the card will ask for, with the network switched off, and see whether it
/// comes back complete. The request shape (`.highQualityFormat`, `.exact`,
/// `ThumbnailLoader.screenPixelSize`, `.aspectFit`) deliberately matches
/// `DeckPrefetcher.start`, so the derivative probed here is the same one the
/// prefetcher downloads; a prefetch that finishes therefore really does turn
/// a probe from "no" to "yes".
///
/// Unprobed means unavailable. Offline-only mode must never show a card that
/// turns out blank, so the safe default for "don't know yet" is hidden, and
/// the set only ever grows (`markAvailable` / a positive probe).
///
/// Results are cached for the deck's lifetime and never re-asked: a photo the
/// probe called missing but the card load later downloaded stays "missing"
/// until the deck is reopened. The prefetcher reports its own downloads via
/// `markAvailable`, which is the path that matters in practice.
@MainActor
final class LocalAvailability {
    /// Concurrent probes. Each is a local-store lookup plus a screen-size
    /// decode; 4 keeps the main-queue completion handlers from piling up.
    /// A guess, not a measurement.
    static let maxConcurrent = 4
    /// `onChange` fires after this many newly-available items during a probe
    /// pass, not once per item: every fire makes the deck rebuild its visible
    /// list (and re-cluster Compare groups over the whole month), which is far
    /// too much work to repeat per photo across a few thousand probes.
    static let flushEvery = 25

    private(set) var availableIDs: Set<String> = []
    private(set) var probedIDs: Set<String> = []
    /// True while a `probe` pass is running, so the deck can say "checking"
    /// instead of "nothing downloaded" while the answer is still arriving.
    private(set) var isProbing = false
    /// Fired when the answers changed (or probing started/stopped). The deck
    /// view model re-derives its visible list from it.
    var onChange: (() -> Void)?

    func isAvailable(_ id: String) -> Bool { availableIDs.contains(id) }

    /// Records a positive answer without probing, e.g. a prefetch that just
    /// finished downloading the card's derivative.
    func markAvailable(_ id: String) {
        probedIDs.insert(id)
        if availableIDs.insert(id).inserted { onChange?() }
    }

    /// Probes `items` in month order starting at `startIndex` (wrapping), so
    /// the cards the user is about to swipe to are answered first. Skips ids
    /// already probed. Cancellable: a cancelled pass keeps what it learned.
    func probe(items: [DeckItem], startIndex: Int) async {
        guard !items.isEmpty else { return }
        let start = min(max(startIndex, 0), items.count - 1)
        // (index in month order, item). The index travels with the item so the
        // DEBUG partial simulation is stable regardless of where the pass starts.
        let indexed = Array(items.enumerated())
        let queue = (indexed[start...] + indexed[..<start]).filter { !probedIDs.contains($0.element.id) }
        guard !queue.isEmpty else { return }

        isProbing = true
        onChange?()
        var pendingFlush = 0
        defer {
            isProbing = false
            onChange?()
        }
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            while next < min(Self.maxConcurrent, queue.count) {
                let (index, item) = queue[next]
                next += 1
                group.addTask { (item.id, await Self.probeOne(item, monthIndex: index)) }
            }
            while let (id, ok) = await group.next() {
                probedIDs.insert(id)
                if ok, availableIDs.insert(id).inserted {
                    pendingFlush += 1
                    if pendingFlush >= Self.flushEvery { pendingFlush = 0; onChange?() }
                }
                // A cancelled pass stops feeding the group; the few probes
                // already in flight finish and are recorded.
                if !Task.isCancelled, next < queue.count {
                    let (index, item) = queue[next]
                    next += 1
                    group.addTask { (item.id, await Self.probeOne(item, monthIndex: index)) }
                }
            }
        }
    }

    /// The probe for one item. nonisolated so the task group runs the
    /// PhotoKit/disk calls off the main actor.
    private nonisolated static func probeOne(_ item: DeckItem, monthIndex: Int) async -> Bool {
        #if DEBUG
        if ThumbnailLoader.simulateUndownloaded { return false }
        if ThumbnailLoader.simulatePartiallyDownloaded { return monthIndex % 2 == 0 }
        #endif
        switch item {
        case .remote(let remote):
            // Videos stream from the server and are never cached to disk, so a
            // remote video is never available offline.
            guard !remote.isVideo, let url = remote.displayURL else { return false }
            return RemoteDisplayCache.isCached(url)
        case .local(let asset):
            return asset.mediaType == .video ? await localVideoIsOnDevice(asset) : await localPhotoIsOnDevice(asset)
        }
    }

    /// Complete, non-degraded, not-in-cloud image with the network off. A
    /// degraded stand-in or an in-cloud flag means the full image would need
    /// iCloud, which is exactly what offline-only mode exists to exclude.
    private nonisolated static func localPhotoIsOnDevice(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.resizeMode = .exact
            // .highQualityFormat calls back once, but a defensive single-resume
            // guard is cheap and a double resume of a checked continuation crashes.
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: ThumbnailLoader.screenPixelSize, contentMode: .aspectFit, options: options
            ) { image, info in
                guard !didResume else { return }
                didResume = true
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                continuation.resume(returning: image != nil && !degraded && !inCloud)
            }
        }
    }

    /// A video is on the device iff PhotoKit hands back its AVAsset without
    /// network access.
    private nonisolated static func localVideoIsOnDevice(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            var didResume = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: avAsset != nil)
            }
        }
    }
}
