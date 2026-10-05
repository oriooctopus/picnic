import Foundation
import SwiftData
import Photos

/// The PHAsset fields a mirror job needs, copied out so tests can build them
/// without a PhotoKit library.
struct MirrorAssetInfo {
    let localID: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isVideo: Bool
    let isLivePhoto: Bool
}

extension MirrorAssetInfo {
    init(_ asset: PHAsset) {
        self.init(
            localID: asset.localIdentifier, creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            isVideo: asset.mediaType == .video, isLivePhoto: asset.mediaSubtypes.contains(.photoLive)
        )
    }
}

/// Production existence check for resolving armed jobs at launch.
func existingPhotoAssetIDs(_ ids: [String]) -> Set<String> {
    guard !ids.isEmpty else { return [] }
    var found = Set<String>()
    PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
        found.insert(asset.localIdentifier)
    }
    return found
}

/// Persists mirror jobs so a failed POST is never silently dropped: it stays
/// "pending" in SwiftData and is retried the next time drainQueue() runs
/// (app launch or foreground — see PicnicApp.swift).
@MainActor
final class MirrorQueueStore: ObservableObject {
    private let context: ModelContext
    @Published var pendingCount: Int = 0
    /// Jobs parked as "failed" (permanent 4xx): shown with Retry/Discard, never dropped silently.
    @Published private(set) var failedCount: Int = 0
    @Published var lastError: String?
    // Last known-good GET /queue response. Deliberately never reset to nil
    // by a failed poll (see refreshServerStatus()) -- MirrorBannerLogic
    // treats nil as "never fetched successfully, ever", not "unknown right
    // now", so resetting it here would flash the server-backlog banner off
    // every time one poll drops a packet.
    @Published private(set) var serverStatus: MirrorQueueStatus?
    private var pollTask: Task<Void, Never>?
    // Injected so tests can drive drainQueue() with a controllable poster
    // instead of hitting the network; production uses MirrorClient.post.
    private let post: (MirrorJobRecord) async throws -> Void
    // Injected so tests can say which assets still exist; production asks PhotoKit.
    private let existingAssetIDs: ([String]) -> Set<String>
    // drainQueue() suspends at every POST, so a second call (foreground
    // drain overlapping the fire-and-forget one from a delete commit) would
    // otherwise fetch the same still-"pending" jobs and double-POST them.
    private var isDraining = false
    // Set by a call that arrives mid-drain: the in-flight pass already
    // fetched its job list, so a job enqueued since (e.g. a delete commit
    // during a hung foreground drain) would otherwise sit "pending" until
    // the next launch/foreground. Only an explicit request triggers another
    // pass -- a failed job never does, so a dead network can't spin.
    private var rerunRequested = false
    private var rerunIgnoresBackoff = false
    // Injected clock so backoff is testable.
    private let now: () -> Date
    // 5 minutes: the banner's own threshold is a full HOUR of backlog, so
    // polling faster than that buys no earlier signal, only battery/data.
    private static let pollIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    init(
        context: ModelContext,
        post: @escaping (MirrorJobRecord) async throws -> Void = MirrorClient.post(job:),
        existingAssetIDs: @escaping ([String]) -> Set<String> = existingPhotoAssetIDs,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.post = post
        self.existingAssetIDs = existingAssetIDs
        self.now = now
        refreshCount()
    }

    /// The delete commit's durable sequence: persist the mirror jobs "armed"
    /// (ignored by the drain), run `delete`, then flip them to "pending". If
    /// `delete` throws (user declined the system confirm, or it failed) the
    /// armed jobs are removed and the error rethrown. A kill between the
    /// delete and the flip leaves armed jobs that resolveArmedJobs() settles
    /// on next launch. Order is the whole point: enqueueing AFTER the delete
    /// loses the Google mirror if the app dies in between.
    ///
    /// filenames/thumbnails are keyed by localIdentifier and gathered by the
    /// caller BEFORE the delete (PhotoKit cannot produce an image afterwards);
    /// a missing thumbnail is a normal outcome, not something to retry.
    func deleteWithMirror(
        _ assets: [MirrorAssetInfo],
        filenames: [String: String],
        thumbnails: [String: String],
        delete: () async throws -> Void
    ) async throws {
        let ids = try arm(assets, filenames: filenames, thumbnails: thumbnails)
        do {
            try await delete()
        } catch {
            disarm(ids)
            throw error
        }
        promote(ids)
    }

    func arm(_ assets: [MirrorAssetInfo], filenames: [String: String], thumbnails: [String: String]) throws -> [UUID] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        var ids: [UUID] = []
        for asset in assets {
            let job = MirrorJobRecord(
                id: UUID(),
                filename: filenames[asset.localID] ?? asset.localID,
                creationDateISO8601: formatter.string(from: asset.creationDate ?? Date()),
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                mediaType: asset.isVideo ? "video" : "image",
                isLivePhoto: asset.isLivePhoto,
                status: "armed",
                thumbnailBase64: thumbnails[asset.localID],
                assetLocalID: asset.localID
            )
            context.insert(job)
            ids.append(job.id)
        }
        try context.save()
        return ids
    }

    /// Delete confirmed: armed -> pending, which makes the drain pick them up.
    func promote(_ ids: [UUID]) {
        for job in armedJobs() where ids.contains(job.id) { job.status = "pending" }
        try? context.save()
        refreshCount()
    }

    /// Delete declined or failed: the asset is still on the phone, drop the jobs.
    func disarm(_ ids: [UUID]) {
        for job in armedJobs() where ids.contains(job.id) { context.delete(job) }
        try? context.save()
    }

    /// Launch-time cleanup of armed jobs left by a kill mid-delete: asset gone
    /// from PhotoKit means the delete happened (-> pending, mirror it); asset
    /// still there means it did not (-> drop the job). Call once at launch,
    /// before drainQueue(). Does nothing unless access is FULL (.authorized):
    /// under .limited an asset outside the user's selection reads as "gone"
    /// though it is still on the phone, which would promote the job and mirror
    /// (and later trash in Google) a photo that was never deleted. Armed jobs
    /// simply stay armed until full access is granted.
    func resolveArmedJobs(authorization: PHAuthorizationStatus) {
        guard authorization == .authorized else { return }
        let armed = armedJobs()
        let present = existingAssetIDs(armed.compactMap(\.assetLocalID))
        for job in armed {
            if let id = job.assetLocalID, present.contains(id) {
                context.delete(job)
            } else {
                job.status = "pending"
            }
        }
        try? context.save()
        refreshCount()
    }

    private func armedJobs() -> [MirrorJobRecord] {
        let descriptor = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "armed" })
        return (try? context.fetch(descriptor)) ?? []
    }

    func refreshCount() {
        let descriptor = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "pending" })
        pendingCount = (try? context.fetchCount(descriptor)) ?? 0
        let failed = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "failed" })
        failedCount = (try? context.fetchCount(failed)) ?? 0
    }

    /// Retry on the user's say-so: failed jobs go back to pending (backoff and
    /// attempt count cleared) and a forced drain runs.
    func retryFailed() {
        for job in failedJobs() {
            job.status = "pending"
            job.attemptCount = 0
            job.nextAttemptAt = nil
            job.lastError = nil
        }
        try? context.save()
        refreshCount()
        scheduleDrain(ignoreBackoff: true)
    }

    /// The user's explicit choice to give up on mirroring these deletions.
    func discardFailed() {
        for job in failedJobs() { context.delete(job) }
        try? context.save()
        refreshCount()
    }

    private func failedJobs() -> [MirrorJobRecord] {
        let descriptor = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "failed" })
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fire-and-forget drain. The delete commit uses this instead of awaiting
    /// drainQueue(): each POST can hang up to URLSession's 60s timeout on a
    /// flaky network, and the deck must not stay locked in "committing" for
    /// that long -- the jobs are already persisted, so a slow drain only
    /// delays the mirror, never loses anything.
    func scheduleDrain(ignoreBackoff: Bool = false) {
        Task { await drainQueue(ignoreBackoff: ignoreBackoff) }
    }

    /// `ignoreBackoff`: network restored / user Retry, where waiting out a
    /// backoff that an outage caused would only delay the mirror.
    func drainQueue(ignoreBackoff: Bool = false) async {
        guard !isDraining else {
            rerunRequested = true
            if ignoreBackoff { rerunIgnoresBackoff = true }
            return
        }
        isDraining = true
        defer { isDraining = false }
        var ignore = ignoreBackoff
        repeat {
            rerunRequested = false
            if rerunIgnoresBackoff { ignore = true }
            rerunIgnoresBackoff = false
            await drainPass(ignoreBackoff: ignore)
        } while rerunRequested
    }

    private func drainPass(ignoreBackoff: Bool) async {
        let descriptor = FetchDescriptor<MirrorJobRecord>(
            predicate: #Predicate { $0.status == "pending" }, sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let jobs = try? context.fetch(descriptor), !jobs.isEmpty else { return }

        for job in jobs {
            if !ignoreBackoff, let next = job.nextAttemptAt, next > now() { continue }
            do {
                try await post(job)
                job.status = "sent"
                job.lastError = nil
                job.nextAttemptAt = nil
            } catch {
                // No defensive fallback: the failure is surfaced via
                // lastError/pendingCount/failedCount, never swallowed.
                job.attemptCount += 1
                job.lastError = "\(error)"
                lastError = "\(error)"
                let kind = JobRetryPolicy.classify(error)
                if kind == .permanent {
                    job.status = "failed"
                } else {
                    job.nextAttemptAt = now().addingTimeInterval(JobRetryPolicy.backoff(attempt: job.attemptCount))
                }
                // Offline/timeout: every remaining job would fail the same way
                // (and each costs a full request timeout), so end the pass.
                if kind == .transport { break }
            }
        }
        try? context.save()
        refreshCount()
    }

    /// One-shot GET /queue refresh. Called on foreground and by the
    /// periodic poll below; also safe to call ad hoc.
    func refreshServerStatus() async {
        do {
            serverStatus = try await MirrorClient.fetchStatus()
        } catch {
            // Printed, not stored: an unreachable status endpoint must not
            // paint a scary banner out of nothing (see MirrorBannerLogic),
            // but a bare `catch {}` here would hide a real outage from
            // anyone watching console output. serverStatus is left exactly
            // as it was -- it just goes stale until the next poll succeeds.
            print("MirrorQueueStore: status fetch failed: \(error)")
        }
    }

    /// Starts a low-frequency repeating poll of server status while the app
    /// is foregrounded (see PicnicApp.swift's scenePhase handling). Safe to
    /// call when already polling -- restarts from a fresh interval rather
    /// than stacking a second loop.
    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServerStatus()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    /// Cancels the periodic poll. Must be called on background/inactive --
    /// leaving the loop running would keep firing network requests against
    /// a suspended process's continuation the moment iOS resumes it.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
