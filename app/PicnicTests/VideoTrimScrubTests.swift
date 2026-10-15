import XCTest
@testable import Picnic

/// Tapping the trim strip seeks to the time under the finger, clamped to the
/// kept window. Gesture wiring is covered by test51 in WalkthroughUITests.
final class VideoTrimScrubTests: XCTestCase {
    // 16pt handle gutter, 200pt track, 10s clip: x = 16 + t * 20.
    private func time(_ x: CGFloat, window: ClosedRange<Double> = 0...10) -> Double {
        VideoTrimBar.scrubTime(x: x, handleWidth: 16, track: 200, duration: 10, window: window)
    }

    func testMapsStripPositionToTime() {
        XCTAssertEqual(time(16), 0, accuracy: 0.001)
        XCTAssertEqual(time(116), 5, accuracy: 0.001)
        XCTAssertEqual(time(216), 10, accuracy: 0.001)
    }

    func testClampsToKeptWindow() {
        XCTAssertEqual(time(36, window: 3...7), 3, accuracy: 0.001, "left of the start handle seeks to the start")
        XCTAssertEqual(time(196, window: 3...7), 7, accuracy: 0.001, "right of the end handle seeks to the end")
        XCTAssertEqual(time(116, window: 3...7), 5, accuracy: 0.001)
    }

    func testClampsOutsideTrack() {
        XCTAssertEqual(time(0), 0, accuracy: 0.001)
        XCTAssertEqual(time(300), 10, accuracy: 0.001)
    }
}
