import CryptoKit
import UIKit

/// Card-size (<=2048px) images of the remote album.
///
/// WHY a disk cache of ENCODED bytes and not an NSCache of UIImages: a decoded
/// 2048x1536 bitmap is ~12.6 MB (2048x2048 ~16.8 MB). The prefetch window is
/// 201 cards (DeckPrefetcher.remoteRadius), so decoded images would cost
/// ~2.5-3.4 GB, which jetsam kills.
/// The encoded JPEG is ~0.5 MB, so the whole window is ~100 MB on disk, and a
/// card decodes only when it is shown (tens of ms, off the main thread).
/// Only the last few decoded images stay in memory (`decoded`, 3 entries, so
/// swiping back one card is instant): 3 x ~17 MB worst case.
///
/// The thumbnail cache (`ThumbnailLoader.remoteImage`, 512px) is separate and
/// unchanged; the filmstrip keeps using it.
enum RemoteDisplayCache {
    /// Disk bound. The prefetch window is 2 * DeckPrefetcher.remoteRadius + 1
    /// = 201 cards, so 256 keeps the whole window plus swipe-back history. At
    /// 0.3-0.5 MB per file that is ~80-130 MB (an estimate, not a measurement).
    /// Must stay above the window or trim() evicts files just downloaded.
    static let maxFiles = 256

    private static let decoded: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 3
        return cache
    }()

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-display", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File name from a hash of the whole URL (album + mediaKey; the token
    /// query is part of it, which only means a token rotation re-downloads once).
    private static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".jpg")
    }

    static func isCached(_ url: URL) -> Bool {
        decoded.object(forKey: url as NSURL) != nil || FileManager.default.fileExists(atPath: file(for: url).path)
    }

    /// Ensures the encoded bytes are on disk. Used by the prefetcher: no decode,
    /// so the wide window costs disk, not RAM. Throws on transport/HTTP failure.
    static func prefetch(_ url: URL) async throws {
        _ = try await data(for: url)
    }

    /// Decoded, display-ready image (decoded off the main thread so the swipe
    /// does not hitch on first draw).
    static func image(url: URL) async throws -> UIImage {
        if let hit = decoded.object(forKey: url as NSURL) { return hit }
        let bytes = try await data(for: url)
        let image = try await Task.detached(priority: .userInitiated) { () throws -> UIImage in
            guard let raw = UIImage(data: bytes) else { throw RemoteAlbumError.undecodableImage }
            return raw.preparingForDisplay() ?? raw
        }.value
        decoded.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func data(for url: URL) async throws -> Data {
        let path = file(for: url)
        if let cached = try? Data(contentsOf: path) {
            // Touch so trimming evicts least-recently-USED, not oldest-written.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            return cached
        }
        let bytes: Data
        #if DEBUG
        if url.scheme == RemoteAlbumFixtures.displayScheme {
            bytes = RemoteAlbumFixtures.displayImage(for: url).jpegData(compressionQuality: 0.9)!
        } else {
            bytes = try await download(url)
        }
        #else
        bytes = try await download(url)
        #endif
        try bytes.write(to: path, options: .atomic)
        trim()
        return bytes
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteAlbumError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// Deletes the least-recently-used files beyond `maxFiles`.
    private static func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > maxFiles else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date.distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    #if DEBUG
    /// Test hook: wipes the disk and memory caches.
    static func removeAll() {
        decoded.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }
    #endif
}
