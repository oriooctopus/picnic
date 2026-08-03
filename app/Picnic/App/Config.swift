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
}
