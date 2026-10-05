import XCTest
import SwiftData
@testable import Picnic

/// A 2xx is saved the moment it happens: a kill while the NEXT job is in
/// flight must not forget it and re-send. Read through a fresh ModelContext,
/// the way a relaunch would see the store.
@MainActor
final class JobDurabilityTests: XCTestCase {
    private var container: ModelContainer!

    private func makeContext() throws -> ModelContext {
        container = try TestSupport.inMemoryContainer()
        let context = ModelContext(container)
        // Only explicit saves count; an autosave must not hide a missing one.
        context.autosaveEnabled = false
        return context
    }

    func testMirrorJobIsSavedSentWhileTheNextJobIsStillInFlight() async throws {
        let context = try makeContext()
        let gate = NamedGate(blocking: "B")
        context.insert(TestSupport.mirrorJob("A", age: 20))
        context.insert(TestSupport.mirrorJob("B", age: 10))
        try context.save()
        let store = MirrorQueueStore(context: context, post: { job in await gate.pass(job.filename) }, existingAssetIDs: { _ in [] })

        let drain = Task { await store.drainQueue() }
        await eventually("B never reached the poster") { gate.calls == ["A", "B"] }

        let fresh = ModelContext(container)
        let byName = Dictionary(uniqueKeysWithValues: try fresh.fetch(FetchDescriptor<MirrorJobRecord>()).map { ($0.filename, $0.status) })
        XCTAssertEqual(byName["A"], "sent", "A's 2xx must be saved before B is attempted: a kill now would re-send A")
        XCTAssertEqual(byName["B"], "pending")
        XCTAssertEqual(store.pendingCount, 1, "the published pending count must drop as soon as A is sent")

        gate.release()
        await drain.value
    }

    func testOutfitJobIsSavedSentWhileTheNextJobIsStillInFlight() async throws {
        let context = try makeContext()
        let gate = NamedGate(blocking: "B")
        context.insert(TestSupport.outfitJob("A", age: 20))
        context.insert(TestSupport.outfitJob("B", age: 10))
        try context.save()
        let store = OutfitLogStore(context: context, upload: { job in await gate.pass(job.assetID) })

        let drain = Task { await store.drainQueue() }
        await eventually("B never reached the uploader") { gate.calls == ["A", "B"] }

        let fresh = ModelContext(container)
        let byID = Dictionary(uniqueKeysWithValues: try fresh.fetch(FetchDescriptor<OutfitImportJob>()).map { ($0.assetID, $0.status) })
        XCTAssertEqual(byID["A"], "sent", "A's 2xx must be saved before B is attempted: a kill now would re-upload A")
        XCTAssertEqual(byID["B"], "pending")
        XCTAssertEqual(store.pendingUploads, 1, "the published pending count must drop as soon as A is sent")

        gate.release()
        await drain.value
    }

    func testTransportFailureIsSavedToo() async throws {
        let context = try makeContext()
        context.insert(TestSupport.mirrorJob("A", age: 20))
        try context.save()
        let store = MirrorQueueStore(context: context, post: { _ in throw URLError(.notConnectedToInternet) }, existingAssetIDs: { _ in [] })
        await store.drainQueue()
        let fresh = ModelContext(container)
        let job = try XCTUnwrap(fresh.fetch(FetchDescriptor<MirrorJobRecord>()).first)
        XCTAssertEqual(job.attemptCount, 1, "the failed attempt and its backoff must reach the store before the pass ends")
        XCTAssertNotNil(job.nextAttemptAt)
    }
}
