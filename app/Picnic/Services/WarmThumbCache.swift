import Photos
import UIKit

/// Our own on-disk store of the mid-size thumbnails the deck pre-downloads for
/// the month being sorted. PhotoKit's internal cache can't be inspected or
/// evicted, so "remove them once swiped" is only possible for files we own.
/// Lives in Caches (the OS may reclaim it under storage pressure, which is
/// harmless: a missing file just means the card loads the normal way).
/// Entries are deleted by `purge(assetIDs:)` once the photo has been sorted
/// for longer than `retention`.
enum WarmThumbCache {
    /// Warm-up size: the screen's native pixel width at 3:4, so a portrait
    /// photo's placeholder is as sharp as the card it fills (~1179x1572 on a
    /// 6.1" iPhone). Was 800x1066, about half that, which read as visibly
    /// low-res on every card whose full iCloud image hadn't arrived yet: the
    /// whole month is warmed, but only the next 150 get the full image
    /// (DeckPrefetcher), so the placeholder IS the picture for most of a busy
    /// month. Cost estimate, not measured: ~300-500 KB JPEG each, so ~100 MB
    /// for a 216-photo month, in Caches (OS-reclaimable).
    static var targetSize: CGSize {
        let width = UIScreen.main.nativeBounds.width
        return CGSize(width: width, height: (width * 4 / 3).rounded())
    }
    /// How long a sorted photo's thumbnail is kept, so undo and re-visits stay instant.
    static let retention: TimeInterval = 24 * 60 * 60

    /// "WarmThumbs-v2": placeholders saved before the switch to screen-width
    /// were 800x1066 and `warmCache` skips any photo that already has a file,
    /// so they would never be replaced. A new directory makes every photo
    /// re-warm at the new size; the old "WarmThumbs" directory is deleted here
    /// so its files don't linger (Caches, nothing else reads it).
    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("WarmThumbs", isDirectory: true))
        let dir = caches.appendingPathComponent("WarmThumbs-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// localIdentifiers look like "ABC-123/L0/001"; the slashes can't be in a filename.
    private static func url(for assetID: String) -> URL {
        directory.appendingPathComponent(assetID.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    static func image(for assetID: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: assetID).path)
    }

    static func contains(_ assetID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: assetID).path)
    }

    /// Returns the bytes written (0 if the image failed to encode).
    @discardableResult
    static func store(_ image: UIImage, for assetID: String) -> Int {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return 0 }
        try? data.write(to: url(for: assetID), options: .atomic)
        return data.count
    }

    static func purge(assetIDs: Set<String>) {
        for id in assetIDs { try? FileManager.default.removeItem(at: url(for: id)) }
    }

    /// Total bytes on disk, for the log line that shows the real cost on a phone.
    static func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
