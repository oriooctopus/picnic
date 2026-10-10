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
        var postedTrims: [(mediaKey: String, trim: RemoteTrim)] = []
        var failNextTrim = false
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

        func postTrim(albumId: String, mediaKey: String, trim: RemoteTrim) async throws {
            if failNextTrim {
                failNextTrim = false
                throw Boom()
            }
            postedTrims.append((mediaKey, trim))
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

    func testRemoteSwipeRecordsRemoteResumeKeyAndLocalSwipeOverwritesIt() throws {
        let container = try TestSupport.inMemoryContainer()
        let store = SortStore(context: container.mainContext)
        UserDefaults.standard.removeObject(forKey: SortStore.lastSwipedMonthKeyDefaultsKey)

        store.setState(.skipped, forID: "gphotos:oliver-album:x", monthKey: "remote:oliver-album")
        XCTAssertEqual(store.state(forID: "gphotos:oliver-album:x"), .skipped)
        XCTAssertEqual(store.lastSwipedMonthKey, "remote:oliver-album",
                       "a remote swipe is where a cold launch must resume")

        store.setState(.kept, forID: "local-id", monthKey: "2026-01")
        XCTAssertEqual(store.lastSwipedMonthKey, "2026-01", "the most recent swipe wins, local or remote")
        UserDefaults.standard.removeObject(forKey: SortStore.lastSwipedMonthKeyDefaultsKey)
    }

    func testAutoOpenTargetRoutesRemoteKeyAndKeepsLocalBehavior() {
        let jan = MonthBucket(year: 2026, month: 1, assets: [])
        let mar = MonthBucket(year: 2026, month: 3, assets: [])
        let buckets = [mar, jan]  // newest first, like AppState.monthBuckets

        guard case .remoteAlbum(let albumId)? = AutoOpenTarget.resolve(
            lastSwipedKey: "remote:oliver-album", buckets: buckets) else {
            return XCTFail("a remote: key must resolve to the remote deck")
        }
        XCTAssertEqual(albumId, "oliver-album")
        guard case .remoteAlbum? = AutoOpenTarget.resolve(lastSwipedKey: "remote:oliver-album", buckets: []) else {
            return XCTFail("the remote deck needs no local months")
        }
        guard case .month(let resumed)? = AutoOpenTarget.resolve(lastSwipedKey: "2026-01", buckets: buckets) else {
            return XCTFail("a month key must resolve to that month")
        }
        XCTAssertEqual(resumed.key, "2026-01")
        guard case .month(let latest)? = AutoOpenTarget.resolve(lastSwipedKey: nil, buckets: buckets) else {
            return XCTFail("no history must open the newest month")
        }
        XCTAssertEqual(latest.key, "2026-03")
        guard case .month(let stale)? = AutoOpenTarget.resolve(lastSwipedKey: "1999-01", buckets: buckets) else {
            return XCTFail("an unknown month key must fall back to the newest month")
        }
        XCTAssertEqual(stale.key, "2026-03")
        XCTAssertNil(AutoOpenTarget.resolve(lastSwipedKey: nil, buckets: []))
    }

    func testWireKindAndHasVideoDecodeToVideoURL() throws {
        let json = """
        {"counts":{"total":3,"keep":0,"skip":0,"undecided":3,"downloaded":0},
         "items":[
          {"mediaKey":"p","thumbUrl":"https://x/p","width":1,"height":1,"captureMs":1,"decision":null,"kind":"photo","hasVideo":false},
          {"mediaKey":"v","thumbUrl":"https://x/v","width":1,"height":1,"captureMs":2,"decision":null,"kind":"video","hasVideo":true},
          {"mediaKey":"u","thumbUrl":"https://x/u","width":1,"height":1,"captureMs":3,"decision":null,"kind":"video","hasVideo":false}
         ]}
        """
        let items = try HTTPRemoteAlbumClient.decodeSnapshot(Data(json.utf8), albumId: "a").items
        XCTAssertEqual(items.map(\.kind), [.photo, .video, .video])
        XCTAssertNil(items[0].videoURL, "a photo has no video URL")
        let url = try XCTUnwrap(items[1].videoURL, "a cached video must carry its server URL")
        XCTAssertTrue(url.path.hasSuffix("/album/a/video/v"), "got \(url)")
        XCTAssertTrue(url.absoluteString.contains("token="), "AVPlayer cannot send a header; the token rides the query")
        XCTAssertNil(items[2].videoURL, "an uncached video must have no URL so the deck disables play")
        XCTAssertEqual(items.map { DeckItem.remote($0).hasPlayableVideo }, [false, true, false])
        XCTAssertEqual(items.map { DeckItem.remote($0).isVideo }, [false, true, true])
    }

    func testWireHasDisplayDecodesToDisplayURLAndMissingKeyMeansNone() throws {
        let json = """
        {"counts":{"total":3,"keep":0,"skip":0,"undecided":3,"downloaded":0},
         "items":[
          {"mediaKey":"a","thumbUrl":"https://x/a","width":1,"height":1,"captureMs":1,"decision":null,"kind":"photo","hasVideo":false,"hasDisplay":true},
          {"mediaKey":"b","thumbUrl":"https://x/b","width":1,"height":1,"captureMs":2,"decision":null,"kind":"photo","hasVideo":false,"hasDisplay":false},
          {"mediaKey":"c","thumbUrl":"https://x/c","width":1,"height":1,"captureMs":3,"decision":null,"kind":"video","hasVideo":false}
         ]}
        """
        let items = try HTTPRemoteAlbumClient.decodeSnapshot(Data(json.utf8), albumId: "a").items
        let url = try XCTUnwrap(items[0].displayURL, "a cached display image must carry its server URL")
        XCTAssertTrue(url.path.hasSuffix("/album/a/display/a"), "got \(url)")
        XCTAssertTrue(url.absoluteString.contains("token="))
        XCTAssertNil(items[1].displayURL, "hasDisplay false: the card keeps the thumb")
        XCTAssertNil(items[2].displayURL, "a server that predates the key must decode, with no display URL")
    }

    /// The card behind the deck is promoted to the current card on swipe, so it
    /// must be the sharp display image whenever that is already on disk; the
    /// 600x800 fixture thumb is the stand-in only when it is not.
    func testPeekImageIsDisplayWhenCachedAndThumbWhenNot() async throws {
        RemoteDisplayCache.removeAll()
        let key = "peek-test"
        let item = DeckItem.remote(RemoteAlbumItem(
            albumId: "a", mediaKey: key, captureMs: 0, width: 600, height: 800, decision: nil,
            thumbnailURL: RemoteAlbumFixtures.thumbnailURL(mediaKey: key),
            displayURL: RemoteAlbumFixtures.displayURL(mediaKey: key)
        ))
        let size = CGSize(width: 600, height: 800)
        let beforeImage = await ThumbnailLoader.bestAvailableImage(for: item, targetSize: size)
        let before = try XCTUnwrap(beforeImage)
        XCTAssertEqual(before.size.width * before.scale, 600, "display not on disk yet: the thumb")
        try await RemoteDisplayCache.prefetch(RemoteAlbumFixtures.displayURL(mediaKey: key))
        let afterImage = await ThumbnailLoader.bestAvailableImage(for: item, targetSize: size)
        let after = try XCTUnwrap(afterImage)
        XCTAssertEqual(after.size.width * after.scale, 1800, "display on disk: the card behind must be the sharp one")
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

    // MARK: remote trim

    func testWireTrimDecodesAndNullMeansUntrimmed() throws {
        let json = """
        {"counts":{"total":2,"keep":0,"skip":0,"undecided":2,"downloaded":0},
         "items":[
          {"mediaKey":"a","thumbUrl":"https://x/a","width":1,"height":1,"captureMs":1,"decision":null,"kind":"video","hasVideo":true,"trim":{"startSec":1.5,"endSec":4.25}},
          {"mediaKey":"b","thumbUrl":"https://x/b","width":1,"height":1,"captureMs":2,"decision":null,"kind":"video","hasVideo":true,"trim":null}
         ]}
        """
        let items = try HTTPRemoteAlbumClient.decodeSnapshot(Data(json.utf8), albumId: "a").items
        XCTAssertEqual(items[0].trim, RemoteTrim(startSec: 1.5, endSec: 4.25))
        XCTAssertNil(items[1].trim, "a null trim on the wire is an untrimmed video")
    }

    func testSaveRemoteTrimPostsAndOverlaysThenFailureSurfacesAndKeepsOld() async throws {
        let rig = try await makeRig()
        let item = try XCTUnwrap(rig.viewModel.currentItem)
        XCTAssertNil(rig.viewModel.remoteTrim(for: item))

        let ok = await rig.viewModel.saveRemoteTrim(RemoteTrim(startSec: 1, endSec: 2), on: item)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.client.postedTrims.map(\.mediaKey), ["k1"], "must POST the card's own mediaKey")
        XCTAssertEqual(rig.client.postedTrims.first?.trim, RemoteTrim(startSec: 1, endSec: 2))
        XCTAssertEqual(rig.viewModel.remoteTrim(for: item), RemoteTrim(startSec: 1, endSec: 2),
                       "a saved trim must be what reopening the trim bar shows")

        rig.client.failNextTrim = true
        let failed = await rig.viewModel.saveRemoteTrim(RemoteTrim(startSec: 0, endSec: 3), on: item)
        XCTAssertFalse(failed, "a refused trim must keep the trim bar open")
        XCTAssertNotNil(rig.viewModel.remoteError, "a refused trim must be shown, not swallowed")
        XCTAssertEqual(rig.viewModel.remoteTrim(for: item), RemoteTrim(startSec: 1, endSec: 2),
                       "a failed save must not replace the previously saved trim")
    }
}
