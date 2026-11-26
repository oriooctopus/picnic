import Foundation
import Photos

/// Finds which unsorted photos are really on this phone, month by month, for
/// the My Life grid in offline mode.
///
/// Why this exists: the grid first counted only `OfflineDownloader.completed`,
/// i.e. photos fetched through the Download screen. Photos that were already
/// on the phone (recent shots, anything iCloud has not offloaded) and photos
/// the deck's prefetcher pulled down never appear in that list, so on the
/// phone offline mode said "Nothing downloaded" for a library that was largely
/// on the device. This runs the same network-off probe the deck's offline-only
/// filter uses (`LocalAvailability.probeOne`), so the grid and the deck agree
/// on what counts as offline.
///
/// Cost: one network-off screen-size request per unsorted photo, 4 at a time,
/// newest month first so the months at the top of the grid fill in first.
/// Positives persist in `OnDeviceStore`: a launch seeds `availableIDs` from it
/// so the count shows at once, then the pass probes unknown photos first and
/// re-verifies the stored ones, dropping any iOS has since offloaded.
@MainActor
final class OfflineMonthScanner: ObservableObject {
    /// Probes at once. Matches `LocalAvailability.maxConcurrent`.
    static let maxConcurrent = 4
    /// Publish after this many new positives, not per item, so the grid is not
    /// re-filtered a few thousand times during one pass. Matches
    /// `LocalAvailability.flushEvery`.
    static let flushEvery = 25

    @Published private(set) var availableIDs: Set<String> = []
    /// Starts true: until the first pass has run, "nothing found" is unknown,
    /// not empty. Starting false showed "Nothing downloaded" on the phone for
    /// the moment between launch and the first scan (buckets not loaded yet).
    @Published private(set) var isScanning = true
    /// True while the storage line should read "Checking": a scan is running
    /// and there is no stored or found count to show yet. Seeded counts are a
    /// real (if slightly stale) answer, so they never wait on the scan.
    @Published private(set) var showsChecking: Bool
    /// Bumped per `scan`, so a cancelled pass finishing late can't clear
    /// `isScanning` while its replacement is still running.
    private var generation = 0
    private var probedIDs: Set<String> = []
    private var pendingAvailable: Set<String> = []
    private var task: Task<Void, Never>?

    /// The probe. Injectable for tests.
    typealias Probe = @Sendable (PHAsset, Int) async -> Bool
    private let probe: Probe
    private let store: OnDeviceStore

    init(store: OnDeviceStore,
         probe: @escaping Probe = { asset, index in await LocalAvailability.probeOne(.local(asset), monthIndex: index) }) {
        self.store = store
        self.probe = probe
        availableIDs = store.ids
        showsChecking = store.ids.isEmpty
    }

    /// Restarts the pass over `months` (newest first, as the grid lists them),
    /// skipping manually sorted months, sorted items and anything already
    /// probed. Cancels a pass already running; what it learned is kept.
    func scan(months: [MonthBucket], isMonthSorted: @escaping (String) -> Bool, isUnsorted: @escaping (PHAsset) -> Bool) {
        task?.cancel()
        // Months not loaded yet (PhotoKit still answering): stay "checking";
        // the grid calls scan again when the buckets arrive.
        guard !months.isEmpty else { return }
        isScanning = true
        showsChecking = availableIDs.isEmpty
        // Bumped here, synchronously, not inside the task: otherwise the old
        // pass could finish between this call and the new task starting, still
        // match the generation, and clear isScanning mid-scan.
        generation += 1
        let myGeneration = generation
        task = Task { await run(months: months, generation: myGeneration, isMonthSorted: isMonthSorted, isUnsorted: isUnsorted) }
    }

    /// Records photos another service (the offline keeper) just downloaded, so
    /// the grid shows them without re-probing: probed ids are never re-asked.
    func markAvailable(_ ids: [String]) {
        probedIDs.formUnion(ids)
        availableIDs.formUnion(ids)
        store.add(ids)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One pass; `myGeneration` is the `scan` call that started it.
    private func run(months: [MonthBucket], generation myGeneration: Int,
                     isMonthSorted: (String) -> Bool, isUnsorted: (PHAsset) -> Bool) async {
        defer {
            flush()
            if generation == myGeneration { isScanning = false; showsChecking = false }
        }
        // (asset, index in its month): the index only feeds the DEBUG
        // partially-downloaded simulation, which keys off month position.
        let candidates: [(PHAsset, Int)] = months.filter { !isMonthSorted($0.key) }.flatMap { month in
            month.assets.enumerated().compactMap { index, asset in
                isUnsorted(asset) ? (asset, index) : nil
            }
        }
        // Sorted since the last launch: no longer part of the offline pool.
        let stillUnsorted = Set(candidates.map { $0.0.localIdentifier })
        let sortedAway = store.ids.subtracting(stillUnsorted)
        store.remove(sortedAway)
        availableIDs.subtract(sortedAway)
        // Unknown photos first (they fill the grid), then re-verify stored
        // positives, which may have been offloaded since they were saved.
        let todo = candidates.filter { !probedIDs.contains($0.0.localIdentifier) }
        let queue = todo.filter { !availableIDs.contains($0.0.localIdentifier) }
            + todo.filter { availableIDs.contains($0.0.localIdentifier) }
        guard !queue.isEmpty else { return }
        let probe = self.probe
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            while next < min(Self.maxConcurrent, queue.count) {
                let (asset, index) = queue[next]
                next += 1
                group.addTask { (asset.localIdentifier, await probe(asset, index)) }
            }
            while let (id, ok) = await group.next() {
                probedIDs.insert(id)
                if ok {
                    pendingAvailable.insert(id)
                    if pendingAvailable.count >= Self.flushEvery { flush() }
                } else if !Task.isCancelled, availableIDs.contains(id) {
                    // Offloaded since it was stored (not a probe cut short by cancel).
                    availableIDs.remove(id)
                    store.remove([id])
                }
                if !Task.isCancelled, next < queue.count {
                    let (asset, index) = queue[next]
                    next += 1
                    group.addTask { (asset.localIdentifier, await probe(asset, index)) }
                }
            }
        }
    }

    private func flush() {
        guard !pendingAvailable.isEmpty else { return }
        availableIDs.formUnion(pendingAvailable)
        store.add(pendingAvailable)
        pendingAvailable.removeAll()
    }
}
