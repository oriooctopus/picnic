import XCTest
import SwiftUI
import Photos
@testable import Picnic

/// The whole-library refetch runs synchronously on the main thread, so it must
/// only run on a real return from the background. A system alert (iOS's
/// "Allow Picnic to modify" prompt after a trim save) bounces the scene
/// .active -> .inactive -> .active, and refetching there froze the deck.
final class ForegroundRefetchTests: XCTestCase {
    func testReturnFromBackgroundRefetches() {
        XCTAssertTrue(ForegroundRefetch.shouldRefetch(from: .background, access: .authorized))
        XCTAssertTrue(ForegroundRefetch.shouldRefetch(from: .background, access: .limited))
    }

    func testSystemAlertBounceDoesNotRefetch() {
        XCTAssertFalse(ForegroundRefetch.shouldRefetch(from: .inactive, access: .authorized))
        XCTAssertFalse(ForegroundRefetch.shouldRefetch(from: .inactive, access: .limited))
    }

    func testNoAccessNeverRefetches() {
        XCTAssertFalse(ForegroundRefetch.shouldRefetch(from: .background, access: .notDetermined))
        XCTAssertFalse(ForegroundRefetch.shouldRefetch(from: .background, access: .denied))
    }
}
