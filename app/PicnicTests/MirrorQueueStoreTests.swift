import XCTest
import SwiftData
@testable import Picnic

/// Covers MirrorQueueStore's drain behavior with an injected poster and an
/// in-memory SwiftData store. DeckViewModel.commitDeletions's call to
/// scheduleDrain() is not covered here (it needs PhotoKit).
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

    private func makeStore(poster: GatedPoster) throws -> (MirrorQueueStore, ModelContext) {
        let container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let store = MirrorQueueStore(context: context, post: poster.post)
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
        // A is suspended inside the poster; B must return without posting.
        await store.drainQueue()
        XCTAssertEqual(poster.calls, [job.id])

        poster.release()
        await a.value
        XCTAssertEqual(poster.calls.count, 1)
        XCTAssertEqual(job.status, "sent")
        XCTAssertEqual(store.pendingCount, 0)
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
}
