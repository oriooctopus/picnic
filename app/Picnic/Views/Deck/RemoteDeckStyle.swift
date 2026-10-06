import SwiftUI
import UIKit

/// Every visual that sets the remote-album deck apart from the local deck,
/// defined once. The point is that a swipe never gets mistaken for the local
/// deck's destructive one: here right = "Keep & download" (queues a server
/// download), left = "Skip" (a plain decision, deletes nothing). The local
/// deck uses NONE of these; DeckView only reaches for them when
/// `viewModel.isRemote`.
enum RemoteDeckStyle {
    /// Cyan: nothing else in the app uses it (outfits are lilac, the toast
    /// check is mint green, trim is yellow, keep/archive are green/red), so
    /// the banner and card frame can't be confused with another mode.
    static let accentRGB: (r: Double, g: Double, b: Double) = (0.0, 0.82, 0.95)
    static let accent = Color(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b)
    static let accentUIColor = UIColor(red: accentRGB.r, green: accentRGB.g, blue: accentRGB.b, alpha: 1)

    /// Left-swipe wash/label color. Neutral gray rather than the local deck's
    /// red, because a remote skip is not a delete.
    static let skipColor = Color(white: 0.7)

    static let bannerText = "ALBUM · Oliver!"
    static let bannerSymbol = "cloud.fill"

    static let keepLabel = "Keep & download"
    static let skipLabel = "Skip"
    static let keepSymbol = "arrow.down.circle.fill"
    static let skipSymbol = "forward.fill"

    /// Card frame, drawn inside the UIKit card (PicnicSwipeCard) so it rides
    /// the Shuffle drag transform instead of staying behind as a SwiftUI
    /// overlay would.
    static let cardBorderWidth: CGFloat = 4
    static let cardCornerRadius: CGFloat = 24

    /// "N kept · M left", from the SERVER's counts (never local state).
    static func counterText(_ counts: RemoteAlbumCounts) -> String {
        "\(counts.keep) kept · \(counts.undecided) left"
    }

    static let bannerIdentifier = "deck.remoteBanner"
    static let counterIdentifier = "deck.remoteCounter"
    static let titleText = "Oliver! album (remote)"
}

/// Persistent strip at the top of a remote deck: cloud icon, "ALBUM · Oliver!",
/// and the server's kept/left counter. Tinted with the accent so it reads as a
/// different place at a glance.
struct RemoteDeckBanner: View {
    let counts: RemoteAlbumCounts?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: RemoteDeckStyle.bannerSymbol)
            Text(RemoteDeckStyle.bannerText)
                .accessibilityIdentifier(RemoteDeckStyle.bannerIdentifier)
            Spacer()
            if let counts {
                Text(RemoteDeckStyle.counterText(counts))
                    .accessibilityIdentifier(RemoteDeckStyle.counterIdentifier)
            }
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(RemoteDeckStyle.accent)
    }
}
