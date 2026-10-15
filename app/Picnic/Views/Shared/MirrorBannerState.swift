import Foundation

/// Which mirror-sync banner (if any) MirrorSyncBanner should render, as a
/// pure Foundation-only value -- no SwiftUI, no EnvironmentObject -- so the
/// decision itself is unit-testable independent of the view and the network
/// stack. MirrorSyncBanner owns the actual copy/styling; this only picks a
/// case.
enum MirrorBannerState: Equatable {
    case none
    /// Device-side outbound queue: jobs PhotoKit deleted locally that the
    /// app has not yet successfully POSTed to the server at all.
    case devicePending(count: Int, outfitCount: Int, lastError: String?)
    /// Jobs a server will never accept (4xx), parked until the user chooses
    /// Retry or Discard. Outranks everything: the only state that needs the
    /// user to act, and it is never dropped silently.
    case failedJobs(count: Int)
    /// Server-side queue: jobs the phone HAS posted that the server's
    /// auto-drain hasn't mirrored yet. Shown at any size, not only when
    /// stuck: deletes mirror asynchronously and the queue should be
    /// watchable while it drains. `isStuck` (oldest job waiting past
    /// serverBacklogThresholdMs) switches the banner to its warning style.
    /// See MirrorSyncBanner.swift's header comment for why pendingCount
    /// alone can't see this -- POST succeeding is not the same as the
    /// server having actually mirrored the file yet.
    case serverQueued(count: Int, waitMs: Int, isStuck: Bool)
}

enum MirrorBannerLogic {
    // 1 hour -- past this a queued job counts as stuck and the banner turns
    // into a warning. Named here (not inlined below) so the tests read as
    // testing the real constant, not a copy of the number.
    static let serverBacklogThresholdMs = 60 * 60 * 1000

    /// - Parameters:
    ///   - pendingCount: MirrorQueueStore.pendingCount (device-side).
    ///   - outfitPendingCount: OutfitLogStore.pendingUploads, shown in the
    ///     same device-pending banner (an outfit upload is also "not yet
    ///     delivered").
    ///   - failedCount: failed mirror + outfit + reconcile jobs.
    ///   - lastError: MirrorQueueStore.lastError, shown only alongside the
    ///     device-pending banner.
    ///   - serverQueuedCount: last known-good GET /queue counts.queued, or
    ///     nil if the status has never been fetched successfully -- server
    ///     unreachable since launch, or every poll so far has failed.
    ///     MirrorQueueStore.refreshServerStatus() deliberately never resets
    ///     an already-real value back to nil after a later failure, so nil
    ///     here specifically means "no real value, ever" -- a value that
    ///     has simply gone stale still comes through as non-nil.
    ///   - oldestQueuedWaitMs: last known-good autoDrain.oldestQueuedWaitMs,
    ///     same nil-means-never-fetched contract as serverQueuedCount.
    static func state(
        pendingCount: Int,
        outfitPendingCount: Int = 0,
        failedCount: Int = 0,
        lastError: String?,
        serverQueuedCount: Int?,
        oldestQueuedWaitMs: Int?
    ) -> MirrorBannerState {
        if failedCount > 0 {
            return .failedJobs(count: failedCount)
        }
        // Device-pending wins outright when both are true: it's a stronger,
        // more actionable signal (the app itself knows for certain these
        // haven't reached the server yet), and showing both at once would
        // read as two contradictory counts rather than one clear one.
        if pendingCount > 0 || outfitPendingCount > 0 {
            return .devicePending(count: pendingCount, outfitCount: outfitPendingCount, lastError: lastError)
        }
        guard let queued = serverQueuedCount, queued > 0 else {
            return .none
        }
        // The server sends oldestQueuedWaitMs null only when nothing is
        // queued; if it is ever missing with queued > 0, that only costs the
        // "stuck" styling, never the count itself.
        let waitMs = oldestQueuedWaitMs ?? 0
        return .serverQueued(count: queued, waitMs: waitMs, isStuck: waitMs > serverBacklogThresholdMs)
    }
}
