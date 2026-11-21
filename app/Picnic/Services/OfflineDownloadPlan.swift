import Foundation
import Photos

/// One month's UNSORTED assets, in month order. Built from a MonthBucket by
/// `OfflineDownloadPlan.months(from:isUnsorted:)`; tests construct it directly.
struct PlanMonth: Equatable, Identifiable {
    let year: Int
    let month: Int // 1...12
    let photoIDs: [String]
    let videoIDs: [String]

    var id: String { key }
    var key: String { String(format: "%04d-%02d", year, month) }
}

/// Pure logic behind "Download for offline": which months to pick, what the
/// queue is, how big it is and how fast Oliver sorts. No PhotoKit calls except
/// the thin `months(from:)` adapter.
enum OfflineDownloadPlan {
    struct Item: Hashable {
        let id: String
        let monthKey: String
        let isVideo: Bool
    }

    /// Screen-size derivative estimate per photo. A guess, not a measurement.
    static let screenBytesPerPhoto: Int64 = 700_000
    /// Photos per minute when there is too little history to measure.
    static let defaultPace = 8.0
    /// Fewer sorted records than this in the window and the pace is the default.
    static let minPaceRecords = 50
    /// A gap longer than this between two sorts ends a sorting session.
    static let sessionGap: TimeInterval = 120
    static let paceWindowDays = 30

    static func screenBytes(photoCount: Int) -> Int64 { Int64(photoCount) * screenBytesPerPhoto }

    // MARK: Months

    /// Unsorted photos and videos of `assets` (id, isVideo) in the given order.
    static func month(year: Int, month: Int, assets: [(id: String, isVideo: Bool)], isUnsorted: (String) -> Bool) -> PlanMonth {
        let unsorted = assets.filter { isUnsorted($0.id) }
        return PlanMonth(
            year: year, month: month,
            photoIDs: unsorted.filter { !$0.isVideo }.map(\.id),
            videoIDs: unsorted.filter { $0.isVideo }.map(\.id)
        )
    }

    /// Newest first, like My Life.
    static func months(from buckets: [MonthBucket], isUnsorted: (String) -> Bool) -> [PlanMonth] {
        buckets.sorted { ($0.year, $0.month) > ($1.year, $1.month) }.map { bucket in
            month(year: bucket.year, month: bucket.month,
                  assets: bucket.assets.map { ($0.localIdentifier, $0.mediaType == .video) }, isUnsorted: isUnsorted)
        }
    }

    /// A month's download items: photos in month order, then its videos when on.
    static func items(for month: PlanMonth, includeVideos: Bool) -> [Item] {
        month.photoIDs.map { Item(id: $0, monthKey: month.key, isVideo: false) }
            + (includeVideos ? month.videoIDs.map { Item(id: $0, monthKey: month.key, isVideo: true) } : [])
    }

    /// Months (given newest first) selected newest-first until the cumulative
    /// item count reaches `hours` of sorting at `pace` items per minute.
    static func autoPick(hours: Int, pace: Double, months: [PlanMonth], includeVideos: Bool) -> Set<String> {
        let target = Double(hours) * 60 * pace
        var picked: Set<String> = []
        var total = 0
        for month in months {
            let count = items(for: month, includeVideos: includeVideos).count
            if count == 0 { continue }
            if Double(total) >= target { break }
            picked.insert(month.key)
            total += count
        }
        return picked
    }

    /// The download queue: selected months in the given (newest first) order.
    static func queue(months: [PlanMonth], selected: Set<String>, includeVideos: Bool) -> [Item] {
        months.filter { selected.contains($0.key) }.flatMap { items(for: $0, includeVideos: includeVideos) }
    }

    // MARK: Pace

    /// Items per active minute from sort timestamps. Consecutive sorts within
    /// `sessionGap` of each other count as one session; the idle time between
    /// sessions is not counted. Too few records means the default.
    static func pace(timestamps: [Date]) -> Double {
        guard timestamps.count >= minPaceRecords else { return defaultPace }
        let sorted = timestamps.sorted()
        var intervals = 0
        var activeSeconds: TimeInterval = 0
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            if gap <= sessionGap {
                intervals += 1
                activeSeconds += gap
            }
        }
        guard intervals > 0, activeSeconds > 0 else { return defaultPace }
        return Double(intervals) / (activeSeconds / 60)
    }

    // MARK: Formatting

    /// "1h 40m", "3h", "45m".
    static func formatDuration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// How much sorting time `readyCount` downloaded items cover.
    static func readyMinutes(readyCount: Int, pace: Double) -> Int {
        Int((Double(readyCount) / max(pace, 1)).rounded())
    }

    /// "48 GB", "4.3 GB", "870 MB", "24 MB", "4.5 MB": one decimal only below 10 of a
    /// unit. ByteCountFormatter's .file style printed "45.36 GB free", precision
    /// that a size estimate and a free-space readout don't have.
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000, mb = Double(bytes) / 1_000_000
        if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
        return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
    }
}
