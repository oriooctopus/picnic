import XCTest
import Photos
@testable import Picnic

final class OfflineSmallItemsTests: XCTestCase {

    // MARK: Request timeout (10s is a guess, see Config.requestTimeout)

    func testRequestTimeoutIsTenSecondsAndAppliedToEveryRequestBuilder() throws {
        XCTAssertEqual(Config.requestTimeout, 10)
        let job = MirrorJobRecord(
            id: UUID(), filename: "A", creationDateISO8601: "2026-01-01T00:00:00Z",
            pixelWidth: 1, pixelHeight: 1, mediaType: "image", isLivePhoto: false, status: "pending"
        )
        XCTAssertEqual(try MirrorClient.request(for: job).timeoutInterval, Config.requestTimeout, "mirror POST")
        XCTAssertEqual(try ReconcileClient.confirmRequest(month: "2026-03", ids: ["g"], phoneDeleted: [1]).timeoutInterval,
                       Config.requestTimeout, "reconcile confirm")
        let outfit = OutfitImportJob(assetID: "A", takenAt: "2026-01-01")
        XCTAssertEqual(OutfitUploader().request(for: outfit, jpeg: Data()).timeoutInterval, Config.requestTimeout, "outfit upload")
    }

    // MARK: Banner

    func testOutfitPendingAloneShowsPendingBanner() {
        let state = MirrorBannerLogic.state(
            pendingCount: 0, outfitPendingCount: 2, lastError: nil,
            serverQueuedCount: nil, oldestQueuedWaitMs: nil
        )
        XCTAssertEqual(state, .devicePending(count: 0, outfitCount: 2, lastError: nil))
    }

    func testFailedJobsOutrankPending() {
        let state = MirrorBannerLogic.state(
            pendingCount: 3, outfitPendingCount: 1, failedCount: 1, lastError: nil,
            serverQueuedCount: nil, oldestQueuedWaitMs: nil
        )
        XCTAssertEqual(state, .failedJobs(count: 1))
    }

    func testPendingTextCombinesMirrorAndOutfitCounts() {
        XCTAssertEqual(MirrorSyncBannerContent.pendingText(count: 2, outfitCount: 0), "2 not yet mirrored")
        XCTAssertEqual(MirrorSyncBannerContent.pendingText(count: 0, outfitCount: 1), "1 outfit not yet uploaded")
        XCTAssertEqual(MirrorSyncBannerContent.pendingText(count: 2, outfitCount: 3), "2 not yet mirrored · 3 outfits not yet uploaded")
    }

    // MARK: Reconcile error sentences

    func testReconcileErrorsMapToPlainSentences() {
        XCTAssertEqual(ReconcileErrorMessage.plain(URLError(.notConnectedToInternet)),
                       "Can't reach the Picnic server. Check that this phone is online and on Tailscale.")
        XCTAssertEqual(ReconcileErrorMessage.plain(MirrorClientError.badStatus(403)),
                       "The Picnic server refused this app's access token.")
        XCTAssertEqual(ReconcileErrorMessage.plain(MirrorClientError.badStatus(502)),
                       "The Picnic server hit an error (HTTP 502); try again in a minute.")
        XCTAssertEqual(ReconcileErrorMessage.plain(MirrorClientError.badStatus(409)),
                       "The Picnic server refused the request (HTTP 409).")
        XCTAssertEqual(ReconcileErrorMessage.plain(NSError(domain: "PHPhotosErrorDomain", code: 3072)),
                       "The phone deletion was cancelled.")
        let raw = NSError(domain: "NSCocoaErrorDomain", code: 4)
        let msg = ReconcileErrorMessage.plain(raw)
        XCTAssertFalse(msg.contains("Domain"), "raw error text must never reach the screen: \(msg)")
    }

    // MARK: Compare BEST star uses resource metadata only

    func testPrimarySizePrefersOriginalOverEditedResources() {
        let size = BestPhotoResolver.primarySize(of: [
            (type: .fullSizePhoto, size: 9_000_000),
            (type: .photo, size: 3_000_000),
            (type: .adjustmentData, size: 100),
        ])
        XCTAssertEqual(size, 3_000_000)
    }

    func testPrimarySizeFallsBackToLargestAndZeroWhenEmpty() {
        XCTAssertEqual(BestPhotoResolver.primarySize(of: [(type: .alternatePhoto, size: 5), (type: .adjustmentData, size: 9)]), 9)
        XCTAssertEqual(BestPhotoResolver.primarySize(of: []), 0)
    }

    // MARK: Deck card policy

    typealias Q = DeckCardImagePolicy.Quality

    func testQualityFoldsPhotoKitCallbacks() {
        XCTAssertEqual(DeckCardImagePolicy.next(after: .loading, hasImage: true, isDegraded: true), .partial)
        XCTAssertEqual(DeckCardImagePolicy.next(after: .partial, hasImage: true, isDegraded: false), .full)
        XCTAssertEqual(DeckCardImagePolicy.next(after: .loading, hasImage: false, isDegraded: false), .none, "final result with no image")
        XCTAssertEqual(DeckCardImagePolicy.next(after: .partial, hasImage: false, isDegraded: false), .partial, "failed upgrade keeps the low-res on screen")
        XCTAssertEqual(DeckCardImagePolicy.next(after: .loading, hasImage: false, isDegraded: true), .loading, "degraded nil is not final")
    }

    func testICloudBadgeOnlyWhileLowResOfCloudPhoto() {
        XCTAssertTrue(DeckCardImagePolicy.showsICloudBadge(quality: .partial, isInCloud: true))
        XCTAssertFalse(DeckCardImagePolicy.showsICloudBadge(quality: .full, isInCloud: true))
        XCTAssertFalse(DeckCardImagePolicy.showsICloudBadge(quality: .partial, isInCloud: false))
        XCTAssertFalse(DeckCardImagePolicy.showsICloudBadge(quality: .none, isInCloud: true))
    }

    func testDeleteBlockedOnlyWhenNoImageAtAll() {
        XCTAssertTrue(DeckCardImagePolicy.blockDeleteWithoutLocalImage, "the documented default")
        XCTAssertTrue(DeckCardImagePolicy.deleteBlocked(quality: .none))
        for q in [Q.loading, .partial, .full] {
            XCTAssertFalse(DeckCardImagePolicy.deleteBlocked(quality: q), "\(q) must still allow delete")
        }
    }
}
