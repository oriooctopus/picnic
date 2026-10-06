import XCTest
@testable import Picnic

final class DeckPrefetcherTests: XCTestCase {
    func testMiddleForwardThenBackward() {
        XCTAssertEqual(DeckPrefetcher.window(count: 100, current: 50, radius: 3), [51, 52, 53, 49, 48, 47])
    }
    func testNearStartClampsBackward() {
        XCTAssertEqual(DeckPrefetcher.window(count: 100, current: 1, radius: 3), [2, 3, 4, 0])
    }
    func testNearEndClampsForward() {
        XCTAssertEqual(DeckPrefetcher.window(count: 100, current: 98, radius: 3), [99, 97, 96, 95])
    }
    func testEmptyAndOutOfRange() {
        XCTAssertEqual(DeckPrefetcher.window(count: 0, current: 0), [])
        XCTAssertEqual(DeckPrefetcher.window(count: 5, current: 5), [])
    }
    func testWindowLargerThanList() {
        XCTAssertEqual(DeckPrefetcher.window(count: 4, current: 1), [2, 3, 0])
    }
    func testDefaultRadiusIs15() {
        let w = DeckPrefetcher.window(count: 100, current: 50)
        XCTAssertEqual(w.count, 30)
        XCTAssertEqual(w.first, 51)
        XCTAssertEqual(w[14], 65)
        XCTAssertEqual(w[15], 49)
        XCTAssertEqual(w.last, 35)
    }
}
