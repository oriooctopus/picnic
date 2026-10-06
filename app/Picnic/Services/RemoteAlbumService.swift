import Foundation

/// The server's two verdicts. Raw values are the wire strings the server's
/// DECISIONS set accepts (server/lib/album.mjs).
enum RemoteDecision: String, Codable, Equatable {
    case keep
    case skip
}

/// Server-computed totals, returned by GET /album/:id and POST .../decision.
/// The deck's "N kept · M left" counter reads these, never local state.
struct RemoteAlbumCounts: Codable, Equatable {
    let total: Int
    let keep: Int
    let skip: Int
    let undecided: Int
    let downloaded: Int
}

/// One album item with its thumbnail resolved to the SERVER'S cached copy
/// (never the raw Google URL, which is not reachable/authorized from the app).
struct RemoteAlbumItem: Equatable, Identifiable {
    let albumId: String
    let mediaKey: String
    let captureMs: Int64
    let width: Int
    let height: Int
    /// The server's stored decision at fetch time; nil = undecided.
    let decision: RemoteDecision?
    let thumbnailURL: URL

    var id: String { "gphotos:\(albumId):\(mediaKey)" }
    var creationDate: Date { Date(timeIntervalSince1970: TimeInterval(captureMs) / 1000) }
}

struct RemoteAlbumSnapshot {
    let counts: RemoteAlbumCounts
    /// Ordered by captureMs ascending (oldest first), the order the deck steps in.
    let items: [RemoteAlbumItem]
}

/// The two server calls the deck needs. A protocol only so the DEBUG fixture
/// (`--seed-remote-album`) can stand in for the network; production uses
/// `HTTPRemoteAlbumClient`.
protocol RemoteAlbumClient {
    func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot
    func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts
}

enum RemoteAlbumError: Error, CustomStringConvertible {
    case badStatus(Int)
    case undecodableImage

    var description: String {
        switch self {
        case .badStatus(let code): return "album server returned HTTP \(code)"
        case .undecodableImage: return "album server sent a thumbnail that is not an image"
        }
    }
}

/// Talks to the mirror server's /album/:id routes (server/queue-server.mjs).
/// Same host/port/bearer token as MirrorClient/ReconcileClient. Thumbnail GETs
/// authenticate with `?token=` (an image loader cannot send a header), the
/// JSON routes with the bearer header.
struct HTTPRemoteAlbumClient: RemoteAlbumClient {
    /// Wire shape of GET /album/:id items (AlbumStore.listItems). `thumbUrl`
    /// is the ORIGINAL Google URL and is ignored: the app only ever loads the
    /// server's cached copy via /album/:id/thumb/:mediaKey.
    private struct WireItem: Decodable {
        let mediaKey: String
        let width: Int?
        let height: Int?
        let captureMs: Int64
        let decision: RemoteDecision?
    }
    private struct WireAlbum: Decodable {
        let counts: RemoteAlbumCounts
        let items: [WireItem]
    }
    private struct WireDecisionResponse: Decodable {
        let counts: RemoteAlbumCounts
    }

    static func albumURL(albumId: String, path: String = "") -> URL {
        Config.reconcileURL(for: "/album/\(albumId)\(path)")
    }

    static func thumbnailURL(albumId: String, mediaKey: String) -> URL {
        Config.reconcileURL(for: "/album/\(albumId)/thumb/\(mediaKey)?token=\(MirrorToken.value)")
    }

    func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
        var request = URLRequest(url: Self.albumURL(albumId: albumId))
        // A 1605-item listing is far bigger than the tiny queue bodies
        // Config.requestTimeout was sized for, so it gets its own longer
        // limit. A guess, not a measurement.
        request.timeoutInterval = 30
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireOK(response)
        let wire = try JSONDecoder().decode(WireAlbum.self, from: data)
        let items = wire.items
            .sorted { $0.captureMs < $1.captureMs }
            .map { item in
                RemoteAlbumItem(
                    albumId: albumId, mediaKey: item.mediaKey, captureMs: item.captureMs,
                    width: item.width ?? 0, height: item.height ?? 0, decision: item.decision,
                    thumbnailURL: Self.thumbnailURL(albumId: albumId, mediaKey: item.mediaKey)
                )
            }
        return RemoteAlbumSnapshot(counts: wire.counts, items: items)
    }

    func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
        var request = URLRequest(url: Self.albumURL(albumId: albumId, path: "/decision"))
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mediaKey": mediaKey, "decision": decision.rawValue,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireOK(response)
        return try JSONDecoder().decode(WireDecisionResponse.self, from: data).counts
    }

    private static func requireOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteAlbumError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

/// What DeckViewModel talks to for a remote album. Errors propagate to the
/// caller (the deck shows them in an alert); there is deliberately no retry
/// queue — a failed decision is reverted locally and the user swipes again.
struct RemoteAlbumService {
    /// The one album this app triages today.
    static let oliverAlbumId = "oliver-album"

    let albumId: String
    let client: RemoteAlbumClient

    init(albumId: String, client: RemoteAlbumClient = HTTPRemoteAlbumClient()) {
        self.albumId = albumId
        self.client = client
    }

    /// The service the Utilities row opens. Under `--seed-remote-album`
    /// (DEBUG only) it is backed by the in-memory fixture instead of the
    /// network, so a UI test needs no server.
    static var oliverAlbum: RemoteAlbumService {
        #if DEBUG
        if RemoteAlbumFixtures.isSeeded {
            return RemoteAlbumService(albumId: oliverAlbumId, client: RemoteAlbumFixtures.sharedClient)
        }
        #endif
        return RemoteAlbumService(albumId: oliverAlbumId)
    }

    func load() async throws -> RemoteAlbumSnapshot {
        try await client.fetchAlbum(albumId: albumId)
    }

    func decide(mediaKey: String, _ decision: RemoteDecision) async throws -> RemoteAlbumCounts {
        try await client.postDecision(albumId: albumId, mediaKey: mediaKey, decision: decision)
    }
}
