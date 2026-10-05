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
    /// Server-side backlog: jobs the phone HAS posted, but the server's
    /// auto-drain hasn't cleared in over an hour. See
    /// MirrorSyncBanner.swift's header comment for why pendingCount alone
    /// can't see this -- POST succeeding is not the same as the server
    /// having actually mirrored the file yet.
    case serverBacklog(count: Int, waitMs: Int)
}

enum MirrorBannerLogic {
    // 1 hour -- "backed up for more than an hour" is the goal's own
    // threshold. Named here (not inlined below) so the tests read as
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
        guard let queued = serverQueuedCount, let waitMs = oldestQueuedWaitMs,
              waitMs > serverBacklogThresholdMs else {
            return .none
        }
        return .serverBacklog(count: queued, waitMs: waitMs)
    }
}
