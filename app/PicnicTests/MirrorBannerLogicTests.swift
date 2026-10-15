import XCTest
@testable import Picnic

/// Covers MirrorBannerLogic.state() -- see MirrorBannerState.swift. Pure
/// Foundation logic, no SwiftUI/SwiftData/network involved, so these run
/// without a simulator's Photos/UI stack.
final class MirrorBannerLogicTests: XCTestCase {

    func testNoBannerWhenNothingPendingOrQueued() {
        // Server reports counts.queued = 0 and oldestQueuedWaitMs null.
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 0, oldestQueuedWaitMs: nil
        )
        XCTAssertEqual(state, .none)
    }

    func testFreshServerQueueShowsNonStuckBanner() {
        // The queue is shown at any size while it drains, not only once
        // it's been stuck an hour (the old behavior returned .none here).
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 3, oldestQueuedWaitMs: 10_000
        )
        XCTAssertEqual(state, .serverQueued(count: 3, waitMs: 10_000, isStuck: false))
    }

    func testDevicePendingWinsOverServerBacklog() {
        // Both a device-side pending job AND a server backlog past the
        // threshold are true at once -- device-pending must win outright,
        // the two must never stack into two banners.
        let state = MirrorBannerLogic.state(
            pendingCount: 2, lastError: "mirror server returned HTTP 500",
            serverQueuedCount: 40, oldestQueuedWaitMs: 5_000_000
        )
        XCTAssertEqual(state, .devicePending(count: 2, outfitCount: 0, lastError: "mirror server returned HTTP 500"))
    }

    func testServerQueueJustUnderThresholdIsNotStuck() {
        let waitMs = MirrorBannerLogic.serverBacklogThresholdMs - 1
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 40, oldestQueuedWaitMs: waitMs
        )
        XCTAssertEqual(state, .serverQueued(count: 40, waitMs: waitMs, isStuck: false))
    }

    func testServerQueueJustOverThresholdIsStuck() {
        let waitMs = MirrorBannerLogic.serverBacklogThresholdMs + 1
        let state = MirrorBannerLogic.state(
            pendingCount: 0, lastError: nil,
            serverQueuedCount: 40, oldestQueuedWaitMs: waitMs
        )
        XCTAssertEqual(state, .serverQueued(count: 40, waitMs: waitMs, isStuck: true))
    }

    func testWaitFormatsMinutesUnderAnHourAndHoursAfter() {
        XCTAssertEqual(MirrorSyncBannerContent.formatWait(465_055), "7m")
        XCTAssertEqual(MirrorSyncBannerContent.formatWait(155_993_263), "43h")
        XCTAssertEqual(
            MirrorSyncBannerContent.serverQueuedText(count: 125, waitMs: 465_055),
            "125 deleting from Google · oldest 7m"
        )
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
        XCTAssertEqual(state, .serverQueued(count: 65, waitMs: 155_993_263, isStuck: true))
    }
}
