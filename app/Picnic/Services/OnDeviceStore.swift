import Foundation

/// Ids of unsorted photos known to be full-quality on this phone, kept across
/// launches.
///
/// Why: `OfflineMonthScanner` and `OfflineKeeper` kept their answers in memory,
/// so every cold launch re-probed the whole library (offline mode sat on
/// "Checking" with counts climbing from 0) and the keeper's background refill
/// had nothing to start from. Positives only: a negative goes stale the moment
/// the deck prefetcher downloads the photo, and the positives are the few
/// hundred that matter. Positives go stale too (iOS "Optimize Storage" evicts
/// originals), so the scanner re-verifies them each pass and `remove`s losers.
@MainActor
final class OnDeviceStore {
    private(set) var ids: Set<String>
    private let url: URL

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnDeviceIDs.json")
    }

    /// A missing file is a first launch. An unreadable one is data loss worth
    /// shouting about, then starts empty so the pass rebuilds it.
    init(url: URL = OnDeviceStore.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { ids = []; return }
        do {
            ids = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
        } catch {
            print("OnDeviceStore: could not read \(url.path), starting empty: \(error)")
            ids = []
        }
    }

    func add<S: Sequence>(_ new: S) where S.Element == String {
        let before = ids.count
        ids.formUnion(new)
        if ids.count != before { save() }
    }

    func remove<S: Sequence>(_ gone: S) where S.Element == String {
        let before = ids.count
        ids.subtract(gone)
        if ids.count != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ids.sorted()).write(to: url, options: .atomic)
        } catch {
            print("OnDeviceStore: FAILED to write \(url.path): \(error)")
        }
    }
}
