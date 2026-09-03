import Foundation

enum MirrorClientError: Error, CustomStringConvertible {
    case badStatus(Int)

    var description: String {
        switch self {
        case .badStatus(let code): return "mirror server returned HTTP \(code)"
        }
    }
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
}
