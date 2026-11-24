import Foundation

/// App-wide offline mode: the same persisted flag as the deck's "offline only"
/// toggle (`DeckViewModel.offlineOnlyDefaultsKey`), so turning it on in My Life
/// also filters every deck, and turning it off in a deck's popover un-filters
/// the grid. One flag on purpose: two flags would let the grid say "ready
/// offline" while the deck still showed iCloud-only cards, which is exactly the
/// "have to think about it" state this mode exists to remove.
///
/// On the grid it keeps only months with at least one unsorted item that is
/// on the phone: either finished by the offline downloader
/// (`OfflineDownloader.completed`) or found by `OfflineMonthScanner`'s
/// network-off probe. The downloader list alone was the first version and
/// showed "Nothing downloaded" on a phone whose photos were mostly local but
/// had never gone through the Download screen.
enum OfflineMode {
    /// Unsorted, downloaded item counts per month key, for months that have at
    /// least one. Manually sorted months are skipped (the deck treats the whole
    /// month as done). Pure so it is unit-testable without PHAssets.
    static func readyCounts(
        months: [(key: String, ids: [String])],
        isMonthSorted: (String) -> Bool,
        isUnsorted: (String) -> Bool,
        isDownloaded: (String) -> Bool
    ) -> [String: Int] {
        var out: [String: Int] = [:]
        for month in months where !isMonthSorted(month.key) {
            let n = month.ids.reduce(0) { $0 + (isUnsorted($1) && isDownloaded($1) ? 1 : 0) }
            if n > 0 { out[month.key] = n }
        }
        return out
    }
}
