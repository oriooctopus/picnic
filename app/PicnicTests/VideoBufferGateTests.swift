import XCTest
@testable import Picnic

/// The remote-video start gate: playback may begin only when the loaded
/// ranges CONTIGUOUSLY cover [0, min(duration, 15s)]. Pure function tests;
/// the on-device behavior (spinner, then play) is in WalkthroughUITests.
final class VideoBufferGateTests: XCTestCase {
    private typealias R = VideoBufferGate.Range

    func testLongVideoNeedsFifteenSecondsNotTheWholeClip() {
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: [(0, 14)], duration: 120), "14s of a 120s clip is under the 15s lead-in")
        XCTAssertTrue(VideoBufferGate.isOpen(ranges: [(0, 15)], duration: 120))
        XCTAssertTrue(VideoBufferGate.isOpen(ranges: [(0, 40)], duration: 120), "more than 15s is fine")
    }

    func testShortVideoNeedsTheWholeClip() {
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: [(0, 5)], duration: 8), "5s of an 8s clip is not loaded yet")
        XCTAssertTrue(VideoBufferGate.isOpen(ranges: [(0, 8)], duration: 8))
        XCTAssertTrue(VideoBufferGate.isOpen(ranges: [(0, 7.97)], duration: 8), "float slack at the very end")
    }

    func testHoleBeforeFifteenSecondsKeepsGateClosed() {
        let ranges: [R] = [(0, 6), (9, 20)]
        XCTAssertEqual(VideoBufferGate.contiguousSeconds(from: ranges), 6, accuracy: 0.001)
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: ranges, duration: 120),
                       "a hole at 6-9s would stall right after start; the gate must stay closed")
    }

    func testAdjacentRangesMergeAndOrderDoesNotMatter() {
        let ranges: [R] = [(10, 10), (0, 10.02)]
        XCTAssertEqual(VideoBufferGate.contiguousSeconds(from: ranges), 20, accuracy: 0.001)
        XCTAssertTrue(VideoBufferGate.isOpen(ranges: ranges, duration: 120))
    }

    func testRangeNotStartingAtZeroDoesNotCount() {
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: [(5, 30)], duration: 60), "buffered 5-35s says nothing about 0-5s")
        XCTAssertEqual(VideoBufferGate.contiguousSeconds(from: []), 0)
    }

    func testUnknownDurationNeverOpens() {
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: [(0, 100)], duration: .nan), "duration is NaN until readyToPlay")
        XCTAssertFalse(VideoBufferGate.isOpen(ranges: [(0, 100)], duration: 0))
        XCTAssertEqual(VideoBufferGate.fraction(ranges: [(0, 100)], duration: .nan), 0)
    }

    func testFractionIsProgressTowardTheRequiredLeadInAndClamped() {
        XCTAssertEqual(VideoBufferGate.fraction(ranges: [(0, 7.5)], duration: 120), 0.5, accuracy: 0.001)
        XCTAssertEqual(VideoBufferGate.fraction(ranges: [(0, 4)], duration: 8), 0.5, accuracy: 0.001,
                       "short clip: fraction is of the whole clip")
        XCTAssertEqual(VideoBufferGate.fraction(ranges: [(0, 90)], duration: 120), 1)
    }

    func testTrackerBufferingThenReadyAndLateTicksCannotRevive() {
        var t = VideoLoadTracker()
        t.begin("a")
        t.buffering(0.4)
        XCTAssertEqual(t.state, .buffering(fraction: 0.4))
        t.playerReady()
        XCTAssertEqual(t.state, .ready, "the gate opening is what makes a remote card ready")
        t.buffering(0.9)
        XCTAssertEqual(t.state, .ready, "a late range tick must not pull a ready card back to a spinner")
        t.reset()
        t.buffering(0.5)
        XCTAssertEqual(t.state, .idle, "no load in flight, nothing to buffer")
    }
}
