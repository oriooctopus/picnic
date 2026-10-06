import UIKit

/// DeckItem-level entry points over ThumbnailLoader, adding the URL source
/// used by remote-album cards. The PHAsset functions in ThumbnailLoader.swift
/// are untouched; local items delegate straight to them, so the local deck's
/// loading behavior is byte-for-byte what it was.
extension ThumbnailLoader {
    /// In-memory only, keyed by URL (the URL embeds the mediaKey, so it is a
    /// stable identity). NOT WarmThumbCache: that is a disk cache keyed by
    /// PHAsset id with its own retention/purge tied to SortStore, and remote
    /// thumbnails are already cached on the server. countLimit is a guess
    /// (~60 portrait thumbnails, a few dozen MB), not a measurement.
    private static let remoteImageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    /// How many upcoming remote cards `warmCache` prefetches. A guess; the
    /// deck only ever shows one card plus a peek, so a short runway is enough.
    static let remoteWarmCount = 8

    /// Loads a remote thumbnail, from the in-memory cache when present.
    /// Throws on transport/HTTP/decode failure — the caller decides how to
    /// surface it (the current card shows an alert; prefetch ignores it).
    static func remoteImage(url: URL) async throws -> UIImage {
        if let cached = remoteImageCache.object(forKey: url as NSURL) { return cached }
        #if DEBUG
        if url.scheme == RemoteAlbumFixtures.thumbnailScheme {
            let image = RemoteAlbumFixtures.image(for: url)
            remoteImageCache.setObject(image, forKey: url as NSURL)
            return image
        }
        #endif
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteAlbumError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let image = UIImage(data: data) else { throw RemoteAlbumError.undecodableImage }
        remoteImageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Best-effort image for the dimmed card behind the deck. A remote
    /// failure yields nil here (the card behind just stays blank) because the
    /// same URL is fetched again, with errors surfaced, when that card
    /// becomes current — alerting twice for one failure would be noise.
    static func bestAvailableImage(for item: DeckItem, targetSize: CGSize) async -> UIImage? {
        switch item {
        case .local(let asset):
            return await bestAvailableImage(for: asset, targetSize: targetSize)
        case .remote(let remote):
            return try? await remoteImage(url: remote.thumbnailURL)
        }
    }

    /// Month warm-up. Local items: the existing PhotoKit/disk warm-up.
    /// Remote items: only the next `remoteWarmCount` cards go into the
    /// in-memory cache — warming all ~1600 would be hundreds of MB of
    /// network for photos the user may never reach.
    static func warmCache(for items: [DeckItem]) async {
        let localAssets = items.compactMap(\.phAsset)
        if !localAssets.isEmpty {
            await warmCache(for: localAssets)
        }
        for item in items.compactMap(\.remoteItem).prefix(remoteWarmCount) {
            if Task.isCancelled { return }
            _ = try? await remoteImage(url: item.thumbnailURL)
        }
    }
}
