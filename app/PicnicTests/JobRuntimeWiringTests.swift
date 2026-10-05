import XCTest
import SwiftData
import Photos
import Network
@testable import Picnic

/// A path source the test drives by hand.
@MainActor
final class FakePathSource: NetworkPathSource {
    private(set) var startCount = 0
    private var onUpdate: (@Sendable (Bool) -> Void)?

    func start(onUpdate: @escaping @Sendable (Bool) -> Void) {
        startCount += 1
        self.onUpdate = onUpdate
    }

    func emit(_ satisfied: Bool) { onUpdate?(satisfied) }
}

/// The composition root: which trigger drains which store, with or without
/// backoff. Every store holds one pending job; the injected senders record
/// who was asked to send.
@MainActor
final class JobRuntimeWiringTests: XCTestCase {
    private var container: ModelContainer!
    private let clock = Date(timeIntervalSince1970: 1_000_000)
    private let path = FakePathSource()
    private var events: [String] = []
    private var mirrorPosts: [String] = []
    private var reconcileSends: [String] = []
    private var outfitUploads: [String] = []
    private var statusFetches = 0

    private func makeRuntime(inBackoff: Bool) throws -> JobRuntime {
        container = try TestSupport.inMemoryContainer()
        let context = ModelContext(container)
        let later: Date? = inBackoff ? clock.addingTimeInterval(3600) : nil
        let m = TestSupport.mirrorJob("mirror.jpg"); m.nextAttemptAt = later
        let r = TestSupport.reconcileJob("2026-03"); r.nextAttemptAt = later
        let o = TestSupport.outfitJob("outfit"); o.nextAttemptAt = later
        context.insert(m); context.insert(r); context.insert(o)
        try context.save()
        return JobRuntime(
            context: context, pathSource: path,
            mirrorPost: { [unowned self] job in self.mirrorPosts.append(job.filename); self.events.append("mirror") },
            reconcileSend: { [unowned self] job in self.reconcileSends.append(job.month) },
            outfitUpload: { [unowned self] job in self.outfitUploads.append(job.assetID) },
            existingAssetIDs: { _ in [] },
            fetchStatus: { [unowned self] in
                self.statusFetches += 1
                throw URLError(.notConnectedToInternet)
            },
            now: { [unowned self] in self.clock }
        )
    }

    private func assertNothingSent(_ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mirrorPosts, [], why, file: file, line: line)
        XCTAssertEqual(reconcileSends, [], why, file: file, line: line)
        XCTAssertEqual(outfitUploads, [], why, file: file, line: line)
    }

    func testLaunchDrainsEveryStore() async throws {
        let runtime = try makeRuntime(inBackoff: false)
        defer { runtime.mirrorQueue.stopPolling() }
        await runtime.launch(authorization: .authorized)
        XCTAssertEqual(mirrorPosts, ["mirror.jpg"], "launch must drain the mirror queue")
        XCTAssertEqual(reconcileSends, ["2026-03"], "launch must drain the Clean up confirm queue")
        XCTAssertEqual(outfitUploads, ["outfit"], "launch must drain the outfit queue")
        XCTAssertGreaterThanOrEqual(statusFetches, 1, "launch must fetch the server status immediately")
    }

    func testLaunchDrainHonorsBackoff() async throws {
        let runtime = try makeRuntime(inBackoff: true)
        defer { runtime.mirrorQueue.stopPolling() }
        await runtime.launch(authorization: .authorized)
        assertNothingSent("a launch drain must wait out backoff; only network-restore and Retry bypass it")
    }

    func testNetworkRestoredDrainsEveryStoreIgnoringBackoff() async throws {
        let runtime = try makeRuntime(inBackoff: true)
        runtime.start()
        XCTAssertEqual(path.startCount, 1, "the runtime must start listening to the network path")
        path.emit(false)
        path.emit(true)
        await eventually("mirror queue not drained (ignoring backoff) when the network came back") { !mirrorPosts.isEmpty }
        await eventually("Clean up confirm queue not drained (ignoring backoff) when the network came back") { !reconcileSends.isEmpty }
        await eventually("outfit queue not drained (ignoring backoff) when the network came back") { !outfitUploads.isEmpty }
    }

    func testForegroundWithoutPhotoAccessStillDrainsEveryStore() async throws {
        let runtime = try makeRuntime(inBackoff: false)
        defer { runtime.mirrorQueue.stopPolling() }
        await runtime.bootstrap(
            requestAuthorization: { .denied },
            settleLibrary: { XCTFail("without photo access the library must not be settled") }
        )
        XCTAssertEqual(path.startCount, 1, "bootstrap must start the network listener even without photo access")
        assertNothingSent("without photo access bootstrap itself drains nothing")

        await runtime.scenePhaseChanged(active: true)
        XCTAssertEqual(mirrorPosts, ["mirror.jpg"], "foreground must drain the mirror queue once launch is done")
        XCTAssertEqual(reconcileSends, ["2026-03"], "foreground must drain the Clean up confirm queue")
        XCTAssertEqual(outfitUploads, ["outfit"], "foreground must drain the outfit queue")
        XCTAssertGreaterThanOrEqual(statusFetches, 1, "foreground must refresh the server status")
    }

    func testForegroundDrainHonorsBackoff() async throws {
        let runtime = try makeRuntime(inBackoff: true)
        defer { runtime.mirrorQueue.stopPolling() }
        runtime.launchWithoutDrain()
        await runtime.scenePhaseChanged(active: true)
        assertNothingSent("a foreground drain must wait out backoff")
    }

    func testBootstrapWithAccessSettlesLibraryThenDrains() async throws {
        let runtime = try makeRuntime(inBackoff: false)
        defer { runtime.mirrorQueue.stopPolling() }
        await runtime.bootstrap(
            requestAuthorization: { [unowned self] in self.events.append("auth"); return .authorized },
            settleLibrary: { [unowned self] in self.events.append("settle") }
        )
        XCTAssertEqual(events, ["auth", "settle", "mirror"], "launch drains after authorization and library settling, once")
        XCTAssertEqual(path.startCount, 1)
        XCTAssertEqual(outfitUploads, ["outfit"])
        XCTAssertEqual(reconcileSends, ["2026-03"])
    }

    func testLeavingActiveStopsPollingWithoutDraining() async throws {
        let runtime = try makeRuntime(inBackoff: false)
        runtime.launchWithoutDrain()
        await runtime.scenePhaseChanged(active: false)
        assertNothingSent("going inactive must not drain")
        XCTAssertEqual(statusFetches, 0)
    }

    // MARK: Real NWPath status mapping

    func testOnlySatisfiedPathCountsAsReachable() {
        XCTAssertTrue(NetworkPathWatcher.isSatisfied(.satisfied))
        XCTAssertFalse(NetworkPathWatcher.isSatisfied(.unsatisfied), "an unsatisfied path is offline")
        XCTAssertFalse(NetworkPathWatcher.isSatisfied(.requiresConnection), "requiresConnection is not reachable yet")
    }
}
