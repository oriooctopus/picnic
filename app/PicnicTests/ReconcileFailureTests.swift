import XCTest
import SwiftData
@testable import Picnic

/// Clean up Google confirm job: only a permanent 4xx parks it; failed jobs are
/// resolved by the user with Retry/Discard; the pass stops when offline.
@MainActor
final class ReconcileFailureTests: XCTestCase {
    private var container: ModelContainer!
    private var sendCalls = 0
    private var errors: [Error?] = []

    private func makeStore() throws -> ReconcileConfirmStore {
        container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        return ReconcileConfirmStore(
            context: ModelContext(container),
            send: { [unowned self] _ in
                self.sendCalls += 1
                if !self.errors.isEmpty, let e = self.errors.removeFirst() { throw e }
            },
            existingAssetIDs: { _ in [] }
        )
    }

    private func statuses() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<ReconcileConfirmJob>()).map(\.status).sorted()
    }

    func testRetryableStatusesStayPending() async throws {
        for code in [408, 429, 502] {
            sendCalls = 0
            let store = try makeStore()
            let id = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
            errors = [MirrorClientError.badStatus(code)]
            try? await store.deliver(id)
            XCTAssertEqual(try statuses(), ["pending"], "HTTP \(code) is retryable, must not be parked")
            XCTAssertEqual(store.failedCount, 0)
        }
    }

    func testPermanentRejectionIsFailedAndCounted() async throws {
        let store = try makeStore()
        let id = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(400)]
        try? await store.deliver(id)
        XCTAssertEqual(try statuses(), ["failed"])
        XCTAssertEqual(store.failedCount, 1)
    }

    func testRetryFailedResendsAndDiscardRemoves() async throws {
        let store = try makeStore()
        let id = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(400)]
        try? await store.deliver(id)

        await store.retryFailed()
        XCTAssertEqual(try statuses(), ["sent"], "Retry must re-send the failed job")
        XCTAssertEqual(sendCalls, 2)
        XCTAssertEqual(store.failedCount, 0)

        errors = [MirrorClientError.badStatus(400)]
        let id2 = try await store.submit(month: "2026-04", googleIds: ["g"], phone: []) {}
        try? await store.deliver(id2)
        XCTAssertEqual(store.failedCount, 1)
        store.discardFailed()
        XCTAssertEqual(try statuses(), ["sent"], "Discard removes only the failed job")
        XCTAssertEqual(store.failedCount, 0)
    }

    func testDrainStopsAtFirstTransportFailure() async throws {
        let store = try makeStore()
        _ = try await store.submit(month: "2026-03", googleIds: ["a"], phone: []) {}
        _ = try await store.submit(month: "2026-04", googleIds: ["b"], phone: []) {}
        errors = [URLError(.notConnectedToInternet)]
        await store.drain()
        XCTAssertEqual(sendCalls, 1, "offline: the second job must not be attempted")
        XCTAssertEqual(try statuses(), ["pending", "pending"])
    }
}
