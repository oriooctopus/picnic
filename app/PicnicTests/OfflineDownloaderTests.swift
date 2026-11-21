import XCTest
@testable import Picnic

/// Records every fetch and can hold or fail chosen ids. The downloader calls
/// `fetch` from its own tasks, hence the lock.
private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _blocked = false
    private var _failing: Set<String> = []

    var calls: [String] { lock.withLock { _calls } }
    func setBlocked(_ b: Bool) { lock.withLock { _blocked = b } }
    func setFailing(_ ids: Set<String>) { lock.withLock { _failing = ids } }

    var fetch: OfflineDownloader.Fetch {
        { [self] item, _ in
            lock.withLock { _calls.append(item.id) }
            while lock.withLock({ _blocked }) { try await Task.sleep(nanoseconds: 2_000_000) }
            if lock.withLock({ _failing.contains(item.id) }) { throw OfflineDownloader.FetchError.incomplete(item.id) }
        }
    }
}

@MainActor
final class OfflineDownloaderTests: XCTestCase {
    private let monthA = PlanMonth(year: 2026, month: 3, photoIDs: (0..<8).map { "a\($0)" }, videoIDs: [])
    private let monthB = PlanMonth(year: 2026, month: 2, photoIDs: (0..<8).map { "b\($0)" }, videoIDs: [])

    /// Fresh defaults suite and temp dir per call, so tests never share state.
    private func env() -> (UserDefaults, URL) {
        let defaults = UserDefaults(suiteName: "od-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("od-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (defaults, dir)
    }

    private func make(_ e: (UserDefaults, URL), _ rec: FetchRecorder) -> OfflineDownloader {
        let d = OfflineDownloader(defaults: e.0, directory: e.1, fetch: rec.fetch)
        d.update(months: [monthA, monthB], pace: 8) // hours 3 * 60 * 8 = 1440 picks both
        return d
    }

    func testSetLimitCutsQueueAndZeroDeselects() {
        let d = make(env(), FetchRecorder())
        d.setLimit(3, for: monthA)
        XCTAssertEqual(d.items.filter { $0.monthKey == monthA.key }.map(\.id), ["a0", "a1", "a2"])
        XCTAssertEqual(d.items.filter { $0.monthKey == monthB.key }.count, 8)
        XCTAssertTrue(d.manualSelection)
        d.setLimit(0, for: monthA)
        XCTAssertFalse(d.selectedKeys.contains(monthA.key))
        XCTAssertNil(d.limits[monthA.key])
        XCTAssertEqual(d.items.count, 8)
        d.setLimit(8, for: monthB) // all of it = no limit
        XCTAssertNil(d.limits[monthB.key])
    }

    func testLimitsPersistAcrossInstances() {
        let e = env()
        let d = make(e, FetchRecorder())
        d.setLimit(5, for: monthB)
        let again = OfflineDownloader(defaults: e.0, directory: e.1, fetch: FetchRecorder().fetch)
        XCTAssertEqual(again.limits, [monthB.key: 5])
        again.update(months: [monthA, monthB], pace: 8)
        XCTAssertEqual(again.items.filter { $0.monthKey == monthB.key }.count, 5)
    }

    func testChoosingHoursClearsManualLimits() {
        let d = make(env(), FetchRecorder())
        d.setLimit(2, for: monthA)
        d.chooseHours(3) // 1440 budget fits both months whole
        XCTAssertTrue(d.limits.isEmpty)
        XCTAssertFalse(d.manualSelection)
        XCTAssertEqual(d.items.count, 16)
    }

    func testPhotoSizesLoadInScreenModeForTheOriginalLabel() async {
        let e = env()
        let d = OfflineDownloader(defaults: e.0, directory: e.1, fetch: FetchRecorder().fetch,
                                  sizeLoader: { ids in Dictionary(uniqueKeysWithValues: ids.map { ($0, 1_000) }) })
        d.update(months: [monthA, monthB], pace: 8)
        XCTAssertEqual(d.quality, .screen)
        await d.loadSizes()
        XCTAssertEqual(d.sizes.count, 16, "every photo's original size loads while Screen is selected")
    }

    func testRunsAllItemsAndGoesIdle() async {
        let rec = FetchRecorder()
        let d = make(env(), rec)
        d.start()
        await eventually("all done") { d.doneCount == 16 && d.state == .idle }
        XCTAssertEqual(rec.calls.count, 16)
        XCTAssertEqual(d.failedCount, 0)
    }

    func testPauseStopsStartingAndResumeContinues() async {
        let rec = FetchRecorder()
        rec.setBlocked(true)
        let d = make(env(), rec)
        d.start()
        await eventually("4 in flight") { rec.calls.count == 4 }
        d.pause()
        rec.setBlocked(false)
        await eventually("in-flight finish") { d.doneCount == 4 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rec.calls.count, 4, "paused run must not start new items")
        XCTAssertEqual(d.state, .paused)
        d.resume()
        await eventually("rest done") { d.doneCount == 16 && d.state == .idle }
    }

    func testFailureIsCountedAndRetryRerunsOnlyFailures() async {
        let rec = FetchRecorder()
        rec.setFailing(["a3"])
        let d = make(env(), rec)
        d.start()
        await eventually("run ends") { d.state == .idle && d.doneCount == 15 }
        XCTAssertEqual(d.failedCount, 1)
        rec.setFailing([])
        d.retryFailed()
        await eventually("retry done") { d.doneCount == 16 && d.state == .idle }
        XCTAssertEqual(rec.calls.filter { $0 == "a3" }.count, 2)
        XCTAssertEqual(rec.calls.count, 17)
        XCTAssertEqual(d.failedCount, 0)
    }

    func testCompletedSetPersistsAcrossInstances() async {
        let e = env()
        let d = make(e, FetchRecorder())
        d.start()
        await eventually("done") { d.doneCount == 16 && d.state == .idle }
        let again = make(e, FetchRecorder())
        XCTAssertEqual(again.doneCount, 16)
        XCTAssertTrue(again.isDone("a0", quality: .screen))
    }

    func testInterruptedRunResumesOnNewInstance() async {
        let e = env()
        let rec = FetchRecorder()
        rec.setBlocked(true)
        let d = make(e, rec)
        d.start()
        await eventually("in flight") { rec.calls.count == 4 }
        XCTAssertTrue(e.0.bool(forKey: OfflineDownloader.wasRunningKey))
        let revived = make(e, FetchRecorder()) // update() resumes the interrupted run
        await eventually("resumed to completion") { revived.doneCount == 16 && revived.state == .idle }
        rec.setBlocked(false)
    }

    func testDeselectedMonthDropsPendingMidRun() async {
        let rec = FetchRecorder()
        rec.setBlocked(true)
        let d = make(env(), rec)
        d.start()
        await eventually("in flight") { rec.calls.count == 4 }
        d.toggle(monthB.key)
        rec.setBlocked(false)
        await eventually("done") { d.state == .idle }
        XCTAssertTrue(rec.calls.allSatisfy { $0.hasPrefix("a") }, "month B was deselected before it started: \(rec.calls)")
        XCTAssertEqual(d.doneCount, 8)
    }

    func testMonthToggledOnMidRunIsPickedUp() async {
        let rec = FetchRecorder()
        rec.setBlocked(true)
        let d = make(env(), rec)
        d.toggle(monthB.key) // manual: B off
        d.start()
        await eventually("in flight") { rec.calls.count == 4 }
        d.toggle(monthB.key)
        rec.setBlocked(false)
        await eventually("all done") { d.doneCount == 16 && d.state == .idle }
    }

    func testOriginalImpliesScreenButNotTheReverse() async {
        let d = make(env(), FetchRecorder())
        d.quality = .original
        d.start()
        await eventually("done") { d.state == .idle && d.doneCount == 16 }
        d.quality = .screen
        XCTAssertEqual(d.doneCount, 16)

        let d2 = make(env(), FetchRecorder())
        d2.start()
        await eventually("done") { d2.state == .idle && d2.doneCount == 16 }
        d2.quality = .original
        XCTAssertEqual(d2.doneCount, 0)
    }
}
