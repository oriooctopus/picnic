import XCTest
@testable import Picnic

final class OfflineDownloadPlanTests: XCTestCase {
    private func month(_ y: Int, _ m: Int, photos: Int, videos: Int = 0) -> PlanMonth {
        PlanMonth(year: y, month: m,
                  photoIDs: (0..<photos).map { "p\(y)-\(m)-\($0)" },
                  videoIDs: (0..<videos).map { "v\(y)-\(m)-\($0)" })
    }

    private var months: [PlanMonth] { [month(2026, 11, photos: 142), month(2026, 10, photos: 310), month(2026, 9, photos: 188)] }

    func testAutoPickStopsOnceTargetReached() {
        // 1h at 5/min = 300: Nov 142 < 300 so Oct is added (452), then stop.
        let picked = OfflineDownloadPlan.autoPick(hours: 1, pace: 5, months: months, includeVideos: false)
        XCTAssertEqual(picked, ["2026-11", "2026-10"])
    }

    func testAutoPickTakesAllWhenTargetExceedsTotal() {
        XCTAssertEqual(OfflineDownloadPlan.autoPick(hours: 1, pace: 8, months: months, includeVideos: false).count, 3)
        XCTAssertEqual(OfflineDownloadPlan.autoPick(hours: 10, pace: 8, months: months, includeVideos: false).count, 3)
    }

    func testAutoPickCountsVideosOnlyWhenOn() {
        let ms = [month(2026, 11, photos: 100, videos: 300), month(2026, 10, photos: 100)]
        XCTAssertEqual(OfflineDownloadPlan.autoPick(hours: 1, pace: 5, months: ms, includeVideos: false).count, 2)
        XCTAssertEqual(OfflineDownloadPlan.autoPick(hours: 1, pace: 5, months: ms, includeVideos: true), ["2026-11"])
    }

    func testQueueOrderIsNewestFirstPhotosBeforeVideosAndOnlySelected() {
        let ms = [month(2026, 11, photos: 2, videos: 1), month(2026, 10, photos: 2), month(2026, 9, photos: 2)]
        let q = OfflineDownloadPlan.queue(months: ms, selected: ["2026-11", "2026-09"], includeVideos: true)
        XCTAssertEqual(q.map(\.id), ["p2026-11-0", "p2026-11-1", "v2026-11-0", "p2026-9-0", "p2026-9-1"])
        let noVideos = OfflineDownloadPlan.queue(months: ms, selected: ["2026-11"], includeVideos: false)
        XCTAssertEqual(noVideos.map(\.id), ["p2026-11-0", "p2026-11-1"])
    }

    func testMonthSkipsSortedAssets() {
        let m = OfflineDownloadPlan.month(
            year: 2026, month: 3,
            assets: [(id: "a", isVideo: false), (id: "b", isVideo: false), (id: "c", isVideo: true)],
            isUnsorted: { $0 != "b" })
        XCTAssertEqual(m.photoIDs, ["a"])
        XCTAssertEqual(m.videoIDs, ["c"])
    }

    func testPaceDefaultsWithTooFewRecords() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let few = (0..<49).map { start.addingTimeInterval(Double($0) * 6) }
        XCTAssertEqual(OfflineDownloadPlan.pace(timestamps: few), OfflineDownloadPlan.defaultPace)
    }

    func testPaceIgnoresIdleGapsBetweenSessions() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = (0..<51).map { start.addingTimeInterval(Double($0) * 6) }
        let second = (0..<51).map { start.addingTimeInterval(3_600 + Double($0) * 6) }
        // One photo per 6 s in each session is 10 per minute; the hour gap must not dilute it.
        XCTAssertEqual(OfflineDownloadPlan.pace(timestamps: first + second), 10.0, accuracy: 0.001)
    }

    func testFormatting() {
        XCTAssertEqual(OfflineDownloadPlan.formatDuration(minutes: 100), "1h 40m")
        XCTAssertEqual(OfflineDownloadPlan.formatDuration(minutes: 60), "1h")
        XCTAssertEqual(OfflineDownloadPlan.formatDuration(minutes: 45), "45m")
        XCTAssertEqual(OfflineDownloadPlan.screenBytes(photoCount: 10), 7_000_000)
        XCTAssertEqual(OfflineDownloadPlan.formatBytes(45_360_000_000), "45 GB")
        XCTAssertEqual(OfflineDownloadPlan.formatBytes(4_310_000_000), "4.3 GB")
        XCTAssertEqual(OfflineDownloadPlan.formatBytes(870_400_000), "870 MB")
        XCTAssertEqual(OfflineDownloadPlan.formatBytes(24_400_000), "24 MB")
        XCTAssertEqual(OfflineDownloadPlan.formatBytes(4_500_000), "4.5 MB")
    }
}
