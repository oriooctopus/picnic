import Foundation
import SwiftData
import Photos

/// Persists mirror jobs so a failed POST is never silently dropped: it stays
/// "pending" in SwiftData and is retried the next time drainQueue() runs
/// (app launch or foreground — see PicnicApp.swift).
@MainActor
final class MirrorQueueStore: ObservableObject {
    private let context: ModelContext
    @Published var pendingCount: Int = 0
    @Published var lastError: String?
    // Last known-good GET /queue response. Deliberately never reset to nil
    // by a failed poll (see refreshServerStatus()) -- MirrorBannerLogic
    // treats nil as "never fetched successfully, ever", not "unknown right
    // now", so resetting it here would flash the server-backlog banner off
    // every time one poll drops a packet.
    @Published private(set) var serverStatus: MirrorQueueStatus?
    private var pollTask: Task<Void, Never>?
    // 5 minutes: the banner's own threshold is a full HOUR of backlog, so
    // polling faster than that buys no earlier signal, only battery/data.
    private static let pollIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    init(context: ModelContext) {
        self.context = context
        refreshCount()
    }

    // thumbnails is keyed the same way filenames is (localIdentifier →
    // value) and is likewise gathered by the caller before the asset was
    // deleted — this method itself only ever sees already-deleted assets, so
    // it has no way to produce a thumbnail on its own. A missing entry (nil
    // via subscript below) means PhotoKit couldn't produce one; that's a
    // normal, expected outcome, not something to retry or flag here.
    func enqueue(assets: [PHAsset], filenames: [String: String], thumbnails: [String: String]) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]

        for asset in assets {
            let creationDate = asset.creationDate ?? Date()
            let job = MirrorJobRecord(
                id: UUID(),
                filename: filenames[asset.localIdentifier] ?? asset.localIdentifier,
                creationDateISO8601: formatter.string(from: creationDate),
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                mediaType: asset.mediaType == .video ? "video" : "image",
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                status: "pending",
                thumbnailBase64: thumbnails[asset.localIdentifier]
            )
            context.insert(job)
        }
        try? context.save()
        refreshCount()
    }

    func refreshCount() {
        let descriptor = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "pending" })
        pendingCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    func drainQueue() async {
        let descriptor = FetchDescriptor<MirrorJobRecord>(predicate: #Predicate { $0.status == "pending" })
        guard let jobs = try? context.fetch(descriptor), !jobs.isEmpty else { return }

        for job in jobs {
            do {
                try await MirrorClient.post(job: job)
                job.status = "sent"
                job.lastError = nil
            } catch {
                // No defensive fallback: leave it "pending" so it keeps
                // retrying, and surface the failure via lastError/pendingCount
                // rather than swallowing it.
                job.attemptCount += 1
                job.lastError = "\(error)"
                lastError = "\(error)"
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
