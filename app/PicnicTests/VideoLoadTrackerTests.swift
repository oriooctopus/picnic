import XCTest
import Photos
import AVFoundation
@testable import Picnic

/// Black-video-card regression: the poster must stay up until the player is
/// ready, a failed load must show a retry hint, and a slow result for card N
/// must never apply to card N+1.
@MainActor
final class VideoLoadTrackerTests: XCTestCase {

    func testLoadingKeepsPosterUntilReady() {
        var t = VideoLoadTracker()
        t.begin("A")
        XCTAssertEqual(t.state, .loading(downloadProgress: nil))
        XCTAssertNil(t.state.overlayText)
        t.playerReady()
        XCTAssertEqual(t.state, .ready)
    }

    func testPosterVisibleEvenWithPlayerAttached() {
        let card = PicnicSwipeCard(frame: CGRect(x: 0, y: 0, width: 200, height: 250))
        card.configure(image: UIImage(), isLivePhoto: false, compareCount: nil, videoPlayer: AVPlayer())
        XCTAssertTrue(card.isPosterVisible, "poster must not be hidden behind the empty player layer")
    }

    func testDownloadProgressOverlayText() {
        var t = VideoLoadTracker()
        t.begin("A")
        t.progress(0.426, for: "A")
        XCTAssertEqual(t.state.overlayText, "Downloading from iCloud 43%")
    }

    func testFailureShowsRetryHint() {
        var t = VideoLoadTracker()
        t.begin("A")
        XCTAssertTrue(t.fail(for: "A"))
        XCTAssertEqual(t.state, .failed)
        XCTAssertEqual(t.state.overlayText, "Couldn't load video, tap to retry")
    }

    func testStaleResultForPreviousCardIsRejected() {
        var t = VideoLoadTracker()
        t.begin("A")
        t.begin("B")
        XCTAssertFalse(t.accepts(itemFor: "A"))
        XCTAssertFalse(t.fail(for: "A"), "stale failure must not mark card B failed")
        XCTAssertEqual(t.state, .loading(downloadProgress: nil))
        t.progress(0.9, for: "A")
        XCTAssertEqual(t.state, .loading(downloadProgress: nil), "stale progress ignored")
        XCTAssertTrue(t.accepts(itemFor: "B"))
    }

    func testControllerRejectsStaleItem() {
        let c = VideoPlaybackController()
        c.beginLoading(assetID: "A")
        c.beginLoading(assetID: "B")
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertFalse(c.loadItem(item, for: "A"))
        XCTAssertNil(c.player.currentItem)
        XCTAssertTrue(c.loadItem(item, for: "B"))
        XCTAssertTrue(c.player.currentItem === item)
    }

    func testControllerFailureLeavesRetryStateAndNoItem() {
        let c = VideoPlaybackController()
        c.beginLoading(assetID: "A")
        c.failLoading(for: "A")
        XCTAssertEqual(c.loadState, .failed)
        XCTAssertNil(c.player.currentItem)
    }

    func testNilItemOrErrorInfoCountsAsFailure() {
        XCTAssertTrue(VideoLoader.didFail(hasItem: false, info: nil))
        XCTAssertTrue(VideoLoader.didFail(hasItem: true, info: [PHImageErrorKey: NSError(domain: "x", code: 1)]))
        XCTAssertTrue(VideoLoader.didFail(hasItem: true, info: [PHImageCancelledKey: true]))
        XCTAssertFalse(VideoLoader.didFail(hasItem: true, info: [PHImageCancelledKey: false]))
        XCTAssertFalse(VideoLoader.didFail(hasItem: true, info: nil))
    }
}
