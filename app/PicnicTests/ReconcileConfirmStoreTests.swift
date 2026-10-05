import XCTest
import SwiftData
@testable import Picnic

/// Covers ReconcileConfirmStore: the Clean up confirm is persisted armed
/// BEFORE the phone delete, so the Google trash request survives a kill or an
/// unreachable server after the phone photos are already gone.
@MainActor
final class ReconcileConfirmStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var present: Set<String> = []
    private var sendCalls = 0
    private var sendError: Error?
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeStore() throws -> ReconcileConfirmStore {
        container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        return ReconcileConfirmStore(
            context: ModelContext(container),
            send: { [unowned self] _ in
                self.sendCalls += 1
                if let e = self.sendError { throw e }
            },
            existingAssetIDs: { [unowned self] ids in Set(ids).intersection(self.present) },
            now: { [unowned self] in self.clock }
        )
    }

    private func persistedStatuses() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<ReconcileConfirmJob>()).map(\.status).sorted()
    }

    private let phone = [(index: 3, assetID: "A")]

    func testJobIsPersistedArmedBeforePhoneDeleteAndPendingAfter() async throws {
        let store = try makeStore()
        var duringDelete: [String] = []
        _ = try await store.submit(month: "2026-03", googleIds: ["g1"], phone: phone) {
            duringDelete = try self.persistedStatuses()
        }
        XCTAssertEqual(duringDelete, ["armed"], "job must already be persisted when the phone delete runs")
        XCTAssertEqual(try persistedStatuses(), ["pending"])
        XCTAssertEqual(sendCalls, 0)
    }

    func testDeclinedPhoneDeleteRemovesJobAndSendsNothing() async throws {
        let store = try makeStore()
        var duringDelete: [String] = []
        do {
            _ = try await store.submit(month: "2026-03", googleIds: ["g1"], phone: phone) {
                duringDelete = try self.persistedStatuses()
                throw URLError(.cancelled)
            }
            XCTFail("submit swallowed the delete error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(duringDelete, ["armed"])
        XCTAssertEqual(try persistedStatuses(), [])
        await store.drain()
        XCTAssertEqual(sendCalls, 0)
    }

    func testUnreachableServerKeepsJobPendingAndDrainRetriesIt() async throws {
        let store = try makeStore()
        let id = try await store.submit(month: "2026-03", googleIds: ["g1"], phone: phone) {}
        sendError = URLError(.notConnectedToInternet)
        do {
            try await store.deliver(id)
            XCTFail("deliver swallowed the send error")
        } catch {}
        XCTAssertEqual(try persistedStatuses(), ["pending"])

        sendError = nil  // server reachable again; next launch/foreground drains
        clock = clock.addingTimeInterval(JobRetryPolicy.backoff(attempt: 1) + 1)  // the 30s backoff the failure set has passed
        await store.drain()
        XCTAssertEqual(try persistedStatuses(), ["sent"])
        XCTAssertEqual(sendCalls, 2)
    }

    func testRejectedJobIsParkedNotRetried() async throws {
        let store = try makeStore()
        let id = try await store.submit(month: "2026-03", googleIds: ["g1"], phone: phone) {}
        sendError = MirrorClientError.badStatus(409)
        try? await store.deliver(id)
        XCTAssertEqual(try persistedStatuses(), ["failed"])
        await store.drain()
        XCTAssertEqual(sendCalls, 1)
    }

    func testLeftoverArmedJobWithPhoneAssetsGoneBecomesPendingOnLaunch() async throws {
        let store = try makeStore()
        // Post-kill state: armed job persisted, phone delete done, never promoted.
        let ctx = ModelContext(container)
        ctx.insert(ReconcileConfirmJob(id: UUID(), month: "2026-03", googleIds: ["g1"],
                                       phoneIndexes: [3], phoneAssetIDs: ["A"], status: "armed"))
        try ctx.save()
        present = []
        store.resolveArmedJobs(authorization: .authorized)
        XCTAssertEqual(try persistedStatuses(), ["pending"])
    }

    func testLeftoverArmedJobWithPhoneAssetPresentIsRemovedOnLaunch() async throws {
        let store = try makeStore()
        let ctx = ModelContext(container)
        ctx.insert(ReconcileConfirmJob(id: UUID(), month: "2026-03", googleIds: ["g1"],
                                       phoneIndexes: [3], phoneAssetIDs: ["A"], status: "armed"))
        try ctx.save()
        present = ["A"]
        store.resolveArmedJobs(authorization: .authorized)
        XCTAssertEqual(try persistedStatuses(), [])
    }

    private func insertArmed(phoneAssetIDs: [String]) throws {
        let ctx = ModelContext(container)
        ctx.insert(ReconcileConfirmJob(id: UUID(), month: "2026-03", googleIds: ["g1"],
                                       phoneIndexes: [3], phoneAssetIDs: phoneAssetIDs, status: "armed"))
        try ctx.save()
    }

    func testLimitedAuthorizationLeavesArmedJobsArmed() async throws {
        let store = try makeStore()
        try insertArmed(phoneAssetIDs: ["A"])
        present = []  // outside the limited selection: reads as gone, is still on the phone

        store.resolveArmedJobs(authorization: .limited)
        XCTAssertEqual(try persistedStatuses(), ["armed"], "limited access must not promote armed jobs")

        store.resolveArmedJobs(authorization: .authorized)
        XCTAssertEqual(try persistedStatuses(), ["pending"])
    }

    /// The PhotoKit confirm alert flips scenePhase inactive -> active, which
    /// fires drain() while the job is armed. It must not POST it.
    func testDrainIgnoresArmedJobs() async throws {
        let store = try makeStore()
        try insertArmed(phoneAssetIDs: ["A"])
        await store.drain()
        XCTAssertEqual(sendCalls, 0, "drain POSTed an armed job")
        XCTAssertEqual(try persistedStatuses(), ["armed"])
    }

    func testDeliverRacingADrainPostsOnce() async throws {
        container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        var waiters: [CheckedContinuation<Void, Never>] = []
        var calls = 0
        let store = ReconcileConfirmStore(
            context: ModelContext(container),
            send: { _ in
                calls += 1
                await withCheckedContinuation { waiters.append($0) }
            },
            existingAssetIDs: { _ in [] }
        )
        let id = try await store.submit(month: "2026-03", googleIds: ["g1"], phone: []) {}

        let first = Task { try? await store.deliver(id) }
        for _ in 0..<200 where calls < 1 { await Task.yield(); try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(calls, 1)
        let second = Task { try? await store.deliver(id) }
        let drain = Task { await store.drain() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 1, "a second deliver/drain POSTed a job that is already in flight")

        waiters.forEach { $0.resume() }
        waiters = []
        await first.value; await second.value; await drain.value
        XCTAssertEqual(try persistedStatuses(), ["sent"])
    }
}
