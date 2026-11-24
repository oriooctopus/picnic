import Foundation
import Photos
import UIKit

/// Keeps a floor of unsorted photos at full quality on the phone, so offline
/// mode always has something to sort.
///
/// Why: full-quality iCloud downloads used to happen only while a deck was
/// open (`DeckPrefetcher`), so on the phone offline mode settled at 152 photos,
/// all from the one month being sorted. This walks the months newest-first,
/// probes each unsorted photo with the same network-off check the deck uses
/// (`LocalAvailability.probeOne`, warm copies NOT counted), and downloads the
/// missing ones the way `DeckPrefetcher` does, until `targetCount` are on the
/// device or the library runs out. Results are discarded: PhotoKit's own store
/// is the goal.
///
/// Foreground only (`setActive`), 2 requests at a time so it doesn't fight an
/// open deck's prefetcher, restarted whenever the months change (a sort moves
/// photos out of the unsorted pool). Positive answers are remembered for the
/// app's lifetime, like `OfflineMonthScanner`, so a restart doesn't re-probe.
@MainActor
final class OfflineKeeper: ObservableObject {
    /// The user's ask, verbatim: "we should always have at least 300 full
    /// quality photos."
    static let targetCount = 300
    /// Requests at once. 2 so the open deck's own loads and prefetch (4) keep
    /// the bandwidth. A guess, not a measurement.
    static let maxConcurrent = 2
    /// Photos probed per round. A round probes, then downloads just enough of
    /// the missing ones to reach the target, so a library with 20k unsorted
    /// photos is never probed past the point where 300 are secured.
    static let batchSize = 50

    /// Unsorted full-quality photos secured so far in the current pass.
    @Published private(set) var availableCount = 0

    private var isActive = true
    private var task: Task<Void, Never>?
    private var known: Set<String> = []

    /// Of `ordered` (newest-first candidates probed so far), which ids to
    /// download so that `target` of them are available: the first unavailable
    /// ones, as many as the shortfall. Pure, so it is unit-tested.
    nonisolated static func idsToDownload(ordered: [String], available: Set<String>, target: Int) -> [String] {
        let have = ordered.filter { available.contains($0) }.count
        let need = max(0, target - have)
        return Array(ordered.filter { !available.contains($0) }.prefix(need))
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { stop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Restarts the pass. Does nothing while backgrounded, with no months yet,
    /// or under a DEBUG simulation flag (real downloads would "repair" the
    /// simulated-missing photos, same reason DeckPrefetcher stands down).
    func start(months: [MonthBucket], isMonthSorted: (String) -> Bool, isUnsorted: (PHAsset) -> Bool,
               onAvailable: @escaping ([String]) -> Void) {
        task?.cancel()
        task = nil
        guard isActive, !months.isEmpty else { return }
        #if DEBUG
        if ThumbnailLoader.simulatedUpdates() != nil || ThumbnailLoader.simulatePartiallyDownloaded { return }
        #endif
        let candidates: [PHAsset] = months.filter { !isMonthSorted($0.key) }.flatMap { month in
            month.assets.filter { $0.mediaType != .video && isUnsorted($0) }
        }
        task = Task { await run(candidates: candidates, onAvailable: onAvailable) }
    }

    private func run(candidates: [PHAsset], onAvailable: ([String]) -> Void) async {
        var ordered: [String] = []
        var available: Set<String> = []
        var failed: Set<String> = []
        var index = 0
        while !Task.isCancelled, available.count < Self.targetCount, index < candidates.count {
            let batch = Array(candidates[index..<min(index + Self.batchSize, candidates.count)])
            index += batch.count
            let unknown = batch.filter { !known.contains($0.localIdentifier) }
            let probedOK = await Self.succeeded(in: unknown) { asset in
                await LocalAvailability.probeOne(.local(asset), monthIndex: 0, countWarm: false)
            }
            for asset in batch {
                let id = asset.localIdentifier
                ordered.append(id)
                if known.contains(id) || probedOK.contains(id) { available.insert(id) }
            }
            known.formUnion(probedOK)

            let wanted = Set(Self.idsToDownload(ordered: ordered.filter { !failed.contains($0) },
                                                available: available, target: Self.targetCount))
            let toDownload = batch.filter { wanted.contains($0.localIdentifier) }
            let downloaded = await Self.succeeded(in: toDownload) { await Self.download($0) }
            failed.formUnion(wanted.subtracting(downloaded))
            available.formUnion(downloaded)
            known.formUnion(downloaded)
            availableCount = available.count
            if !downloaded.isEmpty { onAvailable(Array(downloaded)) }
        }
    }

    /// Ids in `assets` for which `work` returned true, run `maxConcurrent` at a
    /// time. A cancelled pass stops feeding the group; requests in flight finish.
    private nonisolated static func succeeded(in assets: [PHAsset], work: @escaping @Sendable (PHAsset) async -> Bool) async -> Set<String> {
        var ok: Set<String> = []
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = 0
            while next < min(Self.maxConcurrent, assets.count) {
                let asset = assets[next]
                next += 1
                group.addTask { (asset.localIdentifier, await work(asset)) }
            }
            while let (id, good) = await group.next() {
                if good { ok.insert(id) }
                if !Task.isCancelled, next < assets.count {
                    let asset = assets[next]
                    next += 1
                    group.addTask { (asset.localIdentifier, await work(asset)) }
                }
            }
        }
        return ok
    }

    /// Downloads the screen-size image into PhotoKit's store, exactly the
    /// request `DeckPrefetcher.start` makes. True only for a complete image.
    private nonisolated static func download(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: ThumbnailLoader.screenPixelSize, contentMode: .aspectFit,
                options: DeckPrefetcher.screenDownloadOptions()
            ) { image, info in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: DeckPrefetcher.isCompleteScreenImage(image, info))
            }
        }
    }
}

/// Bytes the offline photos take: the available unsorted photos' original
/// sizes (PHAssetResource metadata) plus `WarmThumbCache`. Computed on a GCD
/// queue like `OfflineDownloader.loadSizes`, since the reads block and starve
/// the cooperative pool. `bytes` stays nil until the first answer, so the UI
/// shows "Checking" rather than a wrong number.
@MainActor
final class OfflineStorageMeter: ObservableObject {
    @Published private(set) var bytes: Int64?
    private var sizes: [String: Int64] = [:]
    private var generation = 0

    func update(ids: [String]) {
        generation += 1
        let myGeneration = generation
        let missing = ids.filter { sizes[$0] == nil }
        Task {
            let (loaded, warm) = await withCheckedContinuation { (cont: CheckedContinuation<([String: Int64], Int), Never>) in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: (OfflineDownloader.fileSizes(missing), WarmThumbCache.totalBytes()))
                }
            }
            sizes.merge(loaded) { _, new in new }
            // A newer update owns the answer; its own read will publish.
            guard myGeneration == generation else { return }
            bytes = ids.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) } + Int64(warm)
        }
    }
}
