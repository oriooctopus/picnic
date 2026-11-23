import Foundation
import SwiftData
import Photos
import UIKit

/// One photo logged as an outfit. Doubles as the durable upload job and as the
/// "logged" marker: "an asset has a row that is not `removing`" is the
/// persisted logged set the deck button reads. A row goes away only once its
/// un-log DELETE succeeded (or on Discard of a failed upload). `opID` is
/// minted once per import and sent as X-Op-Id on every retry so the server
/// can dedupe.
@Model
final class OutfitImportJob {
    @Attribute(.unique) var assetID: String
    var opID: UUID
    /// YYYY-MM-DD in the device's local timezone, computed at tap time.
    var takenAt: String
    var createdAt: Date
    var attemptCount: Int
    var lastError: String?
    /// "pending" | "sent" | "failed" (a 4xx the server will never accept, or the
    /// photo is gone; parked until the user taps Retry or Discard) | "removing"
    /// (un-logged: DELETE /api/outfits/media/:id queued, row deleted on success)
    var status: String
    /// While "removing": the status to go back to if the user re-logs before
    /// the DELETE was sent (Undo), so an untouched import is not re-sent.
    /// Optional for lightweight migration.
    var statusBeforeRemove: String?
    /// Backoff gate, see MirrorJobRecord.nextAttemptAt. Optional for lightweight migration.
    var nextAttemptAt: Date?

    init(assetID: String, opID: UUID = UUID(), takenAt: String, status: String = "pending") {
        self.assetID = assetID
        self.opID = opID
        self.takenAt = takenAt
        self.createdAt = Date()
        self.attemptCount = 0
        self.status = status
    }
}

enum OutfitClientError: Error, CustomStringConvertible {
    case badStatus(Int)
    case assetMissing(String)
    case imageUnavailable(String)

    var description: String {
        switch self {
        case .badStatus(let code): return "outfits server returned HTTP \(code)"
        case .assetMissing(let id): return "no PHAsset for \(id)"
        case .imageUnavailable(let id): return "PhotoKit returned no image for \(id)"
        }
    }
}

/// POST /api/outfits/import: raw JPEG body, idempotent on X-Op-Id and media id.
/// 201 (new) and 200 (already existed) are both success.
struct OutfitUploader {
    var session: URLSession = .shared
    var url: URL = Config.outfitsImportURL
    var loadJPEG: (String) async throws -> Data = OutfitImageLoader.jpeg(forAssetID:)

    func request(for job: OutfitImportJob, jpeg: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.httpBody = jpeg
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(job.opID.uuidString, forHTTPHeaderField: "X-Op-Id")
        request.setValue(job.assetID, forHTTPHeaderField: "X-Media-Id")
        request.setValue(job.takenAt, forHTTPHeaderField: "X-Taken-At")
        return request
    }

    /// DELETE /api/outfits/media/:mediaId, the un-log. The server deletes the
    /// outfit imported from this photo and never 404s, so a replay is safe.
    /// The id holds "/" (PHAsset localIdentifier), hence the strict encoding.
    func removeRequest(for job: OutfitImportJob) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let id = job.assetID.addingPercentEncoding(withAllowedCharacters: allowed)!
        // `url` is .../api/outfits/import; its parent ends in "/".
        var request = URLRequest(url: URL(string: url.deletingLastPathComponent().absoluteString + "media/" + id)!)
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Derived from the import's op id but distinct from it: the server
        // records results per op id, and reusing the import's would replay the import.
        request.httpBody = try! JSONSerialization.data(withJSONObject: ["opId": "rm-\(job.opID.uuidString)"])
        return request
    }

    func remove(_ job: OutfitImportJob) async throws {
        let (_, response) = try await session.data(for: removeRequest(for: job))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OutfitClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func upload(_ job: OutfitImportJob) async throws {
        let jpeg = try await loadJPEG(job.assetID)
        let (_, response) = try await session.data(for: request(for: job, jpeg: jpeg))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 201 else {
            throw OutfitClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

/// PhotoKit side: JPEG, 1600px max long edge, iCloud download allowed.
enum OutfitImageLoader {
    static let maxLongEdge: CGFloat = 1600

    static func jpeg(forAssetID id: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw OutfitClientError.assetMissing(id)
        }
        let longEdge = CGFloat(max(asset.pixelWidth, asset.pixelHeight))
        let scale = min(1, maxLongEdge / longEdge)
        let target = CGSize(width: (CGFloat(asset.pixelWidth) * scale).rounded(),
                            height: (CGFloat(asset.pixelHeight) * scale).rounded())
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        let image: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
                cont.resume(returning: image)
            }
        }
        guard let image, let data = image.jpegData(compressionQuality: 0.85) else {
            throw OutfitClientError.imageUnavailable(id)
        }
        return data
    }
}

/// Durable "log as outfit" queue, same shape as MirrorQueueStore: a tap
/// persists a job, the upload runs async and a failed one stays "pending"
/// until the next drain (launch/foreground/next tap).
@MainActor
final class OutfitLogStore: ObservableObject {
    private let context: ModelContext
    private let upload: (OutfitImportJob) async throws -> Void
    private let remove: (OutfitImportJob) async throws -> Void
    /// How long an un-log waits before its DELETE may be sent. The deck's
    /// "Removed from Outfits | Undo" toast is up for less than this, so an
    /// Undo never reaches the server: a confirmed outfit with its pieces
    /// would otherwise come back only as a fresh, unconfirmed import.
    static let removeGrace: TimeInterval = 5
    @Published private(set) var loggedIDs: Set<String> = []
    /// Logged outfits whose upload has not succeeded yet (shown in the pending banner).
    @Published private(set) var pendingUploads: Int = 0
    /// Uploads parked as "failed": shown with Retry/Discard, never dropped silently.
    @Published private(set) var failedCount: Int = 0
    private var isDraining = false
    private var rerunRequested = false
    private var rerunIgnoresBackoff = false
    private let now: () -> Date

    init(
        context: ModelContext,
        upload: @escaping (OutfitImportJob) async throws -> Void = OutfitUploader().upload,
        remove: @escaping (OutfitImportJob) async throws -> Void = OutfitUploader().remove,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.upload = upload
        self.remove = remove
        self.now = now
        let all = (try? context.fetch(FetchDescriptor<OutfitImportJob>())) ?? []
        loggedIDs = Set(all.filter { $0.status != "removing" }.map(\.assetID))
        refreshCounts()
    }

    private func refreshCounts() {
        pendingUploads = count(status: "pending")
        failedCount = count(status: "failed")
    }

    private func count(status: String) -> Int {
        let descriptor = FetchDescriptor<OutfitImportJob>(predicate: #Predicate { $0.status == status })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Retry on the user's say-so: failed uploads go back to pending and a forced drain runs.
    func retryFailed() {
        for job in failedJobs() {
            job.status = "pending"
            job.attemptCount = 0
            job.nextAttemptAt = nil
            job.lastError = nil
        }
        try? context.save()
        refreshCounts()
        Task { await drainQueue(ignoreBackoff: true) }
    }

    /// The user's explicit choice to give up: the row goes, so the photo reads as not logged.
    func discardFailed() {
        for job in failedJobs() {
            loggedIDs.remove(job.assetID)
            context.delete(job)
        }
        try? context.save()
        refreshCounts()
    }

    private func failedJobs() -> [OutfitImportJob] {
        let descriptor = FetchDescriptor<OutfitImportJob>(predicate: #Predicate { $0.status == "failed" })
        return (try? context.fetch(descriptor)) ?? []
    }

    func isLogged(_ asset: PHAsset) -> Bool { loggedIDs.contains(asset.localIdentifier) }

    /// Marks the photo logged and persists its job immediately, then uploads
    /// in the background. No-op if already logged. Re-logging a photo whose
    /// un-log is still queued (Undo) restores its row instead: assetID is
    /// unique so there can't be a second row, and if the DELETE was never
    /// sent the server still has the outfit, so nothing needs re-sending.
    func log(assetID: String, takenAt: Date) {
        guard !loggedIDs.contains(assetID) else { return }
        if let job = job(for: assetID) {
            job.status = job.statusBeforeRemove ?? "pending"
            job.statusBeforeRemove = nil
            job.nextAttemptAt = nil
            try? context.save()
            loggedIDs.insert(assetID)
            refreshCounts()
            Task { await drainQueue() }
            return
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        context.insert(OutfitImportJob(assetID: assetID, takenAt: formatter.string(from: takenAt)))
        try? context.save()
        loggedIDs.insert(assetID)
        refreshCounts()
        Task { await drainQueue() }
    }

    /// Filled-hanger tap: un-log. The photo reads as not logged at once; the
    /// DELETE waits out `removeGrace` so the toast's Undo (log again) can
    /// cancel it locally. Durable across relaunch like any other job.
    func unlog(assetID: String) {
        guard loggedIDs.contains(assetID), let job = job(for: assetID) else { return }
        job.statusBeforeRemove = job.status
        job.status = "removing"
        job.attemptCount = 0
        job.nextAttemptAt = now().addingTimeInterval(Self.removeGrace)
        try? context.save()
        loggedIDs.remove(assetID)
        refreshCounts()
        Task {
            try? await Task.sleep(nanoseconds: UInt64((Self.removeGrace + 0.2) * 1_000_000_000))
            await drainQueue()
        }
    }

    private func job(for assetID: String) -> OutfitImportJob? {
        let descriptor = FetchDescriptor<OutfitImportJob>(predicate: #Predicate { $0.assetID == assetID })
        return try? context.fetch(descriptor).first
    }

    /// `ignoreBackoff`: network restored / user Retry. See MirrorQueueStore.drainQueue.
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
        let descriptor = FetchDescriptor<OutfitImportJob>(
            predicate: #Predicate { $0.status == "pending" || $0.status == "removing" }, sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let jobs = try? context.fetch(descriptor), !jobs.isEmpty else { return }
        for job in jobs {
            let removing = job.status == "removing"
            // An un-log's first wait is the Undo grace, which holds even on a
            // forced (network-restored / Retry) drain; later waits are backoff.
            let inGrace = removing && job.attemptCount == 0
            if !ignoreBackoff || inGrace, let next = job.nextAttemptAt, next > now() { continue }
            do {
                if removing {
                    try await remove(job)
                    if job.status == "removing" {
                        context.delete(job)
                    } else {
                        // Re-logged while the DELETE was in flight: the server just
                        // dropped the outfit, so import it again under a new op id.
                        job.opID = UUID()
                        job.status = "pending"
                        job.attemptCount = 0
                        job.nextAttemptAt = nil
                        rerunRequested = true
                    }
                    try? context.save()
                    refreshCounts()
                    continue
                }
                try await upload(job)
                // Load-bearing guard: an un-log tapped mid-upload set "removing";
                // overwriting it with "sent" would forget the removal.
                if job.status == "pending" { job.status = "sent" } else { job.statusBeforeRemove = "sent" }
                job.lastError = nil
                job.nextAttemptAt = nil
                // Durable per job: a kill mid-pass must not forget the 2xx and re-send it.
                try? context.save()
                refreshCounts()
            } catch {
                job.attemptCount += 1
                job.lastError = "\(error)"
                let kind = JobRetryPolicy.classify(error)
                // A refused un-log stays queued with backoff: parked as "failed" it
                // would sit under the upload Retry, which re-imports the photo.
                if kind == .permanent && job.status == "pending" {
                    job.status = "failed"
                } else {
                    job.nextAttemptAt = now().addingTimeInterval(JobRetryPolicy.backoff(attempt: job.attemptCount))
                }
                // See MirrorQueueStore.drainPass: offline ends the pass.
                try? context.save()
                if kind == .transport { break }
            }
        }
        try? context.save()
        refreshCounts()
    }

    func pendingCount() -> Int {
        let descriptor = FetchDescriptor<OutfitImportJob>(predicate: #Predicate { $0.status == "pending" })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}

/// Opens the Outfits app's review screen for a logged photo.
enum OutfitReview {
    static func url(forAssetID id: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return URL(string: "overland://outfits/media/\(id.addingPercentEncoding(withAllowedCharacters: allowed)!)")!
    }
}
