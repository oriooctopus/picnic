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

    // MARK: Smart collections (Utilities tab)

    func count(for kind: SmartCollectionKind) -> Int {
        PHAsset.fetchAssets(with: fetchOptions(for: kind)).count
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
