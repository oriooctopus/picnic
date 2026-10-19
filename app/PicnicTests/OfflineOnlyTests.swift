import XCTest
import SwiftData
@testable import Picnic

/// Offline-only mode below the view layer, driven through a REMOTE deck
/// because remote items are constructible in a unit test (PHAssets are not) and
/// go through the exact same `refresh(follow:)` / `LocalAvailability` path.
/// Availability answers are injected with `availability.markAvailable`, the
/// same entry point a finished prefetch uses.
@MainActor
final class OfflineOnlyTests: XCTestCase {
    private final class Client: RemoteAlbumClient {
        let items: [RemoteAlbumItem]
        init(count: Int, decided: Set<Int> = []) {
            items = (0..<count).map { i in
                RemoteAlbumItem(
                    albumId: "a", mediaKey: "k\(i)", captureMs: Int64(i), width: 1, height: 1,
                    decision: decided.contains(i) ? .keep : nil,
                    thumbnailURL: URL(string: "fixture://k\(i)")!,
                    kind: .photo,
                    displayURL: URL(string: "fixturedisplay://k\(i)")!
                )
            }
        }
        func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
            RemoteAlbumSnapshot(
                counts: RemoteAlbumCounts(total: items.count, keep: 0, skip: 0, undecided: items.count, downloaded: 0),
                items: items)
        }
        func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
            RemoteAlbumCounts(total: items.count, keep: 0, skip: 0, undecided: items.count, downloaded: 0)
        }
        func postTrim(albumId: String, mediaKey: String, trim: RemoteTrim) async throws {}
    }

    private func id(_ i: Int) -> String { "gphotos:a:k\(i)" }

    /// offlineOnly and hideSorted persist in UserDefaults and would leak
    /// between tests (and into the app-hosted UI tests' simulator), so both
    /// start and end every test cleared.
    private func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: DeckViewModel.offlineOnlyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: DeckViewModel.hideSortedDefaultsKey)
    }
    override func setUp() { resetDefaults() }
    override func tearDown() { resetDefaults() }

    private var containers: [ModelContainer] = []

    private func makeDeck(count: Int, decided: Set<Int> = []) async throws -> DeckViewModel {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        let client = Client(count: count, decided: decided)
        let viewModel = DeckViewModel(
            remoteAlbum: RemoteAlbumService(albumId: "a", client: client), title: "t", sortStore: store)
        await viewModel.loadRemote()
        containers.append(container)  // SortStore only holds the context; keep the container alive
        return viewModel
    }

    func testOfflineOnlyShowsOnlyConfirmedAvailableItems() async throws {
        let vm = try await makeDeck(count: 6)
        XCTAssertEqual(vm.visibleItems.count, 6)

        vm.offlineOnly = true
        XCTAssertEqual(vm.visibleItems.count, 0, "unprobed items are hidden, never assumed downloaded")

        vm.availability.markAvailable(id(2))
        vm.availability.markAvailable(id(4))
        XCTAssertEqual(vm.visibleItems.map(\.id), [id(2), id(4)])

        vm.offlineOnly = false
        XCTAssertEqual(vm.visibleItems.count, 6, "turning it off restores the full deck")
    }

    func testOfflineOnlyComposesWithHideSorted() async throws {
        let vm = try await makeDeck(count: 4, decided: [1])
        vm.availability.markAvailable(id(0))
        vm.availability.markAvailable(id(1))
        vm.hideSorted = true
        vm.offlineOnly = true
        XCTAssertEqual(vm.visibleItems.map(\.id), [id(0)], "k1 is downloaded but sorted; k2/k3 are unsorted but not downloaded")
    }

    func testDeckStaysOnCurrentCardWhenAvailabilityGrows() async throws {
        let vm = try await makeDeck(count: 6)
        vm.availability.markAvailable(id(3))
        vm.offlineOnly = true
        vm.currentIndex = 0
        XCTAssertEqual(vm.currentItem?.id, id(3))

        // Items appear both before and after the current card.
        vm.availability.markAvailable(id(1))
        vm.availability.markAvailable(id(5))
        XCTAssertEqual(vm.visibleItems.map(\.id), [id(1), id(3), id(5)])
        XCTAssertEqual(vm.currentItem?.id, id(3), "the deck must not jump off the card the user is looking at")
    }

    func testTogglingOnFromAHiddenCardLandsOnNextAvailableAndTogglingOffKeepsIt() async throws {
        let vm = try await makeDeck(count: 6)
        vm.currentIndex = 2
        XCTAssertEqual(vm.currentItem?.id, id(2))
        vm.availability.markAvailable(id(1))
        vm.availability.markAvailable(id(4))

        vm.offlineOnly = true
        XCTAssertEqual(vm.currentItem?.id, id(4), "current card is not downloaded: land on the next one in month order, not the previous")

        vm.offlineOnly = false
        XCTAssertEqual(vm.currentItem?.id, id(4), "toggling off must keep showing the same photo")
    }

    func testEmptiedDeckRecoversNearTheLastCard() async throws {
        let vm = try await makeDeck(count: 6)
        vm.currentIndex = 3
        vm.offlineOnly = true
        XCTAssertNil(vm.currentItem, "nothing confirmed yet")

        // First confirmation is a card AFTER where the user was (k3), then one before.
        vm.availability.markAvailable(id(4))
        XCTAssertEqual(vm.currentItem?.id, id(4),
                       "an empty deck re-anchors at the last card the user was on, not at index 0")
        vm.availability.markAvailable(id(0))
        XCTAssertEqual(vm.currentItem?.id, id(4), "later arrivals before it must not move the deck")
    }

    func testOfflineReadyAheadCountsUnsortedDownloadedAfterCurrent() async throws {
        let vm = try await makeDeck(count: 8, decided: [5])
        for i in [0, 1, 3, 5, 6, 7] { vm.availability.markAvailable(id(i)) }
        vm.currentIndex = 1
        // After k1: k3, k6, k7 are downloaded and unsorted; k5 is downloaded but sorted; k2/k4 not downloaded.
        XCTAssertEqual(vm.offlineReadyAhead, 3)
    }

    func testPrefetchSourceIsUnsortedItemsRegardlessOfOfflineFilter() async throws {
        let vm = try await makeDeck(count: 6, decided: [1, 2])
        vm.offlineOnly = true   // hides everything: the prefetch source must NOT shrink with it
        vm.availability.markAvailable(id(4))
        let source = vm.prefetchSource
        XCTAssertEqual(source.items.map(\.id), [id(0), id(3), id(4), id(5)], "sorted items out, undownloaded items IN")
        XCTAssertEqual(vm.currentItem?.id, id(4))
        XCTAssertEqual(source.anchor, 2, "anchor is the current card's index in the unsorted list")
    }

    func testPrefetchWindowIsNext150UnsortedSkippingSorted() async throws {
        // 400 items, every 10th already sorted.
        let sorted = Set(stride(from: 0, to: 400, by: 10))
        let vm = try await makeDeck(count: 400, decided: sorted)
        let source = vm.prefetchSource
        XCTAssertEqual(source.items.count, 400 - sorted.count)

        let wanted = DeckPrefetcher.remoteWanted(items: source.items, currentIndex: source.anchor)
            .compactMap { $0.host }
        XCTAssertEqual(wanted.count, 150, "the user's ask: always 150 swipes")
        XCTAssertEqual(wanted.first, "k2", "nearest unsorted card after the current k1")
        XCTAssertFalse(wanted.contains("k10"), "sorted items don't take window slots")
        XCTAssertTrue(wanted.compactMap { Int($0.dropFirst()) }.allSatisfy { !sorted.contains($0) })
    }

    func testWindowConstantsAndSortedCurrentCard() {
        XCTAssertEqual(DeckPrefetcher.forwardRadius, 150)
        XCTAssertEqual(DeckPrefetcher.behindRadius, 15)
        let w = DeckPrefetcher.window(count: 1000, current: 500, behind: DeckPrefetcher.behindRadius)
        XCTAssertEqual(w.count, 165)
        XCTAssertEqual(w[149], 650)
        XCTAssertEqual(w.last, 485)
        // -1: "before the first unsorted item" (current card sorted, nothing unsorted behind it).
        XCTAssertEqual(DeckPrefetcher.window(count: 5, current: -1, radius: 2, behind: 2), [0, 1])
        XCTAssertEqual(DeckPrefetcher.window(count: 5, current: 5), [])
    }
}
