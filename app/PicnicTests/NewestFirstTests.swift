import XCTest
import SwiftData
@testable import Picnic

/// Newest-first deck order, driven through a REMOTE deck for the same reason as
/// OfflineOnlyTests: remote items are constructible in a unit test (PHAssets are
/// not) and share the `orderedItems` → `refresh(follow:)` path with local decks.
/// Fixture items k0…kN arrive oldest-first, like a MonthBucket.
@MainActor
final class NewestFirstTests: XCTestCase {
    private final class Client: RemoteAlbumClient {
        let items: [RemoteAlbumItem]
        init(count: Int) {
            items = (0..<count).map { i in
                RemoteAlbumItem(
                    albumId: "a", mediaKey: "k\(i)", captureMs: Int64(i), width: 1, height: 1,
                    decision: nil,
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

    /// newestFirst persists in UserDefaults and would leak into later tests
    /// (and the app-hosted UI tests' simulator), so it starts and ends cleared.
    private func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: DeckViewModel.newestFirstDefaultsKey)
        UserDefaults.standard.removeObject(forKey: DeckViewModel.hideSortedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: DeckViewModel.offlineOnlyDefaultsKey)
    }
    override func setUp() { resetDefaults() }
    override func tearDown() { resetDefaults() }

    private var containers: [ModelContainer] = []

    private func makeDeck(count: Int) async throws -> DeckViewModel {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        let viewModel = DeckViewModel(
            remoteAlbum: RemoteAlbumService(albumId: "a", client: Client(count: count)), title: "t", sortStore: store)
        await viewModel.loadRemote()
        containers.append(container)  // SortStore only holds the context; keep the container alive
        return viewModel
    }

    func testTogglingReversesOrderAndKeepsCurrentCard() async throws {
        let vm = try await makeDeck(count: 5)
        XCTAssertEqual(vm.visibleItems.map(\.id), (0..<5).map(id), "default is oldest-first")
        vm.currentIndex = 1

        vm.newestFirst = true
        XCTAssertEqual(vm.visibleItems.map(\.id), (0..<5).reversed().map(id))
        XCTAssertEqual(vm.currentItem?.id, id(1), "toggling must not jump off the photo the user is on")

        vm.newestFirst = false
        XCTAssertEqual(vm.visibleItems.map(\.id), (0..<5).map(id))
        XCTAssertEqual(vm.currentItem?.id, id(1))
    }

    func testPersistedSettingAppliesToNewDeck() async throws {
        UserDefaults.standard.set(true, forKey: DeckViewModel.newestFirstDefaultsKey)
        let vm = try await makeDeck(count: 3)
        XCTAssertEqual(vm.visibleItems.map(\.id), [id(2), id(1), id(0)])
    }

    func testAheadFollowsDeckOrder() async throws {
        let vm = try await makeDeck(count: 5)
        vm.newestFirst = true
        vm.currentIndex = 1  // k3
        for i in 0..<5 { vm.availability.markAvailable(id(i)) }
        // Ahead of k3 when walking newest→oldest is k2, k1, k0.
        XCTAssertEqual(vm.offlineReadyAhead, 3)
    }
}
