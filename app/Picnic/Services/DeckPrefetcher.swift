import Photos
import UIKit

/// Forces PhotoKit to download the full screen-size image of nearby iCloud
/// photos before the user swipes to them, so the on-card load in DeckView is
/// served from PhotoKit's local store instead of waiting on the network.
///
/// Results are discarded on purpose: holding ~30 screen-size bitmaps would cost
/// hundreds of MB, and the download into PhotoKit's store is the whole point.
/// Same targetSize/contentMode as `ThumbnailLoader.imageUpdates` so the cached
/// derivative is the one the card asks for.
@MainActor
final class DeckPrefetcher {
    static let radius = 15
    static let maxInFlight = 2

    /// Indices to prefetch around `current`: the next `radius` cards first
    /// (the user is swiping forward), then the previous `radius`, clamped to
    /// the list.
    nonisolated static func window(count: Int, current: Int, radius: Int = DeckPrefetcher.radius) -> [Int] {
        guard count > 0, (0..<count).contains(current) else { return [] }
        let steps = Array(stride(from: 1, through: radius, by: 1))
        return (steps.map { current + $0 } + steps.map { current - $0 }).filter { (0..<count).contains($0) }
    }

    private var inFlight: [String: PHImageRequestID] = [:]
    private var done: Set<String> = []

    func recenter(items: [DeckItem], currentIndex: Int) {
        lastItems = items
        lastIndex = currentIndex
        #if DEBUG
        if ThumbnailLoader.simulatedUpdates() != nil { return }
        #endif
        let wanted = Self.window(count: items.count, current: currentIndex).compactMap { i -> PHAsset? in
            guard let asset = items[i].phAsset, asset.mediaType != .video else { return nil }
            return asset
        }
        // Only requests whose asset left the window are cancelled; ones still
        // inside it keep running so fast swiping doesn't thrash.
        let wantedIDs = Set(wanted.map(\.localIdentifier))
        for (id, requestID) in inFlight where !wantedIDs.contains(id) {
            PHImageManager.default().cancelImageRequest(requestID)
            inFlight[id] = nil
        }
        for asset in wanted {
            if inFlight.count >= Self.maxInFlight { break }
            let id = asset.localIdentifier
            if done.contains(id) || inFlight[id] != nil { continue }
            start(asset)
        }
    }

    func cancelAll() {
        for requestID in inFlight.values { PHImageManager.default().cancelImageRequest(requestID) }
        inFlight.removeAll()
    }

    private func start(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        let id = asset.localIdentifier
        let requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: ThumbnailLoader.screenPixelSize, contentMode: .aspectFit, options: options
        ) { [weak self] _, info in
            if (info?[PHImageCancelledKey] as? Bool) == true { return }
            Task { @MainActor [weak self] in
                guard let self, self.inFlight[id] != nil else { return }
                self.inFlight[id] = nil
                self.done.insert(id)
                self.refill()
            }
        }
        inFlight[id] = requestID
    }

    private var lastItems: [DeckItem] = []
    private var lastIndex = 0
    private func refill() { recenter(items: lastItems, currentIndex: lastIndex) }
}
