import XCTest
@testable import Picnic

/// Which photos the offline keeper downloads to reach its target.
final class OfflineKeeperTests: XCTestCase {
    func testTargetIsThreeHundred() {
        XCTAssertEqual(OfflineKeeper.targetCount, 300)
    }

    func testDownloadsFirstMissingUpToTheShortfall() {
        // 2 of 5 available, target 4: two more needed, newest (earliest) missing first.
        let ids = OfflineKeeper.idsToDownload(ordered: ["a", "b", "c", "d", "e"], available: ["b", "d"], target: 4)
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testNothingToDownloadOnceTargetMet() {
        XCTAssertEqual(OfflineKeeper.idsToDownload(ordered: ["a", "b", "c"], available: ["a", "b"], target: 2), [])
    }

    func testFewerPhotosThanTargetDownloadsAllMissing() {
        // Only 3 candidates exist; target 300 is unreachable, so all missing ones are requested.
        XCTAssertEqual(OfflineKeeper.idsToDownload(ordered: ["a", "b", "c"], available: ["b"], target: 300), ["a", "c"])
    }

    func testReadyIDsFollowSameFiltersAsCounts() {
        let ids = OfflineMode.readyIDs(
            months: [(key: "2025-05", ids: ["a", "b"]), (key: "2025-04", ids: ["c"])],
            isMonthSorted: { $0 == "2025-04" }, isUnsorted: { $0 != "b" }, isDownloaded: { _ in true })
        XCTAssertEqual(ids, ["a"])
    }
}
