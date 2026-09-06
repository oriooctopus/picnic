import SwiftUI

/// Mirror-sync health banner. Two distinct problems can each cause a "your
/// deletions aren't actually backed up yet" state, and this banner covers
/// both -- but never both at once, see MirrorBannerLogic.state():
///
/// - Device-side: a failed mirror POST is never silently dropped, it stays
///   visible via `pendingCount` until it drains (the badge deletion-safety
///   requires).
/// - Server-side: the POST succeeded, but the server's own auto-drain
///   hasn't actually mirrored the file in over an hour. MirrorClient used to
///   have exactly one method (`post`) and the app never read server state,
///   so this half was completely invisible on the phone -- 65 jobs sat
///   queued server-side for 43 hours with the app showing nothing. See
///   MirrorClient.fetchStatus() / MirrorQueueStore.serverStatus.
struct MirrorSyncBanner: View {
    @EnvironmentObject var appState: AppState

    private var state: MirrorBannerState {
        MirrorBannerLogic.state(
            pendingCount: appState.mirrorQueue.pendingCount,
            lastError: appState.mirrorQueue.lastError,
            serverQueuedCount: appState.mirrorQueue.serverStatus?.counts.queued,
            oldestQueuedWaitMs: appState.mirrorQueue.serverStatus?.autoDrain.oldestQueuedWaitMs
        )
    }

    var body: some View {
        VStack {
            Spacer()
            switch state {
            case .none:
                EmptyView()
            case .devicePending(let count, let lastError):
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(count) not yet mirrored")
                    }
                    .font(.caption.bold())
                    if let lastError {
                        Text(lastError.prefix(80))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.orange.opacity(0.9)))
            case .serverBacklog(let count, let waitMs):
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text("\(count) photos waiting to mirror · \(Self.formatWait(waitMs))")
                }
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.orange.opacity(0.9)))
            }
        }
        .allowsHitTesting(false)
    }

    // Whole hours only -- this banner means "stuck a while", not a live
    // stopwatch; minute precision would just flicker on every 5-minute poll
    // without telling anyone anything more useful.
    private static func formatWait(_ ms: Int) -> String {
        "\(ms / 3_600_000)h"
    }
}
