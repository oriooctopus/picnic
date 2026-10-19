import Photos
import UIKit

/// Forces PhotoKit to download the full screen-size image of nearby iCloud
/// photos before the user swipes to them, so the on-card load in DeckView is
/// served from PhotoKit's local store instead of waiting on the network.
///
/// Results are discarded on purpose: holding even the 15-photo old window of
/// screen-size bitmaps would cost hundreds of MB, and the 150-photo window
/// (`forwardRadius`) would be far worse. The download into PhotoKit's store is
/// the whole point, and offline-only mode relies on it staying there.
/// Same targetSize/contentMode as `ThumbnailLoader.imageUpdates` so the cached
/// derivative is the one the card asks for.
///
/// Remote-album photo cards use a forward-only window (`remoteRadius`) and the same recenter /
/// cancel-out-of-window / refill loop, but the unit of work is "download the
/// server's card-size JPEG into RemoteDisplayCache's disk cache" (encoded
/// bytes, no decode, so the 150-card window (`remoteRadius`) costs ~95 MB of disk, not
/// hundreds of MB of RAM). Remote videos are deliberately not prefetched:
/// one shared player streams the current video only.
@MainActor
final class DeckPrefetcher {
    /// How many UNSORTED cards ahead of the current one are downloaded from
    /// iCloud. 150 is the user's ask ("always 150 available swipes", for
    /// offline-only mode). Affordable because the results are discarded: it is
    /// PhotoKit's on-disk store that grows, not RAM. Counts unsorted items, not
    /// raw deck slots, so sorted photos never eat into the 150.
    static let forwardRadius = 150
    /// Cards behind the current one. Swiping back is rare and the user already
    /// saw those, so this stays small. Was the symmetric radius 15 before.
    static let behindRadius = 15
    /// Raised 2 -> 4 to get through a 150-photo window in reasonable time.
    /// A guess, not a measured iCloud throughput; lower it if the on-card load
    /// of the CURRENT photo starts to stall behind the prefetch queue.
    static let maxInFlight = 4
    /// Remote downloads are small HTTP GETs from the tailnet box, not iCloud
    /// pulls, so a few in parallel is fine. A guess, not a measurement.
    static let remoteMaxInFlight = 4
    /// How many cards AHEAD of the current one remote display images are
    /// predownloaded. Forward only: the user sorts through the album in order,
    /// and cards already passed stay in RemoteDisplayCache (LRU) until evicted,
    /// so swiping back needs no prefetch. Wide because the unit is ~0.6 MB of
    /// encoded JPEG on disk (measured avg 633 KB over the 1604-image album,
    /// never decoded, see RemoteDisplayCache), so 150 is ~95 MB. It must be wide
    /// enough that a quick swipe never outruns it and shows the soft 512px
    /// thumb. A judgement call, not a measurement. RemoteDisplayCache.maxFiles
    /// must stay above remoteRadius with room for history or it evicts what it
    /// just downloaded.
    static let remoteRadius = 150

    /// Downloads one display image into the disk cache. Injectable so a unit
    /// test can observe requests and cancellation without a network.
    typealias RemoteFetch = @Sendable (URL) async throws -> Void

    /// Indices to prefetch around `current`: the next `radius` cards first
    /// (the user is swiping forward), then the previous `behind`, clamped to
    /// the list. `behind` defaults to `radius`; the local window passes
    /// `behindRadius`, the remote window passes 0 (forward only).
    /// `current` may be -1: "before the first item", used when the current card
    /// is sorted and no unsorted item precedes it (see `DeckViewModel.prefetchSource`).
    nonisolated static func window(count: Int, current: Int, radius: Int = DeckPrefetcher.forwardRadius, behind: Int? = nil) -> [Int] {
        guard count > 0, (-1..<count).contains(current) else { return [] }
        let forward = Array(stride(from: 1, through: radius, by: 1))
        let back = Array(stride(from: 1, through: behind ?? radius, by: 1))
        return (forward.map { current + $0 } + back.map { current - $0 }).filter { (0..<count).contains($0) }
    }

    private let remoteFetch: RemoteFetch
    private var remoteInFlight: [URL: Task<Void, Never>] = [:]
    private var remoteDone: Set<URL> = []

    init(remoteFetch: @escaping RemoteFetch = { try await RemoteDisplayCache.prefetch($0) }) {
        self.remoteFetch = remoteFetch
    }

    /// Display URLs to prefetch around `currentIndex`, in `window` order
    /// (forward only). Remote photos that have a display image only: videos
    /// are not prefetched, and an item with no display rendition yet has
    /// nothing to fetch.
    nonisolated static func remoteWanted(items: [DeckItem], currentIndex: Int, radius: Int = DeckPrefetcher.remoteRadius) -> [URL] {
        window(count: items.count, current: currentIndex, radius: radius, behind: 0).compactMap { i in
            guard let remote = items[i].remoteItem, !remote.isVideo else { return nil }
            return remote.displayURL
        }
    }

    private var inFlight: [String: PHImageRequestID] = [:]
    private var done: Set<String> = []

    /// Called whenever a local photo's full-size image is confirmed on the
    /// device by a finished prefetch, so offline-only mode can start showing it.
    var onLocalAvailable: ((String) -> Void)?
    /// Same, for a finished remote display-image download (keyed by item id).
    var onRemoteAvailable: ((String) -> Void)?

    /// `items` is the month's UNSORTED items in month order and `currentIndex`
    /// the current card's position in it (`DeckViewModel.prefetchSource`), NOT
    /// the visible deck: in offline-only mode the visible deck excludes
    /// undownloaded items, which are exactly what must be fetched.
    /// `isAvailable` lets already-downloaded items be skipped.
    func recenter(items: [DeckItem], currentIndex: Int, isAvailable: @escaping (String) -> Bool = { _ in false }) {
        lastItems = items
        lastIndex = currentIndex
        lastIsAvailable = isAvailable
        recenterRemote(items: items, currentIndex: currentIndex)
        #if DEBUG
        // --simulate-partially-downloaded would be undone by real downloads
        // marking simulated-missing items available.
        if ThumbnailLoader.simulatedUpdates() != nil || ThumbnailLoader.simulatePartiallyDownloaded { return }
        #endif
        let wanted = Self.localWanted(items: items, currentIndex: currentIndex, isAvailable: isAvailable)
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

    /// Local photos to download, nearest first: the window over `items`, minus
    /// videos (big iCloud pulls that can't complete offline) and anything
    /// already known to be on the device.
    nonisolated static func localWanted(items: [DeckItem], currentIndex: Int, isAvailable: (String) -> Bool) -> [PHAsset] {
        window(count: items.count, current: currentIndex, behind: behindRadius).compactMap { i in
            guard let asset = items[i].phAsset, asset.mediaType != .video, !isAvailable(asset.localIdentifier) else { return nil }
            return asset
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
        // url -> item id, so a finished download can be reported by id.
        for item in items {
            if let remote = item.remoteItem, let url = remote.displayURL { remoteIDs[url] = item.id }
        }
        for url in wanted {
            if remoteInFlight.count >= Self.remoteMaxInFlight { break }
            if remoteDone.contains(url) || remoteInFlight[url] != nil { continue }
            startRemote(url)
        }
    }

    private var remoteIDs: [URL: String] = [:]

    private func startRemote(_ url: URL) {
        remoteInFlight[url] = Task { [weak self, remoteFetch] in
            // Failure is deliberately swallowed here: see the done-marking below.
            // `succeeded` is the one place the outcome is kept: only a real
            // download may mark the item available offline.
            let succeeded: Bool
            do { try await remoteFetch(url); succeeded = true } catch { succeeded = false }
            // A cancelled task must not touch state: a newer task for the same
            // URL may already own the slot.
            if Task.isCancelled { return }
            guard let self, self.remoteInFlight[url] != nil else { return }
            self.remoteInFlight[url] = nil
            // A failed prefetch is marked done too (no retry loop); the card
            // fetches the same URL itself and surfaces the error if it is real.
            self.remoteDone.insert(url)
            if succeeded, let id = self.remoteIDs[url] { self.onRemoteAvailable?(id) }
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
        ) { [weak self] image, info in
            if (info?[PHImageCancelledKey] as? Bool) == true { return }
            // Same completeness test as LocalAvailability's probe: a failed or
            // degraded result must not unlock the card in offline-only mode.
            let complete = image != nil && (info?[PHImageResultIsDegradedKey] as? Bool) != true
            Task { @MainActor [weak self] in
                guard let self, self.inFlight[id] != nil else { return }
                self.inFlight[id] = nil
                self.done.insert(id)
                if complete { self.onLocalAvailable?(id) }
                self.refill()
            }
        }
        inFlight[id] = requestID
    }

    private var lastItems: [DeckItem] = []
    private var lastIndex = 0
    private var lastIsAvailable: (String) -> Bool = { _ in false }
    private func refill() { recenter(items: lastItems, currentIndex: lastIndex, isAvailable: lastIsAvailable) }
}
