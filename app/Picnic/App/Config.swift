import Foundation

/// Endpoints and other build-time constants. The mirror token AND host live
/// in `MirrorToken.swift`, which CI overwrites with the real values at build
/// time (see .github/workflows/ota.yml) — never commit either here.
enum Config {
    static let mirrorHost = MirrorToken.host
    // NOTE: SPEC.md originally said 8306; the mirror server ended up on 8307
    // because 8306 was already taken on the host machine. This is the port
    // the actual `picnic-mirror` service listens on.
    static let mirrorPort = 8307

    static var mirrorQueueURL: URL {
        URL(string: "http://\(mirrorHost):\(mirrorPort)/queue")!
    }

    /// Outfits server: same host as the mirror, no auth, plain http over the tailnet.
    static let outfitsPort = 8314

    static var outfitsImportURL: URL {
        URL(string: "http://\(mirrorHost):\(outfitsPort)/api/outfits/import")!
    }

    /// Full URL for a route under the mirror server's `/reconcile` namespace.
    /// The reconcile routes share the mirror's host/port and bearer token
    /// (see ReconcileClient.swift) — only the path differs from /queue.
    static func reconcileURL(for path: String) -> URL {
        URL(string: "http://\(mirrorHost):\(mirrorPort)\(path)")!
    }
}
