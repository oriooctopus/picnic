import Foundation
import SwiftData

/// Durable "Clean up" confirm, same armed -> pending -> sent pattern as
/// MirrorQueueStore: the job is persisted BEFORE the phone delete so a kill or
/// an unreachable server between the delete and the Google trash POST cannot
/// lose the trash request. Anything that cannot run now re-runs on the next
/// launch/foreground via drain().
@MainActor
final class ReconcileConfirmStore {
    private let context: ModelContext
    private let send: (ReconcileConfirmJob) async throws -> Void
    private let existingAssetIDs: ([String]) -> Set<String>
    private var inFlight: Set<UUID> = []

    init(
        context: ModelContext,
        send: @escaping (ReconcileConfirmJob) async throws -> Void = { job in
            _ = try await ReconcileClient.confirm(month: job.month, ids: job.googleIds, phoneDeleted: job.phoneIndexes)
        },
        existingAssetIDs: @escaping ([String]) -> Set<String> = existingPhotoAssetIDs
    ) {
        self.context = context
        self.send = send
        self.existingAssetIDs = existingAssetIDs
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
        guard let job = jobs(status: "pending").first(where: { $0.id == id }) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            try await send(job)
            job.status = "sent"
            job.lastError = nil
        } catch {
            job.attemptCount += 1
            job.lastError = "\(error)"
            if case MirrorClientError.badStatus(let code) = error, (400..<500).contains(code) {
                job.status = "failed"
            }
            try? context.save()
            throw error
        }
        try? context.save()
    }

    /// Retries every pending job not already being delivered.
    func drain() async {
        for job in jobs(status: "pending") where !inFlight.contains(job.id) {
            try? await deliver(job.id)
        }
    }

    /// Launch-time cleanup of armed jobs left by a kill mid-delete: every phone
    /// asset gone means the delete happened (-> pending); any still present
    /// means it did not (-> drop). A job with no phone assets was Google-only
    /// and is simply promoted. Call once at launch, before drain().
    func resolveArmedJobs() {
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
