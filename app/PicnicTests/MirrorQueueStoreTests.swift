import XCTest
import SwiftData
@testable import Picnic

/// Covers MirrorQueueStore's drain behavior with an injected poster and an
/// in-memory SwiftData store, plus the armed-before-delete sequence
/// (deleteWithMirror) and launch resolution of armed jobs. DeckViewModel
/// .commitDeletions itself is not covered (it needs PhotoKit assets); it only
/// forwards to deleteWithMirror.
@MainActor
final class MirrorQueueStoreTests: XCTestCase {

    /// Poster that suspends every call until release() is called, and
    /// records how many times each job id was POSTed.
    final class GatedPoster {
        private(set) var calls: [UUID] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var shouldThrow = false

        func post(_ job: MirrorJobRecord) async throws {
            calls.append(job.id)
            if shouldThrow { throw URLError(.timedOut) }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
        }
    }

    /// Asset ids PhotoKit "still has", for resolveArmedJobs.
    private var present: Set<String> = []
    private var container: ModelContainer!

    private func makeStore(poster: GatedPoster) throws -> (MirrorQueueStore, ModelContext) {
        container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let store = MirrorQueueStore(
            context: context, post: poster.post,
            existingAssetIDs: { [unowned self] ids in Set(ids).intersection(self.present) }
        )
        return (store, context)
    }

    private func insertJob(_ context: ModelContext, store: MirrorQueueStore) -> MirrorJobRecord {
        let job = MirrorJobRecord(
            id: UUID(), filename: "IMG_1.JPG", creationDateISO8601: "2026-01-01T00:00:00Z",
            pixelWidth: 10, pixelHeight: 10, mediaType: "image", isLivePhoto: false, status: "pending"
        )
        context.insert(job)
        try! context.save()
        store.refreshCount()
        return job
    }

    private func waitUntil(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if cond() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    func testConcurrentDrainPostsEachJobOnce() async throws {
        let poster = GatedPoster()
        let (store, context) = try makeStore(poster: poster)
        let job = insertJob(context, store: store)

        let a = Task { await store.drainQueue() }
        await waitUntil { poster.calls.count == 1 }
        // A is suspended inside the poster. B runs as its own Task and is
        // given time to reach the poster; without the guard it would post
        // the same pending job and then also suspend (so the assertion fails
        // instead of the test hanging on a never-released B).
        let b = Task { await store.drainQueue() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(poster.calls, [job.id])

        poster.release()
        await a.value
        await b.value
        XCTAssertEqual(poster.calls.count, 1)
        XCTAssertEqual(job.status, "sent")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testJobEnqueuedDuringDrainIsPickedUpByRerun() async throws {
        let poster = GatedPoster()
        let (store, context) = try makeStore(poster: poster)
        let job1 = insertJob(context, store: store)

        let a = Task { await store.drainQueue() }
        await waitUntil { poster.calls.count == 1 }
        let job2 = insertJob(context, store: store)
        await store.drainQueue()  // returns immediately, requests a rerun
        XCTAssertEqual(poster.calls, [job1.id])

        poster.release()
        await waitUntil { poster.calls.count == 2 }
        poster.release()
        await a.value
        XCTAssertEqual(poster.calls, [job1.id, job2.id])
        XCTAssertEqual(job1.status, "sent")
        XCTAssertEqual(job2.status, "sent")
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testFailedPostIsNotRetriedWithoutRerunRequest() async throws {
        let poster = GatedPoster()
        poster.shouldThrow = true
        let (store, context) = try makeStore(poster: poster)
        _ = insertJob(context, store: store)

        await store.drainQueue()
        XCTAssertEqual(poster.calls.count, 1)
    }

    func testScheduleDrainReturnsWhilePosterIsSuspended() async throws {
        let poster = GatedPoster()
        let (store, context) = try makeStore(poster: poster)
        let job = insertJob(context, store: store)

        // Run in a separate Task so a blocking scheduleDrain shows up as a
        // timeout here instead of hanging the whole test run. (`await` on a
        // non-async scheduleDrain is a harmless warning; it is there so the
        // test still compiles if scheduleDrain regresses to async.)
        let returned = expectation(description: "scheduleDrain returned")
        Task { @MainActor in
            await store.scheduleDrain()
            returned.fulfill()
        }
        let outcome = await XCTWaiter.fulfillment(of: [returned], timeout: 3)
        XCTAssertEqual(outcome, .completed, "scheduleDrain blocked on the suspended poster")
        await waitUntil { poster.calls.count == 1 }
        XCTAssertEqual(job.status, "pending")
        XCTAssertEqual(store.pendingCount, 1)

        poster.release()
        await waitUntil { store.pendingCount == 0 }
        XCTAssertEqual(job.status, "sent")
    }

    func testFailedPostLeavesJobPending() async throws {
        let poster = GatedPoster()
        poster.shouldThrow = true
        let (store, context) = try makeStore(poster: poster)
        let job = insertJob(context, store: store)

        await store.drainQueue()
        XCTAssertEqual(job.status, "pending")
        XCTAssertEqual(job.attemptCount, 1)
        XCTAssertNotNil(job.lastError)
        XCTAssertEqual(store.pendingCount, 1)
    }

    // MARK: Armed-before-delete

    private func info(_ id: String) -> MirrorAssetInfo {
        MirrorAssetInfo(localID: id, creationDate: nil, pixelWidth: 10, pixelHeight: 10, isVideo: false, isLivePhoto: false)
    }

    /// Statuses as persisted, read through a fresh context on the same store.
    private func persistedStatuses() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<MirrorJobRecord>()).map(\.status).sorted()
    }

    func testArmedJobIsNotDrained() async throws {
        let poster = GatedPoster()
        poster.shouldThrow = true  // a wrongly-drained job fails fast instead of hanging on the gate
        let (store, _) = try makeStore(poster: poster)
        _ = try store.arm([info("A")], filenames: [:], thumbnails: [:])

        await store.drainQueue()
        XCTAssertTrue(poster.calls.isEmpty, "drain POSTed an armed job")
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(try persistedStatuses(), ["armed"])
    }

    func testJobIsPersistedArmedBeforeDeleteAndPromotedAfter() async throws {
        let poster = GatedPoster()
        let (store, _) = try makeStore(poster: poster)
        var duringDelete: [String] = []

        try await store.deleteWithMirror([info("A")], filenames: ["A": "IMG_A.JPG"], thumbnails: [:]) {
            duringDelete = try self.persistedStatuses()
        }

        XCTAssertEqual(duringDelete, ["armed"], "mirror job must already be persisted when the delete runs")
        XCTAssertEqual(try persistedStatuses(), ["pending"])
        XCTAssertEqual(store.pendingCount, 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<MirrorJobRecord>())
        XCTAssertEqual(rows.first?.filename, "IMG_A.JPG")
        XCTAssertEqual(rows.first?.assetLocalID, "A")
    }

    func testDeclinedDeleteRemovesArmedJob() async throws {
        let poster = GatedPoster()
        let (store, _) = try makeStore(poster: poster)
        var duringDelete: [String] = []

        do {
            try await store.deleteWithMirror([info("A")], filenames: [:], thumbnails: [:]) {
                duringDelete = try self.persistedStatuses()
                throw URLError(.cancelled)
            }
            XCTFail("deleteWithMirror swallowed the delete error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }

        XCTAssertEqual(duringDelete, ["armed"])
        XCTAssertEqual(try persistedStatuses(), [], "declined delete left a mirror job behind")
        XCTAssertEqual(store.pendingCount, 0)
        await store.drainQueue()
        XCTAssertTrue(poster.calls.isEmpty)
    }

    func testLeftoverArmedJobWithAssetGoneBecomesPendingOnLaunch() async throws {
        let poster = GatedPoster()
        let (store, _) = try makeStore(poster: poster)
        _ = try store.arm([info("A")], filenames: [:], thumbnails: [:])
        present = []  // PhotoKit no longer has A: the delete happened, the app died before promote

        store.resolveArmedJobs()

        XCTAssertEqual(try persistedStatuses(), ["pending"])
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testLeftoverArmedJobWithAssetPresentIsRemovedOnLaunch() async throws {
        let poster = GatedPoster()
        let (store, _) = try makeStore(poster: poster)
        _ = try store.arm([info("A")], filenames: [:], thumbnails: [:])
        present = ["A"]  // the user declined (or the delete failed): photo is still on the phone

        store.resolveArmedJobs()

        XCTAssertEqual(try persistedStatuses(), [])
        XCTAssertEqual(store.pendingCount, 0)
    }
}
