import XCTest
import SwiftData
@testable import Picnic

/// Clean up Google confirms back off like the other queues (JobRetryPolicy,
/// 30s growing to 1h) instead of being re-sent on every drain.
@MainActor
final class ReconcileBackoffTests: XCTestCase {
    private var container: ModelContainer!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var sends = 0
    private var errors: [Error?] = []

    private func makeStore() throws -> ReconcileConfirmStore {
        container = try TestSupport.inMemoryContainer()
        return ReconcileConfirmStore(
            context: ModelContext(container),
            send: { [unowned self] _ in
                self.sends += 1
                if !self.errors.isEmpty, let e = self.errors.removeFirst() { throw e }
            },
            existingAssetIDs: { _ in [] },
            now: { [unowned self] in self.clock }
        )
    }

    private func statuses() throws -> [String] {
        try ModelContext(container).fetch(FetchDescriptor<ReconcileConfirmJob>()).map(\.status).sorted()
    }

    func testTwoDrainsAfterA502MakeOneSend() async throws {
        let store = try makeStore()
        _ = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(502)]
        await store.drain()
        await store.drain()
        XCTAssertEqual(sends, 1, "the second drain is inside the 30s backoff the 502 set: it must not re-send")
        XCTAssertEqual(try statuses(), ["pending"])
    }

    func testForcedDrainIgnoresBackoff() async throws {
        let store = try makeStore()
        _ = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(502)]
        await store.drain()
        await store.drain(ignoreBackoff: true)
        XCTAssertEqual(sends, 2, "network-restore / Retry drains must send despite backoff")
        XCTAssertEqual(try statuses(), ["sent"])
    }

    func testJobRetriesOnceItsBackoffHasElapsed() async throws {
        let store = try makeStore()
        _ = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(502)]
        await store.drain()
        clock = clock.addingTimeInterval(JobRetryPolicy.backoff(attempt: 1) + 1)
        await store.drain()
        XCTAssertEqual(sends, 2, "after the backoff elapses the job must be retried")
        XCTAssertEqual(try statuses(), ["sent"])
    }

    func testRetryFailedAlsoForcesBackedOffPendingJobs() async throws {
        let store = try makeStore()
        let pendingID = try await store.submit(month: "2026-03", googleIds: ["g"], phone: []) {}
        errors = [MirrorClientError.badStatus(502)]
        try? await store.deliver(pendingID)  // now pending, in backoff
        let failedID = try await store.submit(month: "2026-04", googleIds: ["h"], phone: []) {}
        errors = [MirrorClientError.badStatus(400)]
        try? await store.deliver(failedID)
        XCTAssertEqual(try statuses(), ["failed", "pending"])

        await store.retryFailed()
        XCTAssertEqual(try statuses(), ["sent", "sent"],
                       "Retry must run a forced drain: the backed-off pending job is sent too, not just the failed one")
    }
}
