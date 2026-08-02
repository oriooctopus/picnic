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

    init(context: ModelContext) {
        self.context = context
        refreshCount()
    }

    func enqueue(assets: [PHAsset], filenames: [String: String]) {
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
                status: "pending"
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
}
