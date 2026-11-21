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
    /// `manuallySorted` empties the month (see `months(from:)`).
    static func month(year: Int, month: Int, assets: [(id: String, isVideo: Bool)], manuallySorted: Bool = false,
                      isUnsorted: (String) -> Bool) -> PlanMonth {
        let unsorted = manuallySorted ? [] : assets.filter { isUnsorted($0.id) }
        return PlanMonth(
            year: year, month: month,
            photoIDs: unsorted.filter { !$0.isVideo }.map(\.id),
            videoIDs: unsorted.filter { $0.isVideo }.map(\.id)
        )
    }

    /// Newest first, like My Life. A month Oliver marked sorted by hand ("Mark as
    /// sorted" on My Life) contributes nothing even if some of its photos are
    /// still unsorted: My Life shows it as Sorted, so downloading it would spend
    /// flight time on a month he already decided not to sort (seen on the phone:
    /// Aug/Apr/Mar ticked with 30/1/34 photos while My Life said "Sorted").
    static func months(from buckets: [MonthBucket], isMonthSorted: (String) -> Bool, isUnsorted: (String) -> Bool) -> [PlanMonth] {
        buckets.sorted { ($0.year, $0.month) > ($1.year, $1.month) }.map { bucket in
            month(year: bucket.year, month: bucket.month,
                  assets: bucket.assets.map { ($0.localIdentifier, $0.mediaType == .video) },
                  manuallySorted: isMonthSorted(bucket.key), isUnsorted: isUnsorted)
        }
    }

    /// A month's download items: its first `limit` photos in month order (all when
    /// nil), then its videos when on. The limit counts photos only: videos are a
    /// separate switch with their own count, and a "how much of this month" slider
    /// over a mixed list would make the first n ambiguous.
    static func items(for month: PlanMonth, includeVideos: Bool, limit: Int? = nil) -> [Item] {
        let photos = limit.map { Array(month.photoIDs.prefix($0)) } ?? month.photoIDs
        return photos.map { Item(id: $0, monthKey: month.key, isVideo: false) }
            + (includeVideos ? month.videoIDs.map { Item(id: $0, monthKey: month.key, isVideo: true) } : [])
    }

    /// What auto-pick chose: whole months, plus a photo limit on the last one when
    /// taking it whole would overshoot the hour budget.
    struct AutoPick: Equatable {
        var keys: Set<String> = []
        var limits: [String: Int] = [:]
    }

    /// Months (given newest first) selected newest-first until the cumulative
    /// item count reaches `hours` of sorting at `pace` items per minute. The month
    /// that crosses the target is trimmed (first n photos) so the plan lands on the
    /// budget instead of overshooting by up to a whole month.
    static func autoPick(hours: Int, pace: Double, months: [PlanMonth], includeVideos: Bool) -> AutoPick {
        let target = Double(hours) * 60 * pace
        var pick = AutoPick()
        var total = 0
        for month in months {
            let count = items(for: month, includeVideos: includeVideos).count
            if count == 0 { continue }
            if Double(total) >= target { break }
            pick.keys.insert(month.key)
            let remaining = Int((target - Double(total)).rounded(.up))
            if count > remaining {
                // Videos are not limited, so they come out of the budget first. If they
                // alone fill it there is no sensible photo limit; keep the month whole.
                let photoLimit = remaining - (count - month.photoIDs.count)
                if photoLimit >= 1 { pick.limits[month.key] = photoLimit }
            }
            total += count
        }
        return pick
    }

    /// The download queue: selected months in the given (newest first) order,
    /// each cut to its entry in `limits` (absent = whole month).
    static func queue(months: [PlanMonth], selected: Set<String>, limits: [String: Int] = [:], includeVideos: Bool) -> [Item] {
        months.filter { selected.contains($0.key) }
            .flatMap { items(for: $0, includeVideos: includeVideos, limit: limits[$0.key]) }
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

    /// Sorting-time estimate for `count` items: "0m" for none, "<1m" when it rounds
    /// to zero minutes (a lone photo would otherwise read "~0m"), else "~1h 40m".
    static func formatSortTime(count: Int, pace: Double) -> String {
        if count == 0 { return "0m" }
        let minutes = readyMinutes(readyCount: count, pace: pace)
        return minutes < 1 ? "<1m" : "~" + formatDuration(minutes: minutes)
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
