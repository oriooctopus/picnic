import Foundation
import SwiftData
import Photos

/// Durable "Clean up" confirm, same armed -> pending -> sent pattern as
/// MirrorQueueStore: the job is persisted BEFORE the phone delete so a kill or
/// an unreachable server between the delete and the Google trash POST cannot
/// lose the trash request. Anything that cannot run now re-runs on the next
/// launch/foreground via drain().
@MainActor
final class ReconcileConfirmStore: ObservableObject {
    /// Jobs parked as "failed": shown with Retry/Discard, never dropped silently.
    @Published private(set) var failedCount: Int = 0
    private let context: ModelContext
    private let send: (ReconcileConfirmJob) async throws -> Void
    private let existingAssetIDs: ([String]) -> Set<String>
    private var inFlight: Set<UUID> = []
    private let now: () -> Date

    init(
        context: ModelContext,
        send: @escaping (ReconcileConfirmJob) async throws -> Void = { job in
            _ = try await ReconcileClient.confirm(month: job.month, ids: job.googleIds, phoneDeleted: job.phoneIndexes)
        },
        existingAssetIDs: @escaping ([String]) -> Set<String> = existingPhotoAssetIDs,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.send = send
        self.existingAssetIDs = existingAssetIDs
        self.now = now
        refreshFailedCount()
    }

    func refreshFailedCount() {
        failedCount = jobs(status: "failed").count
    }

    /// Retry on the user's say-so: failed jobs go back to pending and are re-sent.
    func retryFailed() async {
        for job in jobs(status: "failed") {
            job.status = "pending"
            job.attemptCount = 0
            job.nextAttemptAt = nil
            job.lastError = nil
        }
        try? context.save()
        refreshFailedCount()
        await drain(ignoreBackoff: true)
    }

    /// The user's explicit choice to leave the Google copies untrashed.
    func discardFailed() {
        for job in jobs(status: "failed") { context.delete(job) }
        try? context.save()
        refreshFailedCount()
    }

    /// Arms the job, runs `deletePhone` (skipped when there are no phone
    /// photos), then promotes it. A throwing `deletePhone` removes the armed
    /// job and rethrows: nothing was deleted, so nothing may reach Google.
    func submit(
        month: String, googleIds: [String], phone: [(index: Int, assetID: String)],
        deletePhone: () async throws -> Void
    ) async throws -> UUID {
        let job = ReconcileConfirmJob(
            id: UUID(), month: month, googleIds: googleIds,
            phoneIndexes: phone.map(\.index), phoneAssetIDs: phone.map(\.assetID), status: "armed"
        )
        context.insert(job)
        try context.save()
        if !phone.isEmpty {
            do {
                try await deletePhone()
            } catch {
                context.delete(job)
                try? context.save()
                throw error
            }
        }
        job.status = "pending"
        try? context.save()
        return job.id
    }

    /// POSTs one pending job. Success marks it sent; failure leaves it pending
    /// (retried by drain) except a 4xx, which the server will never accept and
    /// is parked as "failed". Rethrows so the caller can show the error.
    func deliver(_ id: UUID) async throws {
        // A foreground drain (or the view's own deliver) already POSTing this job.
        guard !inFlight.contains(id),
              let job = jobs(status: "pending").first(where: { $0.id == id }) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            try await send(job)
            job.status = "sent"
            job.lastError = nil
            job.nextAttemptAt = nil
        } catch {
            job.attemptCount += 1
            job.lastError = "\(error)"
            if JobRetryPolicy.classify(error) == .permanent {
                job.status = "failed"
            } else {
                job.nextAttemptAt = now().addingTimeInterval(JobRetryPolicy.backoff(attempt: job.attemptCount))
            }
            try? context.save()
            refreshFailedCount()
            throw error
        }
        try? context.save()
    }

    /// Retries every pending job not already being delivered and not waiting
    /// out a backoff (unless `ignoreBackoff`: network restored / user Retry);
    /// stops at the first transport failure (offline: the rest would fail the
    /// same way).
    func drain(ignoreBackoff: Bool = false) async {
        for job in jobs(status: "pending") where !inFlight.contains(job.id) {
            if !ignoreBackoff, let next = job.nextAttemptAt, next > now() { continue }
            do {
                try await deliver(job.id)
            } catch {
                if JobRetryPolicy.classify(error) == .transport { break }
            }
        }
    }

    /// Launch-time cleanup of armed jobs left by a kill mid-delete: every phone
    /// asset gone means the delete happened (-> pending); any still present
    /// means it did not (-> drop). A job with no phone assets was Google-only
    /// and is simply promoted. Call once at launch, before drain(). Does
    /// nothing unless access is FULL (.authorized): under .limited an asset
    /// outside the selection reads as gone though it is still on the phone, and
    /// promoting would trash its Google copy. See MirrorQueueStore.resolveArmedJobs.
    func resolveArmedJobs(authorization: PHAuthorizationStatus) {
        guard authorization == .authorized else { return }
        for job in jobs(status: "armed") {
            if existingAssetIDs(job.phoneAssetIDs).isEmpty {
                job.status = "pending"
            } else {
                context.delete(job)
            }
        }
        try? context.save()
    }

    private func jobs(status: String) -> [ReconcileConfirmJob] {
        let descriptor = FetchDescriptor<ReconcileConfirmJob>(predicate: #Predicate { $0.status == status })
        return (try? context.fetch(descriptor)) ?? []
    }
}
