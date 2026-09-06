import XCTest
@testable import Picnic

/// Covers MirrorBannerLogic.state() -- see MirrorBannerState.swift. Pure
/// Foundation logic, no SwiftUI/SwiftData/network involved, so these run
/// without a simulator's Photos/UI stack.
final class MirrorBannerLogicTests: XCTestCase {

    func testNoBannerWhenNothingPendingOrBackedUp() {
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 3, oldestQueuedWaitMs: 10_000
        )
        XCTAssertEqual(state, .none)
    }

    func testDevicePendingWinsOverServerBacklog() {
        // Both a device-side pending job AND a server backlog past the
        // threshold are true at once -- device-pending must win outright,
        // the two must never stack into two banners.
        let state = MirrorBannerLogic.state(
            pendingCount: 2, lastError: "mirror server returned HTTP 500",
            serverQueuedCount: 40, oldestQueuedWaitMs: 5_000_000
        )
        XCTAssertEqual(state, .devicePending(count: 2, lastError: "mirror server returned HTTP 500"))
    }

    func testServerBacklogJustUnderThresholdShowsNothing() {
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 40,
            oldestQueuedWaitMs: MirrorBannerLogic.serverBacklogThresholdMs - 1
        )
        XCTAssertEqual(state, .none)
    }

    func testServerBacklogJustOverThresholdShowsBanner() {
        let waitMs = MirrorBannerLogic.serverBacklogThresholdMs + 1
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 40, oldestQueuedWaitMs: waitMs
        )
        XCTAssertEqual(state, .serverBacklog(count: 40, waitMs: waitMs))
    }

    func testUnreachableOrNeverFetchedStatusShowsNothing() {
        // nil/nil is MirrorQueueStore's contract for "GET /queue has never
        // returned successfully" -- must never invent a banner out of
        // missing data.
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: nil, oldestQueuedWaitMs: nil
        )
        XCTAssertEqual(state, .none)
    }

    func testStaleServerStatusStillHonoredWhileFreshFetchIsPending() {
        // MirrorQueueStore never resets serverStatus to nil after a failed
        // poll, so from this function's point of view a stale-but-real
        // value is indistinguishable from a fresh one -- and that's the
        // point: a real backlog observed several polls ago is still real.
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 65, oldestQueuedWaitMs: 155_993_263
        )
        XCTAssertEqual(state, .serverBacklog(count: 65, waitMs: 155_993_263))
    }
}
