import XCTest
import SwiftData
@testable import Picnic

/// Poison-job and offline handling for the mirror and outfit queues: 4xx is
/// parked as failed (visible, user-resolved), 5xx backs off, the first
/// transport failure ends the pass, manual/network-restore drains skip backoff.
@MainActor
final class JobFailureHandlingTests: XCTestCase {

    /// Poster that throws the queued errors in order (nil = succeed) and records calls.
    final class ScriptedPoster {
        var script: [Error?] = []
        private(set) var calls: [String] = []
        /// When set, upload() suspends until release().
        var gated = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func release() { let w = waiters; waiters = []; w.forEach { $0.resume() } }
        func post(_ job: MirrorJobRecord) async throws {
            calls.append(job.filename)
            if !script.isEmpty, let e = script.removeFirst() { throw e }
        }
        func upload(_ job: OutfitImportJob) async throws {
            calls.append(job.assetID)
            if gated { await withCheckedContinuation { waiters.append($0) } }
            if !script.isEmpty, let e = script.removeFirst() { throw e }
        }
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var container: ModelContainer!

    private func makeContext() throws -> ModelContext {
        container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func makeMirror(_ poster: ScriptedPoster) throws -> (MirrorQueueStore, ModelContext) {
        let context = try makeContext()
        let store = MirrorQueueStore(context: context, post: poster.post, existingAssetIDs: { _ in [] }, now: { [unowned self] in self.clock })
        return (store, context)
    }

    @discardableResult
    private func addMirrorJob(_ context: ModelContext, _ store: MirrorQueueStore, name: String, age: TimeInterval) -> MirrorJobRecord {
        let job = MirrorJobRecord(
            id: UUID(), filename: name, creationDateISO8601: "2026-01-01T00:00:00Z",
            pixelWidth: 1, pixelHeight: 1, mediaType: "image", isLivePhoto: false, status: "pending"
        )
        job.createdAt = clock.addingTimeInterval(-age)
        context.insert(job)
        try! context.save()
        store.refreshCount()
        return job
    }

    // MARK: Mirror

    func testMirror4xxIsParkedFailedAndNotRedrained() async throws {
        let poster = ScriptedPoster()
        poster.script = [MirrorClientError.badStatus(400)]
        let (store, context) = try makeMirror(poster)
        let job = addMirrorJob(context, store, name: "A", age: 10)

        await store.drainQueue()
        XCTAssertEqual(job.status, "failed", "a 400 will never succeed; it must be parked, not left pending")
        XCTAssertEqual(store.failedCount, 1)
        XCTAssertEqual(store.pendingCount, 0)

        await store.drainQueue(ignoreBackoff: true)
        XCTAssertEqual(poster.calls, ["A"], "a failed job must not be re-posted automatically")
    }

    func testMirror408And429And5xxStayPendingWithBackoff() async throws {
        for code in [408, 429, 503] {
            let poster = ScriptedPoster()
            poster.script = [MirrorClientError.badStatus(code)]
            let (store, context) = try makeMirror(poster)
            let job = addMirrorJob(context, store, name: "A", age: 10)

            await store.drainQueue()
            XCTAssertEqual(job.status, "pending", "HTTP \(code) is retryable")
            XCTAssertEqual(job.nextAttemptAt, clock.addingTimeInterval(JobRetryPolicy.backoff(attempt: 1)), "HTTP \(code) must set backoff")
        }
    }

    func testMirrorBackoffSkipsJobUntilDueOrForced() async throws {
        let poster = ScriptedPoster()
        poster.script = [MirrorClientError.badStatus(503)]
        let (store, context) = try makeMirror(poster)
        addMirrorJob(context, store, name: "A", age: 10)
        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A"])

        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A"], "job in backoff must be skipped by an ordinary drain")

        await store.drainQueue(ignoreBackoff: true)
        XCTAssertEqual(poster.calls, ["A", "A"], "network-restore/Retry drains must ignore backoff")

        // And once the clock passes the backoff, an ordinary drain picks it up again.
        poster.script = [MirrorClientError.badStatus(503)]
        let (store2, context2) = try makeMirror(poster)
        addMirrorJob(context2, store2, name: "B", age: 10)
        await store2.drainQueue()
        let before = poster.calls.count
        clock = clock.addingTimeInterval(JobRetryPolicy.backoff(attempt: 1) + 1)
        await store2.drainQueue()
        XCTAssertEqual(poster.calls.count, before + 1, "job must retry once its backoff has elapsed")
    }

    func testMirrorPassStopsAtFirstTransportFailure() async throws {
        let poster = ScriptedPoster()
        poster.script = [URLError(.notConnectedToInternet)]
        let (store, context) = try makeMirror(poster)
        addMirrorJob(context, store, name: "A", age: 30)
        addMirrorJob(context, store, name: "B", age: 20)
        addMirrorJob(context, store, name: "C", age: 10)

        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A"], "offline: B and C must not each burn a request timeout")
        XCTAssertEqual(store.pendingCount, 3)
    }

    func testMirrorServerErrorDoesNotStopPass() async throws {
        let poster = ScriptedPoster()
        poster.script = [MirrorClientError.badStatus(500)]
        let (store, context) = try makeMirror(poster)
        addMirrorJob(context, store, name: "A", age: 30)
        addMirrorJob(context, store, name: "B", age: 20)

        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A", "B"], "a 5xx on one job says nothing about the next")
    }

    func testMirrorRetryFailedRequeuesAndForcesDrain() async throws {
        let poster = ScriptedPoster()
        poster.script = [MirrorClientError.badStatus(400)]
        let (store, context) = try makeMirror(poster)
        let job = addMirrorJob(context, store, name: "A", age: 10)
        await store.drainQueue()
        XCTAssertEqual(job.status, "failed")

        store.retryFailed()
        XCTAssertEqual(store.failedCount, 0)
        for _ in 0..<200 where job.status != "sent" { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(job.status, "sent", "Retry must re-post the failed job")
        XCTAssertEqual(poster.calls, ["A", "A"])
    }

    func testMirrorDiscardFailedDeletesOnlyFailedJobs() async throws {
        let poster = ScriptedPoster()
        poster.script = [MirrorClientError.badStatus(400)]
        let (store, context) = try makeMirror(poster)
        addMirrorJob(context, store, name: "A", age: 20)
        await store.drainQueue()
        let pending = addMirrorJob(context, store, name: "B", age: 10)
        pending.nextAttemptAt = clock.addingTimeInterval(999)  // keep B out of the drain
        XCTAssertEqual(store.failedCount, 1)

        store.discardFailed()
        XCTAssertEqual(store.failedCount, 0)
        let left = try ModelContext(container).fetch(FetchDescriptor<MirrorJobRecord>())
        XCTAssertEqual(left.map(\.filename), ["B"])
    }

    // MARK: Outfits

    private func makeOutfit(_ poster: ScriptedPoster) throws -> (OutfitLogStore, ModelContext) {
        let context = try makeContext()
        let store = OutfitLogStore(context: context, upload: poster.upload, now: { [unowned self] in self.clock })
        return (store, context)
    }

    @discardableResult
    private func addOutfitJob(_ context: ModelContext, _ store: OutfitLogStore, id: String, age: TimeInterval) -> OutfitImportJob {
        let job = OutfitImportJob(assetID: id, takenAt: "2026-01-01")
        job.createdAt = clock.addingTimeInterval(-age)
        context.insert(job)
        try! context.save()
        return job
    }

    func testOutfit4xxIsParkedFailedAndAssetMissingToo() async throws {
        let poster = ScriptedPoster()
        poster.script = [OutfitClientError.badStatus(422), OutfitClientError.assetMissing("B")]
        let (store, context) = try makeOutfit(poster)
        let a = addOutfitJob(context, store, id: "A", age: 20)
        let b = addOutfitJob(context, store, id: "B", age: 10)

        await store.drainQueue()
        XCTAssertEqual(a.status, "failed")
        XCTAssertEqual(b.status, "failed", "a photo that no longer exists can never upload")
        XCTAssertEqual(store.failedCount, 2)
        XCTAssertEqual(store.pendingUploads, 0)
    }

    func testOutfitPassStopsAtFirstTransportFailure() async throws {
        let poster = ScriptedPoster()
        poster.script = [URLError(.timedOut)]
        let (store, context) = try makeOutfit(poster)
        addOutfitJob(context, store, id: "A", age: 30)
        addOutfitJob(context, store, id: "B", age: 20)

        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A"])
        XCTAssertEqual(store.pendingCount(), 2)
    }

    func testOutfitBackoffSkippedUnlessForced() async throws {
        let poster = ScriptedPoster()
        poster.script = [OutfitClientError.badStatus(500)]
        let (store, context) = try makeOutfit(poster)
        addOutfitJob(context, store, id: "A", age: 10)
        await store.drainQueue()
        await store.drainQueue()
        XCTAssertEqual(poster.calls, ["A"], "job in backoff must be skipped")
        await store.drainQueue(ignoreBackoff: true)
        XCTAssertEqual(poster.calls, ["A", "A"])
    }

    func testOutfitDiscardUnlogsAndRetryRequeues() async throws {
        let poster = ScriptedPoster()
        poster.script = [OutfitClientError.badStatus(400)]
        let (store, _) = try makeOutfit(poster)
        store.log(assetID: "A", takenAt: Date())
        for _ in 0..<200 where store.failedCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(store.failedCount, 1)
        XCTAssertTrue(store.loggedIDs.contains("A"))

        store.discardFailed()
        XCTAssertEqual(store.failedCount, 0)
        XCTAssertFalse(store.loggedIDs.contains("A"), "a discarded outfit must read as not logged")
    }

    func testOutfitRetryFailedReuploads() async throws {
        let poster = ScriptedPoster()
        poster.script = [OutfitClientError.badStatus(400)]
        let (store, _) = try makeOutfit(poster)
        store.log(assetID: "A", takenAt: Date())
        for _ in 0..<200 where store.failedCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        store.retryFailed()
        for _ in 0..<200 where store.pendingUploads != 0 || poster.calls.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(poster.calls, ["A", "A"])
        XCTAssertEqual(store.failedCount, 0)
        XCTAssertEqual(store.pendingUploads, 0)
    }

    func testOutfitConcurrentDrainsUploadOnce() async throws {
        let poster = ScriptedPoster()
        let (store, context) = try makeOutfit(poster)
        poster.gated = true
        addOutfitJob(context, store, id: "A", age: 10)
        let a = Task { await store.drainQueue() }
        for _ in 0..<200 where poster.calls.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let b = Task { await store.drainQueue() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(poster.calls, ["A"], "single-flight: an overlapping drain must not re-upload the in-flight job")
        poster.gated = false
        poster.release()
        await a.value
        await b.value
        XCTAssertEqual(poster.calls, ["A"])
    }
}
