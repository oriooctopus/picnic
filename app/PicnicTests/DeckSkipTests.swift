import XCTest
import SwiftData
@testable import Picnic

/// Skip (offered while a trim is saving) moves on without sorting the card,
/// so it is still in the deck the next time it opens, even with hideSorted.
/// Driven through a remote deck because PHAssets aren't constructible here;
/// `skip()` is the same `advance()` for both kinds.
@MainActor
final class DeckSkipTests: XCTestCase {
    private final class Client: RemoteAlbumClient {
        let items: [RemoteAlbumItem] = (0..<3).map { i in
            RemoteAlbumItem(
                albumId: "a", mediaKey: "k\(i)", captureMs: Int64(i), width: 1, height: 1,
                decision: nil,
                thumbnailURL: URL(string: "fixture://k\(i)")!,
                kind: .photo,
                displayURL: URL(string: "fixturedisplay://k\(i)")!
            )
        }
        func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
            RemoteAlbumSnapshot(
                counts: RemoteAlbumCounts(total: items.count, keep: 0, skip: 0, undecided: items.count, downloaded: 0),
                items: items)
        }
        func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
            XCTFail("skip must not post a decision")
            return RemoteAlbumCounts(total: items.count, keep: 0, skip: 0, undecided: items.count, downloaded: 0)
        }
        func postTrim(albumId: String, mediaKey: String, trim: RemoteTrim) async throws {}
    }

    override func setUp() { UserDefaults.standard.removeObject(forKey: DeckViewModel.hideSortedDefaultsKey) }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: DeckViewModel.hideSortedDefaultsKey) }

    func testSkipAdvancesAndLeavesTheCardUnsorted() async throws {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        let client = Client()
        let vm = DeckViewModel(remoteAlbum: RemoteAlbumService(albumId: "a", client: client), title: "t", sortStore: store)
        await vm.loadRemote()
        vm.hideSorted = true
        let skipped = try XCTUnwrap(vm.currentItem)

        vm.skip()

        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertNotEqual(vm.currentItem?.id, skipped.id)
        XCTAssertEqual(store.state(forID: skipped.id), .unsorted)
        XCTAssertTrue(vm.undoStack.isEmpty, "a skip is not a decision, so there is nothing to undo")

        // Next time the deck opens, the skipped card is still there.
        let reopened = DeckViewModel(remoteAlbum: RemoteAlbumService(albumId: "a", client: client), title: "t", sortStore: store)
        await reopened.loadRemote()
        reopened.hideSorted = true
        XCTAssertEqual(reopened.visibleItems.first?.id, skipped.id)
    }
}
