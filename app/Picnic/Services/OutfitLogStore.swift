import Foundation
import SwiftData
import Photos
import UIKit

/// One photo logged as an outfit. Doubles as the durable upload job and as the
/// "logged" marker: rows are never deleted, so "an asset has a row" is the
/// persisted logged set the deck button reads. `opID` is minted once and sent
/// as X-Op-Id on every retry so the server can dedupe.
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
    /// photo is gone; parked until the user taps Retry or Discard)
    var status: String
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
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.upload = upload
        self.now = now
        let all = (try? context.fetch(FetchDescriptor<OutfitImportJob>())) ?? []
        loggedIDs = Set(all.map(\.assetID))
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
    /// in the background. No-op if already logged.
    func log(assetID: String, takenAt: Date) {
        guard !loggedIDs.contains(assetID) else { return }
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

    /// Filled-button tap: the photo may have been deleted in Outfits, so queue
    /// a fresh import (new op id; the server returns the existing outfit or
    /// recreates it). Skipped while this asset's job is still pending. The row
    /// is reused because assetID is unique.
    func relog(assetID: String) {
        let descriptor = FetchDescriptor<OutfitImportJob>(predicate: #Predicate { $0.assetID == assetID })
        guard let job = try? context.fetch(descriptor).first, job.status != "pending" else { return }
        job.opID = UUID()
        job.status = "pending"
        job.attemptCount = 0
        job.lastError = nil
        job.nextAttemptAt = nil
        try? context.save()
        refreshCounts()
        Task { await drainQueue() }
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
            predicate: #Predicate { $0.status == "pending" }, sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let jobs = try? context.fetch(descriptor), !jobs.isEmpty else { return }
        for job in jobs {
            if !ignoreBackoff, let next = job.nextAttemptAt, next > now() { continue }
            do {
                try await upload(job)
                job.status = "sent"
                job.lastError = nil
                job.nextAttemptAt = nil
                // Durable per job: a kill mid-pass must not forget the 2xx and re-send it.
                try? context.save()
                refreshCounts()
            } catch {
                job.attemptCount += 1
                job.lastError = "\(error)"
                let kind = JobRetryPolicy.classify(error)
                if kind == .permanent {
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
