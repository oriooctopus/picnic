import XCTest
import Photos
import BackgroundTasks
@testable import Picnic

/// What survives a relaunch: the on-device store, the scanner seeded from it,
/// eviction, the keeper's `known`, and the background task request.
@MainActor
final class OnDevicePersistenceTests: XCTestCase {
    final class FakeAsset: PHAsset {
        var fakeID = ""
        override var localIdentifier: String { fakeID }
    }

    private func asset(_ id: String) -> FakeAsset {
        let a = FakeAsset()
        a.fakeID = id
        return a
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OnDeviceIDs-\(UUID().uuidString).json")
    }

    private func scan(_ scanner: OfflineMonthScanner, ids: [String]) async {
        let month = MonthBucket(year: 2026, month: 1, assets: ids.map(asset))
        scanner.scan(months: [month], isMonthSorted: { _ in false }, isUnsorted: { _ in true })
        while scanner.isScanning { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testStoreRoundTripsAcrossFreshInstance() {
        let url = tempURL()
        let first = OnDeviceStore(url: url)
        first.add(["a", "b", "c"])
        first.remove(["b"])
        XCTAssertEqual(OnDeviceStore(url: url).ids, ["a", "c"])
    }

    func testScannerSeedsFromStoreBeforeAnyProbe() {
        let store = OnDeviceStore(url: tempURL())
        store.add(["a", "b"])
        let scanner = OfflineMonthScanner(store: store, probe: { _, _ in
            XCTFail("no probe may run before scan")
            return false
        })
        XCTAssertEqual(scanner.availableIDs, ["a", "b"])
        XCTAssertFalse(scanner.showsChecking, "a stored count must not wait on the scan")
    }

    func testEmptyStoreStillShowsChecking() {
        let scanner = OfflineMonthScanner(store: OnDeviceStore(url: tempURL()), probe: { _, _ in false })
        XCTAssertTrue(scanner.showsChecking)
    }

    func testScanProbesUnknownBeforeStoredPositives() async {
        let store = OnDeviceStore(url: tempURL())
        store.add(["s1", "s2"])
        let order = LockedList()
        let scanner = OfflineMonthScanner(store: store, probe: { asset, _ in
            order.append(asset.localIdentifier)
            return true
        })
        // 4 probes run at once, so s1/s2 can only start after n1...n4 all have.
        await scan(scanner, ids: ["s1", "s2", "n1", "n2", "n3", "n4"])
        XCTAssertEqual(Set(order.values.prefix(4)), ["n1", "n2", "n3", "n4"])
        XCTAssertEqual(Set(order.values), ["s1", "s2", "n1", "n2", "n3", "n4"], "stored positives are re-verified")
    }

    func testEvictedStoredPositiveLeavesMemoryAndStore() async {
        let url = tempURL()
        let store = OnDeviceStore(url: url)
        store.add(["kept", "evicted"])
        let scanner = OfflineMonthScanner(store: store, probe: { asset, _ in asset.localIdentifier == "kept" })
        await scan(scanner, ids: ["kept", "evicted"])
        XCTAssertEqual(scanner.availableIDs, ["kept"])
        XCTAssertEqual(OnDeviceStore(url: url).ids, ["kept"])
    }

    func testNewPositivesAndSortedPhotosPersist() async {
        let url = tempURL()
        let store = OnDeviceStore(url: url)
        store.add(["sortedAway"])
        let scanner = OfflineMonthScanner(store: store, probe: { _, _ in true })
        await scan(scanner, ids: ["fresh"])
        XCTAssertEqual(OnDeviceStore(url: url).ids, ["fresh"])
        XCTAssertEqual(scanner.availableIDs, ["fresh"])
    }

    func testKeeperKnownComesFromStore() {
        let store = OnDeviceStore(url: tempURL())
        store.add(["a"])
        let keeper = OfflineKeeper(store: store)
        XCTAssertEqual(keeper.known, ["a"])
        store.add(["b"])
        XCTAssertEqual(keeper.known, ["a", "b"])
    }

    func testBackgroundRequestProperties() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let request = OfflineKeeperBackground.makeRequest(now: now)
        XCTAssertEqual(request.identifier, "com.oliverullman.picnic.offlineKeeper")
        XCTAssertTrue(request.requiresNetworkConnectivity)
        XCTAssertFalse(request.requiresExternalPower)
        XCTAssertEqual(request.earliestBeginDate, now.addingTimeInterval(OfflineKeeperBackground.minimumInterval))
    }

    func testPlistDeclaresTaskIdentifierAndProcessingMode() {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertEqual(permitted, [OfflineKeeperBackground.taskIdentifier])
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], ["processing"])
    }
}

/// Probe closures are @Sendable, so the order they record needs a lock.
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
