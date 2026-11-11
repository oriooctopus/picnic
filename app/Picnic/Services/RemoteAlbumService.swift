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

    /// These counts with one item moved from `previous` (nil = undecided) to
    /// `decision`. Used for a decision the server has not seen yet (made
    /// offline), so the "N kept · M left" counter still moves on each swipe.
    func applying(_ decision: RemoteDecision, replacing previous: RemoteDecision?) -> RemoteAlbumCounts {
        func delta(_ d: RemoteDecision?) -> Int { (decision == d ? 1 : 0) - (previous == d ? 1 : 0) }
        return RemoteAlbumCounts(total: total, keep: keep + delta(.keep), skip: skip + delta(.skip),
                                 undecided: undecided + delta(nil), downloaded: downloaded)
    }
}

/// Wire strings of the server's item `kind` (server/lib/album.mjs KINDS).
enum RemoteMediaKind: String, Codable, Equatable {
    case photo
    case video
}

/// Kept range of a remote video, seconds (wire shape of the server's trim).
struct RemoteTrim: Codable, Equatable {
    let startSec: Double
    let endSec: Double
}

/// One album item with its thumbnail resolved to the SERVER'S cached copy
/// (never the raw Google URL, which is not reachable/authorized from the app).
struct RemoteAlbumItem: Equatable, Identifiable, Codable {
    let albumId: String
    let mediaKey: String
    let captureMs: Int64
    let width: Int
    let height: Int
    /// The server's stored decision at fetch time; nil = undecided.
    let decision: RemoteDecision?
    let thumbnailURL: URL
    let kind: RemoteMediaKind
    /// Playable mp4 on the server; nil for a photo AND for a video the server
    /// has not cached yet (`hasVideo` false), which the deck shows as a still
    /// with a disabled play control.
    let videoURL: URL?
    /// Saved kept-range of a video (server trims.json); nil = untrimmed. The
    /// server applies it only at download time, the app uses it to loop the
    /// preview and to reopen the trim bar on the saved range.
    let trim: RemoteTrim?
    /// Card-size (<=2048px) rendition on the server; nil while the server has
    /// not cached it yet (`hasDisplay` false). The card shows `thumbnailURL`
    /// (512px, soft on a phone) until this exists, then this. A real
    /// "not cached yet" state, like local low-res-then-high-res loading.
    let displayURL: URL?

    init(albumId: String, mediaKey: String, captureMs: Int64, width: Int, height: Int,
         decision: RemoteDecision?, thumbnailURL: URL,
         kind: RemoteMediaKind = .photo, videoURL: URL? = nil, trim: RemoteTrim? = nil,
         displayURL: URL? = nil) {
        self.albumId = albumId
        self.mediaKey = mediaKey
        self.captureMs = captureMs
        self.width = width
        self.height = height
        self.decision = decision
        self.thumbnailURL = thumbnailURL
        self.kind = kind
        self.videoURL = videoURL
        self.trim = trim
        self.displayURL = displayURL
    }

    var isVideo: Bool { kind == .video }

    var id: String { "gphotos:\(albumId):\(mediaKey)" }
    var creationDate: Date { Date(timeIntervalSince1970: TimeInterval(captureMs) / 1000) }
}

/// Codable so the last listing can be saved to disk for offline opens.
struct RemoteAlbumSnapshot: Codable {
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
    func postTrim(albumId: String, mediaKey: String, trim: RemoteTrim) async throws
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
        let kind: RemoteMediaKind
        let hasVideo: Bool
        let trim: RemoteTrim?
        /// Optional only because the app (OTA) and the server deploy
        /// separately: a server from before the display rendition omits the
        /// key, and that must read as "no display yet", not fail the whole
        /// listing decode.
        let hasDisplay: Bool?
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

    static func displayURL(albumId: String, mediaKey: String) -> URL {
        Config.reconcileURL(for: "/album/\(albumId)/display/\(mediaKey)?token=\(MirrorToken.value)")
    }

    static func videoURL(albumId: String, mediaKey: String) -> URL {
        Config.reconcileURL(for: "/album/\(albumId)/video/\(mediaKey)?token=\(MirrorToken.value)")
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
        return try Self.decodeSnapshot(data, albumId: albumId)
    }

    /// GET /album/:id body -> snapshot. Split out so a unit test can feed it
    /// real wire JSON (kind / hasVideo handling) without a network.
    static func decodeSnapshot(_ data: Data, albumId: String) throws -> RemoteAlbumSnapshot {
        let wire = try JSONDecoder().decode(WireAlbum.self, from: data)
        let items = wire.items
            .sorted { $0.captureMs < $1.captureMs }
            .map { item in
                RemoteAlbumItem(
                    albumId: albumId, mediaKey: item.mediaKey, captureMs: item.captureMs,
                    width: item.width ?? 0, height: item.height ?? 0, decision: item.decision,
                    thumbnailURL: thumbnailURL(albumId: albumId, mediaKey: item.mediaKey),
                    kind: item.kind,
                    videoURL: item.hasVideo ? videoURL(albumId: albumId, mediaKey: item.mediaKey) : nil,
                    trim: item.trim,
                    displayURL: item.hasDisplay == true ? displayURL(albumId: albumId, mediaKey: item.mediaKey) : nil
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

    func postTrim(albumId: String, mediaKey: String, trim: RemoteTrim) async throws {
        var request = URLRequest(url: Self.albumURL(albumId: albumId, path: "/trim/\(mediaKey)"))
        request.timeoutInterval = Config.requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(MirrorToken.value)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(trim)
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.requireOK(response)
    }

    private static func requireOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteAlbumError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

/// A decision made while the server was unreachable, waiting to be POSTed.
struct PendingRemoteDecision: Codable, Equatable {
    let mediaKey: String
    let decision: RemoteDecision
}

/// True for a failure that means "could not reach the server" (offline,
/// timeout, tailnet down), as opposed to the server answering with an error
/// (`RemoteAlbumError.badStatus`). Only the first kind is queued for later:
/// a server that answered and refused will refuse again.
func isUnreachable(_ error: Error) -> Bool { error is URLError }

/// What DeckViewModel talks to for a remote album.
///
/// Offline support (swiping on the subway): every successful listing is
/// saved to disk and served instead when the server is unreachable, and a
/// decision that could not reach the server goes to a durable outbox
/// (`pending.json`) that `flushPending` POSTs once the server answers again.
/// The card images themselves are already on disk via RemoteDisplayCache
/// (DeckPrefetcher fills it 750 cards ahead while the deck is open online).
/// A decision the server answered with an error still propagates to the
/// caller, which reverts it (the server is the source of truth).
struct RemoteAlbumService {
    /// The one album this app triages today.
    static let oliverAlbumId = "oliver-album"

    let albumId: String
    let client: RemoteAlbumClient
    /// Holds `listing.json` and `pending.json`. Application Support, not
    /// Caches: iOS may purge Caches under disk pressure, and the outbox holds
    /// swipes that exist nowhere else.
    let storageDirectory: URL

    init(albumId: String, client: RemoteAlbumClient = HTTPRemoteAlbumClient(), storageDirectory: URL? = nil) {
        self.albumId = albumId
        self.client = client
        self.storageDirectory = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("remote-album/\(albumId)", isDirectory: true)
    }

    /// Service for a "remote:<albumId>" resume key's album id.
    static func service(albumId: String) -> RemoteAlbumService {
        albumId == oliverAlbumId ? oliverAlbum : RemoteAlbumService(albumId: albumId)
    }

    /// The service the Utilities row opens. Under `--seed-remote-album`
    /// (DEBUG only) it is backed by the in-memory fixture instead of the
    /// network, so a UI test needs no server.
    static var oliverAlbum: RemoteAlbumService {
        #if DEBUG
        if RemoteAlbumFixtures.isSeeded {
            // Fresh temp dir per launch: a fixture run must never see a
            // listing or outbox left by a previous test.
            return RemoteAlbumService(albumId: oliverAlbumId, client: RemoteAlbumFixtures.sharedClient,
                                      storageDirectory: RemoteAlbumFixtures.storageDirectory)
        }
        #endif
        return RemoteAlbumService(albumId: oliverAlbumId)
    }

    private var listingFile: URL { storageDirectory.appendingPathComponent("listing.json") }
    private var pendingFile: URL { storageDirectory.appendingPathComponent("pending.json") }

    /// The server's listing (saved to disk on success), or, when the server is
    /// unreachable, the last saved listing with `isCached` true. Throws when
    /// unreachable with nothing saved yet, or when the server answers with an
    /// error (a cached listing would hide a real server problem).
    func load() async throws -> (snapshot: RemoteAlbumSnapshot, isCached: Bool) {
        do {
            let snapshot = try await client.fetchAlbum(albumId: albumId)
            try write(snapshot, to: listingFile)
            return (snapshot, false)
        } catch where isUnreachable(error) {
            guard FileManager.default.fileExists(atPath: listingFile.path) else { throw error }
            let data = try Data(contentsOf: listingFile)
            return (try JSONDecoder().decode(RemoteAlbumSnapshot.self, from: data), true)
        }
    }

    /// Decisions waiting to be sent, oldest first. Throws on an unreadable
    /// outbox rather than reading it as empty, which would silently lose swipes.
    func pending() throws -> [PendingRemoteDecision] {
        guard FileManager.default.fileExists(atPath: pendingFile.path) else { return [] }
        return try JSONDecoder().decode([PendingRemoteDecision].self, from: Data(contentsOf: pendingFile))
    }

    /// Queues a decision to send later; a newer decision for the same item
    /// replaces the older one.
    func enqueue(_ decision: RemoteDecision, mediaKey: String) throws {
        let list = try pending().filter { $0.mediaKey != mediaKey }
            + [PendingRemoteDecision(mediaKey: mediaKey, decision: decision)]
        try write(list, to: pendingFile)
    }

    /// POSTs queued decisions oldest first, removing each one only after the
    /// server answered. Stops at the first unreachable failure (it and the
    /// rest stay queued for the next flush). A decision the server REJECTS is
    /// dropped and its message returned in `rejected`, so one bad entry (e.g.
    /// an item removed from the album) cannot block the queue forever.
    /// `counts` is the server's totals after the last accepted POST.
    ///
    /// @MainActor is load-bearing: `enqueue` runs on the main actor (from a
    /// swipe), so pinning this here too means each read-filter-write of
    /// pending.json below runs without a swipe's write landing in between.
    /// Off the main actor, a swipe made during a POST could be overwritten.
    @MainActor
    func flushPending() async throws
        -> (counts: RemoteAlbumCounts?, rejected: [(entry: PendingRemoteDecision, message: String)]) {
        var counts: RemoteAlbumCounts?
        var rejected: [(entry: PendingRemoteDecision, message: String)] = []
        for entry in try pending() {
            do {
                counts = try await decide(mediaKey: entry.mediaKey, entry.decision)
            } catch where isUnreachable(error) {
                break
            } catch {
                rejected.append((entry, "Couldn't save \(entry.decision.rawValue): \(error)"))
            }
            // Re-read rather than drop the first element: a swipe made while
            // this POST was in flight may have appended to the file.
            try write(try pending().filter { $0 != entry }, to: pendingFile)
        }
        return (counts, rejected)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    func saveTrim(mediaKey: String, _ trim: RemoteTrim) async throws {
        try await client.postTrim(albumId: albumId, mediaKey: mediaKey, trim: trim)
    }

    func decide(mediaKey: String, _ decision: RemoteDecision) async throws -> RemoteAlbumCounts {
        try await client.postDecision(albumId: albumId, mediaKey: mediaKey, decision: decision)
    }
}
