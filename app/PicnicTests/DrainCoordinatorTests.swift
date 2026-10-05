import XCTest
@testable import Picnic

/// Each drain trigger in isolation, with a recording drain closure.
@MainActor
final class DrainCoordinatorTests: XCTestCase {
    private var calls: [Bool] = []  // ignoreBackoff of each drain

    private func makeCoordinator() -> DrainCoordinator {
        calls = []
        return DrainCoordinator(drain: { [unowned self] ignore in self.calls.append(ignore) })
    }

    func testLaunchDrainsOnceWithBackoffRespected() async {
        let c = makeCoordinator()
        await c.drainAtLaunch()
        XCTAssertEqual(calls, [false], "launch must drain exactly once")
    }

    func testForegroundBeforeLaunchDrainDoesNotDrain() async {
        let c = makeCoordinator()
        await c.sceneBecameActive()
        XCTAssertEqual(calls, [], "scenePhase .active at launch must not duplicate bootstrap's drain")
    }

    func testForegroundAfterLaunchDrains() async {
        let c = makeCoordinator()
        await c.drainAtLaunch()
        await c.sceneBecameActive()
        XCTAssertEqual(calls, [false, false])
    }

    func testForegroundDrainsWhenLaunchSkippedDrain() async {
        let c = makeCoordinator()
        c.launchWithoutDrain()
        await c.sceneBecameActive()
        XCTAssertEqual(calls, [false])
    }

    func testNetworkRestoredDrainsIgnoringBackoff() async {
        let c = makeCoordinator()
        await c.pathUpdated(satisfied: false)
        await c.pathUpdated(satisfied: true)
        XCTAssertEqual(calls, [true], "offline -> online must drain, ignoring backoff set by the outage")
    }

    func testFirstSatisfiedReportDoesNotDrain() async {
        let c = makeCoordinator()
        await c.pathUpdated(satisfied: true)
        XCTAssertEqual(calls, [], "the first path report is the current state, not a restore")
    }

    func testSatisfiedToSatisfiedAndLossDoNotDrain() async {
        let c = makeCoordinator()
        await c.pathUpdated(satisfied: true)
        await c.pathUpdated(satisfied: true)
        await c.pathUpdated(satisfied: false)
        XCTAssertEqual(calls, [])
    }
}
