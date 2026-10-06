import Foundation
import Photos

/// What the swipe deck steps through: either a photo on this phone (PhotoKit)
/// or an item of a remote Google Photos album that is only known to the
/// server (cached thumbnail URL, no PHAsset). The deck used to be PHAsset-only;
/// this is the seam that lets the same deck triage both.
///
/// Every PHAsset-only feature (favorite, Live Photo, video playback/trim,
/// Compare groups, delete + mirror queue, share, outfit log) reaches its
/// asset through `phAsset`, which is nil for `.remote`, so each of those
/// sites has to decide explicitly what a remote item does — see the
/// "REMOTE GATE" comments in DeckViewModel/DeckView.
enum DeckItem: Identifiable, Equatable {
    case local(PHAsset)
    case remote(RemoteAlbumItem)

    /// SortStore key. Local: PHAsset.localIdentifier (unchanged, so every
    /// existing persisted record keeps resolving). Remote:
    /// "gphotos:<albumId>:<mediaKey>".
    var id: String {
        switch self {
        case .local(let asset): return asset.localIdentifier
        case .remote(let item): return item.id
        }
    }

    var creationDate: Date? {
        switch self {
        case .local(let asset): return asset.creationDate
        case .remote(let item): return item.creationDate
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// nil for remote items. The single door to PhotoKit-only behavior.
    var phAsset: PHAsset? {
        if case .local(let asset) = self { return asset }
        return nil
    }

    var remoteItem: RemoteAlbumItem? {
        if case .remote(let item) = self { return item }
        return nil
    }
}
