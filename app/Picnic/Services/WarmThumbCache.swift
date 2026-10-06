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
    /// Warm-up size. ~4x the pixels of the earlier 400x533, chosen as roughly
    /// half the screen's pixels: visibly sharper as a placeholder, still a
    /// small fraction of a 12 MP original.
    static let targetSize = CGSize(width: 800, height: 1066)
    /// How long a sorted photo's thumbnail is kept, so undo and re-visits stay instant.
    static let retention: TimeInterval = 24 * 60 * 60

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WarmThumbs", isDirectory: true)
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
