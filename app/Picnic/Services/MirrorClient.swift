import Foundation

enum MirrorClientError: Error, CustomStringConvertible {
    case badStatus(Int)

    var description: String {
        switch self {
        case .badStatus(let code): return "mirror server returned HTTP \(code)"
        }
    }
}

/// Decoded slice of GET /queue's response -- only the fields the banner
/// needs, not the full job array (server/queue-server.mjs also returns up
/// to 50 recent jobs, which we deliberately don't model). `oldestQueuedWaitMs`
/// is nil exactly when the server reports no queued jobs at all.
struct MirrorQueueStatus: Decodable {
    struct Counts: Decodable { let queued: Int }
    struct AutoDrain: Decodable { let oldestQueuedWaitMs: Int? }

    let counts: Counts
    let autoDrain: AutoDrain
}

/// Talks to the picnic-mirror server's POST /queue endpoint. Fire-and-retry:
/// callers persist the job and only mark it sent after a 2xx response.
enum MirrorClient {
    static func post(job: MirrorJobRecord) async throws {
        var request = URLRequest(url: Config.mirrorQueueURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = [
            "filename": job.filename,
            "creationDate": job.creationDateISO8601,
            "pixelWidth": job.pixelWidth,
            "pixelHeight": job.pixelHeight,
            "mediaType": job.mediaType,
            "isLivePhoto": job.isLivePhoto,
        ]
        // Key omitted entirely (not sent as null) when there's no thumbnail —
        // a job PhotoKit couldn't produce one for is still a fully valid job,
        // and the server treats the field as optional.
        if let thumbnailBase64 = job.thumbnailBase64 {
            payload["thumbnailBase64"] = thumbnailBase64
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
    }

    /// GET /queue -- the server-side backlog status the device-side pending
    /// queue can't see (see MirrorSyncBanner.swift's header comment). Reuses
    /// the same endpoint POST uses rather than adding a new one; the ?token=
    /// query param that /issues and /thumb accept does NOT work here, this
    /// route only checks the bearer header (server/lib/auth.mjs).
    static func fetchStatus() async throws -> MirrorQueueStatus {
        var request = URLRequest(url: Config.mirrorQueueURL)
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MirrorClientError.badStatus(code)
        }
        return try JSONDecoder().decode(MirrorQueueStatus.self, from: data)
    }
}
