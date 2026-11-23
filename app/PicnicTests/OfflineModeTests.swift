import XCTest
@testable import Picnic

/// The My Life grid's offline-mode filter: which months stay visible and what
/// count each card shows.
final class OfflineModeTests: XCTestCase {
    func testKeepsOnlyMonthsWithUnsortedDownloadedItems() {
        let counts = OfflineMode.readyCounts(
            months: [
                (key: "2025-05", ids: ["a", "b", "c"]), // a, b downloaded; b sorted
                (key: "2025-04", ids: ["d"]),           // nothing downloaded
                (key: "2025-03", ids: ["e", "f"]),      // downloaded but all sorted
                (key: "2025-02", ids: ["g"]),           // downloaded, month marked sorted
            ],
            isMonthSorted: { $0 == "2025-02" },
            isUnsorted: { !["b", "e", "f"].contains($0) },
            isDownloaded: { ["a", "b", "e", "f", "g"].contains($0) }
        )
        XCTAssertEqual(counts, ["2025-05": 1])
    }
}
