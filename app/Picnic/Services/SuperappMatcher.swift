import Foundation

/// One entry of GET /superapp-uploads: a file the Superapp already uploaded
/// to the desktop.
struct SuperappUpload: Decodable, Equatable {
    let id: String
    let filename: String
    /// ISO 8601; the offset is present only when `captureDateHasOffset`.
    let captureDate: String?
    let captureDateHasOffset: Bool
    let pixelWidth: Int?
    let pixelHeight: Int?
}

/// What the matcher needs to know about a library asset. `filename` is lazy
/// because PHAssetResource lookups are slow; the matcher only asks for it
/// when the time window alone does not decide.
struct SuperappAssetDescriptor {
    let id: String
    let creationDate: Date
    let width: Int
    let height: Int
    let filename: () -> String
}

struct SuperappMatch: Equatable {
    let uploadID: String
    let assetID: String
}

/// Pure matching of server upload records to library assets, mirroring
/// server/lib/reconcile.mjs (capture time + dimensions, either orientation)
/// and lib/matcher.mjs filenamesAgree. `candidates(date, window)` returns the
/// assets whose creationDate is within +-window of `date` (PhotoKit: an
/// NSPredicate on creationDate).
enum SuperappMatcher {
    static let offsetWindow: TimeInterval = 2
    static let noOffsetWindow: TimeInterval = 14 * 3600

    static func match(
        records: [SuperappUpload],
        candidates: (Date, TimeInterval) -> [SuperappAssetDescriptor]
    ) -> [SuperappMatch] {
        struct Pair { let upload: Int; let asset: String; let score: Int; let delta: TimeInterval }
        var pairs: [Pair] = []

        for (i, record) in records.enumerated() {
            guard let captureString = record.captureDate,
                  let date = parseDate(captureString, hasOffset: record.captureDateHasOffset) else { continue }
            let window = record.captureDateHasOffset ? offsetWindow : noOffsetWindow
            for asset in candidates(date, window) {
                let delta = abs(asset.creationDate.timeIntervalSince(date))
                guard delta <= window else { continue }
                let dims = dimensionsAgree(record.pixelWidth, record.pixelHeight, asset.width, asset.height)
                let assetName = asset.filename()
                let exact = normalized(record.filename) == normalized(assetName)
                let stem = stem(record.filename) == stem(assetName)
                if record.captureDateHasOffset {
                    guard dims || stem else { continue }
                } else {
                    guard dims && stem else { continue }
                }
                pairs.append(Pair(upload: i, asset: asset.id, score: exact ? 3 : stem ? 2 : 1, delta: delta))
            }
        }

        // Best pairs first, each record and each asset used at most once.
        pairs.sort { ($0.score, -$0.delta) > ($1.score, -$1.delta) }
        var usedUploads = Set<Int>()
        var usedAssets = Set<String>()
        var matches: [SuperappMatch] = []
        for pair in pairs where !usedUploads.contains(pair.upload) && !usedAssets.contains(pair.asset) {
            usedUploads.insert(pair.upload)
            usedAssets.insert(pair.asset)
            matches.append(SuperappMatch(uploadID: records[pair.upload].id, assetID: pair.asset))
        }
        return matches
    }

    static func dimensionsAgree(_ aW: Int?, _ aH: Int?, _ bW: Int?, _ bH: Int?) -> Bool {
        guard let aW, let aH, let bW, let bH else { return false }
        return (aW == bW && aH == bH) || (aW == bH && aH == bW)
    }

    /// Lowercased name without a trailing `_original` marker (before the extension).
    static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"_original(?=\.[^.]+$)"#, with: "", options: .regularExpression)
    }

    /// `normalized` minus the extension, so IMG_1.HEIC and img_1.jpg agree.
    static func stem(_ name: String) -> String {
        normalized(name).replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
    }

    /// Offset strings parse as instants; offset-less ones are read as UTC
    /// wall-clock (the +-14h window absorbs the real zone).
    static func parseDate(_ string: String, hasOffset: Bool) -> Date? {
        if hasOffset {
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let f = ISO8601DateFormatter()
                f.formatOptions = options
                if let d = f.date(from: string) { return d }
            }
            return nil
        }
        for options: ISO8601DateFormatter.Options in [
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            f.timeZone = TimeZone(identifier: "UTC")
            if let d = f.date(from: string) { return d }
        }
        return nil
    }
}
