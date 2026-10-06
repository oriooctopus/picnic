#if DEBUG
import Foundation
import UIKit

/// `--seed-remote-album`: a DEBUG-only, UI-test-only stand-in for the server so
/// the remote deck can be driven with no network. Same read-once launch-arg
/// pattern as ThumbnailLoader.simulatedUpdates / the --seed-* stages in
/// AppState. Compiled out of Release, so it can never fire on the owner's
/// installed build.
///
/// Decisions live in memory ONLY: nothing here touches the network, and the
/// only on-device write a remote swipe makes is the normal SortStore cache
/// (which the deck re-seeds from this fixture on every open).
enum RemoteAlbumFixtures {
    static let isSeeded = ProcessInfo.processInfo.arguments.contains("--seed-remote-album")
    static let itemCount = 12

    /// URL scheme for fixture thumbnails. ThumbnailLoader's URL path hands any
    /// "fixture" URL to `image(for:)` instead of URLSession.
    static let thumbnailScheme = "fixture"

    /// One client for the whole process so decisions survive closing and
    /// reopening the deck within a test run.
    static let sharedClient = FixtureRemoteAlbumClient(albumId: RemoteAlbumService.oliverAlbumId)

    static func thumbnailURL(mediaKey: String) -> URL {
        URL(string: "\(thumbnailScheme)://\(mediaKey)")!
    }

    /// Draws a labelled solid-color 600x800 card so each fixture is visually
    /// distinct and its number is readable in a screenshot.
    static func image(for url: URL) -> UIImage {
        let key = url.host ?? ""
        let index = Int(key.replacingOccurrences(of: "fixture", with: "")) ?? 0
        let size = CGSize(width: 600, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let hue = CGFloat((index * 37) % 100) / 100
            UIColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 220, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attrs)
        }
    }
}

/// In-memory RemoteAlbumClient. Mirrors the server contract: items ordered by
/// captureMs ascending, counts computed from decisions, `downloaded` always 0.
final class FixtureRemoteAlbumClient: RemoteAlbumClient {
    private let albumId: String
    private var decisions: [String: RemoteDecision] = [:]
    /// When set, the next postDecision throws it once. Lets a test (or manual
    /// run) exercise the error alert without a server.
    var nextDecisionError: Error?

    init(albumId: String) {
        self.albumId = albumId
    }

    private var items: [RemoteAlbumItem] {
        (0..<RemoteAlbumFixtures.itemCount).map { i in
            let key = "fixture\(i)"
            return RemoteAlbumItem(
                albumId: albumId, mediaKey: key,
                // One minute apart from a fixed base so the order is
                // deterministic regardless of when the test runs.
                captureMs: 1_700_000_000_000 + Int64(i) * 60_000,
                width: 600, height: 800, decision: decisions[key],
                thumbnailURL: RemoteAlbumFixtures.thumbnailURL(mediaKey: key)
            )
        }
    }

    private func counts() -> RemoteAlbumCounts {
        let keep = decisions.values.filter { $0 == .keep }.count
        let skip = decisions.values.filter { $0 == .skip }.count
        let total = RemoteAlbumFixtures.itemCount
        return RemoteAlbumCounts(total: total, keep: keep, skip: skip, undecided: total - keep - skip, downloaded: 0)
    }

    func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
        RemoteAlbumSnapshot(counts: counts(), items: items)
    }

    func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
        if let error = nextDecisionError {
            nextDecisionError = nil
            throw error
        }
        decisions[mediaKey] = decision
        return counts()
    }
}
#endif
