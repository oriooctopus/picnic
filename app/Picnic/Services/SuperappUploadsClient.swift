import Foundation

/// GET /superapp-uploads and POST /superapp-uploads/resolve on the mirror
/// server (same host and bearer token as MirrorClient).
enum SuperappUploadsClient {
    enum Action: String { case deleted, kept }

    static func fetch() async throws -> [SuperappUpload] {
        var request = URLRequest(url: Config.reconcileURL(for: "/superapp-uploads"))
        request.timeoutInterval = Config.requestTimeout
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        struct Body: Decodable { let uploads: [SuperappUpload] }
        return try JSONDecoder().decode(Body.self, from: data).uploads
    }

    static func resolve(ids: [String], action: Action) async throws {
        guard !ids.isEmpty else { return }
        var request = URLRequest(url: Config.reconcileURL(for: "/superapp-uploads/resolve"))
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": ids, "action": action.rawValue])
        let (_, response) = try await URLSession.shared.data(for: request)
        try check(response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MirrorClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}
