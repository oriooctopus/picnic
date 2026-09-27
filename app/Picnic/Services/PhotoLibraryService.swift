import Photos
import Foundation

/// Thin wrapper over PHPhotoLibrary/PHAsset. Holds no persisted state of its
/// own — SortStore owns all sort/streak state, this only talks to PhotoKit.
@MainActor
final class PhotoLibraryService: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
    }

    // MARK: Month buckets

    func fetchMonthBuckets() -> [MonthBucket] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)

        var assetsByKey: [String: [PHAsset]] = [:]
        var yearMonthByKey: [String: (Int, Int)] = [:]
        let calendar = Calendar.current

        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { return }
            let key = String(format: "%04d-%02d", year, month)
            assetsByKey[key, default: []].append(asset)
            yearMonthByKey[key] = (year, month)
        }

        return yearMonthByKey.map { key, ym in
            MonthBucket(year: ym.0, month: ym.1, assets: assetsByKey[key] ?? [])
        }
        .sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    // MARK: Mutations

    /// Triggers PhotoKit's own system confirmation dialog automatically —
    /// this call is the ONLY place in the app that deletes assets, and it is
    /// only ever reached from an explicit user commit action (deck X, or a
    /// confirmed Compare group resolution).
    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func setFavorite(_ asset: PHAsset, isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = isFavorite
        }
    }

    func originalFilename(for asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
    }

    // MARK: Reconcile manifest

    /// Builds the POST /reconcile manifest for one month: one entry per
    /// PHAsset with filename, ISO 8601 creation date, and pixel size.
    ///
    /// WHY no filtering: the bucket's assets already include iCloud-only and
    /// hidden photos — PhotoKit's enumerateObjects returns them and this
    /// method deliberately keeps them. The reconcile server needs to diff the
    /// FULL on-phone set against Google Photos, so dropping any of them would
    /// make a genuinely on-phone photo look like "only in Google".
    ///
    /// WHY the filename caveat below: `originalFilename(for:)` falls back to
    /// the asset's `localIdentifier` when PhotoKit can't find a local
    /// resource (typically an iCloud-only asset with "Optimize iPhone
    /// Storage" on). The server can't match that identifier against Google's
    /// own filename, so such photos may surface as false "only in Google"
    /// candidates. That's reported, not papered over — the manifest still
    /// lists the asset so the on-phone count stays honest.
    func reconcileManifest(for bucket: MonthBucket) -> [ReconcileManifestAsset] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]

        return bucket.assets.map { asset in
            ReconcileManifestAsset(
                filename: originalFilename(for: asset),
                // fetchMonthBuckets only keeps assets with a creationDate, so
                // the `?? Date()` below is unreachable in practice — kept for
                // parity with MirrorQueueStore.enqueue, which formats the same
                // optional API the same way.
                creationDate: formatter.string(from: asset.creationDate ?? Date()),
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            )
        }
    }

    // MARK: Smart collections (Utilities tab)

    func count(for kind: SmartCollectionKind) -> Int {
        PHAsset.fetchAssets(with: fetchOptions(for: kind)).count
    }

    /// A single representative asset for the Utilities tile's cover photo —
    /// most-recent for the date/type-scoped collections, a random pick for
    /// Shuffle (matching its dice glyph). `nil` when the collection is
    /// empty, in which case the tile stays the plain dark placeholder.
    func coverAsset(for kind: SmartCollectionKind) -> PHAsset? {
        if kind == .shuffle {
            let result = PHAsset.fetchAssets(with: fetchOptions(for: kind))
            guard result.count > 0 else { return nil }
            return result.object(at: Int.random(in: 0..<result.count))
        }
        let options = fetchOptions(for: kind)
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject
    }

    func fetchSmartCollection(_ kind: SmartCollectionKind) -> [PHAsset] {
        let result = PHAsset.fetchAssets(with: fetchOptions(for: kind))
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        if kind == .shuffle { assets.shuffle() }
        return assets
    }

    private func fetchOptions(for kind: SmartCollectionKind) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch kind {
        case .today:
            options.predicate = NSPredicate(
                format: "creationDate >= %@", Calendar.current.startOfDay(for: Date()) as NSDate
            )
        case .yesterday:
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let startOfYesterday = Calendar.current.date(byAdding: .day, value: -1, to: startOfToday)!
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                startOfYesterday as NSDate, startOfToday as NSDate
            )
        case .last7Days:
            let start = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        case .shuffle:
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            )
        case .favorites:
            options.predicate = NSPredicate(format: "isFavorite == YES")
        case .screenshots:
            options.predicate = NSPredicate(
                format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue
            )
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .photos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .livePhotos:
            options.predicate = NSPredicate(
                format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue
            )
        }
        return options
    }
}
