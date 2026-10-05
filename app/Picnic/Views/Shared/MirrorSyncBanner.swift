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

    var body: some View {
        // The stores are separate ObservableObjects, so the content view
        // observes them directly: reading `appState.mirrorQueue.pendingCount`
        // here would not re-render when the count changes (AppState does not
        // republish its children).
        MirrorSyncBannerContent(
            mirror: appState.mirrorQueue,
            reconcile: appState.reconcileConfirm,
            outfit: appState.outfitLog
        )
    }
}

private struct MirrorSyncBannerContent: View {
    @ObservedObject var mirror: MirrorQueueStore
    @ObservedObject var reconcile: ReconcileConfirmStore
    @ObservedObject var outfit: OutfitLogStore
    @State private var showingFailedActions = false

    private var failedTotal: Int { mirror.failedCount + reconcile.failedCount + outfit.failedCount }

    private var state: MirrorBannerState {
        MirrorBannerLogic.state(
            pendingCount: mirror.pendingCount,
            outfitPendingCount: outfit.pendingUploads,
            failedCount: failedTotal,
            lastError: mirror.lastError,
            serverQueuedCount: mirror.serverStatus?.counts.queued,
            oldestQueuedWaitMs: mirror.serverStatus?.autoDrain.oldestQueuedWaitMs
        )
    }

    var body: some View {
        VStack {
            Spacer()
            switch state {
            case .none:
                EmptyView()
            case .failedJobs(let count):
                Button { showingFailedActions = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(count) \(count == 1 ? "sync" : "syncs") failed · tap to retry or discard")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                }
                .accessibilityIdentifier("failedSyncBanner")
                .confirmationDialog(
                    "The server rejected \(count) \(count == 1 ? "sync" : "syncs")",
                    isPresented: $showingFailedActions, titleVisibility: .visible
                ) {
                    Button("Retry") {
                        mirror.retryFailed()
                        outfit.retryFailed()
                        Task { await reconcile.retryFailed() }
                    }
                    Button("Discard", role: .destructive) {
                        mirror.discardFailed()
                        outfit.discardFailed()
                        reconcile.discardFailed()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Discard gives up: deleted photos will not be mirrored to Google.")
                }
            case .devicePending(let count, let outfitCount, let lastError):
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(Self.pendingText(count: count, outfitCount: outfitCount))
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
                .allowsHitTesting(false)
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
                .allowsHitTesting(false)
            }
        }
    }

    static func pendingText(count: Int, outfitCount: Int) -> String {
        var parts: [String] = []
        if count > 0 { parts.append("\(count) not yet mirrored") }
        if outfitCount > 0 { parts.append("\(outfitCount) \(outfitCount == 1 ? "outfit" : "outfits") not yet uploaded") }
        return parts.joined(separator: " · ")
    }

    // Whole hours only -- this banner means "stuck a while", not a live
    // stopwatch; minute precision would just flicker on every 5-minute poll
    // without telling anyone anything more useful.
    private static func formatWait(_ ms: Int) -> String {
        "\(ms / 3_600_000)h"
    }
}
