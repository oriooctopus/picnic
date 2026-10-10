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
///
/// Remote-album photo cards use a wider window (`remoteRadius`) and the same recenter /
/// cancel-out-of-window / refill loop, but the unit of work is "download the
/// server's card-size JPEG into RemoteDisplayCache's disk cache" (encoded
/// bytes, no decode, so the 201-card window (`remoteRadius`) costs ~60-100 MB of disk, not
/// hundreds of MB of RAM). Remote videos are deliberately not prefetched:
/// one shared player streams the current video only.
@MainActor
final class DeckPrefetcher {
    static let radius = 15
    static let maxInFlight = 2
    /// Remote downloads are small HTTP GETs from the tailnet box, not iCloud
    /// pulls, so a few in parallel is fine. A guess, not a measurement.
    static let remoteMaxInFlight = 4
    /// How far around the current card remote display images are predownloaded.
    /// Much wider than the iCloud `radius` because the unit is ~0.3-0.5 MB of
    /// encoded JPEG on disk (never decoded, see RemoteDisplayCache), so 100
    /// each way is ~60-100 MB. The window must be wide enough that a user
    /// swiping quickly never outruns it and sees the soft 512px thumb. The
    /// number is a judgement call, not a measurement; RemoteDisplayCache.maxFiles
    /// must stay above 2 * remoteRadius + 1 or the cache evicts what it just
    /// downloaded.
    static let remoteRadius = 100

    /// Downloads one display image into the disk cache. Injectable so a unit
    /// test can observe requests and cancellation without a network.
    typealias RemoteFetch = @Sendable (URL) async throws -> Void

    /// Indices to prefetch around `current`: the next `radius` cards first
    /// (the user is swiping forward), then the previous `radius`, clamped to
    /// the list.
    nonisolated static func window(count: Int, current: Int, radius: Int = DeckPrefetcher.radius) -> [Int] {
        guard count > 0, (0..<count).contains(current) else { return [] }
        let steps = Array(stride(from: 1, through: radius, by: 1))
        return (steps.map { current + $0 } + steps.map { current - $0 }).filter { (0..<count).contains($0) }
    }

    private let remoteFetch: RemoteFetch
    private var remoteInFlight: [URL: Task<Void, Never>] = [:]
    private var remoteDone: Set<URL> = []

    init(remoteFetch: @escaping RemoteFetch = { try await RemoteDisplayCache.prefetch($0) }) {
        self.remoteFetch = remoteFetch
    }

    /// Display URLs to prefetch around `currentIndex`, in `window` order
    /// (forward first). Remote photos that have a display image only: videos
    /// are not prefetched, and an item with no display rendition yet has
    /// nothing to fetch.
    nonisolated static func remoteWanted(items: [DeckItem], currentIndex: Int, radius: Int = DeckPrefetcher.remoteRadius) -> [URL] {
        window(count: items.count, current: currentIndex, radius: radius).compactMap { i in
            guard let remote = items[i].remoteItem, !remote.isVideo else { return nil }
            return remote.displayURL
        }
    }

    private var inFlight: [String: PHImageRequestID] = [:]
    private var done: Set<String> = []

    func recenter(items: [DeckItem], currentIndex: Int) {
        lastItems = items
        lastIndex = currentIndex
        recenterRemote(items: items, currentIndex: currentIndex)
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

    /// Remote half of `recenter`: cancel downloads that left the window (ones
    /// still inside keep running so fast swiping doesn't thrash), then start
    /// wanted ones up to the in-flight cap.
    private func recenterRemote(items: [DeckItem], currentIndex: Int) {
        let wanted = Self.remoteWanted(items: items, currentIndex: currentIndex)
        let wantedSet = Set(wanted)
        for (url, task) in remoteInFlight where !wantedSet.contains(url) {
            task.cancel()
            remoteInFlight[url] = nil
        }
        for url in wanted {
            if remoteInFlight.count >= Self.remoteMaxInFlight { break }
            if remoteDone.contains(url) || remoteInFlight[url] != nil { continue }
            startRemote(url)
        }
    }

    private func startRemote(_ url: URL) {
        remoteInFlight[url] = Task { [weak self, remoteFetch] in
            // Failure is deliberately swallowed here: see the done-marking below.
            try? await remoteFetch(url)
            // A cancelled task must not touch state: a newer task for the same
            // URL may already own the slot.
            if Task.isCancelled { return }
            guard let self, self.remoteInFlight[url] != nil else { return }
            self.remoteInFlight[url] = nil
            // A failed prefetch is marked done too (no retry loop); the card
            // fetches the same URL itself and surfaces the error if it is real.
            self.remoteDone.insert(url)
            self.refill()
        }
    }

    func cancelAll() {
        for requestID in inFlight.values { PHImageManager.default().cancelImageRequest(requestID) }
        inFlight.removeAll()
        for task in remoteInFlight.values { task.cancel() }
        remoteInFlight.removeAll()
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
