import Foundation

/// HTTP client and Decodable models for the mirror server's "Clean up
/// Google" reconcile endpoints. The server-side shapes are fixed in
/// SPEC.md (see the reconcile feature plan); these structs decode exactly
/// those fields and nothing more. All routes reuse the queue's bearer token
/// (`MirrorToken.value`) for the Authorization header, while the thumbnail
/// GET routes take the same token as a `?token=` query param (browser-facing
/// routes don't read the bearer header — see ReconcileItem.thumbnailURL).

/// One asset entry in the POST /reconcile manifest body. Client-only: the
/// app builds it from PhotoKit (PhotoLibraryService.reconcileManifest) and
/// encodes it with JSONSerialization, same as MirrorClient.post does its job
/// payload — so it's a plain struct, not Codable.
struct ReconcileManifestAsset {
    let filename: String
    /// ISO 8601 with explicit time zone, matching MirrorQueueStore.enqueue's
    /// formatter (`.withInternetDateTime, .withTimeZone`) — the same string
    /// shape the /queue jobs already send, e.g. "2026-03-14T22:27:00Z".
    let creationDate: String
    let pixelWidth: Int
    let pixelHeight: Int
}

/// GET /reconcile/:month — the server's unified view of the month after
/// diffing the on-phone manifest against Google Photos. `status` is
/// "scanning" until that diff is ready, then "ready".
struct ReconcileResponse: Decodable {
    let month: String
    /// "scanning" | "ready" | "failed" (the finite lifecycle ReconcileStore's
    /// doc comment describes; "confirming"/"done" only ever appear on the
    /// separate GET /results shape). Decoded as a plain String, not an enum,
    /// so an unrecognized future value degrades to the scanning UI rather
    /// than a decode failure -- see ReconcileViewModel.pollUntilReady's
    /// `default:` case.
    let status: String
    /// Set only when status == "failed" (a worker crash -- see
    /// attachReconcileExitHandler on the server). nil otherwise; missing
    /// entirely from the JSON decodes fine since this is Optional. `var`, not
    /// `let`: a `let` with a default value is skipped by synthesized Decodable,
    /// which would silently drop the server's error text.
    var error: String? = nil
    /// Google photos with no phone match; during "scanning" this is the live
    /// found-so-far count shown on the scanning screen.
    let totalCandidates: Int
    /// Every photo of the month, sorted by capture time.
    var items: [ReconcileItem] = []
}

/// One photo in the unified review grid.
struct ReconcileItem: Decodable, Identifiable {
    /// Where the photo lives.
    enum Source: String, Decodable {
        /// On the phone AND in Google Photos.
        case both
        /// Only in Google Photos.
        case google
        /// Only on the phone (no Google match found).
        case phone
    }

    /// Google media key for `both`/`google`; "phone-<index>" for `phone`.
    let id: String
    let source: Source
    /// Position in the manifest the app posted, which is the month bucket's
    /// asset order (PhotoLibraryService.reconcileManifest). nil for `google`.
    let phoneIndex: Int?
    /// The phone's filename for `both`/`phone`; a display placeholder for `google`.
    let filename: String
    let captureDateMs: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    /// nil for `phone` items: the app renders those from PhotoKit.
    let thumbUrl: String?

    var onPhone: Bool { source != .google }
    var inGoogle: Bool { source != .phone }

    /// Full thumbnail URL for ReconcileReviewView's RemoteThumbImage. The thumbnail GET routes are the
    /// browser-facing kind that read the token from `?token=` rather than the
    /// Authorization header (mirroring how /issues and /thumb already work,
    /// per MirrorClient.fetchStatus's comment).
    var thumbnailURL: URL? {
        guard let thumbUrl else { return nil }
        return URL(string: "http://\(Config.mirrorHost):\(Config.mirrorPort)\(thumbUrl)?token=\(MirrorToken.value)")
    }
}

/// One entry of GET /reconcile/:month/results — the terminal state of a
/// single candidate after the trash worker ran.
struct ReconcileResultEntry: Decodable {
    let id: String
    /// "trashed" | "needs_review" | "queued"
    let status: String
}

struct ReconcileResults: Decodable {
    let month: String
    /// True once every queued candidate has reached a terminal state; the
    /// client polls until this flips rather than trusting the worker's
    /// timing.
    let done: Bool
    let results: [ReconcileResultEntry]
}

enum ReconcileClient {
    /// POST /reconcile — uploads the month's full on-phone manifest so the
    /// server can diff it against Google Photos. Fire-and-forget from the
    /// client's perspective: a non-2xx throws and the caller surfaces the
    /// error state rather than silently continuing with stale candidates.
    static func postManifest(month: String, assets: [ReconcileManifestAsset]) async throws {
        let request = try manifestRequest(month: month, assets: assets)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
    }

    static func manifestRequest(month: String, assets: [ReconcileManifestAsset]) throws -> URLRequest {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile"))
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "month": month,
            "assets": assets.map {
                [
                    "filename": $0.filename,
                    "creationDate": $0.creationDate,
                    "pixelWidth": $0.pixelWidth,
                    "pixelHeight": $0.pixelHeight,
                ]
            },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func candidatesRequest(month: String) -> URLRequest {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)"))
        request.timeoutInterval = Config.requestTimeout
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func resultsRequest(month: String) -> URLRequest {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)/results"))
        request.timeoutInterval = Config.requestTimeout
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// GET /reconcile/:month — the review screen's candidate source.
    static func fetchCandidates(month: String) async throws -> ReconcileResponse {
        let request = candidatesRequest(month: month)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        return try JSONDecoder().decode(ReconcileResponse.self, from: data)
    }

    /// POST /reconcile/:month/confirm — queues Google photos for trash.
    /// `phoneDeleted` lists the manifest indexes the app has ALREADY deleted
    /// from the phone; the server refuses (409) any `both` photo whose index
    /// is not listed, because the trash gate only trashes photos that are off
    /// the phone. Returns the server-reported number of jobs actually queued.
    static func confirm(month: String, ids: [String], phoneDeleted: [Int]) async throws -> Int {
        let request = try confirmRequest(month: month, ids: ids, phoneDeleted: phoneDeleted)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        struct ConfirmResponse: Decodable { let queued: Int }
        return try JSONDecoder().decode(ConfirmResponse.self, from: data).queued
    }

    static func confirmRequest(month: String, ids: [String], phoneDeleted: [Int]) throws -> URLRequest {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)/confirm"))
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids, "phoneDeleted": phoneDeleted])
        return request
    }

    /// GET /reconcile/:month/results — per-candidate terminal state after
    /// the trash worker ran, polled by the review screen until `done`.
    static func fetchResults(month: String) async throws -> ReconcileResults {
        let request = resultsRequest(month: month)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        return try JSONDecoder().decode(ReconcileResults.self, from: data)
    }
}
