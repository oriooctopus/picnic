import SwiftUI

/// The remote album deck exactly as Utilities opens it, shared so the
/// cold-launch resume (MyLifeView) presents the identical screen. photoLibrary
/// and mirrorQueue are deliberately not passed: nothing in this deck can touch
/// PhotoKit or enqueue a mirror delete.
struct RemoteAlbumDeckCover: View {
    @EnvironmentObject var appState: AppState
    let service: RemoteAlbumService

    var body: some View {
        DeckView(viewModel: DeckViewModel(
            remoteAlbum: service,
            title: "Oliver! album",
            sortStore: appState.sortStore
        ))
        .environmentObject(appState)
        .environmentObject(appState.outfitLog)
    }
}

/// What a cold launch reopens: the remote album deck when the last swipe was
/// in it ("remote:<albumId>", see DeckViewModel.monthKey), else the My Life
/// month last swiped in, else the newest month.
enum AutoOpenTarget {
    case remoteAlbum(albumId: String)
    case month(MonthBucket)

    /// `buckets` is newest-first. A remote key resolves with no buckets at all.
    static func resolve(lastSwipedKey: String?, buckets: [MonthBucket]) -> AutoOpenTarget? {
        if let key = lastSwipedKey, key.hasPrefix(SortStore.remoteMonthKeyPrefix) {
            return .remoteAlbum(albumId: String(key.dropFirst(SortStore.remoteMonthKeyPrefix.count)))
        }
        guard let latest = buckets.first else { return nil }
        return .month(lastSwipedKey.flatMap { key in buckets.first { $0.key == key } } ?? latest)
    }
}
