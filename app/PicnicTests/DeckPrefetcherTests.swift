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

    // MARK: remote display-image window

    private func remoteItems(_ count: Int, noDisplay: Set<Int> = [], videos: Set<Int> = []) -> [DeckItem] {
        (0..<count).map { i in
            .remote(RemoteAlbumItem(
                albumId: "a", mediaKey: "k\(i)", captureMs: Int64(i), width: 1, height: 1, decision: nil,
                thumbnailURL: URL(string: "fixture://k\(i)")!,
                kind: videos.contains(i) ? .video : .photo,
                displayURL: noDisplay.contains(i) ? nil : URL(string: "fixturedisplay://k\(i)")!
            ))
        }
    }

    private func keys(_ urls: [URL]) -> [String] { urls.compactMap(\.host) }

    func testRemoteWantedIsTheSame15WindowMinusVideosAndMissingDisplays() {
        let items = remoteItems(100, noDisplay: [52], videos: [49])
        let wanted = keys(DeckPrefetcher.remoteWanted(items: items, currentIndex: 50))
        // forward 51...65 (52 has no display), then back 49...35 (49 is a video)
        XCTAssertEqual(wanted.first, "k51")
        XCTAssertFalse(wanted.contains("k52"), "no display rendition yet: nothing to fetch")
        XCTAssertFalse(wanted.contains("k49"), "videos are not prefetched")
        XCTAssertEqual(wanted.count, 30 - 2)
        XCTAssertEqual(Set(wanted).isSubset(of: Set((35...65).map { "k\($0)" })), true)
        XCTAssertFalse(wanted.contains("k50"), "the current card loads itself")
    }

    /// Recenter must request exactly the window (capped in flight), cancel the
    /// requests that left the window when the deck moves, and cancelAll must
    /// cancel whatever is left.
    @MainActor
    func testRemotePrefetchRequestsWindowAndCancelsOutOfWindow() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _requested: [String] = []
            private var _cancelled: Set<String> = []
            func requested(_ k: String) { lock.lock(); _requested.append(k); lock.unlock() }
            func cancelled(_ k: String) { lock.lock(); _cancelled.insert(k); lock.unlock() }
            var requestedKeys: [String] { lock.lock(); defer { lock.unlock() }; return _requested }
            var cancelledKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return _cancelled }
        }
        let rec = Recorder()
        // Never completes on its own: sleeps until cancelled, so in-flight
        // slots stay occupied and cancellation is observable.
        let prefetcher = DeckPrefetcher(remoteFetch: { url in
            let key = url.host ?? ""
            rec.requested(key)
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { rec.cancelled(key); throw error }
        })
        let items = remoteItems(100)
        prefetcher.recenter(items: items, currentIndex: 50)
        try await Task.sleep(nanoseconds: 200_000_000)
        // Set, not array: the three Tasks are started in window order but may
        // run in any order, so only WHICH keys were picked is deterministic.
        XCTAssertEqual(rec.requestedKeys.count, 3, "capped at remoteMaxInFlight")
        XCTAssertEqual(Set(rec.requestedKeys), ["k51", "k52", "k53"], "forward first")

        // Jump far away: all three are out of the new window and must be cancelled.
        prefetcher.recenter(items: items, currentIndex: 90)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.cancelledKeys, ["k51", "k52", "k53"], "out-of-window downloads must be cancelled")
        XCTAssertTrue(rec.requestedKeys.contains("k91"), "the new window starts at the new current index")

        prefetcher.cancelAll()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rec.cancelledKeys.isSuperset(of: Set(rec.requestedKeys)), "cancelAll cancels everything in flight")
    }
}
