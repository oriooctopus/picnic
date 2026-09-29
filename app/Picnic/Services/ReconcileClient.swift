import Foundation

/// HTTP client and Decodable models for the mirror server's "Clean up
/// Google" reconcile endpoints. The server-side shapes are fixed in
/// SPEC.md (see the reconcile feature plan); these structs decode exactly
/// those fields and nothing more. All routes reuse the queue's bearer token
/// (`MirrorToken.value`) for the Authorization header, while the thumbnail
/// GET routes take the same token as a `?token=` query param (browser-facing
/// routes don't read the bearer header — see ReconcileCandidate.thumbnailURL).

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

/// GET /reconcile/:month — the server's verdict after diffing the on-phone
/// manifest against Google Photos. `status` is "scanning" until that diff is
/// ready, then "ready". `totalCandidates` counts Google photos with no match
/// on the phone (the "only in Google" set).
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
    /// entirely from the JSON decodes fine since this is Optional, and the
    /// default lets ReconcileSeed's memberwise-init call sites (never
    /// failed) skip passing it.
    let error: String? = nil
    let totalCandidates: Int
    let sections: ReconcileSections
}

/// The two review sections, split on whether the server believes the Google
/// photo came from this iPhone (`cameraModel != nil`) or not.
struct ReconcileSections: Decodable {
    let iphone: ReconcileSection
    let other: ReconcileSection
}

struct ReconcileSection: Decodable {
    let count: Int
    let candidates: [ReconcileCandidate]
}

struct ReconcileCandidate: Decodable, Identifiable {
    let id: String
    let filename: String
    /// nil exactly when the server couldn't match the photo to this iPhone —
    /// that's the signal driving the "other sources" section.
    let cameraModel: String?
    let captureDateMs: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbUrl: String
    /// "candidate" until the user acts; "kept"/"trashed" afterwards.
    let status: String

    /// Full thumbnail URL for AsyncImage. The thumbnail GET routes are the
    /// browser-facing kind that read the token from `?token=` rather than the
    /// Authorization header (mirroring how /issues and /thumb already work,
    /// per MirrorClient.fetchStatus's comment).
    var thumbnailURL: URL? {
        URL(string: "http://\(Config.mirrorHost):\(Config.mirrorPort)\(thumbUrl)?token=\(MirrorToken.value)")
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
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile"))
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

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
    }

    /// GET /reconcile/:month — the review screen's candidate source.
    static func fetchCandidates(month: String) async throws -> ReconcileResponse {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)"))
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        return try JSONDecoder().decode(ReconcileResponse.self, from: data)
    }

    /// POST /reconcile/:month/confirm — queues the selected candidates for
    /// trash. Returns the server-reported number of jobs actually queued.
    static func confirm(month: String, ids: [String]) async throws -> Int {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)/confirm"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        struct ConfirmResponse: Decodable { let queued: Int }
        return try JSONDecoder().decode(ConfirmResponse.self, from: data).queued
    }

    /// GET /reconcile/:month/results — per-candidate terminal state after
    /// the trash worker ran, polled by the review screen until `done`.
    static func fetchResults(month: String) async throws -> ReconcileResults {
        var request = URLRequest(url: Config.reconcileURL(for: "/reconcile/\(month)/results"))
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        return try JSONDecoder().decode(ReconcileResults.self, from: data)
    }
}
