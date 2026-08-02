import Foundation
import Photos

/// v1 similarity clustering: capture-time proximity only (no ML embeddings,
/// per SPEC.md's v1 scope cuts). Two consecutive assets fall in the same
/// group when they're on the same calendar day and no more than 10s apart.
enum GroupingService {
    static let maxGapSeconds: TimeInterval = 10

    static func groups(in assets: [PHAsset]) -> [CompareGroup] {
        let sorted = assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        var groups: [[PHAsset]] = []
        var current: [PHAsset] = []
        var lastDate: Date?
        let calendar = Calendar.current

        for asset in sorted {
            guard let date = asset.creationDate else { continue }
            if let last = lastDate,
               calendar.isDate(last, inSameDayAs: date),
               date.timeIntervalSince(last) <= maxGapSeconds {
                current.append(asset)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [asset]
            }
            lastDate = date
        }
        if current.count > 1 { groups.append(current) }

        return groups.map { members in
            CompareGroup(id: members.map(\.localIdentifier).sorted().joined(separator: "|"), assets: members)
        }
    }

    static func group(containing asset: PHAsset, in assets: [PHAsset]) -> CompareGroup? {
        groups(in: assets).first { group in
            group.assets.contains { $0.localIdentifier == asset.localIdentifier }
        }
    }
}

/// BEST heuristic = largest file size in the group (matches the ★ BEST
/// display in the reference screenshots). Sizes are only fetched for the
/// small handful of assets in an open Compare group, never the whole library.
enum BestPhotoResolver {
    static func fileSizes(for assets: [PHAsset]) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64).self) { group in
            for asset in assets {
                group.addTask {
                    (asset.localIdentifier, await fileSize(for: asset))
                }
            }
            for await (id, size) in group {
                sizes[id] = size
            }
        }
        return sizes
    }

    static func fileSize(for asset: PHAsset) async -> Int64 {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: Int64(data?.count ?? 0))
            }
        }
    }
}
