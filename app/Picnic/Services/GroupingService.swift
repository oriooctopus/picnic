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
/// display in the reference screenshots). Sizes come from PHAssetResource
/// metadata, which PhotoKit knows without the bytes: this used to call
/// requestImageDataAndOrientation with network access allowed, i.e. downloaded
/// every full-size original of an iCloud-only group just to count its bytes,
/// and never produced a star offline.
enum BestPhotoResolver {
    static func fileSizes(for assets: [PHAsset]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, fileSize(for: $0)) })
    }

    static func fileSize(for asset: PHAsset) -> Int64 {
        // `fileSize` is not a public PHAssetResource property; reading it via
        // KVC is the long-standing way to get it without fetching the data.
        primarySize(of: PHAssetResource.assetResources(for: asset).map {
            (type: $0.type, size: ($0.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
        })
    }

    /// The original's size: the main photo/video resource if the asset has
    /// one, else the largest resource. Edits add `fullSizePhoto` and
    /// adjustment resources that must not outrank the original.
    static func primarySize(of resources: [(type: PHAssetResourceType, size: Int64)]) -> Int64 {
        if let main = resources.first(where: { $0.type == .photo || $0.type == .video }) {
            return main.size
        }
        return resources.map(\.size).max() ?? 0
    }
}
