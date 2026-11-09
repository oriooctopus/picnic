import Foundation
import Photos

/// PhotoKit side of SuperappMatcher: per-record creationDate-window fetches.
enum SuperappLibraryMatcher {
    /// Blocking PhotoKit work; call off the main thread.
    static func matchLibrary(records: [SuperappUpload]) -> [SuperappMatch] {
        SuperappMatcher.match(records: records) { date, window in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                date.addingTimeInterval(-window) as NSDate, date.addingTimeInterval(window) as NSDate
            )
            var out: [SuperappAssetDescriptor] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard let created = asset.creationDate else { return }
                out.append(SuperappAssetDescriptor(
                    id: asset.localIdentifier, creationDate: created,
                    width: asset.pixelWidth, height: asset.pixelHeight,
                    filename: { PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "" }
                ))
            }
            return out
        }
    }

    /// Uploaded records still in the library: fetch + match, off the main thread.
    static func loadMatched() async throws -> (uploads: [SuperappUpload], matches: [SuperappMatch]) {
        #if DEBUG
        if SuperappSeed.isEnabled {
            let uploads = SuperappSeed.uploads()
            return (uploads, await Task.detached { matchLibrary(records: uploads) }.value)
        }
        #endif
        let uploads = try await SuperappUploadsClient.fetch()
        return (uploads, await Task.detached { matchLibrary(records: uploads) }.value)
    }
}

#if DEBUG
/// `--superapp-seed`: upload records built from the first seeded library
/// assets (so the real matcher runs), plus two with no library counterpart.
/// Delete and resolve are no-ops in this mode.
enum SuperappSeed {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--superapp-seed") }

    static func uploads() -> [SuperappUpload] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = 8
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out: [SuperappUpload] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard let created = asset.creationDate else { return }
            out.append(SuperappUpload(
                id: "seed-\(out.count)",
                filename: PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "",
                captureDate: formatter.string(from: created), captureDateHasOffset: true,
                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight
            ))
        }
        out.append(SuperappUpload(id: "seed-gone-1", filename: "IMG_0001.HEIC", captureDate: "2001-01-01T00:00:00Z",
                                  captureDateHasOffset: true, pixelWidth: 10, pixelHeight: 10))
        out.append(SuperappUpload(id: "seed-gone-2", filename: "IMG_0002.HEIC", captureDate: nil,
                                  captureDateHasOffset: false, pixelWidth: nil, pixelHeight: nil))
        return out
    }
}
#endif
