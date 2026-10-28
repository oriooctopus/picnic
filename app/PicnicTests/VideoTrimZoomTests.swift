import XCTest
@testable import Picnic

/// Resting on a trim handle zooms the strip to a window around it. These pin
/// the window math; the gesture itself is covered by test51 in
/// WalkthroughUITests (a held drag moves the handle less than a sweep).
final class VideoTrimZoomTests: XCTestCase {
    func testSpanIsAFifthButAtLeastOneSecond() {
        XCTAssertEqual(VideoTrimBar.zoomSpan(duration: 30)!, 6, accuracy: 0.001)
        XCTAssertEqual(VideoTrimBar.zoomSpan(duration: 2)!, 1, accuracy: 0.001)
        XCTAssertNil(VideoTrimBar.zoomSpan(duration: 1), "a 1s clip can't zoom in further")
    }

    func testWindowKeepsAnchorAtSameStripFraction() {
        for anchor in [0.0, 2.5, 7, 10] {
            let w = VideoTrimBar.zoomWindow(anchor: anchor, span: 2, duration: 10)
            XCTAssertEqual(w.upperBound - w.lowerBound, 2, accuracy: 0.001)
            XCTAssertEqual((anchor - w.lowerBound) / 2, anchor / 10, accuracy: 0.001,
                           "handle must stay under the finger as the strip zooms (anchor \(anchor))")
            XCTAssertGreaterThanOrEqual(w.lowerBound, 0)
            XCTAssertLessThanOrEqual(w.upperBound, 10.0001)
        }
    }

    func testPanFollowsHandleAndStaysInClip() {
        let w = 4.0...6.0
        XCTAssertEqual(VideoTrimBar.panned(w, toInclude: 5, duration: 10), w, "inside: no pan")
        XCTAssertEqual(VideoTrimBar.panned(w, toInclude: 7, duration: 10).lowerBound, 5, accuracy: 0.001)
        XCTAssertEqual(VideoTrimBar.panned(w, toInclude: 3, duration: 10).lowerBound, 3, accuracy: 0.001)
        XCTAssertEqual(VideoTrimBar.panned(w, toInclude: 12, duration: 10).upperBound, 10, accuracy: 0.001)
        XCTAssertEqual(VideoTrimBar.panned(w, toInclude: -1, duration: 10).lowerBound, 0, accuracy: 0.001)
    }
}
