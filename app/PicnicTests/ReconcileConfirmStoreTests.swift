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
            existingAssetIDs: { [unowned self] ids in Set(ids).intersection(self.present) }
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
        store.resolveArmedJobs()
        XCTAssertEqual(try persistedStatuses(), ["pending"])
    }

    func testLeftoverArmedJobWithPhoneAssetPresentIsRemovedOnLaunch() async throws {
        let store = try makeStore()
        let ctx = ModelContext(container)
        ctx.insert(ReconcileConfirmJob(id: UUID(), month: "2026-03", googleIds: ["g1"],
                                       phoneIndexes: [3], phoneAssetIDs: ["A"], status: "armed"))
        try ctx.save()
        present = ["A"]
        store.resolveArmedJobs()
        XCTAssertEqual(try persistedStatuses(), [])
    }
}
