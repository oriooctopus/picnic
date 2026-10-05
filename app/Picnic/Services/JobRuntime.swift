import Foundation
import Photos
import SwiftData

/// The composition root of the durable job queues: the three stores, the
/// DrainCoordinator that decides when they drain, and the triggers that feed
/// it (launch, foreground, network restored). Everything it talks to is
/// injected so the wiring itself (which store drains on which trigger, with
/// or without backoff) is covered by tests; AppState and PicnicApp only
/// forward events into it.
@MainActor
final class JobRuntime {
    let mirrorQueue: MirrorQueueStore
    let reconcileConfirm: ReconcileConfirmStore
    let outfitLog: OutfitLogStore
    let drainCoordinator: DrainCoordinator
    private let pathSource: NetworkPathSource

    init(
        context: ModelContext,
        pathSource: NetworkPathSource,
        mirrorPost: @escaping (MirrorJobRecord) async throws -> Void = MirrorClient.post(job:),
        reconcileSend: @escaping (ReconcileConfirmJob) async throws -> Void = { job in
            _ = try await ReconcileClient.confirm(month: job.month, ids: job.googleIds, phoneDeleted: job.phoneIndexes)
        },
        outfitUpload: @escaping (OutfitImportJob) async throws -> Void = OutfitUploader().upload,
        existingAssetIDs: @escaping ([String]) -> Set<String> = existingPhotoAssetIDs,
        fetchStatus: @escaping () async throws -> MirrorQueueStatus = MirrorClient.fetchStatus,
        now: @escaping () -> Date = Date.init
    ) {
        self.pathSource = pathSource
        let mirror = MirrorQueueStore(
            context: context, post: mirrorPost, existingAssetIDs: existingAssetIDs, now: now, fetchStatus: fetchStatus
        )
        let reconcile = ReconcileConfirmStore(
            context: context, send: reconcileSend, existingAssetIDs: existingAssetIDs, now: now
        )
        let outfit = OutfitLogStore(context: context, upload: outfitUpload, now: now)
        mirrorQueue = mirror
        reconcileConfirm = reconcile
        outfitLog = outfit
        drainCoordinator = DrainCoordinator(drain: { ignoreBackoff in
            async let m: Void = mirror.drainQueue(ignoreBackoff: ignoreBackoff)
            async let r: Void = reconcile.drain(ignoreBackoff: ignoreBackoff)
            async let o: Void = outfit.drainQueue(ignoreBackoff: ignoreBackoff)
            _ = await (m, r, o)
        })
    }

    /// Begins listening for network changes: a restored network drains everything.
    func start() {
        let coordinator = drainCoordinator
        pathSource.start { satisfied in
            Task { @MainActor in await coordinator.pathUpdated(satisfied: satisfied) }
        }
    }

    /// The whole launch sequence. Listens for network changes first; without
    /// photo access nothing is settled or drained, but later foreground events
    /// may drain; with it, `settleLibrary` runs (seeding, month load) and then
    /// the launch drain.
    func bootstrap(
        requestAuthorization: () async -> PHAuthorizationStatus,
        settleLibrary: () async -> Void
    ) async {
        start()
        let status = await requestAuthorization()
        guard status == .authorized || status == .limited else {
            launchWithoutDrain()
            return
        }
        await settleLibrary()
        await launch(authorization: status)
    }

    /// Bootstrap had no photo access: nothing to settle or drain, but later
    /// foreground events may drain.
    func launchWithoutDrain() {
        drainCoordinator.launchWithoutDrain()
    }

    /// Bootstrap's launch sequence once photo access is settled.
    func launch(authorization: PHAuthorizationStatus) async {
        // Settle armed jobs from a kill mid-delete BEFORE draining, so the ones
        // whose delete went through are mirrored on this very launch.
        mirrorQueue.resolveArmedJobs(authorization: authorization)
        reconcileConfirm.resolveArmedJobs(authorization: authorization)
        await drainCoordinator.drainAtLaunch()
        // Launch counts as a foreground: fetch once immediately rather than
        // waiting out the first poll interval, so a launch after hours in the
        // background does not show stale data for 5 minutes.
        await mirrorQueue.refreshServerStatus()
        mirrorQueue.startPolling()
    }

    /// The scene went active/inactive. Retry unsent jobs on launch/foreground/
    /// network-restore only (no background URLSession in v1); server-backlog
    /// polling follows the same rule and stops the moment we leave .active.
    func scenePhaseChanged(active: Bool) async {
        if active {
            mirrorQueue.startPolling()
            await drainCoordinator.sceneBecameActive()
            await mirrorQueue.refreshServerStatus()
        } else {
            mirrorQueue.stopPolling()
        }
    }
}
