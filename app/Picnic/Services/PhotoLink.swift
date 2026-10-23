import UIKit

/// `picnic://photo/<localIdentifier>` — a link that reopens one library photo
/// in Picnic, so it can be pasted into a to-do or note.
enum PhotoLink {
    private static let scheme = "picnic"
    private static let host = "photo"
    // localIdentifier looks like "ABC-123/L0/001"; its slashes must be
    // escaped or they would read as extra path segments.
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func url(forAssetID id: String) -> URL {
        URL(string: "\(scheme)://\(host)/\(id.addingPercentEncoding(withAllowedCharacters: allowed)!)")!
    }

    static func assetID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        // url.path decodes %2F back into "/", so take the raw path instead.
        let raw = url.path
        guard raw.count > 1 else { return nil }
        return String(raw.dropFirst()).removingPercentEncoding
    }
}

/// Share-sheet action that copies the photo's `PhotoLink` to the clipboard.
final class CopyPhotoLinkActivity: UIActivity {
    private let link: URL

    init(assetID: String) {
        link = PhotoLink.url(forAssetID: assetID)
    }

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("com.oliverullman.picnic.copyLink") }
    override var activityTitle: String? { "Copy Picnic Link" }
    override var activityImage: UIImage? { UIImage(systemName: "link") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        UIPasteboard.general.string = link.absoluteString
        activityDidFinish(true)
    }
}
