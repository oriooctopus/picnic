import XCTest
import SwiftData
@testable import Picnic

/// The remote-album deck's safety contract below the view layer. The one
/// property that must never regress: a LEFT swipe in the remote deck is a
/// "skip" decision POSTed to the server, and nothing else. In the local deck
/// the same gesture marks a photo for deletion (and arms a mirror job), so a
/// shared code path that leaked remote left-swipes into it would delete data
/// the user only meant to skip. Each assertion message names what it guards.
@MainActor
final class RemoteAlbumDeckTests: XCTestCase {
    /// Records every call so a test can assert exactly what reached the
    /// "server", and can be told to fail the next POST.
    final class FakeClient: RemoteAlbumClient {
        var posted: [(mediaKey: String, decision: RemoteDecision)] = []
        var failNextPost = false
        let albumId = RemoteAlbumService.oliverAlbumId

        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

        private func item(_ i: Int, decision: RemoteDecision? = nil) -> RemoteAlbumItem {
            RemoteAlbumItem(
                albumId: albumId, mediaKey: "k\(i)", captureMs: Int64(i) * 1000,
                width: 1, height: 1, decision: decision,
                thumbnailURL: URL(string: "fixture://k\(i)")!
            )
        }

        func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
            // k0 is already kept on the "server": the deck must open on k1.
            let items = [item(0, decision: .keep), item(1), item(2), item(3)]
            return RemoteAlbumSnapshot(
                counts: RemoteAlbumCounts(total: 4, keep: 1, skip: 0, undecided: 3, downloaded: 0),
                items: items
            )
        }

        func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
            if failNextPost {
                failNextPost = false
                throw Boom()
            }
            posted.append((mediaKey, decision))
            return RemoteAlbumCounts(total: 4, keep: 1, skip: posted.count, undecided: 3 - posted.count, downloaded: 0)
        }
    }

    private struct Rig {
        let container: ModelContainer
        let store: SortStore
        let client: FakeClient
        let viewModel: DeckViewModel
    }

    private func makeRig() async throws -> Rig {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        let client = FakeClient()
        let viewModel = DeckViewModel(
            remoteAlbum: RemoteAlbumService(albumId: client.albumId, client: client),
            title: "Oliver! album",
            sortStore: store
        )
        await viewModel.loadRemote()
        return Rig(container: container, store: store, client: client, viewModel: viewModel)
    }

    func testLoadSeedsStoreFromServerAndOpensOnFirstUndecided() async throws {
        let rig = try await makeRig()
        XCTAssertNil(rig.viewModel.remoteError, "load failed: \(rig.viewModel.remoteError ?? "")")
        XCTAssertEqual(rig.viewModel.remoteCounts?.keep, 1, "counter must come from the server's counts")
        XCTAssertEqual(rig.store.state(forID: "gphotos:oliver-album:k0"), .kept, "server decision must seed the cache")
        XCTAssertEqual(rig.viewModel.currentItem?.id, "gphotos:oliver-album:k1",
                       "a resumed triage must open on the first undecided item, not item 0")
    }

    func testLeftSwipeSkipsOnServerAndNeverDeletesOrQueuesMirror() async throws {
        let rig = try await makeRig()
        let swiped = try XCTUnwrap(rig.viewModel.currentItem)

        rig.viewModel.markForDelete()  // what a LEFT swipe calls

        XCTAssertEqual(rig.store.state(forID: swiped.id), .skipped,
                       "remote left swipe must be .skipped, not .markedForDelete")
        XCTAssertTrue(rig.viewModel.pendingDeleteIDs.isEmpty,
                      "a remote skip must never show up as a pending PhotoKit delete")
        XCTAssertTrue(rig.viewModel.undoStack.isEmpty, "remote decisions are server-owned; no local undo entry")
        XCTAssertTrue(rig.viewModel.isRemote, "sanity: this is a remote deck")

        await eventually("skip POSTed to the server") { !rig.client.posted.isEmpty }
        XCTAssertEqual(rig.client.posted.first?.mediaKey, "k1")
        XCTAssertEqual(rig.client.posted.first?.decision, .skip)

        // Commit is the only path that reaches PhotoKit / the mirror queue; for
        // a remote deck it must be a no-op even right after a skip.
        await rig.viewModel.commitDeletions()
        XCTAssertNil(rig.viewModel.commitError, "commit on a remote deck must be a silent no-op")
        let mirrorJobs = try rig.container.mainContext.fetch(FetchDescriptor<MirrorJobRecord>())
        XCTAssertTrue(mirrorJobs.isEmpty, "a remote left swipe must never enqueue a mirror job")
    }

    func testRightSwipeKeepsOnServer() async throws {
        let rig = try await makeRig()
        let swiped = try XCTUnwrap(rig.viewModel.currentItem)

        rig.viewModel.markKept()

        XCTAssertEqual(rig.store.state(forID: swiped.id), .kept)
        await eventually("keep POSTed to the server") { !rig.client.posted.isEmpty }
        XCTAssertEqual(rig.client.posted.first?.decision, .keep)
        XCTAssertEqual(rig.viewModel.remoteCounts?.skip, 1, "counts must be replaced by the server's response")
    }

    func testFailedPostRevertsDecisionAndSurfacesError() async throws {
        let rig = try await makeRig()
        let swiped = try XCTUnwrap(rig.viewModel.currentItem)
        rig.client.failNextPost = true

        rig.viewModel.markKept()

        await eventually("error surfaced") { rig.viewModel.remoteError != nil }
        XCTAssertEqual(rig.store.state(forID: swiped.id), .unsorted,
                       "a decision the server never accepted must not stay in the cache (server is source of truth)")
        XCTAssertEqual(rig.viewModel.currentItem?.id, swiped.id, "deck must return to the card whose save failed")
    }

    func testMarkSortedTillHereIsDisabledForRemote() async throws {
        let rig = try await makeRig()
        rig.viewModel.currentIndex = 2
        XCTAssertEqual(rig.viewModel.markSortedUpToCurrent(), 0,
                       "mass-keep would queue a download for every earlier item")
        XCTAssertTrue(rig.client.posted.isEmpty)
    }

    func testRemoteIdsRoundTripThroughStoreAndKeepLastSwipedMonthUntouched() throws {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        UserDefaults.standard.removeObject(forKey: SortStore.lastSwipedMonthKeyDefaultsKey)

        store.setState(.skipped, forID: "gphotos:oliver-album:x", monthKey: "remote:oliver-album")
        XCTAssertEqual(store.state(forID: "gphotos:oliver-album:x"), .skipped)
        XCTAssertNil(store.lastSwipedMonthKey,
                     "a remote swipe must not become MyLife's 'resume where you left off' month")

        store.setState(.kept, forID: "local-id", monthKey: "2026-01")
        XCTAssertEqual(store.lastSwipedMonthKey, "2026-01", "local swipes must still record their month")
    }

    func testDeckItemIdsAndGateAccessors() {
        let remote = DeckItem.remote(RemoteAlbumItem(
            albumId: "a", mediaKey: "m", captureMs: 0, width: 1, height: 1, decision: nil,
            thumbnailURL: URL(string: "fixture://m")!
        ))
        XCTAssertEqual(remote.id, "gphotos:a:m")
        XCTAssertTrue(remote.isRemote)
        XCTAssertNil(remote.phAsset, "remote items must never expose a PHAsset (that is the PhotoKit gate)")
    }
}
