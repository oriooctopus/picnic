import XCTest
import UIKit
import Photos
@testable import Picnic

/// The deck's delete gate end to end below the view layer: PhotoKit callbacks
/// fold into DeckCardImageState (which DeckView hands to the card), the card
/// refuses a delete swipe and explains why. Each assertion message names the
/// regression it guards.
@MainActor
final class DeckGateWiringTests: XCTestCase {
    private func update(image: Bool, degraded: Bool, inCloud: Bool) -> DeckImageUpdate {
        DeckImageUpdate(image: image ? UIImage() : nil, isDegraded: degraded, isInCloud: inCloud)
    }

    // MARK: DeckCardImageState (what DeckView passes to the card)

    func testNoPixelsFromAnICloudPhotoBlocksDeleteWithoutBadge() {
        var s = DeckCardImageState()
        s.begin(prefetched: false)
        XCTAssertFalse(s.deleteBlocked, "a card still loading must not be locked")
        s.apply(update(image: false, degraded: false, inCloud: true))
        XCTAssertTrue(s.deleteBlocked, "final result with no pixels must block the delete swipe")
        XCTAssertFalse(s.showsICloudBadge, "the badge is only for a card showing a low-res stand-in")
    }

    func testLowResThenFailedDownloadKeepsPartialQualityBadgeAndAllowsDelete() {
        var s = DeckCardImageState()
        s.begin(prefetched: false)
        s.apply(update(image: true, degraded: true, inCloud: true))
        XCTAssertTrue(s.showsICloudBadge, "low-res stand-in of an iCloud photo must show the badge")
        // iCloud download fails: PhotoKit's final callback has no image.
        s.apply(update(image: false, degraded: false, inCloud: true))
        XCTAssertEqual(s.quality, .partial, "a failed download after a low-res image must keep .partial (the fold)")
        XCTAssertFalse(s.deleteBlocked, "the user can see the low-res photo, so delete stays allowed")
        XCTAssertTrue(s.showsICloudBadge, "badge stays while the low-res stand-in is what is shown")
    }

    func testFullImageClearsBadgeAndPrefetchedCardStartsPartial() {
        var s = DeckCardImageState()
        s.begin(prefetched: true)
        XCTAssertEqual(s.quality, .partial, "a prefetched stand-in is pixels on screen")
        s.apply(update(image: true, degraded: false, inCloud: false))
        XCTAssertEqual(s.quality, .full)
        XCTAssertFalse(s.showsICloudBadge)
        XCTAssertFalse(s.deleteBlocked)
    }

    func testVideoCardIsNeverDeleteBlocked() {
        var s = DeckCardImageState()
        s.begin(prefetched: false)
        s.markVideo()
        XCTAssertFalse(s.deleteBlocked)
    }

    func testBeginResetsPreviousCardsState() {
        var s = DeckCardImageState()
        s.apply(update(image: false, degraded: false, inCloud: true))
        XCTAssertTrue(s.deleteBlocked)
        s.begin(prefetched: false)
        XCTAssertFalse(s.deleteBlocked, "the next card must not inherit the previous card's block")
        XCTAssertFalse(s.showsICloudBadge)
    }

    // MARK: The card

    private func card(deleteBlocked: Bool, badge: Bool = false) -> PicnicSwipeCard {
        let card = PicnicSwipeCard(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        card.configure(
            image: nil, isLivePhoto: false, compareCount: nil, videoPlayer: nil,
            showsICloudBadge: badge, deleteBlocked: deleteBlocked
        )
        return card
    }

    func testBlockedCardDoesNotAllowLeftSwipeButKeepsKeep() {
        XCTAssertFalse(card(deleteBlocked: true).allowsDeleteSwipe, "a delete-blocked card must not list .left")
        XCTAssertTrue(card(deleteBlocked: false).allowsDeleteSwipe, "an ordinary card must still list .left")
        XCTAssertFalse(PicnicSwipeCard.allowsDeleteSwipe(deleteBlocked: true))
        XCTAssertTrue(PicnicSwipeCard.allowsDeleteSwipe(deleteBlocked: false))
    }

    func testCardShowsBadgeOnlyWhenTold() {
        XCTAssertTrue(card(deleteBlocked: false, badge: true).isICloudBadgeVisible, "showsICloudBadge: true must show the badge")
        XCTAssertFalse(card(deleteBlocked: false, badge: false).isICloudBadgeVisible)
    }

    private func toastCount(blocked: Bool, translation: CGSize, velocity: CGPoint) -> Int {
        let c = card(deleteBlocked: blocked)
        var toasts = 0
        c.onBlockedDelete = { toasts += 1 }
        c.recordDragForTest(translation)
        c.handleCancelledDrag(velocity: velocity)
        return toasts
    }

    func testLongLeftDragOnBlockedCardExplains() {
        XCTAssertEqual(toastCount(blocked: true, translation: CGSize(width: -200, height: 0), velocity: .zero), 1)
    }

    func testShortFastFlickOnBlockedCardExplains() {
        // -60pt is well under the commit threshold but a flick that short commits on a normal card.
        XCTAssertEqual(
            toastCount(blocked: true, translation: CGSize(width: -60, height: 0), velocity: CGPoint(x: -900, y: 0)), 1,
            "a short fast flick on a blocked card must show the toast, not cancel silently"
        )
        XCTAssertEqual(
            toastCount(blocked: true, translation: CGSize(width: -60, height: 0), velocity: .zero), 1,
            "a short slow drag past the attempt travel also counts as an attempt"
        )
    }

    func testNonDeleteGesturesOnBlockedCardStaySilent() {
        XCTAssertEqual(toastCount(blocked: true, translation: CGSize(width: -5, height: 0), velocity: .zero), 0, "a twitch is not an attempt")
        XCTAssertEqual(toastCount(blocked: true, translation: CGSize(width: 80, height: 0), velocity: CGPoint(x: 900, y: 0)), 0, "a rightward drag is keep, not delete")
        XCTAssertEqual(toastCount(blocked: true, translation: CGSize(width: -20, height: -300), velocity: CGPoint(x: 0, y: -900)), 0, "a vertical drag is not a delete attempt")
    }

    func testUnblockedCardNeverShowsTheToast() {
        XCTAssertEqual(toastCount(blocked: false, translation: CGSize(width: -200, height: 0), velocity: CGPoint(x: -900, y: 0)), 0)
    }

    // MARK: Loader options

    func testDeckLoadsOpportunisticallyWithNetworkAccess() {
        let o = ThumbnailLoader.opportunisticOptions()
        XCTAssertEqual(o.deliveryMode, .opportunistic, "highQualityFormat would leave an offline iCloud card blank instead of low-res")
        XCTAssertTrue(o.isNetworkAccessAllowed, "the full image must be able to follow from iCloud")
        XCTAssertEqual(o.resizeMode, .exact)
    }
}
