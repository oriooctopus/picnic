import Foundation
import Photos
import AVFoundation
import CryptoKit

/// One trimmed video waiting to be handed to the mirror server so Google
/// Photos can replace its stale full-length copy (Google never re-uploads
/// edits to an already-backed-up item; server/lib/replace.mjs does the
/// upload-then-trash). Persisted as `<id>.json` next to its `<id>.mov`.
struct TrimReplaceEntry: Codable, Equatable {
    /// Idempotency key sent as X-Replace-Id: the server collapses repeats of
    /// the same id, so a retry after a lost response never double-uploads.
    let id: String
    let localID: String
    /// The ORIGINAL file's name (IMG_1234.MOV): the worker finds the stale
    /// Google item by it.
    let filename: String
    let creationDateISO8601: String
    let pixelWidth: Int
    let pixelHeight: Int
    var attemptCount: Int = 0
    var nextAttemptAt: Date?
    /// Set when the server will never accept this entry (4xx, or the staged
    /// file vanished). Parked, never retried automatically, never dropped.
    var failedReason: String?
}

/// A trimmed video found by the launch backfill scan, with its rendered file
/// already copied somewhere the store can take ownership of (moved, not copied).
struct TrimBackfillCandidate {
    let entry: TrimReplaceEntry
    let file: URL
}

/// Durable, file-based queue of trim replacements. Files (not SwiftData) on
/// purpose: the payload is a multi-hundred-MB video that has to survive
/// relaunch in the app container anyway, and a sidecar manifest avoids a
/// SwiftData schema migration. The local copy is deleted ONLY after the server
/// answers 2xx (it has then stored the file on its own disk).
@MainActor
final class TrimReplaceStore: ObservableObject {
    nonisolated static let formatIdentifier = "com.oliverullman.picnic.trim"

    @Published private(set) var pendingCount = 0
    @Published private(set) var failedCount = 0

    private let directory: URL
    private let upload: (TrimReplaceEntry, URL) async throws -> Void
    private let now: () -> Date
    private var isDraining = false

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrimReplace", isDirectory: true)
    }

    init(
        directory: URL = TrimReplaceStore.defaultDirectory,
        upload: @escaping (TrimReplaceEntry, URL) async throws -> Void = TrimReplaceClient.upload,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.upload = upload
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refreshCounts()
    }

    private func manifestURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).mov") }
    private var doneURL: URL { directory.appendingPathComponent("done.json") }

    /// A fresh path inside the store's directory, so the trimmer can write its
    /// copy on the same volume and `enqueue` can move it instead of copying.
    func stagingURL() -> URL { directory.appendingPathComponent("staging-\(UUID().uuidString).mov") }

    // MARK: persistence

    func entries() -> [TrimReplaceEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "done.json" && $0.lastPathComponent != "scanned.json" }
            .compactMap { try? JSONDecoder().decode(TrimReplaceEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    private func save(_ entry: TrimReplaceEntry) throws {
        try JSONEncoder().encode(entry).write(to: manifestURL(entry.id), options: .atomic)
    }

    func doneIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: doneURL) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    private func markDone(_ id: String) throws {
        try JSONEncoder().encode(Array(doneIDs().union([id])).sorted()).write(to: doneURL, options: .atomic)
    }

    private func refreshCounts() {
        let all = entries()
        pendingCount = all.filter { $0.failedReason == nil }.count
        failedCount = all.count - pendingCount
    }

    // MARK: enqueue

    /// Takes ownership of `stagedFile` (moved into the store). Idempotent per
    /// entry id: an id that is already queued or already confirmed is ignored
    /// and the staged file removed.
    @discardableResult
    func enqueue(_ entry: TrimReplaceEntry, stagedFile: URL) throws -> Bool {
        if doneIDs().contains(entry.id) || FileManager.default.fileExists(atPath: manifestURL(entry.id).path) {
            try? FileManager.default.removeItem(at: stagedFile)
            return false
        }
        let destination = fileURL(entry.id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: stagedFile, to: destination)
        try save(entry)
        refreshCounts()
        return true
    }

    // MARK: drain

    /// Fire-and-forget drain right after an enqueue (the deck can't wait on a
    /// multi-minute upload); launch/foreground/network-restore drains go through
    /// JobRuntime's DrainCoordinator.
    func scheduleDrain() {
        Task { await drain() }
    }

    func drain(ignoreBackoff: Bool = false) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        for var entry in entries() where entry.failedReason == nil {
            if !ignoreBackoff, let next = entry.nextAttemptAt, next > now() { continue }
            let file = fileURL(entry.id)
            guard FileManager.default.fileExists(atPath: file.path) else {
                entry.failedReason = "the trimmed copy is missing from the app container"
                try? save(entry)
                continue
            }
            do {
                try await upload(entry, file)
                // 2xx: the server owns a copy now. Mark done BEFORE deleting so
                // a kill in between can never re-upload (the server dedups by id
                // anyway, but a re-upload of a big file is real cost).
                try markDone(entry.id)
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: manifestURL(entry.id))
            } catch {
                entry.attemptCount += 1
                let kind = JobRetryPolicy.classify(error)
                if kind == .permanent {
                    entry.failedReason = "\(error)"
                } else {
                    entry.nextAttemptAt = now().addingTimeInterval(JobRetryPolicy.backoff(attempt: entry.attemptCount))
                }
                try? save(entry)
                // Offline: the rest would fail the same way after a full timeout each.
                if kind == .transport { break }
            }
        }
        refreshCounts()
    }

    // MARK: backfill

    /// One-time-per-video launch scan: every video already carrying Picnic's
    /// trim adjustment that has no queued or confirmed replacement gets one
    /// (this is what fixes trims made before this feature existed). Idempotent:
    /// candidate ids are deterministic per (asset, adjustment), and a known id
    /// (queued OR confirmed) is skipped, so a second run enqueues nothing.
    func backfill(candidates: () async -> [TrimBackfillCandidate]) async {
        let known = doneIDs().union(entries().map(\.id))
        for candidate in await candidates() {
            if known.contains(candidate.entry.id) {
                try? FileManager.default.removeItem(at: candidate.file)
                continue
            }
            try? enqueue(candidate.entry, stagedFile: candidate.file)
        }
    }

    /// Deterministic idempotency id: same asset + same adjustment payload always
    /// gives the same id (hex, so it satisfies the server's [0-9A-Za-z-]{8,64}
    /// check). Used for BOTH a trim saved in the deck and the launch backfill,
    /// so the backfill finding a just-trimmed video never queues it twice.
    nonisolated static func replaceID(localID: String, adjustmentData: Data) -> String {
        let digest = SHA256.hash(data: Data(localID.utf8) + [0] + adjustmentData)
        return "tr-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func entry(id: String, asset: PHAsset) -> TrimReplaceEntry {
        TrimReplaceEntry(
            id: id,
            localID: asset.localIdentifier,
            // The ORIGINAL file's name, which is what Google Photos shows. After an
            // edit the resource list also holds the rendered .fullSizeVideo (named
            // like FullSizeRender.mov), so prefer the .video resource over `.first`
            // (the mirror delete path's originalFilename(for:), which runs pre-edit).
            filename: {
                let resources = PHAssetResource.assetResources(for: asset)
                return (resources.first { $0.type == .video } ?? resources.first)?.originalFilename ?? asset.localIdentifier
            }(),
            creationDateISO8601: ISO8601DateFormatter().string(from: asset.creationDate ?? Date(timeIntervalSince1970: 0)),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }
}

/// POST /replace: raw video bytes as the body (no base64), metadata in headers.
enum TrimReplaceClient {
    /// A trimmed video can be hundreds of MB over a home tailnet link; the 10s
    /// `Config.requestTimeout` meant for tiny JSON bodies would kill every upload.
    static let uploadTimeout: TimeInterval = 15 * 60

    static func request(for entry: TrimReplaceEntry) -> URLRequest {
        var request = URLRequest(url: Config.mirrorReplaceURL)
        request.timeoutInterval = uploadTimeout
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.setValue(entry.id, forHTTPHeaderField: "X-Replace-Id")
        // Percent-encoded: HTTP header values must be ASCII; the server decodes.
        request.setValue(
            entry.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? entry.filename,
            forHTTPHeaderField: "X-Filename"
        )
        request.setValue(entry.creationDateISO8601, forHTTPHeaderField: "X-Creation-Date")
        request.setValue(String(entry.pixelWidth), forHTTPHeaderField: "X-Pixel-Width")
        request.setValue(String(entry.pixelHeight), forHTTPHeaderField: "X-Pixel-Height")
        return request
    }

    /// Best-effort diagnostics (see TrimBackfillScanner.ScanRow): a failure to
    /// report must never affect the backfill, so errors are only printed.
    static func postScanReport(_ rows: [TrimBackfillScanner.ScanRow]) async {
        var request = URLRequest(url: Config.mirrorReplaceURL.deletingLastPathComponent().appendingPathComponent("trim-scan-report"))
        request.httpMethod = "POST"
        request.timeoutInterval = Config.requestTimeout
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(["videos": rows])
            _ = try await URLSession.shared.data(for: request)
        } catch {
            print("trim scan report failed: \(error)")
        }
    }

    static func upload(entry: TrimReplaceEntry, file: URL) async throws {
        let (_, response) = try await URLSession.shared.upload(for: request(for: entry), fromFile: file)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MirrorClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

/// PhotoKit side of the backfill: finds videos carrying the trim adjustment and
/// copies their current (trimmed) render out of the Photos library.
enum TrimBackfillScanner {
    /// One edited video as the scan saw it; POSTed to the server so a backfill
    /// that queues nothing can be diagnosed without the phone's sandbox.
    struct ScanRow: Codable {
        var asset: String          // last 8 chars of localIdentifier
        var created: String?
        var filename: String?
        var format: String?        // adjustment formatIdentifier, nil = none delivered
        var currentSec: Double
        var originalSec: Double?
        var verdict: String        // queued / skipped-<why> / error-<why>
    }

    /// A video is a trim candidate when Picnic trimmed it (our adjustment) or
    /// when ANY editor (Apple Photos' own Trim) left it clearly shorter than its
    /// original, because Google Photos ignores all edits equally. Edits that
    /// keep the duration (filters, crops) are not candidates, and slo-mo /
    /// time-lapse are excluded because their edit changes duration without trimming.
    static func isTrimCandidate(format: String?, currentSec: Double, originalSec: Double?, subtypes: PHAssetMediaSubtype) -> Bool {
        if format == TrimReplaceStore.formatIdentifier { return true }
        guard let originalSec, !subtypes.contains(.videoHighFrameRate), !subtypes.contains(.videoTimelapse) else { return false }
        return originalSec - currentSec > 1.0
    }

    /// Reading an adjustment needs a content-editing-input request per edited
    /// video, so remember each asset's modificationDate and skip it until that
    /// changes. Versioned filename: v1 (adjustmentData was never delivered
    /// because no canHandleAdjustmentData was set, so every video was stamped
    /// "inspected, nothing") must not block re-scans.
    @MainActor
    static func candidates(store: TrimReplaceStore, directory: URL = TrimReplaceStore.defaultDirectory) async -> [TrimBackfillCandidate] {
        let scannedURL = directory.appendingPathComponent("scanned-v2.json")
        var scanned = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: scannedURL))) ?? [:]
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let videos = PHAsset.fetchAssets(with: options)
        var toInspect: [(PHAsset, Double)] = []
        videos.enumerateObjects { asset, _, _ in
            // Cheap pre-filter: an edited video has a rendered full-size resource.
            guard PHAssetResource.assetResources(for: asset).contains(where: { $0.type == .fullSizeVideo }) else { return }
            let stamp = asset.modificationDate?.timeIntervalSince1970 ?? 0
            if scanned[asset.localIdentifier] == stamp { return }
            toInspect.append((asset, stamp))
        }
        var found: [TrimBackfillCandidate] = []
        var rows: [ScanRow] = []
        for (asset, stamp) in toInspect {
            let (row, candidate) = await inspect(asset, staging: store.stagingURL())
            rows.append(row)
            // Only remember assets that were actually decided: an iCloud-only
            // video (no network allowed here) is retried next launch.
            if !row.verdict.hasPrefix("error") { scanned[asset.localIdentifier] = stamp }
            if let candidate { found.append(candidate) }
        }
        try? JSONEncoder().encode(scanned).write(to: scannedURL, options: .atomic)
        if !rows.isEmpty { await TrimReplaceClient.postScanReport(rows) }
        return found
    }

    private static func inspect(_ asset: PHAsset, staging: URL) async -> (ScanRow, TrimBackfillCandidate?) {
        let resources = PHAssetResource.assetResources(for: asset)
        var row = ScanRow(
            asset: String(asset.localIdentifier.suffix(8)),
            created: asset.creationDate.map { ISO8601DateFormatter().string(from: $0) },
            filename: (resources.first { $0.type == .video } ?? resources.first)?.originalFilename,
            format: nil, currentSec: asset.duration, originalSec: nil, verdict: ""
        )
        let options = PHContentEditingInputRequestOptions()
        // Never trigger an iCloud download just to inspect an adjustment.
        options.isNetworkAccessAllowed = false
        // Without this, PhotoKit hides adjustmentData (and hands back the
        // rendered edit as if it were the original) for any adjustment the app
        // "can't handle". Say yes to all so the format id and the true original
        // are visible; nothing is edited here.
        var format: String?
        options.canHandleAdjustmentData = { data in format = data.formatIdentifier; return true }
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in continuation.resume(returning: input) }
        }
        guard let input else { row.verdict = "error-no-editing-input"; return (row, nil) }
        row.format = input.adjustmentData?.formatIdentifier ?? format
        if let original = input.audiovisualAsset, let d = try? await original.load(.duration) { row.originalSec = d.seconds }
        guard isTrimCandidate(format: row.format, currentSec: row.currentSec, originalSec: row.originalSec, subtypes: asset.mediaSubtypes) else {
            row.verdict = "skipped-not-a-trim"
            return (row, nil)
        }
        guard let rendered = resources.first(where: { $0.type == .fullSizeVideo }) else { row.verdict = "error-no-rendered-resource"; return (row, nil) }
        // The rendered (trimmed) bytes, whoever edited it: PHAssetResourceManager
        // reads exactly what Photos plays, local-only.
        let write = PHAssetResourceRequestOptions()
        write.isNetworkAccessAllowed = false
        let failure: Error? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: rendered, toFile: staging, options: write) { continuation.resume(returning: $0) }
        }
        if let failure { try? FileManager.default.removeItem(at: staging); row.verdict = "error-copy: \(failure.localizedDescription)"; return (row, nil) }
        row.verdict = "queued"
        let key = input.adjustmentData?.data ?? Data((row.format ?? "unknown").utf8)
        let id = TrimReplaceStore.replaceID(localID: asset.localIdentifier, adjustmentData: key)
        return (row, TrimBackfillCandidate(entry: TrimReplaceStore.entry(id: id, asset: asset), file: staging))
    }
}
